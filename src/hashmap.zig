//! A hash map type with built-in YAML hooks.
//!
//! Use `ArrayHashMap(T)` as a struct field when you want to round-trip a
//! YAML mapping with string keys and values of type `T`. The wrapper
//! declares yamlParse, yamlParseFromValue, and yamlStringify so it works
//! with the standard parse and serialize entry points.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const ast = @import("ast.zig");
const decoder = @import("decode.zig");
const ParseOptions = @import("static.zig").ParseOptions;
const static = @import("static.zig");
const Stringify = @import("Stringify.zig");
const Value = @import("dynamic.zig").Value;

/// A hash map with string keys and `T` values that can be parsed from
/// a YAML object and written back out as one.
///
/// Use this as a struct field when the YAML has a mapping whose keys
/// are arbitrary strings (the names of environment variables, the
/// names of jobs in a config, anything you do not know up front) and
/// every value has the same type.
///
/// The actual map is stored in the `map` field. Items come out in the
/// order they were added. Call `deinit` to free the map if it was not
/// parsed into an arena.
///
/// Example:
/// ```zig
/// const Config = struct {
///     name: []const u8,
///     env: yaml.ArrayHashMap([]const u8),
/// };
/// const parsed = try yaml.parseFromSlice(Config, alloc, source, .{});
/// defer parsed.deinit();
/// const home = parsed.value.env.map.get("HOME").?;
/// ```
pub fn ArrayHashMap(comptime T: type) type {
    return struct {
        /// The underlying map. Use the standard hash map methods
        /// (`get`, `put`, `count`, `iterator`) to read and modify it.
        map: std.array_hash_map.String(T) = .empty,

        /// Free the map's storage. Skip this if the map was parsed
        /// into an arena that you free all at once.
        pub fn deinit(self: *@This(), allocator: Allocator) void {
            self.map.deinit(allocator);
        }

        /// Parse hook called when this type is decoded from a YAML AST
        /// node. The node must be a mapping. Every key must be a plain
        /// string. Anything else returns `error.UnexpectedToken`.
        pub fn yamlParse(
            allocator: Allocator,
            node: ast.Node,
            options: ParseOptions,
        ) !@This() {
            if (node != .mapping) return error.UnexpectedToken;
            var result: @This() = .{};
            errdefer result.map.deinit(allocator);
            for (node.mapping.values) |mv| {
                const key_node = mv.key orelse continue;
                if (key_node.* != .string) return error.UnexpectedToken;
                const key = try allocator.dupe(u8, key_node.string.value);
                const val = if (mv.value) |vn|
                    try decoder.innerParse(T, allocator, vn.*, options)
                else
                    return error.MissingField;
                try result.map.put(allocator, key, val);
            }
            return result;
        }

        /// Parse hook called when this type is decoded from a `Value`.
        /// The Value must be an `.object`. Every key inside it must be
        /// a `.string` Value. Anything else returns
        /// `error.UnexpectedToken`. Useful when you already have a
        /// `Value` and want a typed view.
        pub fn yamlParseFromValue(
            allocator: Allocator,
            source: Value,
            options: ParseOptions,
        ) !@This() {
            if (source != .object) return error.UnexpectedToken;
            var result: @This() = .{};
            errdefer result.map.deinit(allocator);
            for (source.object.keys(), source.object.values()) |k, v| {
                if (k != .string) return error.UnexpectedToken;
                const key = try allocator.dupe(u8, k.string);
                const val = try decoder.innerParseFromValue(T, allocator, v, options);
                try result.map.put(allocator, key, val);
            }
            return result;
        }

        /// Stringify hook called when this type is written as YAML.
        /// Writes one `key: value` line per entry, in the order the
        /// entries were added.
        pub fn yamlStringify(self: @This(), s: *Stringify) !void {
            try s.beginObject();
            var it = self.map.iterator();
            while (it.next()) |entry| {
                try s.objectField(entry.key_ptr.*);
                try s.write(entry.value_ptr.*);
            }
            try s.endObject();
        }
    };
}

test "ArrayHashMap round-trips" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const Map = ArrayHashMap(i64);
    var m: Map = .{};
    try m.map.put(aa, "a", 1);
    try m.map.put(aa, "b", 2);

    const out = try Stringify.valueAlloc(testing.allocator, m, .{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a: 1\nb: 2\n", out);

    const parsed = try static.parseFromSliceLeaky(
        Map,
        aa,
        "a: 1\nb: 2",
        .{},
    );
    try testing.expectEqual(@as(usize, 2), parsed.map.count());
    try testing.expectEqual(@as(i64, 1), parsed.map.get("a").?);
    try testing.expectEqual(@as(i64, 2), parsed.map.get("b").?);
}

test "ArrayHashMap as struct field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const Config = struct {
        name: []const u8,
        env: ArrayHashMap([]const u8),
    };

    const parsed = try static.parseFromSliceLeaky(
        Config,
        aa,
        \\name: app
        \\env:
        \\  HOME: /home/me
        \\  PATH: /usr/bin
    ,
        .{},
    );
    try testing.expectEqualStrings("app", parsed.name);
    try testing.expectEqual(@as(usize, 2), parsed.env.map.count());
    try testing.expectEqualStrings("/home/me", parsed.env.map.get("HOME").?);
    try testing.expectEqualStrings("/usr/bin", parsed.env.map.get("PATH").?);
}

test "ArrayHashMap from Value tree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var obj: Value.ObjectMap = .empty;
    try obj.put(aa, .{ .string = "a" }, .{ .integer = 10 });
    try obj.put(aa, .{ .string = "b" }, .{ .integer = 20 });

    const Map = ArrayHashMap(i64);
    const result = try static.parseFromValueLeaky(Map, aa, .{ .object = obj }, .{});
    try testing.expectEqual(@as(usize, 2), result.map.count());
    try testing.expectEqual(@as(i64, 10), result.map.get("a").?);
    try testing.expectEqual(@as(i64, 20), result.map.get("b").?);
}

test "ArrayHashMap empty" {
    const Map = ArrayHashMap(i64);
    const m: Map = .{};

    const out = try Stringify.valueAlloc(testing.allocator, m, .{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{}\n", out);
}

test "ArrayHashMap rejects non-mapping YAML" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const Map = ArrayHashMap(i64);
    try testing.expectError(
        error.UnexpectedToken,
        static.parseFromSliceLeaky(Map, aa, "[1, 2, 3]", .{}),
    );
}

test "ArrayHashMap rejects non-string keys from Value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var obj: Value.ObjectMap = .empty;
    try obj.put(aa, .{ .integer = 1 }, .{ .integer = 10 });

    const Map = ArrayHashMap(i64);
    try testing.expectError(
        error.UnexpectedToken,
        static.parseFromValueLeaky(Map, aa, .{ .object = obj }, .{}),
    );
}

test "ArrayHashMap of structs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const Item = struct { id: i64, label: []const u8 };
    const Map = ArrayHashMap(Item);

    const parsed = try static.parseFromSliceLeaky(
        Map,
        aa,
        \\first:
        \\  id: 1
        \\  label: one
        \\second:
        \\  id: 2
        \\  label: two
    ,
        .{},
    );
    try testing.expectEqual(@as(usize, 2), parsed.map.count());
    try testing.expectEqual(@as(i64, 1), parsed.map.get("first").?.id);
    try testing.expectEqualStrings("one", parsed.map.get("first").?.label);
    try testing.expectEqual(@as(i64, 2), parsed.map.get("second").?.id);
}

test "ArrayHashMap deinit releases memory" {
    const Map = ArrayHashMap(i64);
    var m: Map = .{};
    try m.map.put(testing.allocator, "k", 7);
    m.deinit(testing.allocator);
    // The leak detector in the test runner catches missed frees.
}

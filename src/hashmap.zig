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

pub fn ArrayHashMap(comptime T: type) type {
    return struct {
        map: std.array_hash_map.String(T) = .empty,

        pub fn deinit(self: *@This(), allocator: Allocator) void {
            self.map.deinit(allocator);
        }

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

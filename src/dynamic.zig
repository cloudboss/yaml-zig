const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const decoder = @import("decode.zig");
const Stringify = @import("Stringify.zig");
const ast = @import("ast.zig");
const ParseOptions = @import("static.zig").ParseOptions;

/// A dynamically typed YAML value.
///
/// Represents any YAML scalar, sequence, or mapping without requiring a
/// compile-time Zig type. Useful for working with YAML of unknown structure.
/// Can be used as the target type for `parseFromSlice`.
pub const Value = union(enum) {
    null,
    bool: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    array: Array,
    object: ObjectMap,

    /// Order-preserving list of values.
    pub const Array = std.ArrayList(Value);

    /// Order-preserving map keyed by `Value`.
    ///
    /// YAML 1.2 permits any node as a mapping key (integers, floats, booleans,
    /// sequences, sub-mappings); `Value` keys preserve that capability while
    /// keeping the std.json-style `put`/`get`/`iterator` interface.
    pub const ObjectMap = std.array_hash_map.Custom(
        Value,
        Value,
        ValueContext,
        true,
    );

    /// Hash and equality context for `ObjectMap`. Stateless.
    pub const ValueContext = struct {
        pub fn hash(_: ValueContext, key: Value) u32 {
            var h = std.hash.Wyhash.init(0);
            hashValue(&h, key);
            return @truncate(h.final());
        }
        pub fn eql(_: ValueContext, a: Value, b: Value, _: usize) bool {
            return a.eql(b);
        }
    };

    /// If this is an object, look up an entry by its string key.
    /// Returns null if the value is not an object or no such key exists.
    pub fn objectGet(self: Value, name: []const u8) ?Value {
        return switch (self) {
            .object => |o| o.get(.{ .string = name }),
            else => null,
        };
    }

    /// Deep equality.
    pub fn eql(self: Value, other: Value) bool {
        const Tag = std.meta.Tag(Value);
        if (@as(Tag, self) != @as(Tag, other)) return false;
        return switch (self) {
            .null => true,
            .bool => |b| b == other.bool,
            .integer => |i| i == other.integer,
            .float => |f| @as(u64, @bitCast(f)) == @as(u64, @bitCast(other.float)),
            .string => |s| std.mem.eql(u8, s, other.string),
            .array => |arr| blk: {
                const rhs = other.array;
                if (arr.items.len != rhs.items.len) break :blk false;
                for (arr.items, rhs.items) |x, y| if (!x.eql(y)) break :blk false;
                break :blk true;
            },
            .object => |obj| blk: {
                const rhs = other.object;
                if (obj.count() != rhs.count()) break :blk false;
                for (obj.keys(), obj.values(), rhs.keys(), rhs.values()) |k1, v1, k2, v2| {
                    if (!k1.eql(k2)) break :blk false;
                    if (!v1.eql(v2)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    /// Write a YAML representation of `self` to `writer`. Useful for
    /// debug printing.
    pub fn dump(self: Value, writer: *std.Io.Writer) Stringify.Error!void {
        try Stringify.value(self, .{}, writer);
    }

    /// Decode an AST node into a `Value`. Custom hook for the type, called
    /// automatically when `T == Value` is the parse target.
    pub fn yamlParse(
        allocator: Allocator,
        node: ast.Node,
        options: ParseOptions,
    ) !Value {
        var anchors = decoder.AnchorMap.init(allocator);
        defer anchors.deinit();
        return decoder.decodeToValue(allocator, node, options, &anchors);
    }

    /// Identity decode for `Value`. Performs a deep clone so the result
    /// owns its own memory.
    pub fn yamlParseFromValue(
        allocator: Allocator,
        source: Value,
        options: ParseOptions,
    ) !Value {
        _ = options;
        return decoder.cloneValue(allocator, source);
    }

    /// Emit `self` as YAML through the streaming Stringify writer. Honors
    /// the writer's `flow_style` option.
    pub fn yamlStringify(self: Value, s: *Stringify) !void {
        if (s.options.flow_style) {
            return Stringify.writeFlowValueUnion(s.writer, self, s.options);
        }
        return Stringify.writeValueUnion(s.writer, self, s.indent_level, s.options);
    }
};

fn hashValue(h: *std.hash.Wyhash, v: Value) void {
    const tag: u8 = @intFromEnum(@as(std.meta.Tag(Value), v));
    h.update(std.mem.asBytes(&tag));
    switch (v) {
        .null => {},
        .bool => |b| h.update(std.mem.asBytes(&b)),
        .integer => |i| h.update(std.mem.asBytes(&i)),
        .float => |f| {
            const bits: u64 = @bitCast(f);
            h.update(std.mem.asBytes(&bits));
        },
        .string => |s| h.update(s),
        .array => |arr| {
            const len: usize = arr.items.len;
            h.update(std.mem.asBytes(&len));
            for (arr.items) |item| hashValue(h, item);
        },
        .object => |obj| {
            const n: usize = obj.count();
            h.update(std.mem.asBytes(&n));
            for (obj.keys(), obj.values()) |k, val| {
                hashValue(h, k);
                hashValue(h, val);
            }
        },
    }
}

test "Value eql null" {
    const a: Value = .null;
    const b: Value = .null;
    try testing.expect(a.eql(b));
}

test "Value eql bool" {
    try testing.expect((Value{ .bool = true }).eql(.{ .bool = true }));
    try testing.expect(!(Value{ .bool = true }).eql(.{ .bool = false }));
}

test "Value eql integer" {
    try testing.expect((Value{ .integer = 42 }).eql(.{ .integer = 42 }));
    try testing.expect(!(Value{ .integer = 42 }).eql(.{ .integer = 43 }));
}

test "Value eql float" {
    try testing.expect((Value{ .float = 3.14 }).eql(.{ .float = 3.14 }));
}

test "Value eql string" {
    try testing.expect((Value{ .string = "hello" }).eql(.{ .string = "hello" }));
    try testing.expect(!(Value{ .string = "hello" }).eql(.{ .string = "world" }));
}

test "Value eql different tags" {
    try testing.expect(!(Value{ .integer = 0 }).eql(.null));
    try testing.expect(!(Value{ .integer = 42 }).eql(.{ .string = "42" }));
}

test "Value eql array" {
    var aa = std.heap.ArenaAllocator.init(testing.allocator);
    defer aa.deinit();
    const alloc = aa.allocator();

    var a: Value.Array = .empty;
    try a.appendSlice(alloc, &.{ .{ .integer = 1 }, .{ .integer = 2 } });

    var b: Value.Array = .empty;
    try b.appendSlice(alloc, &.{ .{ .integer = 1 }, .{ .integer = 2 } });

    try testing.expect((Value{ .array = a }).eql(.{ .array = b }));
}

test "Value eql array length mismatch" {
    var aa = std.heap.ArenaAllocator.init(testing.allocator);
    defer aa.deinit();
    const alloc = aa.allocator();

    var a: Value.Array = .empty;
    try a.append(alloc, .{ .integer = 1 });

    var b: Value.Array = .empty;
    try b.appendSlice(alloc, &.{ .{ .integer = 1 }, .{ .integer = 2 } });

    try testing.expect(!(Value{ .array = a }).eql(.{ .array = b }));
}

test "Value eql object" {
    var aa = std.heap.ArenaAllocator.init(testing.allocator);
    defer aa.deinit();
    const alloc = aa.allocator();

    var a: Value.ObjectMap = .empty;
    try a.put(alloc, .{ .string = "x" }, .{ .integer = 1 });

    var b: Value.ObjectMap = .empty;
    try b.put(alloc, .{ .string = "x" }, .{ .integer = 1 });

    try testing.expect((Value{ .object = a }).eql(.{ .object = b }));
}

test "objectGet" {
    var aa = std.heap.ArenaAllocator.init(testing.allocator);
    defer aa.deinit();
    const alloc = aa.allocator();

    var obj: Value.ObjectMap = .empty;
    try obj.put(alloc, .{ .string = "name" }, .{ .string = "ada" });

    const v = Value{ .object = obj };
    const got = v.objectGet("name") orelse return error.TestExpectedValue;
    try testing.expectEqualStrings("ada", got.string);
    try testing.expectEqual(@as(?Value, null), v.objectGet("missing"));
}

test "ObjectMap accepts non-string keys" {
    var aa = std.heap.ArenaAllocator.init(testing.allocator);
    defer aa.deinit();
    const alloc = aa.allocator();

    var obj: Value.ObjectMap = .empty;
    try obj.put(alloc, .{ .integer = 1 }, .{ .string = "v" });
    try obj.put(alloc, .{ .bool = true }, .{ .string = "w" });

    try testing.expectEqual(@as(usize, 2), obj.count());
    try testing.expectEqualStrings("v", obj.get(.{ .integer = 1 }).?.string);
    try testing.expectEqualStrings("w", obj.get(.{ .bool = true }).?.string);
}

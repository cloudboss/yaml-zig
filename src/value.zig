const std = @import("std");
const testing = std.testing;

/// A dynamically-typed YAML value.
///
/// Represents any YAML scalar, sequence, or mapping without requiring a
/// compile-time Zig type. Useful for working with YAML of unknown structure.
/// Can be used as the target type for `parseFromSlice`.
pub const Value = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    sequence: []const Value,
    mapping: Mapping,

    /// A YAML mapping represented as parallel key/value slices.
    pub const Mapping = struct {
        keys: []const Value,
        values: []const Value,
    };

    /// Look up a string key in a mapping value.
    /// Returns null if this is not a mapping or the key is not found.
    pub fn mappingGet(
        self: Value,
        key: []const u8,
    ) ?Value {
        switch (self) {
            .mapping => |m| {
                for (m.keys, m.values) |k, v| {
                    switch (k) {
                        .string => |s| {
                            if (std.mem.eql(u8, s, key))
                                return v;
                        },
                        else => {},
                    }
                }
                return null;
            },
            else => return null,
        }
    }

    /// Deep equality comparison between two values.
    pub fn eql(self: Value, other: Value) bool {
        const Tag = std.meta.Tag(Value);
        const self_tag: Tag = self;
        const other_tag: Tag = other;
        if (self_tag != other_tag) return false;

        return switch (self) {
            .null => true,
            .boolean => |b| b == other.boolean,
            .integer => |i| i == other.integer,
            .float => |f| f == other.float,
            .string => |s| std.mem.eql(
                u8,
                s,
                other.string,
            ),
            .sequence => |seq| {
                const other_seq = other.sequence;
                if (seq.len != other_seq.len) return false;
                for (seq, other_seq) |a, b| {
                    if (!a.eql(b)) return false;
                }
                return true;
            },
            .mapping => |m| {
                const om = other.mapping;
                if (m.keys.len != om.keys.len) {
                    return false;
                }
                for (
                    m.keys,
                    m.values,
                    om.keys,
                    om.values,
                ) |k1, v1, k2, v2| {
                    if (!k1.eql(k2)) return false;
                    if (!v1.eql(v2)) return false;
                }
                return true;
            },
        };
    }
};

test "Value eql null" {
    const a: Value = .null;
    const b: Value = .null;
    try testing.expect(a.eql(b));
}

test "Value eql boolean true" {
    const a = Value{ .boolean = true };
    const b = Value{ .boolean = true };
    try testing.expect(a.eql(b));
}

test "Value eql boolean false mismatch" {
    const a = Value{ .boolean = true };
    const b = Value{ .boolean = false };
    try testing.expect(!a.eql(b));
}

test "Value eql integer" {
    const a = Value{ .integer = 42 };
    const b = Value{ .integer = 42 };
    try testing.expect(a.eql(b));
}

test "Value eql integer mismatch" {
    const a = Value{ .integer = 42 };
    const b = Value{ .integer = 43 };
    try testing.expect(!a.eql(b));
}

test "Value eql float" {
    const a = Value{ .float = 3.14 };
    const b = Value{ .float = 3.14 };
    try testing.expect(a.eql(b));
}

test "Value eql string" {
    const a = Value{ .string = "hello" };
    const b = Value{ .string = "hello" };
    try testing.expect(a.eql(b));
}

test "Value eql string mismatch" {
    const a = Value{ .string = "hello" };
    const b = Value{ .string = "world" };
    try testing.expect(!a.eql(b));
}

test "Value eql sequence" {
    const items_a = [_]Value{
        Value{ .integer = 1 },
        Value{ .integer = 2 },
    };
    const items_b = [_]Value{
        Value{ .integer = 1 },
        Value{ .integer = 2 },
    };
    const a = Value{ .sequence = &items_a };
    const b = Value{ .sequence = &items_b };
    try testing.expect(a.eql(b));
}

test "Value eql sequence length mismatch" {
    const items_a = [_]Value{Value{ .integer = 1 }};
    const items_b = [_]Value{
        Value{ .integer = 1 },
        Value{ .integer = 2 },
    };
    const a = Value{ .sequence = &items_a };
    const b = Value{ .sequence = &items_b };
    try testing.expect(!a.eql(b));
}

test "Value eql mapping" {
    const keys = [_]Value{Value{ .string = "a" }};
    const vals = [_]Value{Value{ .integer = 1 }};
    const a = Value{
        .mapping = .{ .keys = &keys, .values = &vals },
    };
    const b = Value{
        .mapping = .{ .keys = &keys, .values = &vals },
    };
    try testing.expect(a.eql(b));
}

test "Value eql different types" {
    const a = Value{ .integer = 42 };
    const b = Value{ .string = "42" };
    try testing.expect(!a.eql(b));
}

test "Value null not equal to integer" {
    const a: Value = .null;
    const b = Value{ .integer = 0 };
    try testing.expect(!a.eql(b));
}

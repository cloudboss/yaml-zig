const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const Node = @import("ast.zig").Node;
const Value = @import("value.zig").Value;

pub const DecodeOptions = struct {
    disallow_unknown_fields: bool = false,
    max_depth: u32 = 10_000,
};

pub fn decode(
    comptime T: type,
    allocator: Allocator,
    source: []const u8,
    options: DecodeOptions,
) !T {
    _ = allocator;
    _ = source;
    _ = options;
    return error.Unimplemented;
}

pub fn decodeNode(comptime T: type, allocator: Allocator, node: Node, options: DecodeOptions) !T {
    _ = allocator;
    _ = node;
    _ = options;
    return error.Unimplemented;
}

fn testDecode(comptime T: type, source: []const u8) !T {
    return decode(T, testing.allocator, source, .{});
}

fn testDecodeStrict(comptime T: type, source: []const u8) !T {
    return decode(T, testing.allocator, source, .{
        .disallow_unknown_fields = true,
    });
}

fn expectValueString(v: Value, key: []const u8, expected: []const u8) !void {
    const val = v.mappingGet(key) orelse return error.TestExpectedValue;
    switch (val) {
        .string => |s| try testing.expectEqualStrings(
            expected,
            s,
        ),
        else => return error.TestExpectedEqual,
    }
}

fn expectValueInt(v: Value, key: []const u8, expected: i64) !void {
    const val = v.mappingGet(key) orelse return error.TestExpectedValue;
    switch (val) {
        .integer => |i| try testing.expectEqual(
            expected,
            i,
        ),
        else => return error.TestExpectedEqual,
    }
}

fn expectValueBool(v: Value, key: []const u8, expected: bool) !void {
    const val = v.mappingGet(key) orelse return error.TestExpectedValue;
    switch (val) {
        .boolean => |b| try testing.expectEqual(
            expected,
            b,
        ),
        else => return error.TestExpectedEqual,
    }
}

fn expectValueNull(v: Value, key: []const u8) !void {
    const val = v.mappingGet(key) orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(std.meta.Tag(Value), .null), @as(std.meta.Tag(Value), val));
}

fn expectValueFloat(v: Value, key: []const u8, expected: f64, tolerance: f64) !void {
    const val = v.mappingGet(key) orelse return error.TestExpectedValue;
    switch (val) {
        .float => |f| try testing.expectApproxEqAbs(
            expected,
            f,
            tolerance,
        ),
        else => return error.TestExpectedEqual,
    }
}

fn expectValuePosInf(v: Value, key: []const u8) !void {
    const val = v.mappingGet(key) orelse return error.TestExpectedValue;
    switch (val) {
        .float => |f| try testing.expect(
            std.math.isPositiveInf(f),
        ),
        else => return error.TestExpectedEqual,
    }
}

fn expectValueNegInf(v: Value, key: []const u8) !void {
    const val = v.mappingGet(key) orelse return error.TestExpectedValue;
    switch (val) {
        .float => |f| try testing.expect(
            std.math.isNegativeInf(f),
        ),
        else => return error.TestExpectedEqual,
    }
}

fn expectValueNan(v: Value, key: []const u8) !void {
    const val = v.mappingGet(key) orelse return error.TestExpectedValue;
    switch (val) {
        .float => |f| try testing.expect(
            std.math.isNan(f),
        ),
        else => return error.TestExpectedEqual,
    }
}

test "v: hi decoded as string" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: hi\n");
    try testing.expectEqualStrings("hi", r.v);
}

test "v: quoted true as string" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: \"true\"\n");
    try testing.expectEqualStrings("true", r.v);
}

test "v: quoted false as string" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: \"false\"\n");
    try testing.expectEqualStrings("false", r.v);
}

test "v: true as Value bool" {
    const r = try testDecode(Value, "v: true\n");
    try expectValueBool(r, "v", true);
}

test "v: true as string yields true" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: true\n");
    try testing.expectEqualStrings("true", r.v);
}

test "v: 10 as string" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: 10\n");
    try testing.expectEqualStrings("10", r.v);
}

test "v: -10 as string" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: -10\n");
    try testing.expectEqualStrings("-10", r.v);
}

test "v: 1.234 as string" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: 1.234\n");
    try testing.expectEqualStrings("1.234", r.v);
}

test "v: leading space string" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: \" foo\"\n");
    try testing.expectEqualStrings(" foo", r.v);
}

test "v: trailing space string" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: \"foo \"\n");
    try testing.expectEqualStrings("foo ", r.v);
}

test "v: both space string" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: \" foo \"\n");
    try testing.expectEqualStrings(" foo ", r.v);
}

test "v: false as bool" {
    const S = struct { v: bool };
    const r = try testDecode(S, "v: false\n");
    try testing.expect(!r.v);
}

test "v: 10 as int" {
    const S = struct { v: i64 };
    const r = try testDecode(S, "v: 10\n");
    try testing.expectEqual(@as(i64, 10), r.v);
}

test "decode integer from string" {
    const r = try testDecode(i64, "42");
    try testing.expectEqual(@as(i64, 42), r);
}

test "v: 10 as Value integer" {
    const r = try testDecode(Value, "v: 10");
    try expectValueInt(r, "v", 10);
}

test "v: 0b10 as Value" {
    const r = try testDecode(Value, "v: 0b10");
    try expectValueInt(r, "v", 2);
}

test "v: -0b101010 as Value" {
    const r = try testDecode(Value, "v: -0b101010");
    try expectValueInt(r, "v", -42);
}

test "v: min i64 via binary" {
    const S = struct { v: i64 };
    const r = try testDecode(
        S,
        "v: -0b1000000000000000000000000000000000000000000000000000000000000000",
    );
    try testing.expectEqual(std.math.minInt(i64), r.v);
}

test "v: 0xA as Value" {
    const r = try testDecode(Value, "v: 0xA");
    try expectValueInt(r, "v", 10);
}

test "v: .1 as Value float" {
    const r = try testDecode(Value, "v: .1");
    try expectValueFloat(r, "v", 0.1, 0.001);
}

test "v: -.1 as Value float" {
    const r = try testDecode(Value, "v: -.1");
    try expectValueFloat(r, "v", -0.1, 0.001);
}

test "decode negative integer" {
    const r = try testDecode(i64, "-10");
    try testing.expectEqual(@as(i64, -10), r);
}

test "v: -10 as struct int" {
    const S = struct { v: i64 };
    const r = try testDecode(S, "v: -10\n");
    try testing.expectEqual(@as(i64, -10), r.v);
}

test "decode large integer" {
    const r = try testDecode(i64, "4294967296");
    try testing.expectEqual(@as(i64, 4294967296), r);
}

test "v: 0.1 as Value float" {
    const r = try testDecode(Value, "v: 0.1\n");
    try expectValueFloat(r, "v", 0.1, 0.001);
}

test "v: 0.99 as f32" {
    const S = struct { v: f32 };
    const r = try testDecode(S, "v: 0.99\n");
    try testing.expectApproxEqAbs(@as(f32, 0.99), r.v, 0.01);
}

test "v: -0.1 as f64" {
    const S = struct { v: f64 };
    const r = try testDecode(S, "v: -0.1\n");
    try testing.expectApproxEqAbs(@as(f64, -0.1), r.v, 0.001);
}

test "v: 6.8523e+5 as Value" {
    const r = try testDecode(Value, "v: 6.8523e+5");
    try expectValueFloat(r, "v", 685230.0, 0.1);
}

test "v: 685.230_15e+03 as Value" {
    const r = try testDecode(Value, "v: 685.230_15e+03");
    try expectValueFloat(r, "v", 685230.15, 0.1);
}

test "v: 685_230.15 as Value" {
    const r = try testDecode(Value, "v: 685_230.15");
    try expectValueFloat(r, "v", 685230.15, 0.01);
}

test "v: 685_230.15 as f64" {
    const S = struct { v: f64 };
    const r = try testDecode(S, "v: 685_230.15");
    try testing.expectApproxEqAbs(@as(f64, 685230.15), r.v, 0.01);
}

test "v: 685230 as Value integer" {
    const r = try testDecode(Value, "v: 685230");
    try expectValueInt(r, "v", 685230);
}

test "v: +685_230 as Value" {
    const r = try testDecode(Value, "v: +685_230");
    try expectValueInt(r, "v", 685230);
}

test "v: 02472256 octal as Value" {
    const r = try testDecode(Value, "v: 02472256");
    try expectValueInt(r, "v", 685230);
}

test "v: 0x_0A_74_AE as Value" {
    const r = try testDecode(Value, "v: 0x_0A_74_AE");
    try expectValueInt(r, "v", 685230);
}

test "v: binary with underscores as Value" {
    const r = try testDecode(Value, "v: 0b1010_0111_0100_1010_1110");
    try expectValueInt(r, "v", 685230);
}

test "v: +685_230 as int" {
    const S = struct { v: i64 };
    const r = try testDecode(S, "v: +685_230");
    try testing.expectEqual(@as(i64, 685230), r.v);
}

test "v: True as Value bool" {
    const r = try testDecode(Value, "v: True");
    try expectValueBool(r, "v", true);
}

test "v: TRUE as Value bool" {
    const r = try testDecode(Value, "v: TRUE");
    try expectValueBool(r, "v", true);
}

test "v: False as Value bool" {
    const r = try testDecode(Value, "v: False");
    try expectValueBool(r, "v", false);
}

test "v: FALSE as Value bool" {
    const r = try testDecode(Value, "v: FALSE");
    try expectValueBool(r, "v", false);
}

test "v: y is string not bool" {
    const r = try testDecode(Value, "v: y");
    try expectValueString(r, "v", "y");
}

test "v: NO is string not bool" {
    const r = try testDecode(Value, "v: NO");
    try expectValueString(r, "v", "NO");
}

test "v: on is string not bool" {
    const r = try testDecode(Value, "v: on");
    try expectValueString(r, "v", "on");
}

test "v: 42 as u32" {
    const S = struct { v: u32 };
    const r = try testDecode(S, "v: 42");
    try testing.expectEqual(@as(u32, 42), r.v);
}

test "v: 4294967296 as u64" {
    const S = struct { v: u64 };
    const r = try testDecode(S, "v: 4294967296");
    try testing.expectEqual(@as(u64, 4294967296), r.v);
}

test "v: max i32" {
    const S = struct { v: i32 };
    const r = try testDecode(S, "v: 2147483647");
    try testing.expectEqual(std.math.maxInt(i32), r.v);
}

test "v: min i32" {
    const S = struct { v: i32 };
    const r = try testDecode(S, "v: -2147483648");
    try testing.expectEqual(std.math.minInt(i32), r.v);
}

test "decode max i64" {
    const r = try testDecode(i64, "9223372036854775807");
    try testing.expectEqual(std.math.maxInt(i64), r);
}

test "v: max i64 via binary" {
    const S = struct { v: i64 };
    const r = try testDecode(
        S,
        "v: 0b111111111111111111111111111111111111111111111111111111111111111",
    );
    try testing.expectEqual(std.math.maxInt(i64), r.v);
}

test "decode min i64" {
    const r = try testDecode(i64, "-9223372036854775808");
    try testing.expectEqual(std.math.minInt(i64), r);
}

test "v: negative max i64 via binary" {
    const S = struct { v: i64 };
    const r = try testDecode(
        S,
        "v: -0b1111111111111111111111111111111111111111111111111111111111111111",
    );
    try testing.expectEqual(-std.math.maxInt(i64), r.v);
}

test "v: 0 as u32" {
    const S = struct { v: u32 };
    const r = try testDecode(S, "v: 0");
    try testing.expectEqual(@as(u32, 0), r.v);
}

test "v: max u32" {
    const S = struct { v: u32 };
    const r = try testDecode(S, "v: 4294967295");
    try testing.expectEqual(std.math.maxInt(u32), r.v);
}

test "v: 1e3 as u32" {
    const S = struct { v: u32 };
    const r = try testDecode(S, "v: 1e3");
    try testing.expectEqual(@as(u32, 1000), r.v);
}

test "v: max u64" {
    const S = struct { v: u64 };
    const r = try testDecode(S, "v: 18446744073709551615");
    try testing.expectEqual(std.math.maxInt(u64), r.v);
}

test "v: max u64 via binary" {
    const S = struct { v: u64 };
    const r = try testDecode(
        S,
        "v: 0b1111111111111111111111111111111111111111111111111111111111111111",
    );
    try testing.expectEqual(std.math.maxInt(u64), r.v);
}

test "v: max i64 as u64" {
    const S = struct { v: u64 };
    const r = try testDecode(S, "v: 9223372036854775807");
    try testing.expectEqual(@as(u64, std.math.maxInt(i64)), r.v);
}

test "v: 1e3 as u64" {
    const S = struct { v: u64 };
    const r = try testDecode(S, "v: 1e3");
    try testing.expectEqual(@as(u64, 1000), r.v);
}

test "v: 1e-06 as f32" {
    const S = struct { v: f32 };
    const r = try testDecode(S, "v: 1e-06");
    try testing.expectApproxEqAbs(@as(f32, 1e-6), r.v, 1e-8);
}

test "v: 1e-06 as f64" {
    const S = struct { v: f64 };
    const r = try testDecode(S, "v: 1e-06");
    try testing.expectApproxEqAbs(@as(f64, 1e-06), r.v, 1e-10);
}

test "decode hex integer" {
    const r = try testDecode(i64, "0xA");
    try testing.expectEqual(@as(i64, 10), r);
}

test "decode hex with underscores" {
    const r = try testDecode(i64, "0x_0A_74_AE");
    try testing.expectEqual(@as(i64, 685230), r);
}

test "decode octal 0o prefix" {
    const r = try testDecode(i64, "0o2472256");
    try testing.expectEqual(@as(i64, 685230), r);
}

test "decode octal legacy prefix" {
    const r = try testDecode(i64, "02472256");
    try testing.expectEqual(@as(i64, 685230), r);
}

test "decode binary integer" {
    const r = try testDecode(i64, "0b1010");
    try testing.expectEqual(@as(i64, 10), r);
}

test "decode negative binary" {
    const r = try testDecode(i64, "-0b101010");
    try testing.expectEqual(@as(i64, -42), r);
}

test "decode i32" {
    const r = try testDecode(i32, "42");
    try testing.expectEqual(@as(i32, 42), r);
}

test "decode u16" {
    const r = try testDecode(u16, "8080");
    try testing.expectEqual(@as(u16, 8080), r);
}

test "decode float" {
    const r = try testDecode(f64, "3.14");
    try testing.expectApproxEqAbs(@as(f64, 3.14), r, 0.001);
}

test "decode negative float" {
    const r = try testDecode(f64, "-0.1");
    try testing.expectApproxEqAbs(@as(f64, -0.1), r, 0.001);
}

test "decode leading dot float" {
    const r = try testDecode(f64, ".1");
    try testing.expectApproxEqAbs(@as(f64, 0.1), r, 0.001);
}

test "decode negative leading dot" {
    const r = try testDecode(f64, "-.1");
    try testing.expectApproxEqAbs(@as(f64, -0.1), r, 0.001);
}

test "decode scientific notation" {
    const r = try testDecode(f64, "6.8523e+5");
    try testing.expectApproxEqAbs(@as(f64, 685230.0), r, 0.1);
}

test "decode float with underscores" {
    const r = try testDecode(f64, "685_230.15");
    try testing.expectApproxEqAbs(@as(f64, 685230.15), r, 0.01);
}

test "decode f32" {
    const r = try testDecode(f32, "0.99");
    try testing.expectApproxEqAbs(@as(f32, 0.99), r, 0.01);
}

test "decode bool true" {
    const r = try testDecode(bool, "true");
    try testing.expect(r);
}

test "decode bool True" {
    const r = try testDecode(bool, "True");
    try testing.expect(r);
}

test "decode bool TRUE" {
    const r = try testDecode(bool, "TRUE");
    try testing.expect(r);
}

test "decode bool false" {
    const r = try testDecode(bool, "false");
    try testing.expect(!r);
}

test "decode bool False" {
    const r = try testDecode(bool, "False");
    try testing.expect(!r);
}

test "decode bool FALSE" {
    const r = try testDecode(bool, "FALSE");
    try testing.expect(!r);
}

test "decode string" {
    const r = try testDecode([]const u8, "hello");
    try testing.expectEqualStrings("hello", r);
}

test "decode quoted string" {
    const r = try testDecode([]const u8, "\"hello world\"");
    try testing.expectEqualStrings("hello world", r);
}

test "decode null to optional" {
    const r = try testDecode(?i64, "null");
    try testing.expect(r == null);
}

test "decode Null to optional" {
    const r = try testDecode(?i64, "Null");
    try testing.expect(r == null);
}

test "decode NULL to optional" {
    const r = try testDecode(?i64, "NULL");
    try testing.expect(r == null);
}

test "decode tilde to optional" {
    const r = try testDecode(?i64, "~");
    try testing.expect(r == null);
}

test "decode empty to optional" {
    const r = try testDecode(?[]const u8, "");
    try testing.expect(r == null);
}

test "null as pointer" {
    const r = try testDecode(?i64, "null");
    try testing.expect(r == null);
}

test "tilde as pointer" {
    const r = try testDecode(?i64, "~");
    try testing.expect(r == null);
}

test "v: empty value as null in Value" {
    const r = try testDecode(Value, "v:");
    try expectValueNull(r, "v");
}

test "v: tilde as null in Value" {
    const r = try testDecode(Value, "v: ~");
    try expectValueNull(r, "v");
}

test "v: null as Value" {
    const r = try testDecode(Value, "v: null");
    try expectValueNull(r, "v");
}

test "v: Null as Value" {
    const r = try testDecode(Value, "v: Null");
    try expectValueNull(r, "v");
}

test "v: NULL as Value" {
    const r = try testDecode(Value, "v: NULL");
    try expectValueNull(r, "v");
}

test "v: null to optional string is null" {
    const S = struct { v: ?[]const u8 };
    const r = try testDecode(S, "v: null");
    try testing.expect(r.v == null);
}

test "v: null to string is empty" {
    const S = struct { v: []const u8 = "" };
    const r = try testDecode(S, "v: null");
    try testing.expectEqualStrings("", r.v);
}

test "v: tilde to optional string is null" {
    const S = struct { v: ?[]const u8 };
    const r = try testDecode(S, "v: ~");
    try testing.expect(r.v == null);
}

test "v: tilde to string is empty" {
    const S = struct { v: []const u8 = "" };
    const r = try testDecode(S, "v: ~");
    try testing.expectEqualStrings("", r.v);
}

test "decode simple struct" {
    const Config = struct {
        name: []const u8,
        port: u16,
    };
    const r = try testDecode(Config, "name: app\nport: 8080");
    try testing.expectEqualStrings("app", r.name);
    try testing.expectEqual(@as(u16, 8080), r.port);
}

test "decode nested struct" {
    const Inner = struct { b: []const u8 };
    const Outer = struct { a: Inner };
    const r = try testDecode(Outer, "a:\n  b: c");
    try testing.expectEqualStrings("c", r.a.b);
}

test "decode struct with optional field" {
    const Config = struct {
        name: []const u8,
        port: ?u16 = null,
    };
    const r = try testDecode(Config, "name: app");
    try testing.expectEqualStrings("app", r.name);
    try testing.expect(r.port == null);
}

test "decode struct with default value" {
    const Config = struct {
        name: []const u8,
        port: u16 = 3000,
    };
    const r = try testDecode(Config, "name: app");
    try testing.expectEqualStrings("app", r.name);
    try testing.expectEqual(@as(u16, 3000), r.port);
}

test "decode struct with custom yamlParse" {
    const Config = struct {
        api_key: []const u8,
        max_retries: i64,

        pub fn yamlParse(allocator: Allocator, node: Node) !@This() {
            const v = try decodeNode(Value, allocator, node, .{});
            return .{
                .api_key = (v.mappingGet("apiKey") orelse
                    return error.MissingField).string,
                .max_retries = (v.mappingGet("maxRetries") orelse
                    return error.MissingField).integer,
            };
        }
    };
    const r = try testDecode(Config,
        \\apiKey: secret123
        \\maxRetries: 5
        \\
    );
    try testing.expectEqualStrings("secret123", r.api_key);
    try testing.expectEqual(@as(i64, 5), r.max_retries);
}

test "decode struct hello world" {
    const S = struct { hello: []const u8 };
    const r = try testDecode(S, "hello: world");
    try testing.expectEqualStrings("world", r.hello);
}

test "decode struct nested flow mapping" {
    const Inner = struct { b: []const u8 };
    const Outer = struct { a: Inner };
    const r = try testDecode(Outer, "a: {b: c}");
    try testing.expectEqualStrings("c", r.a.b);
}

test "decode struct empty map field" {
    const S = struct { a: ?[]const u8 = null };
    const r = try testDecode(S, "a:");
    try testing.expect(r.a == null);
}

test "decode struct a: 1 as int" {
    const S = struct { a: i64 };
    const r = try testDecode(S, "a: 1");
    try testing.expectEqual(@as(i64, 1), r.a);
}

test "decode struct a: 1 as f64" {
    const S = struct { a: f64 };
    const r = try testDecode(S, "a: 1");
    try testing.expectApproxEqAbs(
        @as(f64, 1.0),
        r.a,
        0.001,
    );
}

test "decode struct a: 1.0 as int" {
    const S = struct { a: i64 };
    const r = try testDecode(S, "a: 1.0");
    try testing.expectEqual(@as(i64, 1), r.a);
}

test "decode struct a: 1.0 as u32" {
    const S = struct { a: u32 };
    const r = try testDecode(S, "a: 1.0");
    try testing.expectEqual(@as(u32, 1), r.a);
}

test "decode struct with int slice" {
    const S = struct { a: []const i64 };
    const r = try testDecode(S, "a: [1, 2]");
    try testing.expectEqual(@as(usize, 2), r.a.len);
    try testing.expectEqual(@as(i64, 1), r.a[0]);
    try testing.expectEqual(@as(i64, 2), r.a[1]);
}

test "decode struct unmatched field" {
    const S = struct { b: i64 = 0 };
    const r = try testDecode(S, "a: 1");
    try testing.expectEqual(@as(i64, 0), r.b);
}

test "decode struct with default field override" {
    const S = struct {
        a: []const u8,
        b: i64 = 0,
    };
    const r = try testDecode(S,
        \\a: b
        \\b: 2
        \\
    );
    try testing.expectEqualStrings("b", r.a);
    try testing.expectEqual(@as(i64, 2), r.b);
}

test "decode slice of strings" {
    const result = try testDecode(
        []const []const u8,
        \\- a
        \\- b
        \\- c
        ,
    );
    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqualStrings("a", result[0]);
    try testing.expectEqualStrings("b", result[1]);
    try testing.expectEqualStrings("c", result[2]);
}

test "decode slice of integers" {
    const result = try testDecode(
        []const i64,
        \\- 1
        \\- 2
        \\- 3
        ,
    );
    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqual(@as(i64, 1), result[0]);
    try testing.expectEqual(@as(i64, 2), result[1]);
    try testing.expectEqual(@as(i64, 3), result[2]);
}

test "decode flow sequence" {
    const r = try testDecode([]const []const u8, "[A, B, C]");
    try testing.expectEqual(@as(usize, 3), r.len);
    try testing.expectEqualStrings("A", r[0]);
}

test "flow sequence with trailing comma" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(S, "v: [A,B,C,]");
    try testing.expectEqual(@as(usize, 3), r.v.len);
    try testing.expectEqualStrings("A", r.v[0]);
    try testing.expectEqualStrings("B", r.v[1]);
    try testing.expectEqualStrings("C", r.v[2]);
}

test "flow sequence mixed types as strings" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(S, "v: [A,1,C]");
    try testing.expectEqual(@as(usize, 3), r.v.len);
    try testing.expectEqualStrings("A", r.v[0]);
    try testing.expectEqualStrings("1", r.v[1]);
    try testing.expectEqualStrings("C", r.v[2]);
}

test "flow sequence mixed as Value" {
    const r = try testDecode(Value, "v: [A,1,C]");
    const seq = r.mappingGet("v") orelse return error.TestExpectedValue;
    switch (seq) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 3), s.len);
            try testing.expectEqualStrings("A", s[0].string);
            try testing.expectEqual(@as(i64, 1), s[1].integer);
            try testing.expectEqualStrings("C", s[2].string);
        },
        else => return error.TestExpectedEqual,
    }
}

test "flow sequence of mappings" {
    const r = try testDecode(Value, "v: [a: b, c: d]");
    const seq = r.mappingGet("v") orelse return error.TestExpectedValue;
    switch (seq) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 2), s.len);
            const m0 = s[0].mappingGet("a") orelse return error.TestExpectedValue;
            try testing.expectEqualStrings("b", m0.string);
            const m1 = s[1].mappingGet("c") orelse return error.TestExpectedValue;
            try testing.expectEqualStrings("d", m1.string);
        },
        else => return error.TestExpectedEqual,
    }
}

test "flow sequence of flow mappings" {
    const r = try testDecode(Value, "v: [{a: b}, {c: d, e: f}]");
    const seq = r.mappingGet("v") orelse return error.TestExpectedValue;
    switch (seq) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 2), s.len);
            const m0 = s[0].mappingGet("a") orelse return error.TestExpectedValue;
            try testing.expectEqualStrings("b", m0.string);
            const m1 = s[1].mappingGet("c") orelse return error.TestExpectedValue;
            try testing.expectEqualStrings("d", m1.string);
            const m2 = s[1].mappingGet("e") orelse return error.TestExpectedValue;
            try testing.expectEqualStrings("f", m2.string);
        },
        else => return error.TestExpectedEqual,
    }
}

test "block sequence as Value" {
    const r = try testDecode(
        Value,
        \\v:
        \\ - A
        \\ - B
        ,
    );
    const seq = r.mappingGet("v") orelse return error.TestExpectedValue;
    switch (seq) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 2), s.len);
            try testing.expectEqualStrings("A", s[0].string);
            try testing.expectEqualStrings("B", s[1].string);
        },
        else => return error.TestExpectedEqual,
    }
}

test "block sequence of strings" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(
        S,
        \\v:
        \\ - A
        \\ - B
        \\ - C
        ,
    );
    try testing.expectEqual(@as(usize, 3), r.v.len);
    try testing.expectEqualStrings("A", r.v[0]);
}

test "block sequence mixed as strings" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(
        S,
        \\v:
        \\ - A
        \\ - 1
        \\ - C
        ,
    );
    try testing.expectEqual(@as(usize, 3), r.v.len);
    try testing.expectEqualStrings("1", r.v[1]);
}

test "block sequence mixed as Value" {
    const r = try testDecode(
        Value,
        \\v:
        \\ - A
        \\ - 1
        \\ - C
        ,
    );
    const seq = r.mappingGet("v") orelse return error.TestExpectedValue;
    switch (seq) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 3), s.len);
            try testing.expectEqualStrings("A", s[0].string);
            try testing.expectEqual(@as(i64, 1), s[1].integer);
            try testing.expectEqualStrings("C", s[2].string);
        },
        else => return error.TestExpectedEqual,
    }
}

test "nested flow mapping as Value" {
    const r = try testDecode(Value, "a: {b: c}");
    const inner = r.mappingGet("a") orelse return error.TestExpectedValue;
    const val = inner.mappingGet("b") orelse return error.TestExpectedValue;
    try testing.expectEqualStrings("c", val.string);
}

test "decode simple mapping to Value" {
    const r = try testDecode(Value, "a: 1\nb: 2");
    try expectValueInt(r, "a", 1);
    try expectValueInt(r, "b", 2);
}

test "decode key value string map" {
    const r = try testDecode(Value, "v: hi");
    try expectValueString(r, "v", "hi");
}

test "v: empty string" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: \"\"\n");
    try testing.expectEqualStrings("", r.v);
}

test "v: block sequence strings" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(S,
        \\v:
        \\- A
        \\- B
        \\
    );
    try testing.expectEqual(@as(usize, 2), r.v.len);
    try testing.expectEqualStrings("A", r.v[0]);
}

test "a: dash in single quotes" {
    const S = struct { a: []const u8 };
    const r = try testDecode(S, "a: '-'\n");
    try testing.expectEqualStrings("-", r.a);
}

test "decode bare integer 123" {
    const r = try testDecode(i64, "123\n");
    try testing.expectEqual(@as(i64, 123), r);
}

test "decode hello: world string" {
    const S = struct { hello: []const u8 };
    const r = try testDecode(S, "hello: world\n");
    try testing.expectEqualStrings("world", r.hello);
}

test "decode with crlf line endings" {
    const r = try testDecode(Value, "hello: world\r\nfoo: bar");
    try expectValueString(r, "hello", "world");
    try expectValueString(r, "foo", "bar");
}

test "decode with cr line endings" {
    const r = try testDecode(Value, "hello: world\rZig: Ziguana");
    try expectValueString(r, "hello", "world");
    try expectValueString(r, "Zig", "Ziguana");
}

test "decode infinity to f64" {
    const r = try testDecode(f64, ".inf");
    try testing.expect(std.math.isPositiveInf(r));
}

test "decode negative infinity to f64" {
    const r = try testDecode(f64, "-.inf");
    try testing.expect(std.math.isNegativeInf(r));
}

test "decode nan to f64" {
    const r = try testDecode(f64, ".nan");
    try testing.expect(std.math.isNan(r));
}

test "decode Inf case insensitive" {
    const r = try testDecode(f64, ".Inf");
    try testing.expect(std.math.isPositiveInf(r));
}

test "decode INF uppercase" {
    const r = try testDecode(f64, ".INF");
    try testing.expect(std.math.isPositiveInf(r));
}

test "decode neg Inf" {
    const r = try testDecode(f64, "-.Inf");
    try testing.expect(std.math.isNegativeInf(r));
}

test "decode neg INF" {
    const r = try testDecode(f64, "-.INF");
    try testing.expect(std.math.isNegativeInf(r));
}

test "decode NaN mixed case" {
    const r = try testDecode(f64, ".NaN");
    try testing.expect(std.math.isNan(r));
}

test "decode NAN uppercase" {
    const r = try testDecode(f64, ".NAN");
    try testing.expect(std.math.isNan(r));
}

test "v: .inf as Value" {
    const r = try testDecode(Value, "v: .inf\n");
    try expectValuePosInf(r, "v");
}

test "v: .Inf as Value" {
    const r = try testDecode(Value, "v: .Inf\n");
    try expectValuePosInf(r, "v");
}

test "v: .INF as Value" {
    const r = try testDecode(Value, "v: .INF\n");
    try expectValuePosInf(r, "v");
}

test "v: -.inf as Value" {
    const r = try testDecode(Value, "v: -.inf\n");
    try expectValueNegInf(r, "v");
}

test "v: -.Inf as Value" {
    const r = try testDecode(Value, "v: -.Inf\n");
    try expectValueNegInf(r, "v");
}

test "v: -.INF as Value" {
    const r = try testDecode(Value, "v: -.INF\n");
    try expectValueNegInf(r, "v");
}

test "v: .nan as Value" {
    const r = try testDecode(Value, "v: .nan\n");
    try expectValueNan(r, "v");
}

test "v: .NaN as Value" {
    const r = try testDecode(Value, "v: .NaN\n");
    try expectValueNan(r, "v");
}

test "v: .NAN as Value" {
    const r = try testDecode(Value, "v: .NAN\n");
    try expectValueNan(r, "v");
}

test "decode tagged float" {
    const r = try testDecode(f64, "!!float '1.1'");
    try testing.expectApproxEqAbs(
        @as(f64, 1.1),
        r,
        0.001,
    );
}

test "decode tagged float zero" {
    const r = try testDecode(f64, "!!float 0");
    try testing.expectApproxEqAbs(
        @as(f64, 0.0),
        r,
        0.001,
    );
}

test "decode tagged float negative" {
    const r = try testDecode(f64, "!!float -1");
    try testing.expectApproxEqAbs(
        @as(f64, -1.0),
        r,
        0.001,
    );
}

test "decode tagged null" {
    const r = try testDecode(?[]const u8, "!!null ''");
    try testing.expect(r == null);
}

test "decode tagged bool yes" {
    const r = try testDecode(bool, "!!bool yes");
    try testing.expect(r);
}

test "decode tagged bool False" {
    const r = try testDecode(bool, "!!bool False");
    try testing.expect(!r);
}

test "single quote 1: 2" {
    const r = try testDecode(Value, "'1': '2'");
    try expectValueString(r, "1", "2");
}

test "single quote with double quotes inside" {
    const r = try testDecode(Value, "'1': '\"2\"'");
    try expectValueString(r, "1", "\"2\"");
}

test "single quote escaped apostrophe" {
    const r = try testDecode([]const u8, "'it''s'");
    try testing.expectEqualStrings("it's", r);
}

test "single quote solo apostrophe" {
    const r = try testDecode(Value, "'1': ''''");
    try expectValueString(r, "1", "'");
}

test "single quote wrapped apostrophes" {
    const r = try testDecode(Value, "'1': '''2'''");
    try expectValueString(r, "1", "'2'");
}

test "single quote mid apostrophe" {
    const r = try testDecode(Value, "'1': 'B''z'");
    try expectValueString(r, "1", "B'z");
}

test "single quote backslash literal" {
    const r = try testDecode([]const u8, "'\\'");
    try testing.expectEqualStrings("\\", r);
}

test "single quote double backslash" {
    const r = try testDecode(Value, "'1': '\\\\'");
    try expectValueString(r, "1", "\\\\");
}

test "single quote escaped double quotes" {
    const r = try testDecode(Value, "'1': '\\\"2\\\"'");
    try expectValueString(r, "1", "\\\"2\\\"");
}

test "double quote 1: 2" {
    const r = try testDecode(Value, "\"1\": \"2\"");
    try expectValueString(r, "1", "2");
}

test "double quote escaped quotes" {
    const r = try testDecode(Value, "\"1\": \"\\\"2\\\"\"");
    try expectValueString(r, "1", "\"2\"");
}

test "double quote single escaped quote" {
    const r = try testDecode(Value, "\"1\": \"\\\"\"");
    try expectValueString(r, "1", "\"");
}

test "double quote backslash" {
    const r = try testDecode(Value, "\"1\": \"\\\\\"");
    try expectValueString(r, "1", "\\");
}

test "double quote with newline escape" {
    const r = try testDecode([]const u8, "\"hello\\nworld\"");
    try testing.expectEqualStrings("hello\nworld", r);
}

test "double quote with tab escape" {
    const r = try testDecode([]const u8, "\"hello\\tworld\"");
    try testing.expectEqualStrings("hello\tworld", r);
}

test "double quote with hex escape" {
    const r = try testDecode([]const u8, "\"a\\x2Fb\"");
    try testing.expectEqualStrings("a/b", r);
}

test "double quote with unicode escape" {
    const r = try testDecode([]const u8, "\"a\\u002Fb\"");
    try testing.expectEqualStrings("a/b", r);
}

test "double quote multi unicode escapes" {
    const r = try testDecode(Value, "\"1\": \"a\\x2Fb\\u002Fc\\U0000002Fd\"");
    try expectValueString(r, "1", "a/b/c/d");
}

test "double quote newline escape n" {
    const r = try testDecode(Value, "'1': \"2\\n3\"");
    try expectValueString(r, "1", "2\n3");
}

test "double quote carriage return newline" {
    const r = try testDecode(Value, "'1': \"2\\r\\n3\"");
    try expectValueString(r, "1", "2\r\n3");
}

test "double quote line continuation" {
    const r = try testDecode(Value, "'1': \"a\\\nb\\\nc\"");
    try expectValueString(r, "1", "abc");
}

test "a: -b_c is string" {
    const r = try testDecode(Value, "a: -b_c");
    try expectValueString(r, "a", "-b_c");
}

test "a: +b_c is string" {
    const r = try testDecode(Value, "a: +b_c");
    try expectValueString(r, "a", "+b_c");
}

test "a: 50cent_of_dollar is string" {
    const r = try testDecode(Value, "a: 50cent_of_dollar");
    try expectValueString(r, "a", "50cent_of_dollar");
}

test "decode with document header" {
    const r = try testDecode(Value, "---\na: b");
    try expectValueString(r, "a", "b");
}

test "decode with document end" {
    const r = try testDecode(Value, "a: b\n...");
    try expectValueString(r, "a", "b");
}

test "decode empty document" {
    const r = try testDecode(?Value, "---\n");
    try testing.expect(r == null);
}

test "decode document end only" {
    const r = try testDecode(?Value, "...");
    try testing.expect(r == null);
}

test "decode empty string as null" {
    const r = try testDecode(?Value, "");
    try testing.expect(r == null);
}

test "v: zig build test as string" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: zig build test");
    try testing.expectEqualStrings("zig build test", r.v);
}

test "v: echo --- as string" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: echo ---");
    try testing.expectEqualStrings("echo ---", r.v);
}

test "decode literal block scalar" {
    const r = try testDecode(
        Value,
        \\v: |
        \\  hello
        \\  world
        \\
        ,
    );
    try expectValueString(
        r,
        "v",
        "hello\nworld\n",
    );
}

test "literal block with dots" {
    const S = struct { v: []const u8 };
    const r = try testDecode(
        S,
        \\v: |
        \\  hello
        \\  ...
        \\  world
        \\
        ,
    );
    try testing.expectEqualStrings("hello\n...\nworld\n", r.v);
}

test "literal block crlf" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: |\r\n  hello\r\n  ...\r\n  world\r\n");
    try testing.expectEqualStrings("hello\n...\nworld\n", r.v);
}

test "literal block cr only" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: |\r  hello\r  ...\r  world\r");
    try testing.expectEqualStrings("hello\n...\nworld\n", r.v);
}

test "decode literal block scalar strip" {
    const r = try testDecode(
        Value,
        \\v: |-
        \\  hello
        \\  world
        ,
    );
    try expectValueString(r, "v", "hello\nworld");
}

test "decode folded block scalar" {
    const r = try testDecode(
        Value,
        \\v: >
        \\  hello
        \\  world
        \\
        ,
    );
    try expectValueString(r, "v", "hello world\n");
}

test "block sequence with literal strip" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(
        S,
        \\v:
        \\- A
        \\- |-
        \\  B
        \\  C
        \\
        ,
    );
    try testing.expectEqual(@as(usize, 2), r.v.len);
    try testing.expectEqualStrings("A", r.v[0]);
    try testing.expectEqualStrings("B\nC", r.v[1]);
}

test "block literal strip crlf" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(S, "v:\r\n- A\r\n- |-\r\n  B\r\n  C\r\n");
    try testing.expectEqual(@as(usize, 2), r.v.len);
    try testing.expectEqualStrings("B\nC", r.v[1]);
}

test "block literal strip cr" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(S, "v:\r- A\r- |-\r  B\r  C\r");
    try testing.expectEqual(@as(usize, 2), r.v.len);
    try testing.expectEqualStrings("B\nC", r.v[1]);
}

test "block literal strip trailing newlines" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(
        S,
        \\v:
        \\- A
        \\- |-
        \\  B
        \\  C
        \\
        \\
        \\
        ,
    );
    try testing.expectEqual(@as(usize, 2), r.v.len);
    try testing.expectEqualStrings("B\nC", r.v[1]);
}

test "block folded strip" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(
        S,
        \\v:
        \\- A
        \\- >-
        \\  B
        \\  C
        \\
        ,
    );
    try testing.expectEqual(@as(usize, 2), r.v.len);
    try testing.expectEqualStrings("B C", r.v[1]);
}

test "block folded strip crlf" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(S, "v:\r\n- A\r\n- >-\r\n  B\r\n  C\r\n");
    try testing.expectEqualStrings("B C", r.v[1]);
}

test "block folded strip cr" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(S, "v:\r- A\r- >-\r  B\r  C\r");
    try testing.expectEqualStrings("B C", r.v[1]);
}

test "block folded strip trailing newlines" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(
        S,
        \\v:
        \\- A
        \\- >-
        \\  B
        \\  C
        \\
        \\
        \\
        ,
    );
    try testing.expectEqualStrings("B C", r.v[1]);
}

test "decode anchor and alias" {
    const r = try testDecode(Value, "a: &ref hello\nb: *ref");
    try expectValueString(r, "a", "hello");
    try expectValueString(r, "b", "hello");
}

test "decode merge key" {
    const r = try testDecode(
        Value,
        \\a: &a
        \\  foo: 1
        \\b:
        \\  <<: *a
        \\  bar: 2
        ,
    );
    const a = r.mappingGet("a") orelse return error.TestExpectedValue;
    try expectValueInt(a, "foo", 1);
    const b = r.mappingGet("b") orelse return error.TestExpectedValue;
    try expectValueInt(b, "bar", 2);
    try expectValueInt(b, "foo", 1);
}

test "anchor alias integers in struct" {
    const S = struct { a: i64, b: i64, c: i64, d: i64 };
    const r = try testDecode(
        S,
        \\a: &x 1
        \\b: &y 2
        \\c: *x
        \\d: *y
        \\
        ,
    );
    try testing.expectEqual(@as(i64, 1), r.a);
    try testing.expectEqual(@as(i64, 2), r.b);
    try testing.expectEqual(@as(i64, 1), r.c);
    try testing.expectEqual(@as(i64, 2), r.d);
}

test "anchor alias flow mapping" {
    const Inner = struct { c: i64 };
    const S = struct { a: Inner, b: Inner };
    const r = try testDecode(
        S,
        \\a: &a {c: 1}
        \\b: *a
        \\
        ,
    );
    try testing.expectEqual(@as(i64, 1), r.a.c);
    try testing.expectEqual(@as(i64, 1), r.b.c);
}

test "anchor alias sequence" {
    const S = struct { b: []const i64 };
    const r = try testDecode(
        S,
        \\a: &a [1, 2]
        \\b: *a
        \\
        ,
    );
    try testing.expectEqual(@as(usize, 2), r.b.len);
    try testing.expectEqual(@as(i64, 1), r.b[0]);
    try testing.expectEqual(@as(i64, 2), r.b[1]);
}

test "anchor self reference is null" {
    const r = try testDecode(
        Value,
        \\key1: &anchor
        \\  subkey: *anchor
        \\key2: *anchor
        \\
        ,
    );
    const key1 = r.mappingGet("key1") orelse return error.TestExpectedValue;
    try expectValueNull(key1, "subkey");
}

test "anchor as key" {
    const r = try testDecode(Value, "{a: &a c, *a : b}");
    try expectValueString(r, "a", "c");
    const val = r.mappingGet("c") orelse return error.TestExpectedValue;
    try testing.expectEqualStrings("b", val.string);
}

test "struct with tags and sequence" {
    const S = struct {
        tags: []const []const u8,
        a: []const u8,
    };
    const r = try testDecode(
        S,
        \\tags:
        \\- hello-world
        \\a: foo
        ,
    );
    try testing.expectEqual(@as(usize, 1), r.tags.len);
    try testing.expectEqualStrings("hello-world", r.tags[0]);
    try testing.expectEqualStrings("foo", r.a);
}

test "decode empty struct" {
    const r = try testDecode(Value, "{}");
    try testing.expectEqual(@as(std.meta.Tag(Value), .mapping), @as(std.meta.Tag(Value), r));
    try testing.expectEqual(@as(usize, 0), r.mapping.keys.len);
}

test "flow mapping with null value" {
    const r = try testDecode(Value, "{a: , b: c}");
    try expectValueNull(r, "a");
    try expectValueString(r, "b", "c");
}

test "v: path with braces" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: /a/{b}");
    try testing.expectEqualStrings("/a/{b}", r.v);
}

test "v: special characters" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: 1[]{},!%?&*");
    try testing.expectEqualStrings("1[]{},!%?&*", r.v);
}

test "v: user's item" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: user's item");
    try testing.expectEqualStrings("user's item", r.v);
}

test "nested flow sequences" {
    const r = try testDecode(Value, "v: [1,[2,[3,[4,5],6],7],8]");
    const seq = r.mappingGet("v") orelse return error.TestExpectedValue;
    switch (seq) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 3), s.len);
            try testing.expectEqual(@as(i64, 1), s[0].integer);
            try testing.expectEqual(@as(i64, 8), s[2].integer);
            const inner = s[1].sequence;
            try testing.expectEqual(@as(usize, 3), inner.len);
            try testing.expectEqual(@as(i64, 2), inner[0].integer);
            try testing.expectEqual(@as(i64, 7), inner[2].integer);
        },
        else => return error.TestExpectedEqual,
    }
}

test "nested flow mappings" {
    const r = try testDecode(Value, "v: {a: {b: {c: {d: e},f: g},h: i},j: k}");
    const v = r.mappingGet("v") orelse return error.TestExpectedValue;
    try expectValueString(v, "j", "k");
    const a = v.mappingGet("a") orelse return error.TestExpectedValue;
    try expectValueString(a, "h", "i");
    const b = a.mappingGet("b") orelse return error.TestExpectedValue;
    try expectValueString(b, "f", "g");
    const c = b.mappingGet("c") orelse return error.TestExpectedValue;
    try expectValueString(c, "d", "e");
}

test "sequence of mappings with null" {
    const r = try testDecode(
        Value,
        \\---
        \\- a:
        \\    b:
        \\- c: d
        \\
        ,
    );
    switch (r) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 2), s.len);
            const m0 = s[0].mappingGet("a") orelse return error.TestExpectedValue;
            try expectValueNull(m0, "b");
            const m1 = s[1].mappingGet("c") orelse return error.TestExpectedValue;
            try testing.expectEqualStrings("d", m1.string);
        },
        else => return error.TestExpectedEqual,
    }
}

test "mapping with nested null" {
    const r = try testDecode(
        Value,
        \\---
        \\a:
        \\  b:
        \\c: d
        \\
        ,
    );
    const a = r.mappingGet("a") orelse return error.TestExpectedValue;
    try expectValueNull(a, "b");
    try expectValueString(r, "c", "d");
}

test "mapping all null values" {
    const r = try testDecode(
        Value,
        \\---
        \\a:
        \\b:
        \\c:
        \\
        ,
    );
    try expectValueNull(r, "a");
    try expectValueNull(r, "b");
    try expectValueNull(r, "c");
}

test "mapping with dots and nulls" {
    const r = try testDecode(
        Value,
        \\---
        \\a: zig build test
        \\b:
        \\c:
        \\
        ,
    );
    try expectValueString(
        r,
        "a",
        "zig build test",
    );
    try expectValueNull(r, "b");
    try expectValueNull(r, "c");
}

test "mapping with literal and nulls" {
    const r = try testDecode(
        Value,
        \\---
        \\a: |
        \\  hello
        \\  ...
        \\  world
        \\b:
        \\c:
        \\
        ,
    );
    try expectValueString(
        r,
        "a",
        "hello\n...\nworld\n",
    );
    try expectValueNull(r, "b");
    try expectValueNull(r, "c");
}

test "a: nested map as string" {
    const S = struct { a: Value };
    const r = try testDecode(S,
        \\a:
        \\  b: c
        \\
    );
    const inner = r.a.mappingGet("b") orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(std.meta.Tag(Value), .string), @as(std.meta.Tag(Value), inner));
    try testing.expectEqualStrings("c", inner.string);
}

test "a: flow map of int" {
    const r = try testDecode(Value, "a: {x: 1}\n");
    const a = r.mappingGet("a") orelse return error.TestExpectedValue;
    try expectValueInt(a, "x", 1);
}

test "a: flow map of strings" {
    const r = try testDecode(Value, "a: {b: c, d: e}\n");
    const a = r.mappingGet("a") orelse return error.TestExpectedValue;
    try expectValueString(a, "b", "c");
    try expectValueString(a, "d", "e");
}

test "a: string 3s" {
    const S = struct { a: []const u8 };
    const r = try testDecode(S, "a: 3s\n");
    try testing.expectEqualStrings("3s", r.a);
}

test "a: angle bracket string" {
    const S = struct { a: []const u8 };
    const r = try testDecode(S, "a: <foo>\n");
    try testing.expectEqualStrings("<foo>", r.a);
}

test "a: quoted colon string" {
    const S = struct { a: []const u8 };
    const r = try testDecode(S, "a: \"1:1\"\n");
    try testing.expectEqualStrings("1:1", r.a);
}

test "a: dotted version string" {
    const S = struct { a: []const u8 };
    const r = try testDecode(S, "a: 1.2.3.4\n");
    try testing.expectEqualStrings("1.2.3.4", r.a);
}

test "a: single quoted colon" {
    const S = struct { a: []const u8 };
    const r = try testDecode(S, "a: 'b: c'\n");
    try testing.expectEqualStrings("b: c", r.a);
}

test "a: single quoted with hash" {
    const S = struct { a: []const u8 };
    const r = try testDecode(S, "a: 'Hello #comment'\n");
    try testing.expectEqualStrings("Hello #comment", r.a);
}

test "a: 100.5 as Value float" {
    const r = try testDecode(Value, "a: 100.5\n");
    try expectValueFloat(r, "a", 100.5, 0.01);
}

test "a: null byte escape" {
    const S = struct { a: []const u8 };
    const r = try testDecode(S, "a: \"\\0\"\n");
    try testing.expectEqualStrings("\x00", r.a);
}

test "whitespace around key-value" {
    const S = struct { a: []const u8 };
    const r = try testDecode(S, "       a       :          b        \n");
    try testing.expectEqualStrings("b", r.a);
}

test "comment after value" {
    const S = struct { a: []const u8, b: []const u8 };
    const r = try testDecode(
        S,
        \\a: b # comment
        \\b: c
        \\
        ,
    );
    try testing.expectEqualStrings("b", r.a);
    try testing.expectEqualStrings("c", r.b);
}

test "document separator" {
    const S = struct { a: []const u8 };
    const r = try testDecode(S,
        \\---
        \\a: b
        \\
    );
    try testing.expectEqualStrings("b", r.a);
}

test "document end marker" {
    const S = struct { a: []const u8 };
    const r = try testDecode(S,
        \\a: b
        \\...
        \\
    );
    try testing.expectEqualStrings("b", r.a);
}

test "a: int slice from flow" {
    const r = try testDecode(Value, "a: [1, 2]\n");
    const seq = r.mappingGet("a") orelse return error.TestExpectedValue;
    switch (seq) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 2), s.len);
            try testing.expectEqual(@as(i64, 1), s[0].integer);
            try testing.expectEqual(@as(i64, 2), s[1].integer);
        },
        else => return error.TestExpectedEqual,
    }
}

test "multi-key map ordering" {
    const r = try testDecode(
        Value,
        \\b: 2
        \\a: 1
        \\d: 4
        \\c: 3
        \\sub:
        \\  e: 5
        \\
        ,
    );
    try expectValueInt(r, "b", 2);
    try expectValueInt(r, "a", 1);
    try expectValueInt(r, "d", 4);
    try expectValueInt(r, "c", 3);
    const sub = r.mappingGet("sub") orelse return error.TestExpectedValue;
    try expectValueInt(sub, "e", 5);
}

test "decode y as string not bool" {
    const r = try testDecode([]const u8, "y");
    try testing.expectEqualStrings("y", r);
}

test "decode yes as string not bool" {
    const r = try testDecode([]const u8, "yes");
    try testing.expectEqualStrings("yes", r);
}

test "decode no as string not bool" {
    const r = try testDecode([]const u8, "no");
    try testing.expectEqualStrings("no", r);
}

test "decode on as string not bool" {
    const r = try testDecode([]const u8, "on");
    try testing.expectEqualStrings("on", r);
}

test "decode off as string not bool" {
    const r = try testDecode([]const u8, "off");
    try testing.expectEqualStrings("off", r);
}

test "decode quoted string with leading space" {
    const r = try testDecode([]const u8, "\" foo\"");
    try testing.expectEqualStrings(" foo", r);
}

test "decode quoted string with trailing space" {
    const r = try testDecode([]const u8, "\"foo \"");
    try testing.expectEqualStrings("foo ", r);
}

test "decode type mismatch returns error" {
    const r = testDecode(i64, "hello");
    try testing.expectError(error.TypeMismatch, r);
}

test "decode overflow returns error" {
    const r = testDecode(u8, "999");
    try testing.expectError(error.Overflow, r);
}

test "decode unknown field strict mode" {
    const Config = struct { name: []const u8 };
    const result = decode(
        Config,
        testing.allocator,
        "name: app\nunknown: field",
        .{ .disallow_unknown_fields = true },
    );
    try testing.expectError(error.UnknownField, result);
}

test "negative to u32 overflow" {
    const S = struct { v: u32 };
    const r = testDecode(S, "v: -42");
    try testing.expectError(error.Overflow, r);
}

test "negative to u64 overflow" {
    const S = struct { v: u64 };
    const r = testDecode(S, "v: -4294967296");
    try testing.expectError(error.Overflow, r);
}

test "i32 overflow" {
    const S = struct { v: i32 };
    const r = testDecode(S, "v: 4294967297");
    try testing.expectError(error.Overflow, r);
}

test "i8 overflow" {
    const S = struct { v: i8 };
    const r = testDecode(S, "v: 128");
    try testing.expectError(error.Overflow, r);
}

test "string to int type mismatch" {
    const S = struct { a: i64 };
    const r = testDecode(S, "a: str");
    try testing.expectError(error.TypeMismatch, r);
}

test "string to u32 type mismatch" {
    const S = struct { b: u32 };
    const r = testDecode(S, "b: str");
    try testing.expectError(error.TypeMismatch, r);
}

test "string to bool type mismatch" {
    const S = struct { d: bool };
    const r = testDecode(S, "d: str");
    try testing.expectError(error.TypeMismatch, r);
}

test "string to int in flow seq error" {
    const S = struct { v: []const i64 };
    const r = testDecode(S, "v: [A,1,C]");
    try testing.expectError(error.TypeMismatch, r);
}

test "string to int in block seq error" {
    const S = struct { v: []const i64 };
    const r = testDecode(
        S,
        \\v:
        \\ - A
        \\ - 1
        \\ - C
        ,
    );
    try testing.expectError(error.TypeMismatch, r);
}

test "scientific 1e3 as i64" {
    const S = struct { v: i64 };
    const r = try testDecode(S, "v: 1e3");
    try testing.expectEqual(@as(i64, 1000), r.v);
}

test "scientific 1e-3 as i64 truncated" {
    const S = struct { v: i64 };
    const r = try testDecode(S, "v: 1e-3");
    try testing.expectEqual(@as(i64, 0), r.v);
}

test "scientific 1e3 as f32" {
    const S = struct { v: f32 };
    const r = try testDecode(S, "v: 1e3");
    try testing.expectApproxEqAbs(
        @as(f32, 1000.0),
        r.v,
        0.1,
    );
}

test "scientific 1.0e3 as f64" {
    const S = struct { v: f64 };
    const r = try testDecode(S, "v: 1.0e3");
    try testing.expectApproxEqAbs(
        @as(f64, 1000.0),
        r.v,
        0.1,
    );
}

test "scientific 1e-3 as f64" {
    const S = struct { v: f64 };
    const r = try testDecode(S, "v: 1e-3");
    try testing.expectApproxEqAbs(
        @as(f64, 0.001),
        r.v,
        0.0001,
    );
}

test "scientific 1.0e-3 as f64" {
    const S = struct { v: f64 };
    const r = try testDecode(S, "v: 1.0e-3");
    try testing.expectApproxEqAbs(
        @as(f64, 0.001),
        r.v,
        0.0001,
    );
}

test "scientific 1.0e+3 as f64" {
    const S = struct { v: f64 };
    const r = try testDecode(S, "v: 1.0e+3");
    try testing.expectApproxEqAbs(
        @as(f64, 1000.0),
        r.v,
        0.1,
    );
}

test "merge key with struct" {
    const Item = struct { b: i64, c: []const u8 };
    const T = struct { items: []const Item };
    const r = try testDecode(
        T,
        \\a: &a
        \\  b: 1
        \\  c: hello
        \\items:
        \\- <<: *a
        \\- <<: *a
        \\  c: world
        \\
        ,
    );
    try testing.expectEqual(@as(usize, 2), r.items.len);
    try testing.expectEqual(@as(i64, 1), r.items[0].b);
    try testing.expectEqualStrings("hello", r.items[0].c);
    try testing.expectEqual(@as(i64, 1), r.items[1].b);
    try testing.expectEqualStrings("world", r.items[1].c);
}

test "merge key as Value" {
    const r = try testDecode(
        Value,
        \\a: &a
        \\  b: 1
        \\  c: hello
        \\items:
        \\- <<: *a
        \\- <<: *a
        \\  c: world
        \\
        ,
    );
    const a = r.mappingGet("a") orelse return error.TestExpectedValue;
    try expectValueInt(a, "b", 1);
    try expectValueString(a, "c", "hello");
    const items = r.mappingGet("items") orelse return error.TestExpectedValue;
    switch (items) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 2), s.len);
            try expectValueInt(s[0], "b", 1);
            try expectValueString(s[0], "c", "hello");
            try expectValueInt(s[1], "b", 1);
            try expectValueString(s[1], "c", "world");
        },
        else => return error.TestExpectedEqual,
    }
}

test "merge key from sequence of aliases" {
    const r = try testDecode(
        Value,
        \\a: &a
        \\ foo: 1
        \\b: &b
        \\ bar: 2
        \\merge:
        \\ <<: [*a, *b]
        \\
        ,
    );
    const a = r.mappingGet("a") orelse return error.TestExpectedValue;
    try expectValueInt(a, "foo", 1);
    const b = r.mappingGet("b") orelse return error.TestExpectedValue;
    try expectValueInt(b, "bar", 2);
    const merge = r.mappingGet("merge") orelse return error.TestExpectedValue;
    try expectValueInt(merge, "foo", 1);
    try expectValueInt(merge, "bar", 2);
}

test "merge tag with flow mapping" {
    const r = try testDecode(
        Value,
        \\
        \\!!merge <<: { a: 1, b: 2 }
        \\c: 3
        \\
        ,
    );
    try expectValueInt(r, "a", 1);
    try expectValueInt(r, "b", 2);
    try expectValueInt(r, "c", 3);
}

test "flow sequence A B as Value" {
    const r = try testDecode(Value, "v: [A,B]");
    const seq = r.mappingGet("v") orelse return error.TestExpectedValue;
    switch (seq) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 2), s.len);
            try testing.expectEqualStrings("A", s[0].string);
            try testing.expectEqualStrings("B", s[1].string);
        },
        else => return error.TestExpectedEqual,
    }
}

test "mixed nested list" {
    const r = try testDecode(
        Value,
        \\v:
        \\- A
        \\- 1
        \\- B:
        \\  - 2
        \\  - 3
        \\
        ,
    );
    const seq = r.mappingGet("v") orelse return error.TestExpectedValue;
    switch (seq) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 3), s.len);
            try testing.expectEqualStrings("A", s[0].string);
            try testing.expectEqual(@as(i64, 1), s[1].integer);
        },
        else => return error.TestExpectedEqual,
    }
}

test "same anchor redefined" {
    const S = struct {
        a: i64,
        b: i64,
        c: i64,
        d: i64,
    };
    const r = try testDecode(
        S,
        \\a: &a 1
        \\b: &a 2
        \\c: &a 3
        \\d: *a
        \\
        ,
    );
    try testing.expectEqual(@as(i64, 1), r.a);
    try testing.expectEqual(@as(i64, 2), r.b);
    try testing.expectEqual(@as(i64, 3), r.c);
    try testing.expectEqual(@as(i64, 3), r.d);
}

test "duplicate map key with allow option" {
    const r = try testDecode(
        Value,
        \\a: b
        \\a: c
        \\
        ,
    );
    try expectValueString(r, "a", "c");
}

test "struct with string and seq" {
    const S = struct {
        a: []const u8,
        b: []const u8,
    };
    const r = try testDecode(S,
        \\a: b
        \\b: d
        \\
    );
    try testing.expectEqualStrings("b", r.a);
    try testing.expectEqualStrings("d", r.b);
}

test "empty sequence item" {
    const r = try testDecode(
        Value,
        \\args:
        \\- a
        \\-
        \\command:
        \\- python
        ,
    );
    const args = r.mappingGet("args") orelse return error.TestExpectedValue;
    switch (args) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 2), s.len);
            try testing.expectEqualStrings("a", s[0].string);
            try testing.expectEqual(
                @as(std.meta.Tag(Value), .null),
                @as(std.meta.Tag(Value), s[1]),
            );
        },
        else => return error.TestExpectedEqual,
    }
    const cmd = r.mappingGet("command") orelse return error.TestExpectedValue;
    switch (cmd) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 1), s.len);
            try testing.expectEqualStrings("python", s[0].string);
        },
        else => return error.TestExpectedEqual,
    }
}

test "indented empty sequence item" {
    const r = try testDecode(
        Value,
        \\parent:
        \\  items:
        \\    - a
        \\    -
        \\  other: val
        ,
    );
    const parent = r.mappingGet("parent") orelse return error.TestExpectedValue;
    try expectValueString(parent, "other", "val");
    const items = parent.mappingGet("items") orelse return error.TestExpectedValue;
    switch (items) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 2), s.len);
            try testing.expectEqualStrings("a", s[0].string);
            try testing.expectEqual(
                @as(std.meta.Tag(Value), .null),
                @as(std.meta.Tag(Value), s[1]),
            );
        },
        else => return error.TestExpectedEqual,
    }
}

test "empty seq item with next line value" {
    const r = try testDecode(
        Value,
        \\items:
        \\-
        \\  key: val
        \\- b
        ,
    );
    const items = r.mappingGet("items") orelse return error.TestExpectedValue;
    switch (items) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 2), s.len);
            try expectValueString(s[0], "key", "val");
            try testing.expectEqualStrings("b", s[1].string);
        },
        else => return error.TestExpectedEqual,
    }
}

test "anchor in unmapped field" {
    const Job = struct {
        name: []const u8,
    };
    const Config = struct {
        name: []const u8,
        jobs: []const Job,
    };
    const r = try testDecode(
        Config,
        \\shared:
        \\  endpoint: &base_url "http://example.com"
        \\
        \\name: Test Config
        \\jobs:
        \\- name: Job1
        \\
        ,
    );
    try testing.expectEqualStrings("Test Config", r.name);
    try testing.expectEqual(@as(usize, 1), r.jobs.len);
    try testing.expectEqualStrings("Job1", r.jobs[0].name);
}

test "sibling anchor alias simple" {
    const r = try testDecode(
        Value,
        \\a: &a
        \\  b: &b value
        \\  ref: *b
        \\
        ,
    );
    const a = r.mappingGet("a") orelse return error.TestExpectedValue;
    try expectValueString(a, "b", "value");
    try expectValueString(a, "ref", "value");
}

test "sibling anchor alias multiple" {
    const r = try testDecode(
        Value,
        \\config: &config
        \\  db: &db postgres://localhost/mydb
        \\  cache: &cache redis://localhost:6379
        \\  app:
        \\    database_url: *db
        \\    cache_url: *cache
        \\
        ,
    );
    const config = r.mappingGet("config") orelse return error.TestExpectedValue;
    try expectValueString(
        config,
        "db",
        "postgres://localhost/mydb",
    );
    try expectValueString(
        config,
        "cache",
        "redis://localhost:6379",
    );
    const app = config.mappingGet("app") orelse return error.TestExpectedValue;
    try expectValueString(
        app,
        "database_url",
        "postgres://localhost/mydb",
    );
    try expectValueString(
        app,
        "cache_url",
        "redis://localhost:6379",
    );
}

test "nested map sibling alias" {
    const r = try testDecode(
        Value,
        \\service: &service
        \\  auth: &auth
        \\    required: true
        \\    type: jwt
        \\  endpoint:
        \\    security: *auth
        \\
        ,
    );
    const svc = r.mappingGet("service") orelse return error.TestExpectedValue;
    const auth = svc.mappingGet("auth") orelse return error.TestExpectedValue;
    try expectValueBool(auth, "required", true);
    try expectValueString(auth, "type", "jwt");
    const ep = svc.mappingGet("endpoint") orelse return error.TestExpectedValue;
    const sec = ep.mappingGet("security") orelse return error.TestExpectedValue;
    try expectValueBool(sec, "required", true);
    try expectValueString(sec, "type", "jwt");
}

test "self recursion anchor is null" {
    const r = try testDecode(
        Value,
        \\a: &a
        \\  self: *a
        \\
        ,
    );
    const a = r.mappingGet("a") orelse return error.TestExpectedValue;
    try expectValueNull(a, "self");
}

test "invalid alias reference" {
    const r = testDecode(Value, "*-0");
    try testing.expectError(error.Unimplemented, r);
}

test "roundtrip merge key struct" {
    const Foo = struct {
        k1: []const u8,
        k2: []const u8,
    };
    const Bar = struct {
        k1: []const u8,
        k3: []const u8,
    };
    const Doc = struct { foo: Foo, bar: Bar };
    const r = try testDecode(
        Doc,
        \\foo:
        \\ <<: &test-anchor
        \\   k1: "One"
        \\ k2: "Two"
        \\
        \\bar:
        \\ <<: *test-anchor
        \\ k3: "Three"
        \\
        ,
    );
    try testing.expectEqualStrings("One", r.foo.k1);
    try testing.expectEqualStrings("Two", r.foo.k2);
    try testing.expectEqualStrings("One", r.bar.k1);
    try testing.expectEqualStrings("Three", r.bar.k3);
}

test "anchor with any value and alias" {
    const r = try testDecode(
        Value,
        \\def:
        \\  myenv: &my_env
        \\    - VAR1=1
        \\    - VAR2=2
        \\config:
        \\  env: *my_env
        \\
        ,
    );
    const def = r.mappingGet("def") orelse return error.TestExpectedValue;
    const myenv = def.mappingGet("myenv") orelse return error.TestExpectedValue;
    switch (myenv) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 2), s.len);
            try testing.expectEqualStrings("VAR1=1", s[0].string);
            try testing.expectEqualStrings("VAR2=2", s[1].string);
        },
        else => return error.TestExpectedEqual,
    }
    const config = r.mappingGet("config") orelse return error.TestExpectedValue;
    const env = config.mappingGet("env") orelse return error.TestExpectedValue;
    switch (env) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 2), s.len);
            try testing.expectEqualStrings("VAR1=1", s[0].string);
            try testing.expectEqualStrings("VAR2=2", s[1].string);
        },
        else => return error.TestExpectedEqual,
    }
}

test "canonical mapping" {
    const r = try testDecode(
        Value,
        \\!!map {
        \\  ? !!str "explicit":!!str "entry",
        \\  ? !!str "implicit" : !!str "entry",
        \\  ? !!null "" : !!null "",
        \\}
        \\
        ,
    );
    try expectValueString(r, "explicit", "entry");
    try expectValueString(r, "implicit", "entry");
}

test "binary tag decode" {
    const S = struct { a: []const u8 };
    const r = try testDecode(S, "a: !!binary gIGC\n");
    try testing.expectEqualStrings("\x80\x81\x82", r.a);
}

test "quoted map keys" {
    const Inner = struct { b: i64, c: bool };
    const S = struct { a: Inner };
    const r = try testDecode(S, "a:\n  \"b\"  : 2\n  'c': true\n");
    try testing.expectEqual(@as(i64, 2), r.a.b);
    try testing.expect(r.a.c);
}

test "tab after value" {
    const r = try testDecode(Value, "- a: [2 , 2] \t\t\t\n  b: [2 , 2] \t\t\t\n  c: [2 , 2]");
    switch (r) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 1), s.len);
            const a = s[0].mappingGet("a") orelse return error.TestExpectedValue;
            switch (a) {
                .sequence => |as| {
                    try testing.expectEqual(@as(usize, 2), as.len);
                    try testing.expectEqual(@as(i64, 2), as[0].integer);
                },
                else => return error.TestExpectedEqual,
            }
            const b = s[0].mappingGet("b") orelse return error.TestExpectedValue;
            switch (b) {
                .sequence => |bs| {
                    try testing.expectEqual(@as(usize, 2), bs.len);
                    try testing.expectEqual(@as(i64, 2), bs[0].integer);
                },
                else => return error.TestExpectedEqual,
            }
            const c = s[0].mappingGet("c") orelse return error.TestExpectedValue;
            switch (c) {
                .sequence => |cs| {
                    try testing.expectEqual(@as(usize, 2), cs.len);
                    try testing.expectEqual(@as(i64, 2), cs[0].integer);
                },
                else => return error.TestExpectedEqual,
            }
        },
        else => return error.TestExpectedEqual,
    }
}

test "preserve struct defaults" {
    const Nested = struct {
        val: []const u8 = "default",
    };
    const T = struct {
        first: []const u8,
        nested: Nested = .{},
    };
    const r = try testDecode(T, "first: \"Test\"\nnested:\n");
    try testing.expectEqualStrings("Test", r.first);
    try testing.expectEqualStrings("default", r.nested.val);
}

test "decode integer as string key" {
    const r = try testDecode(Value, "42: 100");
    try testing.expectEqual(@as(std.meta.Tag(Value), .mapping), @as(std.meta.Tag(Value), r));
    try testing.expectEqual(@as(usize, 1), r.mapping.keys.len);
    try testing.expectEqual(@as(i64, 42), r.mapping.keys[0].integer);
    try testing.expectEqual(@as(i64, 100), r.mapping.values[0].integer);
}

test "decode struct with two fields" {
    const S = struct { a: []const u8, c: []const u8 };
    const r = try testDecode(S,
        \\a: b
        \\c: d
        \\
    );
    try testing.expectEqualStrings("b", r.a);
    try testing.expectEqualStrings("d", r.c);
}

test "decode nested null values" {
    const r = try testDecode(
        Value,
        \\a:
        \\  b:
        \\c: d
        ,
    );
    const a = r.mappingGet("a") orelse return error.TestExpectedValue;
    try expectValueNull(a, "b");
    try expectValueString(r, "c", "d");
}

test "disallow unknown nested" {
    const Inner = struct { b: i64 };
    const S = struct { c: Inner };
    const result = decode(
        S,
        testing.allocator,
        \\---
        \\b: 1
        \\c:
        \\  b: 1
        \\
    ,
        .{ .disallow_unknown_fields = true },
    );
    try testing.expectError(error.UnknownField, result);
}

test "timestamps as string" {
    const S = struct { t2: []const u8, t4: []const u8 };
    const r = try testDecode(
        S,
        \\t2: 2018-01-09T10:40:47Z
        \\t4: 2098-01-09T10:40:47Z
        \\
        ,
    );
    try testing.expectEqualStrings("2018-01-09T10:40:47Z", r.t2);
    try testing.expectEqualStrings("2098-01-09T10:40:47Z", r.t4);
}

test "single quote multiline fold" {
    const r = try testDecode(
        Value,
        \\'1': '   1
        \\    2
        \\    3'
        ,
    );
    try expectValueString(r, "1", "   1 2 3");
}

test "single quote multiline leading" {
    const r = try testDecode(
        Value,
        \\'1': '
        \\    2
        \\    3'
        ,
    );
    try expectValueString(r, "1", " 2 3");
}

test "double quote multiline fold" {
    const r = try testDecode(Value, "'1': \"   1\n    2\n    3\"");
    try expectValueString(r, "1", "   1 2 3");
}

test "double quote multiline leading" {
    const r = try testDecode(Value, "'1': \"\n    2\n    3\"");
    try expectValueString(r, "1", " 2 3");
}

test "decode percent yaml directive" {
    const r = try testDecode(
        ?Value,
        \\%YAML 1.2
        \\---
        \\
        ,
    );
    try testing.expect(r == null);
}

test "decode bare null keyword" {
    const r = try testDecode(?Value, "null");
    try testing.expect(r == null);
}

test "decode bare tilde" {
    const r = try testDecode(?Value, "~");
    try testing.expect(r == null);
}

test "flow map A B as Value" {
    const r = try testDecode(Value, "v: [A,B]");
    const seq = r.mappingGet("v") orelse return error.TestExpectedValue;
    switch (seq) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 2), s.len);
            try testing.expectEqualStrings("A", s[0].string);
            try testing.expectEqualStrings("B", s[1].string);
        },
        else => return error.TestExpectedEqual,
    }
}

test "decode struct with seq no dash" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(S,
        \\v:
        \\- A
        \\- B
        \\
    );
    try testing.expectEqual(@as(usize, 2), r.v.len);
}

test "f64 max float32 range" {
    const S = struct { v: f32 };
    const r = try testDecode(S, "v: 3.40282346638528859811704183484516925440e+38");
    try testing.expectApproxEqRel(std.math.floatMax(f32), r.v, 1e-6);
}

test "f64 smallest nonzero f32" {
    const S = struct { v: f32 };
    const r = try testDecode(S, "v: 1.401298464324817070923729583289916131280e-45");
    try testing.expect(r.v > 0 and r.v <= std.math.floatMin(f32));
}

test "max f64" {
    const S = struct { v: f64 };
    const r = try testDecode(S, "v: 1.797693134862315708145274237317043567981e+308");
    try testing.expectApproxEqRel(std.math.floatMax(f64), r.v, 1e-15);
}

test "smallest nonzero f64" {
    const S = struct { v: f64 };
    const r = try testDecode(S, "v: 4.940656458412465441765687928682213723651e-324");
    try testing.expect(r.v > 0 and r.v <= std.math.floatMin(f64));
}

test "large uint as f64" {
    const S = struct { v: f64 };
    const r = try testDecode(S, "v: 18446744073709551615");
    try testing.expectApproxEqRel(@as(f64, 1.8446744073709552e+19), r.v, 1e-15);
}

test "large uint+1 as f64" {
    const S = struct { v: f64 };
    const r = try testDecode(S, "v: 18446744073709551616");
    try testing.expectApproxEqRel(@as(f64, 1.8446744073709552e+19), r.v, 1e-15);
}

test "large uint as f32" {
    const S = struct { v: f32 };
    const r = try testDecode(S, "v: 18446744073709551615");
    try testing.expectApproxEqRel(@as(f32, 1.8446744e+19), r.v, 1e-6);
}

test "large uint+1 as f32" {
    const S = struct { v: f32 };
    const r = try testDecode(S, "v: 18446744073709551616");
    try testing.expectApproxEqRel(@as(f32, 1.8446744e+19), r.v, 1e-6);
}

test "scientific underscore float" {
    const r = try testDecode(f64, "685.230_15e+03");
    try testing.expectApproxEqAbs(
        @as(f64, 685230.15e+0),
        r,
        0.1,
    );
}

test "binary with underscores as i64" {
    const r = try testDecode(i64, "0b1010_0111_0100_1010_1110");
    try testing.expectEqual(@as(i64, 685230), r);
}

test "decode positive sign integer" {
    const r = try testDecode(i64, "+685_230");
    try testing.expectEqual(@as(i64, 685230), r);
}

test "decode escape bell" {
    const r = try testDecode([]const u8, "\"\\a\"\n");
    try testing.expectEqual(@as(u8, 0x07), r[0]);
}

test "decode escape backspace" {
    const r = try testDecode([]const u8, "\"\\b\"\n");
    try testing.expectEqual(@as(u8, 0x08), r[0]);
}

test "decode escape vertical tab" {
    const r = try testDecode([]const u8, "\"\\v\"\n");
    try testing.expectEqual(@as(u8, 0x0B), r[0]);
}

test "decode escape form feed" {
    const r = try testDecode([]const u8, "\"\\f\"\n");
    try testing.expectEqual(@as(u8, 0x0C), r[0]);
}

test "decode escape esc" {
    const r = try testDecode([]const u8, "\"\\e\"\n");
    try testing.expectEqual(@as(u8, 0x1B), r[0]);
}

test "decode escape non-breaking space" {
    const r = try testDecode([]const u8, "\"\\_\"\n");
    try testing.expectEqualStrings("\xc2\xa0", r);
}

test "decode escape next line" {
    const r = try testDecode([]const u8, "\"\\N\"\n");
    try testing.expectEqualStrings("\xc2\x85", r);
}

test "decode escape line separator" {
    const r = try testDecode([]const u8, "\"\\L\"\n");
    try testing.expectEqualStrings("\xe2\x80\xa8", r);
}

test "decode escape paragraph separator" {
    const r = try testDecode([]const u8, "\"\\P\"\n");
    try testing.expectEqualStrings("\xe2\x80\xa9", r);
}

test "decode multi-byte unicode string" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: \xc3\xa9\xc3\xa0\xc3\xbc\n");
    try testing.expectEqualStrings("\xc3\xa9\xc3\xa0\xc3\xbc", r.v);
}

test "decode unicode escape u00e9" {
    const r = try testDecode([]const u8, "\"\\u00e9\"\n");
    try testing.expectEqualStrings("\xc3\xa9", r);
}

test "decode unicode escape U0001F600" {
    const r = try testDecode([]const u8, "\"\\U0001F600\"\n");
    try testing.expectEqualStrings("\xf0\x9f\x98\x80", r);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const decoder = @import("decode.zig");
const Node = @import("ast.zig").Node;
const Value = @import("value.zig").Value;

pub const EncodeOptions = struct {
    indent: u8 = 2,
    flow_style: bool = false,
    use_literal_multiline: bool = false,
    use_single_quote: bool = false,
    omit_empty: bool = false,
    indent_sequence: bool = false,
};

pub fn encode(allocator: Allocator, val: anytype, options: EncodeOptions) ![]u8 {
    _ = allocator;
    _ = val;
    _ = options;
    return error.Unimplemented;
}

pub fn encodeToNode(allocator: Allocator, val: anytype, options: EncodeOptions) !Node {
    _ = allocator;
    _ = val;
    _ = options;
    return error.Unimplemented;
}

fn testEncode(val: anytype) ![]u8 {
    return encode(testing.allocator, val, .{});
}

fn testEncodeOpts(val: anytype, opts: EncodeOptions) ![]u8 {
    return encode(testing.allocator, val, opts);
}

fn testEncodeWithOptions(val: anytype, opts: EncodeOptions) ![]u8 {
    return encode(testing.allocator, val, opts);
}

test "encode null pointer" {
    const r = try testEncode(@as(?*const struct {}, null));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("null\n", r);
}

test "encode struct with string value" {
    const S = struct { v: []const u8 };
    const r = try testEncode(S{ .v = "hi" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("v: hi\n", r);
}

test "encode struct with string true" {
    const S = struct { v: []const u8 };
    const r = try testEncode(S{ .v = "true" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("v: \"true\"\n", r);
}

test "encode struct with string false" {
    const S = struct { v: []const u8 };
    const r = try testEncode(S{ .v = "false" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("v: \"false\"\n", r);
}

test "encode struct with bool true" {
    const S = struct { v: bool };
    const r = try testEncode(S{ .v = true });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("v: true\n", r);
}

test "encode struct with bool false" {
    const S = struct { v: bool };
    const r = try testEncode(S{ .v = false });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("v: false\n", r);
}

test "encode struct with int 10" {
    const S = struct { v: i64 };
    const r = try testEncode(S{ .v = 10 });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("v: 10\n", r);
}

test "encode struct with int -10" {
    const S = struct { v: i64 };
    const r = try testEncode(S{ .v = -10 });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("v: -10\n", r);
}

test "encode struct with large int" {
    const S = struct { v: i64 };
    const r = try testEncode(S{ .v = 4294967296 });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("v: 4294967296\n", r);
}

test "encode struct with float 0.1" {
    const S = struct { v: f64 };
    const r = try testEncode(S{ .v = 0.1 });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("v: 0.1\n", r);
}

test "encode struct with float 0.99 f32" {
    const S = struct { v: f32 };
    const r = try testEncode(S{ .v = 0.99 });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("v: 0.99\n", r);
}

test "encode struct with float 0.123456789" {
    const S = struct { v: f64 };
    const r = try testEncode(S{ .v = 0.123456789 });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("v: 0.123456789\n", r);
}

test "encode struct with float -0.1" {
    const S = struct { v: f64 };
    const r = try testEncode(S{ .v = -0.1 });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("v: -0.1\n", r);
}

test "encode struct with positive inf" {
    const S = struct { v: f64 };
    const r = try testEncode(S{ .v = std.math.inf(f64) });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("v: .inf\n", r);
}

test "encode struct with negative inf" {
    const S = struct { v: f64 };
    const r = try testEncode(S{ .v = -std.math.inf(f64) });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("v: -.inf\n", r);
}

test "encode struct with nan" {
    const S = struct { v: f64 };
    const r = try testEncode(S{ .v = std.math.nan(f64) });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("v: .nan\n", r);
}

test "encode struct with null optional" {
    const S = struct { v: ?i64 };
    const r = try testEncode(S{ .v = null });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("v: null\n", r);
}

test "encode struct with empty string" {
    const S = struct { v: []const u8 };
    const r = try testEncode(S{ .v = "" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("v: \"\"\n", r);
}

test "encode struct with string slice" {
    const S = struct { v: []const []const u8 };
    const r = try testEncode(S{ .v = &.{ "A", "B" } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\v:
        \\- A
        \\- B
    ,
        r,
    );
}

test "encode struct with string array" {
    const S = struct { v: [2][]const u8 };
    const r = try testEncode(S{ .v = .{ "A", "B" } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\v:
        \\- A
        \\- B
    ,
        r,
    );
}

test "encode struct with dash string" {
    const S = struct { a: []const u8 };
    const r = try testEncode(S{ .a = "-" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a: \"-\"\n", r);
}

test "encode bare integer" {
    const r = try testEncode(@as(i64, 123));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("123\n", r);
}

test "encode struct hello world" {
    const S = struct { hello: []const u8 };
    const r = try testEncode(S{ .hello = "world" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("hello: world\n", r);
}

test "encode struct with multiline keep" {
    const S = struct { hello: []const u8 };
    const r = try testEncode(S{ .hello = "hello\nworld\n" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\hello: |
        \\  hello
        \\  world
    ,
        r,
    );
}

test "encode struct with multiline strip" {
    const S = struct { hello: []const u8 };
    const r = try testEncode(S{ .hello = "hello\nworld" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\hello: |-
        \\  hello
        \\  world
    ,
        r,
    );
}

test "encode struct with multiline extra trailing" {
    const S = struct { hello: []const u8 };
    const r = try testEncode(S{ .hello = "hello\nworld\n\n" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\hello: |+
        \\  hello
        \\  world
        \\
    ,
        r,
    );
}

test "encode nested struct with multiline" {
    const Inner = struct { hello: []const u8 };
    const Outer = struct { hello: Inner };
    const r = try testEncode(Outer{ .hello = Inner{ .hello = "hello\nworld\n" } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\hello:
        \\  hello: |
        \\    hello
        \\    world
    ,
        r,
    );
}

test "encode literal multiline opt strip" {
    const S = struct { v: []const u8 };
    const r = try testEncodeOpts(
        S{
            .v = std.mem.trimRight(u8,
                \\username: hello
                \\password: hello123
                \\
            , "\n"),
        },
        .{ .use_literal_multiline = true },
    );
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\v: |-
        \\  username: hello
        \\  password: hello123
        \\
    ,
        r,
    );
}

test "encode literal multiline opt with comment" {
    const S = struct { v: []const u8 };
    const r = try testEncodeOpts(
        S{
            .v = std.mem.trimRight(u8,
                \\# comment
                \\username: hello
                \\password: hello123
                \\
            , "\n"),
        },
        .{ .use_literal_multiline = true },
    );
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\v: |-
        \\  # comment
        \\  username: hello
        \\  password: hello123
        \\
    ,
        r,
    );
}

test "encode struct with angle brackets" {
    const S = struct { a: []const u8 };
    const r = try testEncode(S{ .a = "<foo>" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a: <foo>\n", r);
}

test "encode struct with colon in value" {
    const S = struct { a: []const u8 };
    const r = try testEncode(S{ .a = "1:1" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a: \"1:1\"\n", r);
}

test "encode struct with ip-like value" {
    const S = struct { a: []const u8 };
    const r = try testEncode(S{ .a = "1.2.3.4" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a: 1.2.3.4\n", r);
}

test "encode struct with colon space" {
    const S = struct { a: []const u8 };
    const r = try testEncode(S{ .a = "b: c" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a: \"b: c\"\n", r);
}

test "encode struct with hash comment" {
    const S = struct { a: []const u8 };
    const r = try testEncode(S{ .a = "Hello #comment" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a: \"Hello #comment\"\n", r);
}

test "encode struct with leading space" {
    const S = struct { a: []const u8 };
    const r = try testEncode(S{ .a = " b" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a: \" b\"\n", r);
}

test "encode struct with trailing space" {
    const S = struct { a: []const u8 };
    const r = try testEncode(S{ .a = "b " });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a: \"b \"\n", r);
}

test "encode struct with both spaces" {
    const S = struct { a: []const u8 };
    const r = try testEncode(S{ .a = " b " });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a: \" b \"\n", r);
}

test "encode struct with backtick" {
    const S = struct { a: []const u8 };
    const r = try testEncode(S{ .a = "`b` c" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a: \"`b` c\"\n", r);
}

test "encode struct with float 100.5" {
    const S = struct { a: f64 };
    const r = try testEncode(S{ .a = 100.5 });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a: 100.5\n", r);
}

test "encode struct with backslash zero" {
    const S = struct { a: []const u8 };
    const r = try testEncode(S{ .a = "\\0" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a: \"\\\\0\"\n", r);
}

test "encode struct with sub mapping" {
    const Sub = struct { e: i64 };
    const S = struct {
        a: i64,
        b: i64,
        c: i64,
        d: i64,
        sub: Sub,
    };
    const r = try testEncode(S{ .a = 1, .b = 2, .c = 3, .d = 4, .sub = Sub{ .e = 5 } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\a: 1
        \\b: 2
        \\c: 3
        \\d: 4
        \\sub:
        \\  e: 5
    ,
        r,
    );
}

test "encode struct with empty slice" {
    const S = struct { a: i64, b: []const []const u8 };
    const r = try testEncode(S{ .a = 1, .b = &.{} });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\a: 1
        \\b: []
    ,
        r,
    );
}

test "encode struct with empty string field" {
    const S = struct { a: []const u8 };
    const r = try testEncode(S{ .a = "" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a: \"\"\n", r);
}

test "encode struct with null optional ptr" {
    const S = struct { a: ?*const []const u8 };
    const r = try testEncode(S{ .a = null });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a: null\n", r);
}

test "encode struct with null optional int" {
    const S = struct { a: ?i64 };
    const r = try testEncode(S{ .a = null });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a: null\n", r);
}

test "encode struct with optional int zero" {
    const S = struct { a: ?i64 };
    const r = try testEncode(S{ .a = 0 });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a: 0\n", r);
}

test "encode integer" {
    const r = try testEncode(@as(i64, 42));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("42\n", r);
}

test "encode negative integer" {
    const r = try testEncode(@as(i64, -10));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("-10\n", r);
}

test "encode zero" {
    const r = try testEncode(@as(i64, 0));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("0\n", r);
}

test "encode float" {
    const r = try testEncode(@as(f64, 0.1));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("0.1\n", r);
}

test "encode negative float" {
    const r = try testEncode(@as(f64, -0.1));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("-0.1\n", r);
}

test "encode positive infinity" {
    const r = try testEncode(std.math.inf(f64));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(".inf\n", r);
}

test "encode negative infinity" {
    const r = try testEncode(-std.math.inf(f64));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("-.inf\n", r);
}

test "encode nan" {
    const r = try testEncode(std.math.nan(f64));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(".nan\n", r);
}

test "encode bool true" {
    const r = try testEncode(true);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("true\n", r);
}

test "encode bool false" {
    const r = try testEncode(false);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("false\n", r);
}

test "encode string" {
    const r = try testEncode(@as([]const u8, "hi"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("hi\n", r);
}

test "encode empty string" {
    const r = try testEncode(@as([]const u8, ""));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\"\"\n", r);
}

test "encode string requiring quotes true" {
    const r = try testEncode(@as([]const u8, "true"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\"true\"\n", r);
}

test "encode string requiring quotes false" {
    const r = try testEncode(@as([]const u8, "false"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\"false\"\n", r);
}

test "encode string with colon" {
    const r = try testEncode(@as([]const u8, "1:1"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\"1:1\"\n", r);
}

test "encode string with hash" {
    const r = try testEncode(@as([]const u8, "Hello #comment"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\"Hello #comment\"\n", r);
}

test "encode string with leading space" {
    const r = try testEncode(@as([]const u8, " b"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\" b\"\n", r);
}

test "encode string with trailing space" {
    const r = try testEncode(@as([]const u8, "b "));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\"b \"\n", r);
}

test "encode null optional" {
    const r = try testEncode(@as(?i64, null));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("null\n", r);
}

test "encode simple struct" {
    const Config = struct {
        a: i64,
        b: []const u8,
    };
    const r = try testEncode(Config{ .a = 1, .b = "hello" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\a: 1
        \\b: hello
    ,
        r,
    );
}

test "encode nested struct" {
    const Inner = struct { b: []const u8 };
    const Outer = struct { a: Inner };
    const r = try testEncode(Outer{ .a = Inner{ .b = "c" } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\a:
        \\  b: c
    ,
        r,
    );
}

test "encode struct with optional null" {
    const Config = struct {
        a: i64,
        b: ?i64 = null,
    };
    const r = try testEncode(Config{ .a = 1 });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\a: 1
        \\b: null
    ,
        r,
    );
}

test "encode slice of strings" {
    const r = try testEncode(@as([]const []const u8, &.{ "A", "B", "C" }));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\- A
        \\- B
        \\- C
    ,
        r,
    );
}

test "encode slice of integers" {
    const r = try testEncode(@as([]const i64, &.{ 1, 2, 3 }));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\- 1
        \\- 2
        \\- 3
    ,
        r,
    );
}

test "encode empty slice" {
    const r = try testEncode(@as([]const i64, &.{}));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("[]\n", r);
}

test "encode multiline string literal" {
    const r = try testEncodeOpts(
        @as([]const u8, "hello\nworld\n"),
        .{ .use_literal_multiline = true },
    );
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\|
        \\  hello
        \\  world
    ,
        r,
    );
}

test "encode multiline string literal strip" {
    const r = try testEncodeOpts(
        @as([]const u8, "hello\nworld"),
        .{ .use_literal_multiline = true },
    );
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\|-
        \\  hello
        \\  world
    ,
        r,
    );
}

test "encode Value null" {
    const r = try testEncode(Value.null);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("null\n", r);
}

test "encode Value boolean" {
    const r = try testEncode(Value{ .boolean = true });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("true\n", r);
}

test "encode Value integer" {
    const r = try testEncode(Value{ .integer = 42 });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("42\n", r);
}

test "encode Value string" {
    const r = try testEncode(Value{ .string = "hello" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("hello\n", r);
}

test "encode Value sequence" {
    const items = [_]Value{
        Value{ .string = "A" },
        Value{ .string = "B" },
    };
    const r = try testEncode(Value{ .sequence = &items });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\- A
        \\- B
    ,
        r,
    );
}

test "encode Value float" {
    const r = try testEncode(Value{ .float = 3.14 });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("3.14\n", r);
}

test "encode Value mapping" {
    const keys = [_]Value{
        Value{ .string = "a" },
        Value{ .string = "b" },
    };
    const vals = [_]Value{
        Value{ .integer = 1 },
        Value{ .integer = 2 },
    };
    const r = try testEncode(Value{ .mapping = .{ .keys = &keys, .values = &vals } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\a: 1
        \\b: 2
    ,
        r,
    );
}

test "encode Value nested mapping" {
    const inner_keys = [_]Value{
        Value{ .string = "b" },
    };
    const inner_vals = [_]Value{
        Value{ .string = "c" },
    };
    const inner = Value{
        .mapping = .{
            .keys = &inner_keys,
            .values = &inner_vals,
        },
    };
    const keys = [_]Value{
        Value{ .string = "a" },
    };
    const vals = [_]Value{inner};
    const r = try testEncode(Value{ .mapping = .{ .keys = &keys, .values = &vals } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\a:
        \\  b: c
    ,
        r,
    );
}

test "encode Value mapping with two entries" {
    const keys = [_]Value{
        Value{ .string = "b" },
        Value{ .string = "d" },
    };
    const vals = [_]Value{
        Value{ .string = "c" },
        Value{ .string = "e" },
    };
    const outer_keys = [_]Value{
        Value{ .string = "a" },
    };
    const outer_vals = [_]Value{
        Value{
            .mapping = .{
                .keys = &keys,
                .values = &vals,
            },
        },
    };
    const r = try testEncode(Value{ .mapping = .{ .keys = &outer_keys, .values = &outer_vals } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\a:
        \\  b: c
        \\  d: e
    ,
        r,
    );
}

test "encode Value with mixed sequence" {
    const inner_keys = [_]Value{
        Value{ .string = "B" },
    };
    const inner_seq = [_]Value{
        Value{ .integer = 2 },
        Value{ .integer = 3 },
    };
    const inner_vals = [_]Value{
        Value{ .sequence = &inner_seq },
    };
    const seq = [_]Value{
        Value{ .string = "A" },
        Value{ .integer = 1 },
        Value{
            .mapping = .{
                .keys = &inner_keys,
                .values = &inner_vals,
            },
        },
    };
    const outer_keys = [_]Value{
        Value{ .string = "v" },
    };
    const outer_vals = [_]Value{
        Value{ .sequence = &seq },
    };
    const r = try testEncode(Value{ .mapping = .{ .keys = &outer_keys, .values = &outer_vals } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\v:
        \\- A
        \\- 1
        \\- B:
        \\  - 2
        \\  - 3
    ,
        r,
    );
}

test "encode Value string 3s" {
    const keys = [_]Value{
        Value{ .string = "a" },
    };
    const vals = [_]Value{
        Value{ .string = "3s" },
    };
    const r = try testEncode(Value{ .mapping = .{ .keys = &keys, .values = &vals } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a: 3s\n", r);
}

test "encode Value timestamp-like string" {
    const keys = [_]Value{
        Value{ .string = "t2" },
        Value{ .string = "t4" },
    };
    const vals = [_]Value{
        Value{ .string = "2018-01-09T10:40:47Z" },
        Value{ .string = "2098-01-09T10:40:47Z" },
    };
    const r = try testEncode(Value{ .mapping = .{ .keys = &keys, .values = &vals } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\t2: "2018-01-09T10:40:47Z"
        \\t4: "2098-01-09T10:40:47Z"
        \\
    ,
        r,
    );
}

test "encode with single quotes" {
    const r = try testEncodeOpts(@as([]const u8, "'a'b"), .{ .use_single_quote = true });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("'''a''b'\n", r);
}

test "encode single quote with no single" {
    const S = struct { v: []const u8 };
    const r = try testEncodeOpts(S{ .v = "'a'b" }, .{ .use_single_quote = false });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("v: \"'a'b\"\n", r);
}

test "encode single quote backslash yaml" {
    const S = struct { a: []const u8 };
    const r = try testEncodeOpts(S{ .a = "\\.yaml" }, .{ .use_single_quote = true });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a: '\\.yaml'\n", r);
}

test "encode struct with yamlStringify" {
    const Custom = struct {
        x: i64,
        pub fn yamlStringify(
            _: @This(),
            _: Allocator,
        ) !Node {
            return error.Unimplemented;
        }
    };
    const r = try testEncode(Custom{ .x = 1 });
    defer testing.allocator.free(r);
    try testing.expect(r.len > 0);
}

test "encode flow style struct" {
    const Inner = struct {
        a: i64,
        b: []const u8,
        c: struct { d: i64, e: []const u8 },
        f: []const i64,
    };
    const r = try testEncodeOpts(
        Inner{
            .a = 1,
            .b = "hello",
            .c = .{ .d = 3, .e = "world" },
            .f = &.{ 1, 2 },
        },
        .{ .flow_style = true },
    );
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\{a: 1, b: hello, c: {d: 3, e: world}, f: [1, 2]}
        \\
    ,
        r,
    );
}

test "encode flow style slice of ints" {
    const S = struct { a: []const i64 };
    const r = try testEncodeOpts(S{ .a = &.{ 1, 2 } }, .{ .flow_style = true });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{a: [1, 2]}\n", r);
}

test "encode flow style struct fields" {
    const Inner = struct { b: []const u8, d: []const u8 };
    const S = struct { a: Inner };
    const r = try testEncodeOpts(S{ .a = Inner{ .b = "c", .d = "e" } }, .{ .flow_style = true });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{a: {b: c, d: e}}\n", r);
}

test "encode flow comma in string" {
    const S = struct { a: []const []const u8 };
    const r = try testEncodeOpts(S{ .a = &.{ "b", "c,d", "e" } }, .{ .flow_style = true });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{a: [b, \"c,d\", e]}\n", r);
}

test "encode flow bracket in string" {
    const S = struct { a: []const []const u8 };
    const r = try testEncodeOpts(S{ .a = &.{ "b", "c]", "d" } }, .{ .flow_style = true });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{a: [b, \"c]\", d]}\n", r);
}

test "encode flow brace in string" {
    const S = struct { a: []const []const u8 };
    const r = try testEncodeOpts(S{ .a = &.{ "b", "c}", "d" } }, .{ .flow_style = true });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{a: [b, \"c}\", d]}\n", r);
}

test "encode flow double quote in string" {
    const S = struct { a: []const []const u8 };
    const r = try testEncodeOpts(S{ .a = &.{ "b", "c\"", "d" } }, .{ .flow_style = true });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{a: [b, \"c\\\"\", d]}\n", r);
}

test "encode flow single quote in string" {
    const S = struct { a: []const []const u8 };
    const r = try testEncodeOpts(S{ .a = &.{ "b", "c'", "d" } }, .{ .flow_style = true });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{a: [b, \"c'\", d]}\n", r);
}

test "encode non-flow comma in string" {
    const S = struct { a: []const []const u8 };
    const r = try testEncode(S{ .a = &.{ "b", "c,d", "e" } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\a:
        \\- b
        \\- c,d
        \\- e
    ,
        r,
    );
}

test "encode string with dash" {
    const r = try testEncode(@as([]const u8, "-"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\"-\"\n", r);
}

test "encode string with colon space" {
    const r = try testEncode(@as([]const u8, "b: c"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\"b: c\"\n", r);
}

test "encode string angle brackets" {
    const r = try testEncode(@as([]const u8, "<foo>"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("<foo>\n", r);
}

test "encode string ip address" {
    const r = try testEncode(@as([]const u8, "1.2.3.4"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("1.2.3.4\n", r);
}

test "encode string backtick" {
    const r = try testEncode(@as([]const u8, "`b` c"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\"`b` c\"\n", r);
}

test "encode string backslash zero" {
    const r = try testEncode(@as([]const u8, "\\0"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\"\\\\0\"\n", r);
}

test "encode string both spaces" {
    const r = try testEncode(@as([]const u8, " b "));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\" b \"\n", r);
}

test "encode f32 positive" {
    const r = try testEncode(@as(f32, 0.99));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("0.99\n", r);
}

test "encode f32 inf" {
    const r = try testEncode(std.math.inf(f32));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(".inf\n", r);
}

test "encode f32 negative inf" {
    const r = try testEncode(-std.math.inf(f32));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("-.inf\n", r);
}

test "encode f32 nan" {
    const r = try testEncode(std.math.nan(f32));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(".nan\n", r);
}

test "encode u8" {
    const r = try testEncode(@as(u8, 255));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("255\n", r);
}

test "encode u16" {
    const r = try testEncode(@as(u16, 1000));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("1000\n", r);
}

test "encode u32" {
    const r = try testEncode(@as(u32, 100000));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("100000\n", r);
}

test "encode u64" {
    const r = try testEncode(@as(u64, 4294967296));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("4294967296\n", r);
}

test "encode i8" {
    const r = try testEncode(@as(i8, -1));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("-1\n", r);
}

test "encode i16" {
    const r = try testEncode(@as(i16, -100));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("-100\n", r);
}

test "encode i32" {
    const r = try testEncode(@as(i32, -50000));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("-50000\n", r);
}

test "encode optional with value" {
    const r = try testEncode(@as(?i64, 42));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("42\n", r);
}

test "encode optional bool null" {
    const r = try testEncode(@as(?bool, null));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("null\n", r);
}

test "encode optional string null" {
    const r = try testEncode(@as(?[]const u8, null));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("null\n", r);
}

test "encode optional string value" {
    const r = try testEncode(@as(?[]const u8, "hello"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("hello\n", r);
}

test "encode array of ints" {
    const r = try testEncode([_]i64{ 10, 20, 30 });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\- 10
        \\- 20
        \\- 30
    ,
        r,
    );
}

test "encode array of bools" {
    const r = try testEncode([_]bool{ true, false, true });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\- true
        \\- false
        \\- true
    ,
        r,
    );
}

test "encode empty array" {
    const r = try testEncode([_]i64{});
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("[]\n", r);
}

test "encode struct two string fields" {
    const S = struct { a: []const u8, c: []const u8 };
    const r = try testEncode(S{ .a = "b", .c = "d" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\a: b
        \\c: d
    ,
        r,
    );
}

test "encode deeply nested struct" {
    const C = struct { d: i64 };
    const B = struct { c: C };
    const A = struct { b: B };
    const r = try testEncode(A{ .b = B{ .c = C{ .d = 42 } } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\b:
        \\  c:
        \\    d: 42
    ,
        r,
    );
}

test "encode struct with slice field" {
    const S = struct {
        name: []const u8,
        items: []const i64,
    };
    const r = try testEncode(S{ .name = "test", .items = &.{ 1, 2 } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\name: test
        \\items:
        \\- 1
        \\- 2
    ,
        r,
    );
}

test "encode struct with nested slice" {
    const Inner = struct { tags: []const []const u8 };
    const Outer = struct { config: Inner };
    const r = try testEncode(Outer{ .config = Inner{ .tags = &.{ "a", "b" } } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\config:
        \\  tags:
        \\  - a
        \\  - b
    ,
        r,
    );
}

test "encode struct with bool fields" {
    const S = struct { enabled: bool, debug: bool };
    const r = try testEncode(S{ .enabled = true, .debug = false });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\enabled: true
        \\debug: false
    ,
        r,
    );
}

test "encode struct with float fields" {
    const S = struct { x: f64, y: f64 };
    const r = try testEncode(S{ .x = 1.5, .y = -2.5 });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\x: 1.5
        \\y: -2.5
    ,
        r,
    );
}

test "encode struct with optional present" {
    const S = struct { a: i64, b: ?i64 };
    const r = try testEncode(S{ .a = 1, .b = 99 });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\a: 1
        \\b: 99
    ,
        r,
    );
}

test "encode struct with multiple optionals" {
    const S = struct { a: ?i64, b: ?[]const u8 };
    const r = try testEncode(S{ .a = null, .b = null });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\a: null
        \\b: null
    ,
        r,
    );
}

test "encode Value empty sequence" {
    const items = [_]Value{};
    const r = try testEncode(Value{ .sequence = &items });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("[]\n", r);
}

test "encode Value empty mapping" {
    const keys = [_]Value{};
    const vals = [_]Value{};
    const r = try testEncode(Value{ .mapping = .{ .keys = &keys, .values = &vals } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{}\n", r);
}

test "encode Value boolean false" {
    const r = try testEncode(Value{ .boolean = false });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("false\n", r);
}

test "encode Value negative integer" {
    const r = try testEncode(Value{ .integer = -99 });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("-99\n", r);
}

test "encode Value zero integer" {
    const r = try testEncode(Value{ .integer = 0 });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("0\n", r);
}

test "encode Value empty string" {
    const r = try testEncode(Value{ .string = "" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\"\"\n", r);
}

test "encode Value string needing quotes" {
    const r = try testEncode(Value{ .string = "true" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\"true\"\n", r);
}

test "encode Value float inf" {
    const r = try testEncode(Value{ .float = std.math.inf(f64) });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(".inf\n", r);
}

test "encode Value float neg inf" {
    const r = try testEncode(Value{ .float = -std.math.inf(f64) });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("-.inf\n", r);
}

test "encode Value float nan" {
    const r = try testEncode(Value{ .float = std.math.nan(f64) });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(".nan\n", r);
}

test "encode Value sequence of ints" {
    const items = [_]Value{
        Value{ .integer = 1 },
        Value{ .integer = 2 },
        Value{ .integer = 3 },
    };
    const r = try testEncode(Value{ .sequence = &items });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\- 1
        \\- 2
        \\- 3
    ,
        r,
    );
}

test "encode Value sequence of mixed types" {
    const items = [_]Value{
        Value{ .string = "hello" },
        Value{ .integer = 42 },
        Value{ .boolean = true },
        Value.null,
    };
    const r = try testEncode(Value{ .sequence = &items });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\- hello
        \\- 42
        \\- true
        \\- null
    ,
        r,
    );
}

test "encode Value nested sequence" {
    const inner = [_]Value{
        Value{ .integer = 1 },
        Value{ .integer = 2 },
    };
    const items = [_]Value{
        Value{ .string = "a" },
        Value{ .sequence = &inner },
    };
    const r = try testEncode(Value{ .sequence = &items });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\- a
        \\-
        \\  - 1
        \\  - 2
    ,
        r,
    );
}

test "encode Value mapping with sequence value" {
    const seq = [_]Value{
        Value{ .integer = 1 },
        Value{ .integer = 2 },
    };
    const keys = [_]Value{
        Value{ .string = "items" },
    };
    const vals = [_]Value{
        Value{ .sequence = &seq },
    };
    const r = try testEncode(Value{ .mapping = .{ .keys = &keys, .values = &vals } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\items:
        \\- 1
        \\- 2
    ,
        r,
    );
}

test "encode Value mapping with null value" {
    const keys = [_]Value{
        Value{ .string = "v" },
    };
    const vals = [_]Value{Value.null};
    const r = try testEncode(Value{ .mapping = .{ .keys = &keys, .values = &vals } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("v: null\n", r);
}

test "encode Value mapping with empty string" {
    const keys = [_]Value{
        Value{ .string = "v" },
    };
    const vals = [_]Value{
        Value{ .string = "" },
    };
    const r = try testEncode(Value{ .mapping = .{ .keys = &keys, .values = &vals } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("v: \"\"\n", r);
}

test "encode Value int key mapping" {
    const keys = [_]Value{
        Value{ .integer = 1 },
    };
    const vals = [_]Value{
        Value{ .string = "v" },
    };
    const r = try testEncode(Value{ .mapping = .{ .keys = &keys, .values = &vals } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("1: v\n", r);
}

test "encode Value float key mapping" {
    const keys = [_]Value{
        Value{ .float = 1.1 },
    };
    const vals = [_]Value{
        Value{ .string = "v" },
    };
    const r = try testEncode(Value{ .mapping = .{ .keys = &keys, .values = &vals } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("1.1: v\n", r);
}

test "encode Value bool key mapping" {
    const keys = [_]Value{
        Value{ .boolean = true },
    };
    const vals = [_]Value{
        Value{ .string = "v" },
    };
    const r = try testEncode(Value{ .mapping = .{ .keys = &keys, .values = &vals } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("true: v\n", r);
}

test "encode multiline string with cr" {
    const S = struct { hello: []const u8 };
    const r = try testEncode(S{ .hello = "hello\rworld\r" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("hello: |\r  hello\r  world\n", r);
}

test "encode multiline string with crlf" {
    const S = struct { hello: []const u8 };
    const r = try testEncode(S{ .hello = "hello\r\nworld\r\n" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("hello: |\r\n  hello\r\n  world\n", r);
}

test "encode struct with nested struct" {
    const M = struct { x: []const u8 };
    const U = struct { m: M };
    const T = struct { a: U };
    const r = try testEncode(T{ .a = U{ .m = M{ .x = "y" } } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a:\n  m:\n    x: \"y\"\n", r);
}

test "encode struct with f64 1.0" {
    const S = struct { v: f64 };
    const r = try testEncode(S{ .v = 1.0 });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("v: 1.0\n", r);
}

test "encode multiline bare string keep" {
    const r = try testEncode(@as([]const u8, "hello\nworld\n"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\|
        \\  hello
        \\  world
    ,
        r,
    );
}

test "encode multiline bare string strip" {
    const r = try testEncode(@as([]const u8, "hello\nworld"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\|-
        \\  hello
        \\  world
    ,
        r,
    );
}

test "encode multiline bare string plus" {
    const r = try testEncode(@as([]const u8, "hello\nworld\n\n"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\|+
        \\  hello
        \\  world
        \\
    ,
        r,
    );
}

test "encode struct with multiline at depth" {
    const Inner = struct { key: []const u8 };
    const Outer = struct { outer: Inner };
    const r = try testEncode(Outer{ .outer = Inner{ .key = "line1\nline2\nline3" } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\outer:
        \\  key: |-
        \\    line1
        \\    line2
        \\    line3
        \\
    ,
        r,
    );
}

test "encode indent 4 multiline" {
    const S = struct { key: []const u8 };
    const r = try testEncodeOpts(S{ .key = "line1\nline2\nline3" }, .{ .indent = 4 });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\key: |-
        \\    line1
        \\    line2
        \\    line3
        \\
    ,
        r,
    );
}

test "encode slice of structs" {
    const Item = struct { name: []const u8 };
    const r = try testEncode(@as([]const Item, &.{ Item{ .name = "a" }, Item{ .name = "b" } }));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\- name: a
        \\- name: b
    ,
        r,
    );
}

test "encode struct with slice of structs" {
    const Item = struct { id: i64 };
    const S = struct { items: []const Item };
    const r = try testEncode(S{ .items = &.{ Item{ .id = 1 }, Item{ .id = 2 } } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\items:
        \\- id: 1
        \\- id: 2
    ,
        r,
    );
}

test "encode struct with all field types" {
    const S = struct {
        name: []const u8,
        count: i64,
        rate: f64,
        active: bool,
    };
    const r = try testEncode(S{ .name = "test", .count = 5, .rate = 1.5, .active = true });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\name: test
        \\count: 5
        \\rate: 1.5
        \\active: true
        \\
    ,
        r,
    );
}

test "encode flow empty struct" {
    const S = struct {};
    const r = try testEncodeOpts(S{}, .{ .flow_style = true });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{}\n", r);
}

test "encode flow empty slice" {
    const r = try testEncodeOpts(@as([]const i64, &.{}), .{ .flow_style = true });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("[]\n", r);
}

test "encode flow single value" {
    const S = struct { x: i64 };
    const r = try testEncodeOpts(S{ .x = 1 }, .{ .flow_style = true });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{x: 1}\n", r);
}

test "encode flow nested" {
    const Inner = struct {
        test_field: []const i64,
    };
    const Outer = struct { m: Inner };
    const r = try testEncodeOpts(
        Outer{
            .m = Inner{
                .test_field = &.{ 1, 2, 3 },
            },
        },
        .{ .flow_style = true },
    );
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{m: {test_field: [1, 2, 3]}}\n", r);
}

test "encode f64 zero" {
    const r = try testEncode(@as(f64, 0.0));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("0.0\n", r);
}

test "encode f64 one" {
    const r = try testEncode(@as(f64, 1.0));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("1.0\n", r);
}

test "encode struct single bool field" {
    const S = struct { c: bool };
    const r = try testEncode(S{ .c = true });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("c: true\n", r);
}

test "encode struct three fields" {
    const S = struct {
        a: i64,
        b: []const u8,
        c: bool,
    };
    const r = try testEncode(S{ .a = 1, .b = "hello", .c = true });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\a: 1
        \\b: hello
        \\c: true
    ,
        r,
    );
}

test "encode string null" {
    const r = try testEncode(@as([]const u8, "null"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\"null\"\n", r);
}

test "encode string yes" {
    const r = try testEncode(@as([]const u8, "yes"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\"yes\"\n", r);
}

test "encode string no" {
    const r = try testEncode(@as([]const u8, "no"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\"no\"\n", r);
}

test "encode string on" {
    const r = try testEncode(@as([]const u8, "on"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\"on\"\n", r);
}

test "encode string off" {
    const r = try testEncode(@as([]const u8, "off"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\"off\"\n", r);
}

test "encode string tilde" {
    const r = try testEncode(@as([]const u8, "~"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\"~\"\n", r);
}

test "encode string numeric" {
    const r = try testEncode(@as([]const u8, "123"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\"123\"\n", r);
}

test "encode string float-like" {
    const r = try testEncode(@as([]const u8, "1.5"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\"1.5\"\n", r);
}

test "encode string .inf" {
    const r = try testEncode(@as([]const u8, ".inf"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\".inf\"\n", r);
}

test "encode string .nan" {
    const r = try testEncode(@as([]const u8, ".nan"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\".nan\"\n", r);
}

test "encode struct optional string present" {
    const S = struct { a: ?[]const u8 };
    const r = try testEncode(S{ .a = "hello" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a: hello\n", r);
}

test "encode struct optional string null" {
    const S = struct { a: ?[]const u8 };
    const r = try testEncode(S{ .a = null });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a: null\n", r);
}

test "encode struct with empty optional string" {
    const s: []const u8 = "";
    const S = struct { a: ?[]const u8 };
    const r = try testEncode(S{ .a = s });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a: \"\"\n", r);
}

test "encode struct optional bool present" {
    const S = struct { a: ?bool };
    const r = try testEncode(S{ .a = false });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a: false\n", r);
}

test "encode struct optional float present" {
    const S = struct { a: ?f64 };
    const r = try testEncode(S{ .a = 3.14 });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a: 3.14\n", r);
}

test "encode struct optional float null" {
    const S = struct { a: ?f64 };
    const r = try testEncode(S{ .a = null });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a: null\n", r);
}

test "encode slice of bools" {
    const r = try testEncode(@as([]const bool, &.{ true, false }));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\- true
        \\- false
    ,
        r,
    );
}

test "encode slice of floats" {
    const r = try testEncode(@as([]const f64, &.{ 1.1, 2.2 }));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\- 1.1
        \\- 2.2
    ,
        r,
    );
}

test "encode single element slice" {
    const r = try testEncode(@as([]const i64, &.{42}));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("- 42\n", r);
}

test "encode large struct" {
    const S = struct {
        a: i64,
        b: i64,
        c: i64,
        d: i64,
        e: i64,
    };
    const r = try testEncode(S{
        .a = 1,
        .b = 2,
        .c = 3,
        .d = 4,
        .e = 5,
    });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\a: 1
        \\b: 2
        \\c: 3
        \\d: 4
        \\e: 5
    ,
        r,
    );
}

test "encode struct with nested optional" {
    const Inner = struct { x: i64 };
    const Outer = struct { inner: ?Inner };
    const r = try testEncode(Outer{ .inner = Inner{ .x = 5 } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\inner:
        \\  x: 5
    ,
        r,
    );
}

test "encode struct with nested optional null" {
    const Inner = struct { x: i64 };
    const Outer = struct { inner: ?Inner };
    const r = try testEncode(Outer{ .inner = null });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("inner: null\n", r);
}

test "encode flow Value mapping" {
    const keys = [_]Value{
        Value{ .string = "a" },
        Value{ .string = "b" },
    };
    const vals = [_]Value{
        Value{ .integer = 1 },
        Value{ .integer = 2 },
    };
    const r = try testEncodeOpts(
        Value{ .mapping = .{
            .keys = &keys,
            .values = &vals,
        } },
        .{ .flow_style = true },
    );
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{a: 1, b: 2}\n", r);
}

test "encode flow Value sequence" {
    const items = [_]Value{
        Value{ .integer = 1 },
        Value{ .integer = 2 },
        Value{ .integer = 3 },
    };
    const r = try testEncodeOpts(Value{ .sequence = &items }, .{ .flow_style = true });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("[1, 2, 3]\n", r);
}

test "encode string with tab" {
    const r = try testEncode(@as([]const u8, "a\tb"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\"a\\tb\"\n", r);
}

test "encode string with newline only" {
    const r = try testEncode(@as([]const u8, "\n"));
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("\"\\n\"\n", r);
}

test "encode struct with array field" {
    const S = struct { v: [3]i64 };
    const r = try testEncode(S{ .v = .{ 1, 2, 3 } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\v:
        \\- 1
        \\- 2
        \\- 3
    ,
        r,
    );
}

test "encode struct with nested empty slice" {
    const Inner = struct { items: []const i64 };
    const Outer = struct { data: Inner };
    const r = try testEncode(Outer{ .data = Inner{ .items = &.{} } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\data:
        \\  items: []
    ,
        r,
    );
}

test "encode Value mapping with bool values" {
    const keys = [_]Value{
        Value{ .string = "x" },
        Value{ .string = "y" },
    };
    const vals = [_]Value{
        Value{ .boolean = true },
        Value{ .boolean = false },
    };
    const r = try testEncode(Value{ .mapping = .{ .keys = &keys, .values = &vals } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\x: true
        \\y: false
    ,
        r,
    );
}

test "encode Value mapping with float value" {
    const keys = [_]Value{
        Value{ .string = "a" },
    };
    const vals = [_]Value{
        Value{ .float = 100.5 },
    };
    const r = try testEncode(Value{ .mapping = .{ .keys = &keys, .values = &vals } });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("a: 100.5\n", r);
}

test "encode struct many string fields" {
    const S = struct {
        first: []const u8,
        second: []const u8,
        third: []const u8,
    };
    const r = try testEncode(S{ .first = "a", .second = "b", .third = "c" });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        \\first: a
        \\second: b
        \\third: c
    ,
        r,
    );
}

test "encode flow string needing quotes" {
    const S = struct { a: []const u8 };
    const r = try testEncodeOpts(S{ .a = "b: c" }, .{ .flow_style = true });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{a: \"b: c\"}\n", r);
}

test "encode flow with null optional" {
    const S = struct { a: ?i64 };
    const r = try testEncodeOpts(S{ .a = null }, .{ .flow_style = true });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{a: null}\n", r);
}

test "encode flow bool values" {
    const S = struct { a: bool, b: bool };
    const r = try testEncodeOpts(S{ .a = true, .b = false }, .{ .flow_style = true });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("{a: true, b: false}\n", r);
}
test "encode round-trip integer" {
    const encoded = try testEncode(@as(i64, 42));
    defer testing.allocator.free(encoded);
    const decoded = try decoder.decode(i64, testing.allocator, encoded, .{});
    try testing.expectEqual(@as(i64, 42), decoded);
}

test "encode round-trip string" {
    const encoded = try testEncode(@as([]const u8, "hello"));
    defer testing.allocator.free(encoded);
    const decoded = try decoder.decode([]const u8, testing.allocator, encoded, .{});
    try testing.expectEqualStrings("hello", decoded);
}

test "encode round-trip bool" {
    const encoded = try testEncode(true);
    defer testing.allocator.free(encoded);
    const decoded = try decoder.decode(bool, testing.allocator, encoded, .{});
    try testing.expect(decoded);
}

test "encode f64 scientific small" {
    const S = struct { v: f64 };
    const output = try testEncode(S{ .v = 0.000001 });
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("v: 1e-06\n", output);
}

test "encode f64 scientific large" {
    const S = struct { v: f64 };
    const output = try testEncode(S{ .v = 1000000.0 });
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("v: 1e+06\n", output);
}

test "encode f64 one point zero" {
    const S = struct { v: f64 };
    const output = try testEncode(S{ .v = 1.0 });
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("v: 1.0\n", output);
}

test "encode f32 scientific small" {
    const S = struct { v: f32 };
    const output = try testEncode(S{ .v = 1e-06 });
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("v: 1e-06\n", output);
}

test "encode multiline with cr line endings" {
    const S = struct { hello: []const u8 };
    const output = try testEncode(S{ .hello = "hello\rworld\r" });
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("hello: |\r  hello\r  world\n", output);
}

test "encode multiline with crlf line endings" {
    const S = struct { hello: []const u8 };
    const output = try testEncode(S{ .hello = "hello\r\nworld\r\n" });
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("hello: |\r\n  hello\r\n  world\n", output);
}

test "encode multi-byte unicode string" {
    const S = struct { v: []const u8 };
    const output = try testEncode(S{ .v = "\xc3\xa9\xc3\xa0\xc3\xbc" });
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("v: \xc3\xa9\xc3\xa0\xc3\xbc\n", output);
}

test "encode struct omit empty string" {
    const S = struct { a: []const u8, b: []const u8 };
    const output = try testEncodeWithOptions(S{ .a = "hello", .b = "" }, .{ .omit_empty = true });
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("a: hello\n", output);
}

test "encode struct omit null optional" {
    const S = struct { a: []const u8, b: ?[]const u8 };
    const output = try testEncodeWithOptions(S{ .a = "hello", .b = null }, .{ .omit_empty = true });
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("a: hello\n", output);
}

test "encode struct omit zero int" {
    const S = struct { a: i64, b: i64 };
    const output = try testEncodeWithOptions(S{ .a = 42, .b = 0 }, .{ .omit_empty = true });
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("a: 42\n", output);
}

test "encode struct omit false bool" {
    const S = struct { a: bool, b: bool };
    const output = try testEncodeWithOptions(S{ .a = true, .b = false }, .{ .omit_empty = true });
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("a: true\n", output);
}

test "encode struct omit empty slice" {
    const S = struct { a: i64, b: []const []const u8 };
    const output = try testEncodeWithOptions(S{ .a = 1, .b = &.{} }, .{ .omit_empty = true });
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("a: 1\n", output);
}

test "encode struct no omit when disabled" {
    const S = struct { a: i64, b: i64 };
    const output = try testEncode(S{ .a = 42, .b = 0 });
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("a: 42\nb: 0\n", output);
}

test "encode indent sequence true" {
    const S = struct { v: []const []const u8 };
    const r = try testEncodeOpts(S{ .v = &.{ "A", "B" } }, .{ .indent_sequence = true });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("v:\n  - A\n  - B\n", r);
}

test "encode indent sequence false" {
    const S = struct { v: []const []const u8 };
    const r = try testEncodeOpts(S{ .v = &.{ "A", "B" } }, .{ .indent_sequence = false });
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("v:\n- A\n- B\n", r);
}

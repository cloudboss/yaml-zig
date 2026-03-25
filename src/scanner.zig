const std = @import("std");
const Allocator = std.mem.Allocator;

const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;

pub const Scanner = struct {
    allocator: Allocator,
    source: []const u8,

    pub fn init(allocator: Allocator, source: []const u8) Scanner {
        return .{
            .allocator = allocator,
            .source = source,
        };
    }

    pub fn deinit(self: *Scanner) void {
        _ = self;
    }

    pub fn scan(self: *Scanner) ![]Token {
        _ = self;
        return error.Unimplemented;
    }
};

fn expectTokenTypes(source: []const u8, expected: []const TokenType) !void {
    var s = Scanner.init(std.testing.allocator, source);
    defer s.deinit();
    const tokens = try s.scan();
    try std.testing.expectEqual(expected.len, tokens.len);
    for (tokens, expected) |tok, exp| {
        try std.testing.expectEqual(exp, tok.token_type);
    }
}

fn expectTokenTypesAndValues(
    source: []const u8,
    expected_types: []const TokenType,
    expected_values: []const []const u8,
) !void {
    var s = Scanner.init(std.testing.allocator, source);
    defer s.deinit();
    const tokens = try s.scan();
    try std.testing.expectEqual(expected_types.len, tokens.len);
    for (tokens, expected_types, expected_values) |tok, et, ev| {
        try std.testing.expectEqual(et, tok.token_type);
        try std.testing.expectEqualStrings(ev, tok.value);
    }
}

test "scan null" {
    try expectTokenTypesAndValues("null\n  ", &.{.null_value}, &.{"null"});
}

test "scan integer with underscore" {
    try expectTokenTypesAndValues("0_", &.{.integer}, &.{"0_"});
}

test "scan double quoted with tab escape" {
    try expectTokenTypesAndValues("\"hello\\tworld\"", &.{.double_quote}, &.{"hello\tworld"});
}

test "scan hex integer with underscores" {
    try expectTokenTypesAndValues("0x_1A_2B_3C", &.{.integer}, &.{"0x_1A_2B_3C"});
}

test "scan positive binary integer" {
    try expectTokenTypesAndValues("+0b1010", &.{.integer}, &.{"+0b1010"});
}

test "scan legacy octal integer 0100" {
    try expectTokenTypesAndValues("0100", &.{.integer}, &.{"0100"});
}

test "scan octal integer 0o10" {
    try expectTokenTypesAndValues("0o10", &.{.integer}, &.{"0o10"});
}

test "scan scientific notation" {
    try expectTokenTypesAndValues("0.123e+123", &.{.float}, &.{"0.123e+123"});
}

test "scan empty mapping braces" {
    try expectTokenTypesAndValues("{}\n  ", &.{ .mapping_start, .mapping_end }, &.{ "{", "}" });
}

test "scan key value v hi" {
    try expectTokenTypesAndValues(
        "v: hi",
        &.{ .string, .mapping_value, .string },
        &.{ "v", ":", "hi" },
    );
}

test "scan key with tab separated value" {
    try expectTokenTypesAndValues(
        "v:\ta",
        &.{ .string, .mapping_value, .string },
        &.{ "v", ":", "a" },
    );
}

test "scan key with quoted true value" {
    try expectTokenTypesAndValues(
        "v: \"true\"",
        &.{ .string, .mapping_value, .double_quote },
        &.{ "v", ":", "true" },
    );
}

test "scan key with quoted false value" {
    try expectTokenTypesAndValues(
        "v: \"false\"",
        &.{ .string, .mapping_value, .double_quote },
        &.{ "v", ":", "false" },
    );
}

test "scan key with bool true" {
    try expectTokenTypesAndValues(
        "v: true",
        &.{ .string, .mapping_value, .bool_value },
        &.{ "v", ":", "true" },
    );
}

test "scan key with bool false" {
    try expectTokenTypesAndValues(
        "v: false",
        &.{ .string, .mapping_value, .bool_value },
        &.{ "v", ":", "false" },
    );
}

test "scan key with integer 10" {
    try expectTokenTypesAndValues(
        "v: 10",
        &.{ .string, .mapping_value, .integer },
        &.{ "v", ":", "10" },
    );
}

test "scan key with negative integer -10" {
    try expectTokenTypesAndValues(
        "v: -10",
        &.{ .string, .mapping_value, .integer },
        &.{ "v", ":", "-10" },
    );
}

test "scan key with integer 42" {
    try expectTokenTypesAndValues(
        "v: 42",
        &.{ .string, .mapping_value, .integer },
        &.{ "v", ":", "42" },
    );
}

test "scan key with large integer" {
    try expectTokenTypesAndValues(
        "v: 4294967296",
        &.{ .string, .mapping_value, .integer },
        &.{ "v", ":", "4294967296" },
    );
}

test "scan key with quoted integer" {
    try expectTokenTypesAndValues(
        "v: \"10\"",
        &.{ .string, .mapping_value, .double_quote },
        &.{ "v", ":", "10" },
    );
}

test "scan key with float 0.1" {
    try expectTokenTypesAndValues(
        "v: 0.1",
        &.{ .string, .mapping_value, .float },
        &.{ "v", ":", "0.1" },
    );
}

test "scan key with float 0.99" {
    try expectTokenTypesAndValues(
        "v: 0.99",
        &.{ .string, .mapping_value, .float },
        &.{ "v", ":", "0.99" },
    );
}

test "scan key with negative float" {
    try expectTokenTypesAndValues(
        "v: -0.1",
        &.{ .string, .mapping_value, .float },
        &.{ "v", ":", "-0.1" },
    );
}

test "scan key with infinity" {
    try expectTokenTypesAndValues(
        "v: .inf",
        &.{ .string, .mapping_value, .infinity },
        &.{ "v", ":", ".inf" },
    );
}

test "scan key with negative infinity" {
    try expectTokenTypesAndValues(
        "v: -.inf",
        &.{ .string, .mapping_value, .infinity },
        &.{ "v", ":", "-.inf" },
    );
}

test "scan key with nan" {
    try expectTokenTypesAndValues(
        "v: .nan",
        &.{ .string, .mapping_value, .nan },
        &.{ "v", ":", ".nan" },
    );
}

test "scan multiline double quoted string" {
    try expectTokenTypesAndValues(
        \\
        \\a:
        \\  "bbb  \
        \\      ccc
        \\
        \\      ddd eee\n\
        \\  \ \ fff ggg\nhhh iii\n
        \\  jjj kkk
        \\  "
        \\
    ,
        &.{ .string, .mapping_value, .double_quote },
        &.{
            "a",
            ":",
            "bbb  ccc\nddd eee\n  fff ggg\nhhh iii\n jjj kkk ",
        },
    );
}

test "scan key with null value" {
    try expectTokenTypesAndValues(
        "v: null",
        &.{ .string, .mapping_value, .null_value },
        &.{ "v", ":", "null" },
    );
}

test "scan key with empty double quote" {
    try expectTokenTypesAndValues(
        "v: \"\"",
        &.{ .string, .mapping_value, .double_quote },
        &.{ "v", ":", "" },
    );
}

test "scan block sequence under map" {
    try expectTokenTypesAndValues(
        \\
        \\v:
        \\- A
        \\- B
    ,
        &.{
            .string,
            .mapping_value,
            .sequence_entry,
            .string,
            .sequence_entry,
            .string,
        },
        &.{ "v", ":", "-", "A", "-", "B" },
    );
}

test "scan sequence with literal block" {
    try expectTokenTypesAndValues(
        \\
        \\v:
        \\- A
        \\- |-
        \\ B
        \\ C
    ,
        &.{
            .string,
            .mapping_value,
            .sequence_entry,
            .string,
            .sequence_entry,
            .literal,
            .string,
        },
        &.{ "v", ":", "-", "A", "-", "|-", "B\nC" },
    );
}

test "scan nested sequence with map" {
    try expectTokenTypesAndValues(
        \\
        \\v:
        \\- A
        \\- 1
        \\- B:
        \\ - 2
        \\ - 3
    ,
        &.{
            .string,
            .mapping_value,
            .sequence_entry,
            .string,
            .sequence_entry,
            .integer,
            .sequence_entry,
            .string,
            .mapping_value,
            .sequence_entry,
            .integer,
            .sequence_entry,
            .integer,
        },
        &.{ "v", ":", "-", "A", "-", "1", "-", "B", ":", "-", "2", "-", "3" },
    );
}

test "scan nested map" {
    try expectTokenTypesAndValues(
        \\
        \\a:
        \\ b: c
    ,
        &.{
            .string,
            .mapping_value,
            .string,
            .mapping_value,
            .string,
        },
        &.{ "a", ":", "b", ":", "c" },
    );
}

test "scan single quoted dash" {
    try expectTokenTypesAndValues(
        "a: '-'",
        &.{ .string, .mapping_value, .single_quote },
        &.{ "a", ":", "-" },
    );
}

test "scan bare integer 123" {
    try expectTokenTypesAndValues("123", &.{.integer}, &.{"123"});
}

test "scan hello world mapping" {
    try expectTokenTypesAndValues(
        "hello: world\n",
        &.{ .string, .mapping_value, .string },
        &.{ "hello", ":", "world" },
    );
}

test "scan a null mapping" {
    try expectTokenTypesAndValues(
        "a: null",
        &.{ .string, .mapping_value, .null_value },
        &.{ "a", ":", "null" },
    );
}

test "scan flow mapping a x 1" {
    try expectTokenTypesAndValues(
        "a: {x: 1}",
        &.{
            .string,
            .mapping_value,
            .mapping_start,
            .string,
            .mapping_value,
            .integer,
            .mapping_end,
        },
        &.{ "a", ":", "{", "x", ":", "1", "}" },
    );
}

test "scan flow sequence a 1 2" {
    try expectTokenTypesAndValues(
        "a: [1, 2]",
        &.{
            .string,
            .mapping_value,
            .sequence_start,
            .integer,
            .collect_entry,
            .integer,
            .sequence_end,
        },
        &.{ "a", ":", "[", "1", ",", "2", "]" },
    );
}

test "scan timestamp values" {
    try expectTokenTypesAndValues(
        \\
        \\t2: 2018-01-09T10:40:47Z
        \\t4: 2098-01-09T10:40:47Z
        \\
    ,
        &.{
            .string,
            .mapping_value,
            .string,
            .string,
            .mapping_value,
            .string,
        },
        &.{ "t2", ":", "2018-01-09T10:40:47Z", "t4", ":", "2098-01-09T10:40:47Z" },
    );
}

test "scan flow mapping with multiple keys" {
    try expectTokenTypesAndValues(
        "a: {b: c, d: e}",
        &.{
            .string,
            .mapping_value,
            .mapping_start,
            .string,
            .mapping_value,
            .string,
            .collect_entry,
            .string,
            .mapping_value,
            .string,
            .mapping_end,
        },
        &.{ "a", ":", "{", "b", ":", "c", ",", "d", ":", "e", "}" },
    );
}

test "scan duration-like string" {
    try expectTokenTypesAndValues(
        "a: 3s",
        &.{ .string, .mapping_value, .string },
        &.{ "a", ":", "3s" },
    );
}

test "scan angle bracket string" {
    try expectTokenTypesAndValues(
        "a: <foo>",
        &.{ .string, .mapping_value, .string },
        &.{ "a", ":", "<foo>" },
    );
}

test "scan quoted colon string" {
    try expectTokenTypesAndValues(
        "a: \"1:1\"",
        &.{ .string, .mapping_value, .double_quote },
        &.{ "a", ":", "1:1" },
    );
}

test "scan null byte in double quote" {
    try expectTokenTypesAndValues(
        "a: \"\\0\"",
        &.{ .string, .mapping_value, .double_quote },
        &.{ "a", ":", "\x00" },
    );
}

test "scan tag binary" {
    try expectTokenTypesAndValues(
        "a: !!binary gIGC",
        &.{ .string, .mapping_value, .tag, .string },
        &.{ "a", ":", "!!binary", "gIGC" },
    );
}

test "scan tag binary with literal block" {
    try expectTokenTypesAndValues(
        \\
        \\a: !!binary |
        \\ kJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJ
        \\ CQ
        \\
    ,
        &.{
            .string,
            .mapping_value,
            .tag,
            .literal,
            .string,
        },
        &.{
            "a",
            ":",
            "!!binary",
            "|",
            "kJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJ\nCQ\n",
        },
    );
}

test "scan multiple keys with sub map" {
    try expectTokenTypesAndValues(
        \\
        \\b: 2
        \\a: 1
        \\d: 4
        \\c: 3
        \\sub:
        \\  e: 5
    ,
        &.{
            .string,        .mapping_value, .integer,
            .string,        .mapping_value, .integer,
            .string,        .mapping_value, .integer,
            .string,        .mapping_value, .integer,
            .string,        .mapping_value, .string,
            .mapping_value, .integer,
        },
        &.{ "b", ":", "2", "a", ":", "1", "d", ":", "4", "c", ":", "3", "sub", ":", "e", ":", "5" },
    );
}

test "scan ip address as string" {
    try expectTokenTypesAndValues(
        "a: 1.2.3.4",
        &.{ .string, .mapping_value, .string },
        &.{ "a", ":", "1.2.3.4" },
    );
}

test "scan quoted timestamp" {
    try expectTokenTypesAndValues(
        "a: \"2015-02-24T18:19:39Z\"",
        &.{ .string, .mapping_value, .double_quote },
        &.{ "a", ":", "2015-02-24T18:19:39Z" },
    );
}

test "scan single quoted with colon" {
    try expectTokenTypesAndValues(
        "a: 'b: c'",
        &.{ .string, .mapping_value, .single_quote },
        &.{ "a", ":", "b: c" },
    );
}

test "scan single quoted with hash" {
    try expectTokenTypesAndValues(
        "a: 'Hello #comment'",
        &.{ .string, .mapping_value, .single_quote },
        &.{ "a", ":", "Hello #comment" },
    );
}

test "scan float 100.5" {
    try expectTokenTypesAndValues(
        "a: 100.5",
        &.{ .string, .mapping_value, .float },
        &.{ "a", ":", "100.5" },
    );
}

test "scan bogus string value" {
    try expectTokenTypesAndValues(
        "a: bogus",
        &.{ .string, .mapping_value, .string },
        &.{ "a", ":", "bogus" },
    );
}

test "scan double quoted map key" {
    try expectTokenTypesAndValues(
        "\"a\": double quoted map key",
        &.{ .double_quote, .mapping_value, .string },
        &.{ "a", ":", "double quoted map key" },
    );
}

test "scan single quoted map key" {
    try expectTokenTypesAndValues(
        "'a': single quoted map key",
        &.{ .single_quote, .mapping_value, .string },
        &.{ "a", ":", "single quoted map key" },
    );
}

test "scan double quoted key value pairs" {
    try expectTokenTypesAndValues(
        \\
        \\a: "double quoted"
        \\b: "value map"
    ,
        &.{
            .string, .mapping_value, .double_quote,
            .string, .mapping_value, .double_quote,
        },
        &.{ "a", ":", "double quoted", "b", ":", "value map" },
    );
}

test "scan single quoted key value pairs" {
    try expectTokenTypesAndValues(
        \\
        \\a: 'single quoted'
        \\b: 'value map'
    ,
        &.{
            .string, .mapping_value, .single_quote,
            .string, .mapping_value, .single_quote,
        },
        &.{ "a", ":", "single quoted", "b", ":", "value map" },
    );
}

test "scan single quoted json expression" {
    try expectTokenTypesAndValues(
        "json: '\\\"expression\\\": \\\"thi:\\\"'",
        &.{ .string, .mapping_value, .single_quote },
        &.{ "json", ":", "\\\"expression\\\": \\\"thi:\\\"" },
    );
}

test "scan double quoted json expression" {
    try expectTokenTypesAndValues(
        "json: \"\\\"expression\\\": \\\"thi:\\\"\"",
        &.{ .string, .mapping_value, .double_quote },
        &.{ "json", ":", "\"expression\": \"thi:\"" },
    );
}

test "scan multiline plain scalar" {
    try expectTokenTypesAndValues(
        \\
        \\a:
        \\ b
        \\
        \\ c
    ,
        &.{ .string, .mapping_value, .string },
        &.{ "a", ":", "b\nc" },
    );
}

test "scan multiline plain scalar with trailing ws" {
    try expectTokenTypesAndValues(
        "\na:   \n b   \n\n  \n c\n d \ne: f\n",
        &.{
            .string, .mapping_value, .string,
            .string, .mapping_value, .string,
        },
        &.{ "a", ":", "b\nc d", "e", ":", "f" },
    );
}

test "scan literal block with whitespace" {
    try expectTokenTypesAndValues(
        "\na: |\n b   \n\n  \n c\n d \ne: f\n",
        &.{
            .string, .mapping_value, .literal, .string,
            .string, .mapping_value, .string,
        },
        &.{
            "a",                  ":", "|",
            "b   \n\n \nc\nd \n", "e", ":",
            "f",
        },
    );
}

test "scan folded block with whitespace" {
    try expectTokenTypesAndValues(
        "\na: >\n b   \n\n  \n c\n d \ne: f\n",
        &.{
            .string, .mapping_value, .folded, .string,
            .string, .mapping_value, .string,
        },
        &.{
            "a",                 ":", ">",
            "b   \n\n \nc d \n", "e", ":",
            "f",
        },
    );
}

test "scan folded block simple text" {
    try expectTokenTypesAndValues(
        "\na: >\n  Text",
        &.{
            .string,
            .mapping_value,
            .folded,
            .string,
        },
        &.{ "a", ":", ">", "Text" },
    );
}

test "scan folded block with string-like content" {
    try expectTokenTypesAndValues(
        \\
        \\s: >
        \\        1s
    ,
        &.{
            .string,
            .mapping_value,
            .folded,
            .string,
        },
        &.{ "s", ":", ">", "1s" },
    );
}

test "scan folded with indent and comment" {
    try expectTokenTypesAndValues(
        \\
        \\s: >1        # comment
        \\        1s
    ,
        &.{
            .string,
            .mapping_value,
            .folded,
            .comment,
            .string,
        },
        &.{ "s", ":", ">1", " comment", "       1s" },
    );
}

test "scan folded with keep and indent" {
    try expectTokenTypesAndValues(
        \\
        \\s: >+2
        \\        1s
    ,
        &.{
            .string,
            .mapping_value,
            .folded,
            .string,
        },
        &.{ "s", ":", ">+2", "      1s\n" },
    );
}

test "scan folded with strip and indent" {
    try expectTokenTypesAndValues(
        \\
        \\s: >-3
        \\        1s
    ,
        &.{
            .string,
            .mapping_value,
            .folded,
            .string,
        },
        &.{ "s", ":", ">-3", "     1s" },
    );
}

test "scan folded two lines same indent" {
    try expectTokenTypesAndValues(
        \\
        \\s: >
        \\    1s
        \\    2s
    ,
        &.{
            .string,
            .mapping_value,
            .folded,
            .string,
        },
        &.{ "s", ":", ">", "1s 2s\n" },
    );
}

test "scan folded three lines mixed indent" {
    try expectTokenTypesAndValues(
        \\
        \\s: >
        \\    1s
        \\      2s
        \\    3s
    ,
        &.{
            .string,
            .mapping_value,
            .folded,
            .string,
        },
        &.{ "s", ":", ">", "1s\n  2s\n3s\n" },
    );
}

test "scan folded five lines mixed indent" {
    try expectTokenTypesAndValues(
        \\
        \\s: >
        \\    1s
        \\      2s
        \\      3s
        \\    4s
        \\    5s
        \\
    ,
        &.{
            .string,
            .mapping_value,
            .folded,
            .string,
        },
        &.{
            "s",
            ":",
            ">",
            "1s\n  2s\n  3s\n4s 5s\n",
        },
    );
}

test "scan folded strip with indent five lines" {
    try expectTokenTypesAndValues(
        \\
        \\s: >-3
        \\    1s
        \\      2s
        \\      3s
        \\    4s
        \\    5s
        \\
    ,
        &.{
            .string,
            .mapping_value,
            .folded,
            .string,
        },
        &.{
            "s",
            ":",
            ">-3",
            " 1s\n   2s\n   3s\n 4s\n 5s",
        },
    );
}

test "scan literal with strip and indent" {
    try expectTokenTypesAndValues(
        \\
        \\|2-
        \\
        \\                  text
    ,
        &.{ .literal, .string },
        &.{ "|2-", "\n                text" },
    );
}

test "scan literal with trailing newlines" {
    try expectTokenTypesAndValues(
        \\
        \\|
        \\  a
        \\
        \\
        \\
    ,
        &.{ .literal, .string },
        &.{ "|", "a\n" },
    );
}

test "scan literal with comment after header" {
    try expectTokenTypesAndValues(
        "\n|  \t\t  # comment\n  foo\n",
        &.{ .literal, .comment, .string },
        &.{ "|", " comment", "foo\n" },
    );
}

test "scan invalid number 1x0 as string" {
    try expectTokenTypesAndValues("1x0", &.{.string}, &.{"1x0"});
}

test "scan invalid binary 0b98765 as string" {
    try expectTokenTypesAndValues("0b98765", &.{.string}, &.{"0b98765"});
}

test "scan invalid octal 098765 as string" {
    try expectTokenTypesAndValues("098765", &.{.string}, &.{"098765"});
}

test "scan invalid octal 0o98765 as string" {
    try expectTokenTypesAndValues("0o98765", &.{.string}, &.{"0o98765"});
}

test "scan document header" {
    try expectTokenTypesAndValues(
        "---\na: b",
        &.{
            .document_header,
            .string,
            .mapping_value,
            .string,
        },
        &.{ "---", "a", ":", "b" },
    );
}

test "scan document end" {
    try expectTokenTypesAndValues(
        "a: b\n...",
        &.{
            .string,
            .mapping_value,
            .string,
            .document_end,
        },
        &.{ "a", ":", "b", "..." },
    );
}

test "scan sequence entries" {
    try expectTokenTypesAndValues(
        "- A\n- B",
        &.{
            .sequence_entry,
            .string,
            .sequence_entry,
            .string,
        },
        &.{ "-", "A", "-", "B" },
    );
}

test "scan flow sequence" {
    try expectTokenTypesAndValues(
        "[A, B]",
        &.{
            .sequence_start,
            .string,
            .collect_entry,
            .string,
            .sequence_end,
        },
        &.{ "[", "A", ",", "B", "]" },
    );
}

test "scan flow mapping" {
    try expectTokenTypesAndValues(
        "{a: b, c: d}",
        &.{
            .mapping_start,
            .string,
            .mapping_value,
            .string,
            .collect_entry,
            .string,
            .mapping_value,
            .string,
            .mapping_end,
        },
        &.{
            "{", "a", ":", "b", ",", "c", ":", "d", "}",
        },
    );
}

test "scan anchor" {
    try expectTokenTypesAndValues("&anchor value", &.{ .anchor, .string }, &.{ "&", "value" });
}

test "scan alias" {
    try expectTokenTypesAndValues("*anchor", &.{.alias}, &.{"*"});
}

test "scan tag" {
    try expectTokenTypesAndValues("!!str value", &.{ .tag, .string }, &.{ "!!str", "value" });
}

test "scan comment" {
    try expectTokenTypesAndValues("# this is a comment", &.{.comment}, &.{" this is a comment"});
}

test "scan literal block scalar" {
    try expectTokenTypesAndValues(
        \\v: |
        \\  hello
        \\  world
    ,
        &.{
            .string,
            .mapping_value,
            .literal,
            .string,
        },
        &.{ "v", ":", "|", "hello\nworld\n" },
    );
}

test "scan folded block scalar" {
    try expectTokenTypesAndValues(
        \\v: >
        \\  hello
        \\  world
    ,
        &.{
            .string,
            .mapping_value,
            .folded,
            .string,
        },
        &.{ "v", ":", ">", "hello world\n" },
    );
}

test "scan single quoted string" {
    try expectTokenTypesAndValues("'hello world'", &.{.single_quote}, &.{"hello world"});
}

test "scan directive" {
    try expectTokenTypesAndValues("%YAML 1.2", &.{.directive}, &.{"%YAML 1.2"});
}

test "scan merge key" {
    try expectTokenTypesAndValues(
        "<<: *alias",
        &.{
            .merge_key,
            .mapping_value,
            .alias,
        },
        &.{ "<<", ":", "*" },
    );
}

test "scan deeply nested map" {
    try expectTokenTypesAndValues(
        \\a:
        \\  b: c
    ,
        &.{
            .string,
            .mapping_value,
            .string,
            .mapping_value,
            .string,
        },
        &.{ "a", ":", "b", ":", "c" },
    );
}

test "scan nested sequence in map" {
    try expectTokenTypesAndValues(
        \\v:
        \\- A
        \\- B
    ,
        &.{
            .string,
            .mapping_value,
            .sequence_entry,
            .string,
            .sequence_entry,
            .string,
        },
        &.{ "v", ":", "-", "A", "-", "B" },
    );
}

test "scan explicit mapping key" {
    try expectTokenTypesAndValues(
        \\? key
        \\: value
    ,
        &.{
            .mapping_key,
            .string,
            .mapping_value,
            .string,
        },
        &.{ "?", "key", ":", "value" },
    );
}

test "scan key with flow sequence value" {
    try expectTokenTypesAndValues(
        "a: [1, 2]",
        &.{
            .string,
            .mapping_value,
            .sequence_start,
            .integer,
            .collect_entry,
            .integer,
            .sequence_end,
        },
        &.{ "a", ":", "[", "1", ",", "2", "]" },
    );
}

test "scan key with flow mapping value" {
    try expectTokenTypesAndValues(
        "a: {x: 1}",
        &.{
            .string,
            .mapping_value,
            .mapping_start,
            .string,
            .mapping_value,
            .integer,
            .mapping_end,
        },
        &.{ "a", ":", "{", "x", ":", "1", "}" },
    );
}

test "scan multi-document" {
    try expectTokenTypesAndValues(
        \\---
        \\a: 1
        \\---
        \\b: 2
    ,
        &.{
            .document_header,
            .string,
            .mapping_value,
            .integer,
            .document_header,
            .string,
            .mapping_value,
            .integer,
        },
        &.{ "---", "a", ":", "1", "---", "b", ":", "2" },
    );
}

test "scan tagged value" {
    try expectTokenTypesAndValues(
        "v: !!binary gIGC",
        &.{
            .string,
            .mapping_value,
            .tag,
            .string,
        },
        &.{ "v", ":", "!!binary", "gIGC" },
    );
}

test "scan block scalar strip" {
    try expectTokenTypesAndValues(
        \\v: |-
        \\  hello
    ,
        &.{
            .string,
            .mapping_value,
            .literal,
            .string,
        },
        &.{ "v", ":", "|-", "hello" },
    );
}

test "scan single quote with escape" {
    try expectTokenTypesAndValues("'it''s'", &.{.single_quote}, &.{"it's"});
}

test "scan anchor with value" {
    try expectTokenTypesAndValues(
        "a: &ref value",
        &.{
            .string,
            .mapping_value,
            .anchor,
            .string,
        },
        &.{ "a", ":", "&", "value" },
    );
}

test "scan triple nested map" {
    try expectTokenTypesAndValues(
        \\a:
        \\  b:
        \\    c: d
    ,
        &.{
            .string,
            .mapping_value,
            .string,
            .mapping_value,
            .string,
            .mapping_value,
            .string,
        },
        &.{ "a", ":", "b", ":", "c", ":", "d" },
    );
}

test "scan null bare" {
    try expectTokenTypesAndValues("null", &.{.null_value}, &.{"null"});
}

test "scan integer bare" {
    try expectTokenTypesAndValues("42", &.{.integer}, &.{"42"});
}

test "scan float bare" {
    try expectTokenTypesAndValues("3.14", &.{.float}, &.{"3.14"});
}

test "scan true bare" {
    try expectTokenTypesAndValues("true", &.{.bool_value}, &.{"true"});
}

test "scan false bare" {
    try expectTokenTypesAndValues("false", &.{.bool_value}, &.{"false"});
}

test "scan infinity bare" {
    try expectTokenTypesAndValues(".inf", &.{.infinity}, &.{".inf"});
}

test "scan negative infinity bare" {
    try expectTokenTypesAndValues("-.inf", &.{.infinity}, &.{"-.inf"});
}

test "scan nan bare" {
    try expectTokenTypesAndValues(".nan", &.{.nan}, &.{".nan"});
}

test "scan v foo 1" {
    try expectTokenTypesAndValues(
        "v: !!foo 1",
        &.{ .string, .mapping_value, .tag, .string },
        &.{ "v", ":", "!!foo", "1" },
    );
}

test "scan folded strip in sequence" {
    try expectTokenTypesAndValues(
        \\
        \\v:
        \\- A
        \\- >-
        \\ B
        \\ C
    ,
        &.{
            .string,
            .mapping_value,
            .sequence_entry,
            .string,
            .sequence_entry,
            .folded,
            .string,
        },
        &.{ "v", ":", "-", "A", "-", ">-", "B C" },
    );
}

test "scan literal strip 0" {
    try expectTokenTypesAndValues(
        \\v: |-
        \\  0
    ,
        &.{
            .string,
            .mapping_value,
            .literal,
            .string,
        },
        &.{ "v", ":", "|-", "0" },
    );
}

test "scan literal strip 0 with next key" {
    try expectTokenTypesAndValues(
        \\v: |-
        \\  0
        \\x: 0
    ,
        &.{
            .string,
            .mapping_value,
            .literal,
            .string,
            .string,
            .mapping_value,
            .integer,
        },
        &.{ "v", ":", "|-", "0", "x", ":", "0" },
    );
}

test "scan double quoted newline" {
    try expectTokenTypesAndValues("\"a\\n1\\nb\"", &.{.double_quote}, &.{"a\n1\nb"});
}

test "scan json style mapping" {
    try expectTokenTypesAndValues(
        "{\"a\":\"b\"}",
        &.{
            .mapping_start,
            .double_quote,
            .mapping_value,
            .double_quote,
            .mapping_end,
        },
        &.{ "{", "a", ":", "b", "}" },
    );
}

test "scan explicit typed map" {
    try expectTokenTypesAndValues(
        std.mem.trimRight(u8,
            \\!!map {
            \\  ? !!str "explicit":!!str "entry",
            \\  ? !!str "implicit" : !!str "entry",
            \\  ? !!null "" : !!null "",
            \\}
            \\
        , "\n"),
        &.{
            .tag,
            .mapping_start,
            .mapping_key,
            .tag,
            .double_quote,
            .mapping_value,
            .tag,
            .double_quote,
            .collect_entry,
            .mapping_key,
            .tag,
            .double_quote,
            .mapping_value,
            .tag,
            .double_quote,
            .collect_entry,
            .mapping_key,
            .tag,
            .double_quote,
            .mapping_value,
            .tag,
            .double_quote,
            .collect_entry,
            .mapping_end,
        },
        &.{
            "!!map",    "{",
            "?",        "!!str",
            "explicit", ":",
            "!!str",    "entry",
            ",",        "?",
            "!!str",    "implicit",
            ":",        "!!str",
            "entry",    ",",
            "?",        "!!null",
            "",         ":",
            "!!null",   "",
            ",",        "}",
        },
    );
}

test "scan double quoted keys" {
    try expectTokenTypesAndValues(
        \\"a": a
        \\"b": b
    ,
        &.{
            .double_quote,
            .mapping_value,
            .string,
            .double_quote,
            .mapping_value,
            .string,
        },
        &.{ "a", ":", "a", "b", ":", "b" },
    );
}

test "scan single quoted keys" {
    try expectTokenTypesAndValues(
        "'a': a\n'b': b",
        &.{
            .single_quote,
            .mapping_value,
            .string,
            .single_quote,
            .mapping_value,
            .string,
        },
        &.{ "a", ":", "a", "b", ":", "b" },
    );
}

test "scan crlf line endings" {
    try expectTokenTypesAndValues(
        "a: \r\n  b: 1\r\n",
        &.{
            .string,
            .mapping_value,
            .string,
            .mapping_value,
            .integer,
        },
        &.{ "a", ":", "b", ":", "1" },
    );
}

test "scan cr line endings" {
    try expectTokenTypesAndValues(
        "a_ok: \r  bc: 2\r",
        &.{
            .string,
            .mapping_value,
            .string,
            .mapping_value,
            .integer,
        },
        &.{ "a_ok", ":", "bc", ":", "2" },
    );
}

test "scan lf line endings" {
    try expectTokenTypesAndValues(
        \\a_mk: 
        \\  bd: 3
        \\
    ,
        &.{
            .string,
            .mapping_value,
            .string,
            .mapping_value,
            .integer,
        },
        &.{ "a_mk", ":", "bd", ":", "3" },
    );
}

test "scan colon value" {
    try expectTokenTypesAndValues(
        "a: :a",
        &.{ .string, .mapping_value, .string },
        &.{ "a", ":", ":a" },
    );
}

test "scan flow map with empty value" {
    try expectTokenTypesAndValues(
        "{a: , b: c}",
        &.{
            .mapping_start,
            .string,
            .mapping_value,
            .collect_entry,
            .string,
            .mapping_value,
            .string,
            .mapping_end,
        },
        &.{ "{", "a", ":", ",", "b", ":", "c", "}" },
    );
}

test "scan folded empty value" {
    try expectTokenTypesAndValues(
        "value: >\n",
        &.{
            .string,
            .mapping_value,
            .folded,
        },
        &.{ "value", ":", ">" },
    );
}

test "scan folded empty value double newline" {
    try expectTokenTypesAndValues(
        \\value: >
        \\
    ,
        &.{
            .string,
            .mapping_value,
            .folded,
        },
        &.{ "value", ":", ">" },
    );
}

test "scan folded followed by key" {
    try expectTokenTypesAndValues(
        \\value: >
        \\other:
    ,
        &.{
            .string,
            .mapping_value,
            .folded,
            .string,
            .mapping_value,
        },
        &.{ "value", ":", ">", "other", ":" },
    );
}

test "scan folded empty then key" {
    try expectTokenTypesAndValues(
        \\value: >
        \\
        \\other:
    ,
        &.{
            .string,
            .mapping_value,
            .folded,
            .string,
            .mapping_value,
        },
        &.{ "value", ":", ">", "other", ":" },
    );
}

test "scan map with empty sequence" {
    try expectTokenTypesAndValues(
        "a:\n-",
        &.{
            .string,
            .mapping_value,
            .sequence_entry,
        },
        &.{ "a", ":", "-" },
    );
}

test "scan flow map bare key" {
    try expectTokenTypesAndValues(
        "a: {foo}",
        &.{
            .string,
            .mapping_value,
            .mapping_start,
            .string,
            .mapping_end,
        },
        &.{ "a", ":", "{", "foo", "}" },
    );
}

test "scan flow map bare keys comma" {
    try expectTokenTypesAndValues(
        "a: {foo,bar}",
        &.{
            .string,
            .mapping_value,
            .mapping_start,
            .string,
            .collect_entry,
            .string,
            .mapping_end,
        },
        &.{ "a", ":", "{", "foo", ",", "bar", "}" },
    );
}

test "scan nested flow map" {
    try expectTokenTypesAndValues(
        \\
        \\{
        \\  a: {
        \\    b: c
        \\  },
        \\  d: e
        \\}
    ,
        &.{
            .mapping_start,
            .string,
            .mapping_value,
            .mapping_start,
            .string,
            .mapping_value,
            .string,
            .mapping_end,
            .collect_entry,
            .string,
            .mapping_value,
            .string,
            .mapping_end,
        },
        &.{ "{", "a", ":", "{", "b", ":", "c", "}", ",", "d", ":", "e", "}" },
    );
}

test "scan flow sequence with map entry" {
    try expectTokenTypesAndValues(
        \\
        \\[
        \\  a: {
        \\    b: c
        \\  }]
    ,
        &.{
            .sequence_start,
            .string,
            .mapping_value,
            .mapping_start,
            .string,
            .mapping_value,
            .string,
            .mapping_end,
            .sequence_end,
        },
        &.{ "[", "a", ":", "{", "b", ":", "c", "}", "]" },
    );
}

test "scan nested flow map no trailing comma" {
    try expectTokenTypesAndValues(
        \\
        \\{
        \\  a: {
        \\    b: c
        \\  }}
    ,
        &.{
            .mapping_start,
            .string,
            .mapping_value,
            .mapping_start,
            .string,
            .mapping_value,
            .string,
            .mapping_end,
            .mapping_end,
        },
        &.{ "{", "a", ":", "{", "b", ":", "c", "}", "}" },
    );
}

test "scan tag on sequence entry" {
    try expectTokenTypesAndValues(
        \\
        \\- !tag
        \\  a: b
        \\  c: d
    ,
        &.{
            .sequence_entry,
            .tag,
            .string,
            .mapping_value,
            .string,
            .string,
            .mapping_value,
            .string,
        },
        &.{ "-", "!tag", "a", ":", "b", "c", ":", "d" },
    );
}

test "scan tag on map value" {
    try expectTokenTypesAndValues(
        \\
        \\a: !tag
        \\  b: c
    ,
        &.{
            .string,
            .mapping_value,
            .tag,
            .string,
            .mapping_value,
            .string,
        },
        &.{ "a", ":", "!tag", "b", ":", "c" },
    );
}

test "scan tag on map value multi keys" {
    try expectTokenTypesAndValues(
        \\
        \\a: !tag
        \\  b: c
        \\  d: e
    ,
        &.{
            .string,
            .mapping_value,
            .tag,
            .string,
            .mapping_value,
            .string,
            .string,
            .mapping_value,
            .string,
        },
        &.{ "a", ":", "!tag", "b", ":", "c", "d", ":", "e" },
    );
}

test "scan multiline doc separator" {
    try expectTokenTypesAndValues(
        \\
        \\foo: xxx
        \\---
        \\foo: yyy
        \\---
        \\foo: zzz
    ,
        &.{
            .string,
            .mapping_value,
            .string,
            .document_header,
            .string,
            .mapping_value,
            .string,
            .document_header,
            .string,
            .mapping_value,
            .string,
        },
        &.{
            "foo", ":", "xxx", "---",
            "foo", ":", "yyy", "---",
            "foo", ":", "zzz",
        },
    );
}

test "scan tab before colon in map" {
    try expectTokenTypesAndValues(
        "\nv:\n  a\t: 'a'\n  bb\t: 'a'\n",
        &.{
            .string,
            .mapping_value,
            .string,
            .mapping_value,
            .single_quote,
            .string,
            .mapping_value,
            .single_quote,
        },
        &.{ "v", ":", "a", ":", "a", "bb", ":", "a" },
    );
}

test "scan mixed space tab before colon" {
    try expectTokenTypesAndValues(
        "\nv:\n  a : 'x'\n  b\t: 'y'\n",
        &.{
            .string,
            .mapping_value,
            .string,
            .mapping_value,
            .single_quote,
            .string,
            .mapping_value,
            .single_quote,
        },
        &.{ "v", ":", "a", ":", "x", "b", ":", "y" },
    );
}

test "scan multiple tabs before colon" {
    try expectTokenTypesAndValues(
        "\nv:\n  a\t: 'x'\n  b\t: 'y'\n  c\t\t: 'z'\n",
        &.{
            .string,
            .mapping_value,
            .string,
            .mapping_value,
            .single_quote,
            .string,
            .mapping_value,
            .single_quote,
            .string,
            .mapping_value,
            .single_quote,
        },
        &.{ "v", ":", "a", ":", "x", "b", ":", "y", "c", ":", "z" },
    );
}

test "scan anchor and alias in flow" {
    try expectTokenTypesAndValues(
        "{a: &a c, *a : b}",
        &.{
            .mapping_start,
            .string,
            .mapping_value,
            .anchor,
            .string,
            .collect_entry,
            .alias,
            .mapping_value,
            .string,
            .mapping_end,
        },
        &.{ "{", "a", ":", "&", "c", ",", "*", ":", "b", "}" },
    );
}

test "scan whitespace around key value" {
    try expectTokenTypesAndValues(
        "       a       :          b        \n",
        &.{ .string, .mapping_value, .string },
        &.{ "a", ":", "b" },
    );
}

test "scan comment after value" {
    try expectTokenTypesAndValues(
        \\a: b # comment
        \\b: c
    ,
        &.{
            .string,
            .mapping_value,
            .string,
            .comment,
            .string,
            .mapping_value,
            .string,
        },
        &.{ "a", ":", "b", " comment", "b", ":", "c" },
    );
}

test "scan abc shift def ghi" {
    try expectTokenTypesAndValues(
        "a: abc <<def>> ghi",
        &.{ .string, .mapping_value, .string },
        &.{ "a", ":", "abc <<def>> ghi" },
    );
}

test "scan shift abcd" {
    try expectTokenTypesAndValues(
        "a: <<abcd",
        &.{ .string, .mapping_value, .string },
        &.{ "a", ":", "<<abcd" },
    );
}

test "scan shift colon abcd" {
    try expectTokenTypesAndValues(
        "a: <<:abcd",
        &.{ .string, .mapping_value, .string },
        &.{ "a", ":", "<<:abcd" },
    );
}

test "scan shift space colon abcd" {
    try expectTokenTypesAndValues(
        "a: <<  :abcd",
        &.{ .string, .mapping_value, .string },
        &.{ "a", ":", "<<  :abcd" },
    );
}

test "scan anchor without value" {
    try expectTokenTypesAndValues(
        \\
        \\a:
        \\ b: &anchor
        \\ c: &anchor2
        \\d: e
    ,
        &.{
            .string,
            .mapping_value,
            .string,
            .mapping_value,
            .anchor,
            .string,
            .mapping_value,
            .anchor,
            .string,
            .mapping_value,
            .string,
        },
        &.{ "a", ":", "b", ":", "&", "c", ":", "&", "d", ":", "e" },
    );
}


test "scan literal keep plus" {
    try expectTokenTypesAndValues(
        \\
        \\a:  |+
        \\  value
        \\b: c
    ,
        &.{
            .string,
            .mapping_value,
            .literal,
            .string,
            .string,
            .mapping_value,
            .string,
        },
        &.{ "a", ":", "|+", "value\n", "b", ":", "c" },
    );
}

test "scan literal strip" {
    try expectTokenTypesAndValues(
        \\
        \\a: |-
        \\  value
        \\b: c
    ,
        &.{
            .string,
            .mapping_value,
            .literal,
            .string,
            .string,
            .mapping_value,
            .string,
        },
        &.{ "a", ":", "|-", "value", "b", ":", "c" },
    );
}

test "scan document header and end" {
    try expectTokenTypesAndValues(
        \\
        \\---
        \\a: 1
        \\b: 2
        \\...
        \\---
        \\c: 3
        \\d: 4
        \\...
    ,
        &.{
            .document_header,
            .string,
            .mapping_value,
            .integer,
            .string,
            .mapping_value,
            .integer,
            .document_end,
            .document_header,
            .string,
            .mapping_value,
            .integer,
            .string,
            .mapping_value,
            .integer,
            .document_end,
        },
        &.{
            "---", "a",   ":", "1", "b", ":", "2",
            "...", "---", "c", ":", "3", "d", ":",
            "4",   "...",
        },
    );
}

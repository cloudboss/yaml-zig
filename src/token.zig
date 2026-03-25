const std = @import("std");

pub const TokenType = enum(u8) {
    document_header,
    document_end,
    sequence_entry,
    mapping_key,
    mapping_value,
    merge_key,
    sequence_start,
    sequence_end,
    mapping_start,
    mapping_end,
    collect_entry,
    anchor,
    alias,
    tag,
    literal,
    folded,
    single_quote,
    double_quote,
    string,
    null_value,
    bool_value,
    integer,
    float,
    infinity,
    nan,
    comment,
    directive,
    space,
    _,
};

pub const CharacterType = enum(u8) {
    indicator,
    white_space,
    misc,
    escaped,
};

pub const Indicator = enum(u8) {
    sequence_entry,
    mapping_key,
    mapping_value,
    collect_entry,
    sequence_start,
    sequence_end,
    mapping_start,
    mapping_end,
    comment,
    anchor,
    alias,
    tag,
    literal,
    folded,
    single_quote,
    double_quote,
    directive,
    reserved_at,
    reserved_backtick,
};

pub const Position = struct {
    line: u32 = 1,
    column: u32 = 1,
    offset: u32 = 0,
    indent_num: u32 = 0,
    indent_level: u32 = 0,
};

pub const Token = struct {
    token_type: TokenType,
    value: []const u8 = "",
    origin: []const u8 = "",
    position: Position = .{},
    next: ?*Token = null,
    prev: ?*Token = null,
};

pub const NumberValue = union(enum) {
    int: i64,
    float: f64,
};

pub fn toNumber(val: []const u8) ?NumberValue {
    _ = val;
    return null;
}

pub fn needsQuoting(val: []const u8) bool {
    _ = val;
    return false;
}

pub fn reservedKeyword(val: []const u8) ?TokenType {
    _ = val;
    return null;
}

test "toNumber parses decimal integer" {
    const result = toNumber("42") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(
        NumberValue{ .int = 42 },
        result,
    );
}

test "toNumber parses negative integer" {
    const result = toNumber("-10") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(
        NumberValue{ .int = -10 },
        result,
    );
}

test "toNumber parses zero" {
    const result = toNumber("0") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(
        NumberValue{ .int = 0 },
        result,
    );
}

test "toNumber parses hex integer" {
    const result = toNumber("0xA") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(
        NumberValue{ .int = 10 },
        result,
    );
}

test "toNumber parses hex with underscores" {
    const result = toNumber("0x_0A_74_AE") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(
        NumberValue{ .int = 685230 },
        result,
    );
}

test "toNumber parses octal 0o prefix" {
    const result = toNumber("0o2472256") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(
        NumberValue{ .int = 685230 },
        result,
    );
}

test "toNumber parses octal legacy prefix" {
    const result = toNumber("02472256") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(
        NumberValue{ .int = 685230 },
        result,
    );
}

test "toNumber parses binary" {
    const result = toNumber("0b1010") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(
        NumberValue{ .int = 10 },
        result,
    );
}

test "toNumber parses positive binary" {
    const result = toNumber("+0b1010") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(
        NumberValue{ .int = 10 },
        result,
    );
}

test "toNumber parses negative binary" {
    const result = toNumber("-0b101010") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(
        NumberValue{ .int = -42 },
        result,
    );
}

test "toNumber parses binary with underscores" {
    const result = toNumber("0b1010_0111_0100_1010_1110") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(
        NumberValue{ .int = 685230 },
        result,
    );
}

test "toNumber parses float" {
    const result = toNumber("3.14") orelse return error.TestExpectedValue;
    switch (result) {
        .float => |f| try std.testing.expectApproxEqAbs(
            @as(f64, 3.14),
            f,
            0.001,
        ),
        else => return error.TestExpectedValue,
    }
}

test "toNumber parses negative float" {
    const result = toNumber("-0.1") orelse return error.TestExpectedValue;
    switch (result) {
        .float => |f| try std.testing.expectApproxEqAbs(
            @as(f64, -0.1),
            f,
            0.001,
        ),
        else => return error.TestExpectedValue,
    }
}

test "toNumber parses scientific notation" {
    const result = toNumber("6.8523e+5") orelse return error.TestExpectedValue;
    switch (result) {
        .float => |f| try std.testing.expectApproxEqAbs(
            @as(f64, 685230.0),
            f,
            0.1,
        ),
        else => return error.TestExpectedValue,
    }
}

test "toNumber parses float with underscores" {
    const result = toNumber("685_230.15") orelse return error.TestExpectedValue;
    switch (result) {
        .float => |f| try std.testing.expectApproxEqAbs(
            @as(f64, 685230.15),
            f,
            0.01,
        ),
        else => return error.TestExpectedValue,
    }
}

test "toNumber parses leading dot float" {
    const result = toNumber(".1") orelse return error.TestExpectedValue;
    switch (result) {
        .float => |f| try std.testing.expectApproxEqAbs(
            @as(f64, 0.1),
            f,
            0.001,
        ),
        else => return error.TestExpectedValue,
    }
}

test "toNumber returns null for non-numeric" {
    try std.testing.expect(toNumber("hello") == null);
}

test "toNumber returns null for empty" {
    try std.testing.expect(toNumber("") == null);
}

test "toNumber returns null for ip address" {
    try std.testing.expect(toNumber("1.1.1.1") == null);
}

test "toNumber returns null for underscore only" {
    try std.testing.expect(toNumber("_") == null);
}

test "toNumber returns null for tilde" {
    try std.testing.expect(toNumber("~") == null);
}

test "toNumber returns null for plus only" {
    try std.testing.expect(toNumber("+") == null);
}

test "toNumber returns null for minus only" {
    try std.testing.expect(toNumber("-") == null);
}

test "toNumber returns null for underscore prefixed" {
    try std.testing.expect(toNumber("_1") == null);
}

test "reservedKeyword detects null" {
    const result = reservedKeyword("null") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(TokenType.null_value, result);
}

test "reservedKeyword detects Null" {
    const result = reservedKeyword("Null") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(TokenType.null_value, result);
}

test "reservedKeyword detects NULL" {
    const result = reservedKeyword("NULL") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(TokenType.null_value, result);
}

test "reservedKeyword detects tilde as null" {
    const result = reservedKeyword("~") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(TokenType.null_value, result);
}

test "reservedKeyword detects true" {
    const result = reservedKeyword("true") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(TokenType.bool_value, result);
}

test "reservedKeyword detects True" {
    const result = reservedKeyword("True") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(TokenType.bool_value, result);
}

test "reservedKeyword detects TRUE" {
    const result = reservedKeyword("TRUE") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(TokenType.bool_value, result);
}

test "reservedKeyword detects false" {
    const result = reservedKeyword("false") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(TokenType.bool_value, result);
}

test "reservedKeyword detects False" {
    const result = reservedKeyword("False") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(TokenType.bool_value, result);
}

test "reservedKeyword detects FALSE" {
    const result = reservedKeyword("FALSE") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(TokenType.bool_value, result);
}

test "reservedKeyword detects .inf" {
    const result = reservedKeyword(".inf") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(TokenType.infinity, result);
}

test "reservedKeyword detects .Inf" {
    const result = reservedKeyword(".Inf") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(TokenType.infinity, result);
}

test "reservedKeyword detects .INF" {
    const result = reservedKeyword(".INF") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(TokenType.infinity, result);
}

test "reservedKeyword detects -.inf" {
    const result = reservedKeyword("-.inf") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(TokenType.infinity, result);
}

test "reservedKeyword detects -.Inf" {
    const result = reservedKeyword("-.Inf") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(TokenType.infinity, result);
}

test "reservedKeyword detects -.INF" {
    const result = reservedKeyword("-.INF") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(TokenType.infinity, result);
}

test "reservedKeyword detects .nan" {
    const result = reservedKeyword(".nan") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(TokenType.nan, result);
}

test "reservedKeyword detects .NaN" {
    const result = reservedKeyword(".NaN") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(TokenType.nan, result);
}

test "reservedKeyword detects .NAN" {
    const result = reservedKeyword(".NAN") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(TokenType.nan, result);
}

test "reservedKeyword returns null for hello" {
    try std.testing.expect(reservedKeyword("hello") == null);
}

test "reservedKeyword returns null for y" {
    try std.testing.expect(reservedKeyword("y") == null);
}

test "reservedKeyword returns null for yes" {
    try std.testing.expect(reservedKeyword("yes") == null);
}

test "reservedKeyword returns null for no" {
    try std.testing.expect(reservedKeyword("no") == null);
}

test "reservedKeyword returns null for on" {
    try std.testing.expect(reservedKeyword("on") == null);
}

test "reservedKeyword returns null for off" {
    try std.testing.expect(reservedKeyword("off") == null);
}

test "needsQuoting for empty string" {
    try std.testing.expect(needsQuoting(""));
}

test "needsQuoting for true" {
    try std.testing.expect(needsQuoting("true"));
}

test "needsQuoting for false" {
    try std.testing.expect(needsQuoting("false"));
}

test "needsQuoting for null" {
    try std.testing.expect(needsQuoting("null"));
}

test "needsQuoting for Null" {
    try std.testing.expect(needsQuoting("Null"));
}

test "needsQuoting for NULL" {
    try std.testing.expect(needsQuoting("NULL"));
}

test "needsQuoting for tilde" {
    try std.testing.expect(needsQuoting("~"));
}

test "needsQuoting for number" {
    try std.testing.expect(needsQuoting("1.234"));
}

test "needsQuoting for colon value" {
    try std.testing.expect(needsQuoting("1:1"));
}

test "needsQuoting for hash comment" {
    try std.testing.expect(needsQuoting("hoge # comment"));
}

test "needsQuoting for leading hash" {
    try std.testing.expect(needsQuoting("#a b"));
}

test "needsQuoting for leading star" {
    try std.testing.expect(needsQuoting("*a b"));
}

test "needsQuoting for leading ampersand" {
    try std.testing.expect(needsQuoting("&a b"));
}

test "needsQuoting for dash" {
    try std.testing.expect(needsQuoting("-"));
}

test "needsQuoting for dash dash foo" {
    try std.testing.expect(needsQuoting("- --foo"));
}

test "needsQuoting for leading space" {
    try std.testing.expect(needsQuoting(" foo"));
}

test "needsQuoting for trailing space" {
    try std.testing.expect(needsQuoting("foo "));
}

test "needsQuoting not for Hello World" {
    try std.testing.expect(!needsQuoting("Hello World"));
}

test "needsQuoting not for simple word" {
    try std.testing.expect(!needsQuoting("hello"));
}

test "needsQuoting for legacy YAML 1.1 bool keywords" {
    try std.testing.expect(needsQuoting("y"));
    try std.testing.expect(needsQuoting("Y"));
    try std.testing.expect(needsQuoting("yes"));
    try std.testing.expect(needsQuoting("Yes"));
    try std.testing.expect(needsQuoting("YES"));
    try std.testing.expect(needsQuoting("n"));
    try std.testing.expect(needsQuoting("N"));
    try std.testing.expect(needsQuoting("no"));
    try std.testing.expect(needsQuoting("No"));
    try std.testing.expect(needsQuoting("NO"));
    try std.testing.expect(needsQuoting("on"));
    try std.testing.expect(needsQuoting("On"));
    try std.testing.expect(needsQuoting("ON"));
    try std.testing.expect(needsQuoting("off"));
    try std.testing.expect(needsQuoting("Off"));
    try std.testing.expect(needsQuoting("OFF"));
}

test "needsQuoting for leading special characters" {
    try std.testing.expect(needsQuoting("{a b"));
    try std.testing.expect(needsQuoting("}a b"));
    try std.testing.expect(needsQuoting("[a b"));
    try std.testing.expect(needsQuoting("]a b"));
    try std.testing.expect(needsQuoting(",a b"));
    try std.testing.expect(needsQuoting("!a b"));
    try std.testing.expect(needsQuoting("|a b"));
    try std.testing.expect(needsQuoting(">a b"));
    try std.testing.expect(needsQuoting("%a b"));
    try std.testing.expect(needsQuoting("'a b"));
    try std.testing.expect(needsQuoting("\"a b"));
}

test "needsQuoting for colon patterns" {
    try std.testing.expect(needsQuoting("a:"));
    try std.testing.expect(needsQuoting("a: b"));
    try std.testing.expect(needsQuoting(":0"));
    try std.testing.expect(needsQuoting(":8080"));
    try std.testing.expect(needsQuoting(":value"));
}

test "needsQuoting for at-sign prefix" {
    try std.testing.expect(needsQuoting("@test"));
}

test "needsQuoting for timestamps" {
    try std.testing.expect(needsQuoting("2001-12-15T02:59:43.1Z"));
    try std.testing.expect(needsQuoting("2001-12-14t21:59:43.10-05:00"));
    try std.testing.expect(needsQuoting("2001-12-15 2:59:43.10"));
    try std.testing.expect(needsQuoting("2002-12-14"));
}

test "needsQuoting for overflow numbers" {
    try std.testing.expect(needsQuoting("999999999999999999999999999999999999999999"));
}

test "needsQuoting for null byte literal" {
    try std.testing.expect(needsQuoting("\\0"));
}

test "needsQuoting not for safe strings" {
    try std.testing.expect(!needsQuoting("Hello World"));
    try std.testing.expect(!needsQuoting("hello"));
    try std.testing.expect(!needsQuoting("2001-12-14 21:59:43.10 -5"));
}

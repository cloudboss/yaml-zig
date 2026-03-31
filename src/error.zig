const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const parser = @import("parser.zig");
const token = @import("token.zig");

pub const Detail = struct {
    message: []const u8 = "",
    position: ?token.Position = null,
    context_message: []const u8 = "",
    context_position: ?token.Position = null,

    pub fn format(self: Detail, allocator: std.mem.Allocator) ![]u8 {
        if (self.context_message.len > 0) {
            if (self.context_position) |cp| {
                return std.fmt.allocPrint(allocator,
                    \\{s} at line {d}, column {d}
                    \\{s} at line {d}, column {d}
                , .{
                    self.message,
                    if (self.position) |p| p.line else 0,
                    if (self.position) |p| p.column else 0,
                    self.context_message,
                    cp.line,
                    cp.column,
                });
            }
        }
        if (self.position) |p| {
            return std.fmt.allocPrint(
                allocator,
                "{s} at line {d}, column {d}",
                .{ self.message, p.line, p.column },
            );
        }
        return std.fmt.allocPrint(allocator, "{s}", .{self.message});
    }
};

pub const ScanError = error{
    InvalidYaml,
    InvalidUtf8,
    UnexpectedEof,
    InvalidEscape,
    InvalidIndent,
    TabInIndent,
};

pub const ParseError = error{
    SyntaxError,
    UnexpectedToken,
    DuplicateKey,
    MaxDepthExceeded,
};

pub const DecodeError = error{
    TypeMismatch,
    Overflow,
    UnknownField,
    MissingField,
    InvalidAnchor,
};

pub const EncodeError = error{
    UnsupportedType,
    InvalidValue,
};

test "error detail has position for invalid yaml" {
    try testing.expectError(error.SyntaxError, parser.parse(testing.allocator, ":\n  :\n    :"));
}

test "error detail format produces readable message" {
    const detail = Detail{
        .message = "unexpected token",
        .position = .{
            .line = 3,
            .column = 5,
        },
    };
    const msg = try detail.format(testing.allocator);
    defer testing.allocator.free(msg);
    try testing.expect(msg.len > 0);
    try testing.expect(mem.indexOf(u8, msg, "unexpected token") != null);
    try testing.expect(mem.indexOf(u8, msg, "3") != null);
    try testing.expect(mem.indexOf(u8, msg, "5") != null);
}

test "error detail format includes line and column" {
    const detail = Detail{
        .message = "bad indent",
        .position = .{
            .line = 10,
            .column = 3,
        },
    };
    const msg = try detail.format(testing.allocator);
    defer testing.allocator.free(msg);
    try testing.expect(mem.indexOf(u8, msg, "10") != null);
    try testing.expect(mem.indexOf(u8, msg, "3") != null);
}

test "error detail format with context" {
    const detail = Detail{
        .message = "unexpected mapping",
        .position = .{ .line = 5, .column = 1 },
        .context_message = "while parsing block",
        .context_position = .{ .line = 3, .column = 1 },
    };
    const msg = try detail.format(testing.allocator);
    defer testing.allocator.free(msg);
    try testing.expect(mem.indexOf(u8, msg, "unexpected mapping") != null);
    try testing.expect(mem.indexOf(u8, msg, "while parsing block") != null);
}

test "tab in indentation reports correct position" {
    try testing.expectError(error.TabInIndent, parser.parse(testing.allocator, "a:\n\tb: c\n"));
}

test "duplicate key error" {
    try testing.expectError(error.DuplicateKey, parser.parse(testing.allocator, "a: 1\na: 2\n"));
}

test "unclosed quote reports error" {
    try testing.expectError(error.UnexpectedEof, parser.parse(testing.allocator, "a: \"unclosed\n"));
}

test "syntax error position for invalid sequence" {
    try testing.expectError(error.SyntaxError, parser.parse(testing.allocator, "a\n- b: c"));
}

test "syntax error position for non-map value" {
    try testing.expectError(error.SyntaxError, parser.parse(testing.allocator, "a: 1\nb\n"));
}

test "unclosed flow mapping returns error" {
    const input = "{ \"key\": \"value\" ";
    try testing.expectError(error.SyntaxError, parser.parse(testing.allocator, input));
}

test "unclosed flow sequence returns error" {
    try testing.expectError(error.SyntaxError, parser.parse(testing.allocator, "a: ["));
}

test "unclosed single quote returns error" {
    try testing.expectError(error.UnexpectedEof, parser.parse(testing.allocator, "a: 'foobarbaz"));
}

test "invalid literal block option returns error" {
    try testing.expectError(
        error.SyntaxError,
        parser.parse(testing.allocator, "a: |invalidopt\n  foo\n"),
    );
}

test "invalid folded indent count returns error" {
    try testing.expectError(error.SyntaxError, parser.parse(testing.allocator, "a: >3\n  1\n"));
}

test "flow sequence without comma returns error" {
    try testing.expectError(error.SyntaxError, parser.parse(testing.allocator, "a: [ [1] [2] ]"));
}

test "unexpected close bracket returns error" {
    try testing.expectError(error.SyntaxError, parser.parse(testing.allocator, "a: ]"));
}

test "reserved at character returns error" {
    try testing.expectError(error.SyntaxError, parser.parse(testing.allocator, "key: [@val]"));
}

test "reserved backtick character returns error" {
    try testing.expectError(error.SyntaxError, parser.parse(testing.allocator, "key: [`val]"));
}

test "folded then folded returns error" {
    try testing.expectError(error.SyntaxError, parser.parse(testing.allocator, ">\n>"));
}

test "folded then number returns error" {
    try testing.expectError(error.SyntaxError, parser.parse(testing.allocator, ">\n1"));
}

test "literal then number returns error" {
    try testing.expectError(error.SyntaxError, parser.parse(testing.allocator, "|\n1"));
}

test "dash after colon returns error" {
    try testing.expectError(error.SyntaxError, parser.parse(testing.allocator, "a: -\nb: -\n"));
}

test "dash value after colon returns error" {
    try testing.expectError(error.SyntaxError, parser.parse(testing.allocator, "a: - 1\nb: - 2\n"));
}

test "flow map as key parses" {
    var doc = try parser.parse(testing.allocator, "{a: b}: v");
    doc.deinit();
}

test "flow seq as key parses" {
    var doc = try parser.parse(testing.allocator, "[a]: v");
    doc.deinit();
}

test "invalid flow map content returns error" {
    try testing.expectError(error.SyntaxError, parser.parse(testing.allocator, "{invalid"));
}

test "flow map trailing comma returns error" {
    try testing.expectError(error.SyntaxError, parser.parse(testing.allocator, "{\"000\":0000A,"));
}

test "directive with content returns error" {
    try testing.expectError(error.SyntaxError, parser.parse(testing.allocator, "%YAML 1.1 {}"));
}

test "value after quoted scalar returns error" {
    try testing.expectError(error.SyntaxError, parser.parse(testing.allocator, "a: 'b'\n  c: d\n"));
}

test "sequence after quoted scalar returns error" {
    try testing.expectError(error.SyntaxError, parser.parse(testing.allocator, "a: 'b'\n  - c\n"));
}

test "value after literal block returns error" {
    const input = "a:\n  - |\n        b\n    c: d\n";
    try testing.expectError(error.SyntaxError, parser.parse(testing.allocator, input));
}

test "map after literal block returns error" {
    const input = "a:\n  - |\n        b\n    c:\n      d: e\n";
    try testing.expectError(error.SyntaxError, parser.parse(testing.allocator, input));
}

test "dollar brace in flow sequence returns error" {
    try testing.expectError(
        error.SyntaxError,
        parser.parse(testing.allocator, "foo: [${should not be allowed}]"),
    );
}

test "dollar bracket in flow sequence returns error" {
    try testing.expectError(
        error.SyntaxError,
        parser.parse(testing.allocator, "foo: [$[should not be allowed]]"),
    );
}

test "sequence in value context returns error" {
    const input = "a:\n- b\n  c: d\n  e: f\n  g: h";
    try testing.expectError(error.SyntaxError, parser.parse(testing.allocator, input));
}

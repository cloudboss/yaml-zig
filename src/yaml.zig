const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const ast = @import("ast.zig");
pub const Node = ast.Node;
pub const Document = ast.Document;
pub const Stream = ast.Stream;
pub const decoder = @import("decode.zig");
pub const ParseOptions = decoder.ParseOptions;
pub const Parsed = decoder.Parsed;
pub const emitter = @import("emitter.zig");
pub const encoder = @import("encode.zig");
pub const StringifyOptions = encoder.StringifyOptions;
pub const err = @import("error.zig");
pub const parser = @import("parser.zig");
pub const scanner = @import("scanner.zig");
pub const suite = @import("suite.zig");
pub const token = @import("token.zig");
pub const value = @import("value.zig");

pub fn parseFromSlice(
    comptime T: type,
    allocator: Allocator,
    source: []const u8,
    options: ParseOptions,
) !decoder.Parsed(T) {
    return decoder.decode(T, allocator, source, options);
}

pub fn stringifyAlloc(allocator: Allocator, val: anytype, options: StringifyOptions) ![]u8 {
    return encoder.stringifyAlloc(allocator, val, options);
}

pub fn stringify(val: anytype, options: StringifyOptions, writer: anytype) !void {
    return encoder.stringify(val, options, writer);
}

test {
    _ = token;
    _ = ast;
    _ = value;
    _ = err;
    _ = scanner;
    _ = parser;
    _ = emitter;
    _ = decoder;
    _ = encoder;
    _ = suite;
}

test "parseAll multi-document" {
    var stream = try parser.parseAll(
        testing.allocator,
        \\---
        \\a: 1
        \\---
        \\b: 2
        ,
    );
    defer stream.deinit();
    try testing.expectEqual(@as(usize, 2), stream.docs.len);
}

test "parseAll stream of documents" {
    var stream = try parser.parseAll(
        testing.allocator,
        \\---
        \\a: b
        \\c: d
        \\---
        \\e: f
        \\g: h
        \\---
        \\i: j
        \\k: l
        \\
        ,
    );
    defer stream.deinit();
    try testing.expectEqual(@as(usize, 3), stream.docs.len);
}

test "full pipeline parseFromSlice stringifyAlloc" {
    const Config = struct {
        name: []const u8,
        port: u16,
    };
    const input =
        \\name: myapp
        \\port: 3000
        \\
    ;
    const parsed = try parseFromSlice(Config, testing.allocator, input, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("myapp", parsed.value.name);
    try testing.expectEqual(@as(u16, 3000), parsed.value.port);
    const output = try stringifyAlloc(testing.allocator, parsed.value, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(input, output);
}

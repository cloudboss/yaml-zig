const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const ast = @import("ast.zig");
pub const Node = ast.Node;
pub const decoder = @import("decode.zig");
pub const emitter = @import("emitter.zig");
pub const encoder = @import("encode.zig");
pub const err = @import("error.zig");
pub const parser = @import("parser.zig");
pub const scanner = @import("scanner.zig");
pub const suite = @import("suite.zig");
pub const token = @import("token.zig");
pub const value = @import("value.zig");

pub const Document = struct {
    allocator: Allocator,
    body: ?*Node = null,

    pub fn deinit(self: *Document) void {
        _ = self;
    }
};

pub const File = struct {
    allocator: Allocator,
    docs: []Document = &.{},

    pub fn deinit(self: *File) void {
        _ = self;
    }
};

pub fn parse(allocator: Allocator, source: []const u8) !Document {
    _ = allocator;
    _ = source;
    return error.Unimplemented;
}

pub fn parseAll(allocator: Allocator, source: []const u8) !File {
    _ = allocator;
    _ = source;
    return error.Unimplemented;
}

pub fn emit(allocator: Allocator, doc: Document) ![]u8 {
    _ = allocator;
    _ = doc;
    return error.Unimplemented;
}

pub fn decode(comptime T: type, allocator: Allocator, source: []const u8) !T {
    return decoder.decode(T, allocator, source, .{});
}

pub fn encode(allocator: Allocator, val: anytype) ![]u8 {
    return encoder.encode(allocator, val, .{});
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
    var file = try parseAll(
        testing.allocator,
        \\---
        \\a: 1
        \\---
        \\b: 2
        ,
    );
    defer file.deinit();
    try testing.expectEqual(@as(usize, 2), file.docs.len);
}

test "parseAll stream of documents" {
    var file = try parseAll(
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
    defer file.deinit();
    try testing.expectEqual(@as(usize, 3), file.docs.len);
}

test "full pipeline parse decode encode" {
    const Config = struct {
        name: []const u8,
        port: u16,
    };
    const input =
        \\name: myapp
        \\port: 3000
        \\
    ;
    const config = try decode(
        Config,
        testing.allocator,
        input,
    );
    try testing.expectEqualStrings("myapp", config.name);
    try testing.expectEqual(@as(u16, 3000), config.port);
    const output = try encode(
        testing.allocator,
        config,
    );
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(input, output);
}

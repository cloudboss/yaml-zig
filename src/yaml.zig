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
    arena: ?std.heap.ArenaAllocator = null,
    body: ?*Node = null,

    pub fn deinit(self: *Document) void {
        if (self.arena) |*a| {
            a.deinit();
        }
    }
};

pub const File = struct {
    arena: ?std.heap.ArenaAllocator = null,
    docs: []Document = &.{},

    pub fn deinit(self: *File) void {
        if (self.arena) |*a| {
            a.deinit();
        }
    }
};

pub fn parse(allocator: Allocator, source: []const u8) !Document {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    var s = scanner.Scanner.init(arena_alloc, source);
    const tokens = try s.scan();

    var p = parser.Parser.init(arena_alloc);
    const root = try p.parse(tokens);

    var body_ptr: ?*Node = null;
    switch (root) {
        .document => |d| {
            body_ptr = if (d.body) |b| @constCast(b) else null;
        },
        else => {
            const node = try arena_alloc.create(Node);
            node.* = root;
            body_ptr = node;
        },
    }

    return Document{
        .arena = arena,
        .body = body_ptr,
    };
}

pub fn parseAll(allocator: Allocator, source: []const u8) !File {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    var s = scanner.Scanner.init(arena_alloc, source);
    const tokens = try s.scan();

    // Split tokens by document headers
    var docs = std.ArrayListUnmanaged(Document){};
    var doc_start: usize = 0;
    var i: usize = 0;
    var found_header = false;

    while (i < tokens.len) {
        if (tokens[i].token_type == .document_header) {
            if (found_header or doc_start < i) {
                // Parse previous document
                var p = parser.Parser.init(arena_alloc);
                const root = try p.parse(tokens[doc_start..i]);
                var body_ptr: ?*Node = null;
                switch (root) {
                    .document => |d| {
                        body_ptr = if (d.body) |b| @constCast(b) else null;
                    },
                    else => {
                        const node = try arena_alloc.create(Node);
                        node.* = root;
                        body_ptr = node;
                    },
                }
                try docs.append(arena_alloc, .{
                    .body = body_ptr,
                });
            }
            doc_start = i;
            found_header = true;
            i += 1;
        } else {
            i += 1;
        }
    }

    // Parse last document
    if (doc_start < tokens.len) {
        var p = parser.Parser.init(arena_alloc);
        const root = try p.parse(tokens[doc_start..]);
        var body_ptr: ?*Node = null;
        switch (root) {
            .document => |d| {
                body_ptr = if (d.body) |b| @constCast(b) else null;
            },
            else => {
                const node = try arena_alloc.create(Node);
                node.* = root;
                body_ptr = node;
            },
        }
        try docs.append(arena_alloc, .{
            .body = body_ptr,
        });
    }

    return File{
        .arena = arena,
        .docs = docs.items,
    };
}

pub fn emit(allocator: Allocator, doc: Document) ![]u8 {
    return emitter.emit(allocator, doc);
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

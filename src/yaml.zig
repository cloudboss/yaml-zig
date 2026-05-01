//! A YAML 1.2 parser and serializer for Zig.
//!
//! Provides two main workflows:
//!
//! **Typed parsing** — decode YAML directly into Zig structs and types:
//! ```zig
//! const Config = struct { name: []const u8, port: u16 };
//! const parsed = try yaml.parseFromSlice(Config, allocator, input, .{});
//! defer parsed.deinit();
//! std.debug.print("{s}:{d}\n", .{ parsed.value.name, parsed.value.port });
//! ```
//!
//! **AST parsing** — get a full syntax tree for round-trip editing:
//! ```zig
//! var doc = try yaml.parser.parse(allocator, input);
//! defer doc.deinit();
//! const output = try yaml.emitter.emit(allocator, doc.body.?.*, .{});
//! ```
//!
//! **Serialization** — encode Zig values back to YAML:
//! ```zig
//! const output = try yaml.Stringify.valueAlloc(allocator, my_struct, .{});
//! defer allocator.free(output);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const decoder = @import("decode.zig");

/// Abstract syntax tree types for YAML documents.
pub const ast = @import("ast.zig");
/// AST-to-YAML emitter for round-trip output.
pub const emitter = @import("emitter.zig");
/// Error types and diagnostic details.
pub const err = @import("error.zig");
/// Low-level YAML parser producing AST nodes from tokens.
pub const parser = @import("parser.zig");
/// YAML tokenizer (lexer).
pub const scanner = @import("scanner.zig");
/// YAML test suite runner.
pub const suite = @import("suite.zig");
/// Token types and utility functions.
pub const token = @import("token.zig");
/// Dynamic YAML value type.
pub const dynamic = @import("dynamic.zig");
/// YAML serialization. See `Stringify.value` and `Stringify.valueAlloc`.
pub const Stringify = @import("Stringify.zig");

/// A parsed YAML document with an optional AST body node.
pub const Document = ast.Document;
/// A tagged union representing any YAML AST node.
pub const Node = ast.Node;
/// A stream of multiple YAML documents parsed from a single input.
pub const Stream = ast.Stream;
/// A dynamically typed YAML value (null, bool, int, float, string, array, or object).
pub const Value = dynamic.Value;
/// Options for `parseFromSlice`. See `ParseOptions` for field details.
pub const ParseOptions = decoder.ParseOptions;
/// The result of decoding YAML into a Zig type `T`. Owns all allocated memory
/// via an internal arena. Call `deinit()` to free.
pub const Parsed = decoder.Parsed;

/// Decode a YAML string into a Zig type `T`.
///
/// Returns a `Parsed(T)` that owns all allocated memory. Call `deinit()` when done.
/// Supports structs, optionals, slices, integers, floats, booleans, strings, and
/// `Value` for dynamic access. See `ParseOptions` for configuration.
pub fn parseFromSlice(
    comptime T: type,
    allocator: Allocator,
    source: []const u8,
    options: ParseOptions,
) !Parsed(T) {
    return decoder.decode(T, allocator, source, options);
}

/// Decode a YAML string into a Zig type `T` using the caller's allocator directly.
///
/// Unlike `parseFromSlice`, the result is not wrapped in `Parsed(T)`. There is no
/// internal arena, and the caller is responsible for the lifetime of any allocated
/// strings or slices. Pair with an `ArenaAllocator` for the same all-or-nothing
/// cleanup semantics without the double indirection.
pub fn parseFromSliceLeaky(
    comptime T: type,
    allocator: Allocator,
    source: []const u8,
    options: ParseOptions,
) !T {
    return decoder.decodeLeaky(T, allocator, source, options);
}

/// Decode an existing `Value` tree into a Zig type `T`.
///
/// Useful when YAML has already been parsed dynamically and a typed view
/// is needed afterwards. Returns a `Parsed(T)` whose arena owns any
/// memory allocated while building the result.
pub fn parseFromValue(
    comptime T: type,
    allocator: Allocator,
    source: Value,
    options: ParseOptions,
) !Parsed(T) {
    return decoder.decodeFromValue(T, allocator, source, options);
}

/// Decode an existing `Value` tree into `T` using the caller's allocator.
pub fn parseFromValueLeaky(
    comptime T: type,
    allocator: Allocator,
    source: Value,
    options: ParseOptions,
) !T {
    return decoder.decodeFromValueLeaky(T, allocator, source, options);
}

test {
    _ = token;
    _ = ast;
    _ = dynamic;
    _ = err;
    _ = scanner;
    _ = parser;
    _ = emitter;
    _ = decoder;
    _ = Stringify;
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

test "parseFromSliceLeaky into arena" {
    const Config = struct {
        name: []const u8,
        port: u16,
    };
    const input =
        \\name: myapp
        \\port: 3000
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const config = try parseFromSliceLeaky(Config, arena.allocator(), input, .{});
    try testing.expectEqualStrings("myapp", config.name);
    try testing.expectEqual(@as(u16, 3000), config.port);
}

test "parseFromSliceLeaky scalar" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const n = try parseFromSliceLeaky(i64, arena.allocator(), "42", .{});
    try testing.expectEqual(@as(i64, 42), n);
}

test "parseFromValue into struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var obj: Value.ObjectMap = .empty;
    try obj.put(aa, .{ .string = "name" }, .{ .string = "myapp" });
    try obj.put(aa, .{ .string = "port" }, .{ .integer = 3000 });

    const Config = struct { name: []const u8, port: u16 };
    var parsed = try parseFromValue(Config, testing.allocator, .{ .object = obj }, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("myapp", parsed.value.name);
    try testing.expectEqual(@as(u16, 3000), parsed.value.port);
}

test "parseFromValueLeaky scalar" {
    const n = try parseFromValueLeaky(i64, testing.allocator, .{ .integer = 42 }, .{});
    try testing.expectEqual(@as(i64, 42), n);
}

test "parseFromValue identity for Value clones" {
    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer src_arena.deinit();
    const sa = src_arena.allocator();

    var arr: Value.Array = .empty;
    try arr.appendSlice(sa, &.{ .{ .integer = 1 }, .{ .integer = 2 } });
    const source = Value{ .array = arr };

    var parsed = try parseFromValue(Value, testing.allocator, source, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
    try testing.expectEqual(@as(i64, 1), parsed.value.array.items[0].integer);

    // Source can be torn down independently of the result.
    src_arena.deinit();
    try testing.expectEqual(@as(i64, 2), parsed.value.array.items[1].integer);
    src_arena = std.heap.ArenaAllocator.init(testing.allocator);
}

test "full pipeline parseFromSlice Stringify.valueAlloc" {
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
    const output = try Stringify.valueAlloc(testing.allocator, parsed.value, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(input, output);
}

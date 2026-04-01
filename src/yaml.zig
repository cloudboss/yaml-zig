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
//! const output = try yaml.stringifyAlloc(allocator, my_struct, .{});
//! defer allocator.free(output);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const decoder = @import("decode.zig");
const encoder = @import("encode.zig");

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
pub const value = @import("value.zig");

/// A parsed YAML document with an optional AST body node.
pub const Document = ast.Document;
/// A tagged union representing any YAML AST node.
pub const Node = ast.Node;
/// A stream of multiple YAML documents parsed from a single input.
pub const Stream = ast.Stream;
/// A dynamically-typed YAML value (null, bool, int, float, string, sequence, or mapping).
pub const Value = value.Value;
/// Options for `parseFromSlice`. See `ParseOptions` for field details.
pub const ParseOptions = decoder.ParseOptions;
/// The result of decoding YAML into a Zig type `T`. Owns all allocated memory
/// via an internal arena. Call `deinit()` to free.
pub const Parsed = decoder.Parsed;
/// Options for `stringifyAlloc` and `stringify`. See `StringifyOptions` for field details.
pub const StringifyOptions = encoder.StringifyOptions;

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

/// Serialize a Zig value to a YAML string.
///
/// The caller owns the returned slice and must free it with `allocator`.
/// See `StringifyOptions` for output format configuration.
pub fn stringifyAlloc(allocator: Allocator, val: anytype, options: StringifyOptions) ![]u8 {
    return encoder.stringifyAlloc(allocator, val, options);
}

/// Serialize a Zig value as YAML, writing to `writer`.
/// See `StringifyOptions` for output format configuration.
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

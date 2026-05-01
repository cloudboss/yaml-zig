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
const static = @import("static.zig");

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
pub const ParseOptions = static.ParseOptions;
/// The result of decoding YAML into a Zig type `T`. Owns all allocated memory
/// via an internal arena. Call `deinit()` to free.
pub const Parsed = static.Parsed;

pub const parseFromSlice = static.parseFromSlice;
pub const parseFromSliceLeaky = static.parseFromSliceLeaky;
pub const parseFromValue = static.parseFromValue;
pub const parseFromValueLeaky = static.parseFromValueLeaky;
pub const innerParse = decoder.innerParse;
pub const innerParseFromValue = decoder.innerParseFromValue;

/// Generic hash map wrapper that round-trips through YAML mappings with
/// string keys. See `hashmap.zig`.
pub const ArrayHashMap = @import("hashmap.zig").ArrayHashMap;

/// Build a value that formats `value` as YAML when used with `{f}` in
/// any std.fmt printing function. The returned wrapper carries the
/// value and the Stringify options to apply.
///
/// Example:
/// ```zig
/// std.debug.print("{f}\n", .{yaml.fmt(my_struct, .{})});
/// ```
pub fn fmt(value: anytype, options: Stringify.Options) Formatter(@TypeOf(value)) {
    return .{ .value = value, .options = options };
}

/// The wrapper type returned by `fmt`. Has a `format` method usable with
/// the `{f}` formatting verb.
pub fn Formatter(comptime T: type) type {
    return struct {
        value: T,
        options: Stringify.Options,
        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try Stringify.value(self.value, self.options, writer);
        }
    };
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
    _ = static;
    _ = Stringify;
    _ = @import("hashmap.zig");
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

test "type with all three hooks round-trips" {
    // A type whose YAML form is an array of two ints but whose Zig
    // representation is a struct of named fields. Exercises yamlParse,
    // yamlParseFromValue, and yamlStringify on a single type.
    const Pair = struct {
        x: i64,
        y: i64,
        pub fn yamlParse(
            allocator: std.mem.Allocator,
            node: Node,
            options: ParseOptions,
        ) !@This() {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const v = try innerParse(Value, arena.allocator(), node, options);
            return fromArray(v);
        }
        pub fn yamlParseFromValue(
            _: std.mem.Allocator,
            source: Value,
            _: ParseOptions,
        ) !@This() {
            return fromArray(source);
        }
        pub fn yamlStringify(self: @This(), s: *Stringify) !void {
            try s.beginArray();
            try s.write(self.x);
            try s.write(self.y);
            try s.endArray();
        }
        fn fromArray(v: Value) !@This() {
            if (v != .array or v.array.items.len != 2) return error.LengthMismatch;
            const a = v.array.items[0];
            const b = v.array.items[1];
            if (a != .integer or b != .integer) return error.UnexpectedToken;
            return .{ .x = a.integer, .y = b.integer };
        }
    };

    // yamlStringify path
    const out = try Stringify.valueAlloc(testing.allocator, Pair{ .x = 3, .y = 4 }, .{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("- 3\n- 4\n", out);

    // yamlParse path (slice -> Pair)
    const sliced = try parseFromSliceLeaky(Pair, testing.allocator, "[3, 4]", .{});
    try testing.expectEqual(@as(i64, 3), sliced.x);
    try testing.expectEqual(@as(i64, 4), sliced.y);

    // yamlParseFromValue path (Value -> Pair)
    var arr: Value.Array = .empty;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try arr.appendSlice(arena.allocator(), &.{ .{ .integer = 3 }, .{ .integer = 4 } });
    const fv = try parseFromValueLeaky(Pair, testing.allocator, .{ .array = arr }, .{});
    try testing.expectEqual(@as(i64, 3), fv.x);
    try testing.expectEqual(@as(i64, 4), fv.y);
}

test "fmt formats a value via std.fmt" {
    var buf: [64]u8 = undefined;
    const Config = struct { name: []const u8, port: u16 };
    const cfg = Config{ .name = "myapp", .port = 8080 };
    const result = try std.fmt.bufPrint(&buf, "{f}", .{fmt(cfg, .{})});
    try testing.expectEqualStrings("name: myapp\nport: 8080", result);
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

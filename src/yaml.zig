//! A YAML 1.2 parser and serializer for Zig. The API follows a style
//! similar to `std.json` as much as possible.
//!
//! For parsing, there are four main entry points that come in two flavors:
//! those that return a `Parsed`(`T`), and "leaky" variants that return `T`.
//! The leaky variants use the caller's allocator, while the `Parsed`(`T`)
//! variants contain an internal arena and have `deinit` methods.
//!
//! Serialization goes through a `Stringify` writer with both whole-value
//! helpers and a streaming method API.
//!
//! Where YAML differs from JSON, the API diverges to match YAML
//! semantics. The most visible divergence is `Value.ObjectMap`, which
//! keeps YAML's allowance of non-string mapping keys.
//!
//! Custom types may implement `yamlParse`, `yamlParseFromValue`, and
//! `yamlStringify` (see `Hooks` below).
//!
//! ## Parsing
//!
//! Four entry points cover the common cases:
//!
//! - `parseFromSlice(T, allocator, source, options)`: Allocates a result
//!   arena alongside the decoded value and returns a `Parsed`(`T`). Call
//!   `parsed.deinit()` to free everything.
//! - `parseFromSliceLeaky(T, allocator, source, options)`: Decodes into
//!   the caller's allocator without an internal arena. Pair it with an
//!   `ArenaAllocator` if you want a single point of cleanup.
//! - `parseFromValue(T, allocator, source, options)`: Decodes a Value
//!   the caller already has. Returns a `Parsed`(`T`) whose arena owns
//!   deep-cloned data, so the source `Value` can be released independently.
//! - `parseFromValueLeaky(T, allocator, source, options)`: The same path
//!   as `parseFromValue` without the arena wrapper.
//!
//! ```zig
//! const Config = struct { name: []const u8, port: u16 };
//! const parsed = try yaml.parseFromSlice(Config, allocator, input, .{});
//! defer parsed.deinit();
//! std.debug.print("{s}:{d}\n", .{ parsed.value.name, parsed.value.port });
//! ```
//!
//! To decode with an arena owned by the caller:
//!
//! ```zig
//! var arena = std.heap.ArenaAllocator.init(gpa);
//! defer arena.deinit();
//! const cfg = try yaml.parseFromSliceLeaky(Config, arena.allocator(), input, .{});
//! ```
//!
//! `T` may be `Value` to decode without committing to a static schema.
//! `Value` itself implements hooks, so it follows the the same parse
//! and stringify paths.
//!
//! ## Serialization
//!
//! `Stringify.value(val, options, writer)` writes any value as a YAML string
//! to a `std.Io.Writer`.
//!
//! `Stringify.valueAlloc(allocator, val, options)` returns an owned slice
//! instead.
//!
//! Both honor `Stringify.Options` for indent width, flow versus block style,
//! and other knobs.
//!
//! ```zig
//! const out = try yaml.Stringify.valueAlloc(allocator, my_struct, .{});
//! defer allocator.free(out);
//! ```
//!
//! For incremental emission from inside a hook, construct a
//! `Stringify` with `Stringify.init(writer, options)` and call
//! `beginObject`, `objectField`, `write`, `print`, `beginArray`,
//! `endArray`, and `endObject`.
//!
//! `yaml.fmt(value, options)` returns a small wrapper that formats as
//! YAML when passed through `{f}` to `std.fmt`.
//!
//! ## Hooks
//!
//! A user type can take control of how it is parsed and serialized by
//! declaring any of:
//!
//! ```zig
//! pub fn yamlParse(allocator: Allocator, node: yaml.Node, options: yaml.ParseOptions) !@This()
//! pub fn yamlParseFromValue(allocator: Allocator, source: yaml.Value, options: yaml.ParseOptions) !@This()
//! pub fn yamlStringify(self: @This(), s: *yaml.Stringify) !void
//! ```
//!
//! `yamlParse` runs when the value is reached during AST decoding.
//! `yamlParseFromValue` runs during `Value` decoding. Inside these,
//! call `innerParse` or `innerParseFromValue` to recurse
//! on a sub-`Node` or sub-`Value`.
//!
//! `yamlStringify` runs when the encoder reaches the value. Inside this,
//! use the streaming methods on the `Stringify` argument to emit YAML.
//!
//! ## YAML-specific extensions
//!
//! The features that have no JSON counterpart sit under the AST and
//! parser modules and stay unchanged from earlier versions of this
//! library:
//!
//! - Multi-document streams. Use `yaml.parser.parseAll` to get a
//!   `yaml.Stream` of documents.
//! - Anchors and aliases (`&` and `*`). The decoder resolves these
//!   automatically.
//! - Comment-preserving emission. The AST module retains comments and
//!   `yaml.emitter.emit` produces a round-trip rendering.
//!
//! For working with the AST directly:
//!
//! ```zig
//! var doc = try yaml.parser.parse(allocator, input);
//! defer doc.deinit();
//! const output = try yaml.emitter.emit(allocator, doc.body.?.*, .{});
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// String-keyed hash map of `T` values that round-trips through a YAML
/// mapping. Use as a struct field for YAML inputs whose keys are
/// arbitrary strings and whose values share one type.
pub const ArrayHashMap = @import("hashmap.zig").ArrayHashMap;
/// Abstract syntax tree types for YAML documents.
pub const ast = @import("ast.zig");
/// A parsed YAML document with an optional AST body node.
pub const Document = ast.Document;
/// A tagged union representing any YAML AST node.
pub const Node = ast.Node;
/// A stream of multiple YAML documents parsed from a single input.
pub const Stream = ast.Stream;
const decoder = @import("decode.zig");
pub const innerParse = decoder.innerParse;
pub const innerParseFromValue = decoder.innerParseFromValue;
/// Dynamic YAML value type.
pub const dynamic = @import("dynamic.zig");
/// A dynamically typed YAML value (null, bool, int, float, string, array, or object).
pub const Value = dynamic.Value;
/// AST-to-YAML emitter for round-trip output.
pub const emitter = @import("emitter.zig");
/// Error types and diagnostic details.
pub const err = @import("error.zig");
/// Low-level YAML parser producing AST nodes from tokens.
pub const parser = @import("parser.zig");
/// YAML tokenizer (lexer).
pub const scanner = @import("scanner.zig");
const static = @import("static.zig");
/// Options for `parseFromSlice`. See `ParseOptions` for field details.
pub const ParseOptions = static.ParseOptions;
/// The result of decoding YAML into a Zig type `T`. Owns all allocated memory
/// via an internal arena. Call `deinit()` to free.
pub const Parsed = static.Parsed;
pub const parseFromSlice = static.parseFromSlice;
pub const parseFromSliceLeaky = static.parseFromSliceLeaky;
pub const parseFromValue = static.parseFromValue;
pub const parseFromValueLeaky = static.parseFromValueLeaky;
/// YAML serialization. See `Stringify.value` and `Stringify.valueAlloc`.
pub const Stringify = @import("Stringify.zig");
/// YAML test suite runner.
pub const suite = @import("suite.zig");
/// Token types and utility functions.
pub const token = @import("token.zig");

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

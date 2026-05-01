//! Typed-decoding entry points and their supporting types.
//!
//! Mirrors the role of std.json's static.zig: this is where Parsed,
//! ParseOptions, and the four parseFromX functions live. The actual
//! type-walking logic stays in decode.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;

const decoder = @import("decode.zig");
const Value = @import("dynamic.zig").Value;

/// Options controlling how YAML is decoded into Zig types.
pub const ParseOptions = struct {
    /// What to do when a YAML mapping has the same key twice. The default
    /// is to fail; choose `.use_first` or `.use_last` to take one of the
    /// duplicates instead.
    duplicate_field_behavior: enum {
        use_first,
        @"error",
        use_last,
    } = .@"error",

    /// When true, YAML keys that don't match any struct field are silently
    /// dropped. When false (default), they cause an `UnknownField` error.
    ignore_unknown_fields: bool = false,

    /// Maximum nesting depth for YAML structures. Exceeding this limit
    /// returns a `MaxDepthExceeded` error.
    max_depth: u32 = 10_000,
};

/// Result of decoding YAML into a Zig type `T`.
///
/// Owns all allocated memory (strings, slices, nested arrays and objects)
/// via an internal arena. Call `deinit()` to release everything when done.
pub fn Parsed(comptime T: type) type {
    return struct {
        arena: *std.heap.ArenaAllocator,
        value: T,

        /// Free all memory owned by this parsed result.
        pub fn deinit(self: @This()) void {
            const child_allocator = self.arena.child_allocator;
            self.arena.deinit();
            child_allocator.destroy(self.arena);
        }
    };
}

/// Decode a YAML string into a Zig type `T`.
///
/// Returns a Parsed(T) that owns all allocated memory. Call deinit() when
/// done. Supports structs, optionals, slices, integers, floats, booleans,
/// strings, and Value for dynamic access.
pub fn parseFromSlice(
    comptime T: type,
    allocator: Allocator,
    source: []const u8,
    options: ParseOptions,
) !Parsed(T) {
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const parse_alloc = parse_arena.allocator();

    const node_val = try decoder.parseToNode(parse_alloc, source, options);

    var parsed = Parsed(T){
        .arena = try allocator.create(std.heap.ArenaAllocator),
        .value = undefined,
    };
    errdefer allocator.destroy(parsed.arena);
    parsed.arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer parsed.arena.deinit();

    var anchors = decoder.AnchorMap.init(parse_alloc);
    parsed.value = try decoder.decodeNodeInternal(
        T,
        parsed.arena.allocator(),
        node_val,
        options,
        &anchors,
    );
    return parsed;
}

/// Decode a YAML string into `T` using the caller's allocator directly.
///
/// Unlike parseFromSlice, the result is not wrapped in Parsed(T). There is
/// no internal arena, and the caller is responsible for the lifetime of any
/// allocated strings or slices. Pair with an ArenaAllocator for the same
/// all-or-nothing cleanup semantics without the double indirection.
pub fn parseFromSliceLeaky(
    comptime T: type,
    allocator: Allocator,
    source: []const u8,
    options: ParseOptions,
) !T {
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const parse_alloc = parse_arena.allocator();

    const node_val = try decoder.parseToNode(parse_alloc, source, options);
    var anchors = decoder.AnchorMap.init(parse_alloc);
    return try decoder.decodeNodeInternal(T, allocator, node_val, options, &anchors);
}

/// Decode an existing Value tree into a Zig type `T`.
///
/// Returns a Parsed(T) whose arena owns any memory allocated for the
/// result (duped strings, allocated slices, nested arrays and objects).
/// The source Value is left untouched.
pub fn parseFromValue(
    comptime T: type,
    allocator: Allocator,
    source: Value,
    options: ParseOptions,
) !Parsed(T) {
    var parsed = Parsed(T){
        .arena = try allocator.create(std.heap.ArenaAllocator),
        .value = undefined,
    };
    errdefer allocator.destroy(parsed.arena);
    parsed.arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer parsed.arena.deinit();

    parsed.value = try decoder.decodeValueInternal(
        T,
        parsed.arena.allocator(),
        source,
        options,
    );
    return parsed;
}

/// Decode an existing Value tree into `T` using the caller's allocator.
pub fn parseFromValueLeaky(
    comptime T: type,
    allocator: Allocator,
    source: Value,
    options: ParseOptions,
) !T {
    return decoder.decodeValueInternal(T, allocator, source, options);
}

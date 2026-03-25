const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const ast = @import("ast.zig");
const Node = ast.Node;
const yaml = @import("yaml.zig");

pub const EmitOptions = struct {
    indent: u8 = 2,
    flow_style: bool = false,
};

pub fn emit(allocator: Allocator, node: Node, options: EmitOptions) ![]u8 {
    _ = allocator;
    _ = node;
    _ = options;
    return error.Unimplemented;
}

pub fn emitTo(writer: anytype, node: Node, options: EmitOptions) !void {
    _ = writer;
    _ = node;
    _ = options;
    return error.Unimplemented;
}

fn roundTrip(input: []const u8) !void {
    var doc = try yaml.parse(testing.allocator, input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const output = try emit(testing.allocator, body.*, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(input, output);
}

fn roundTripNormalized(input: []const u8, expected: []const u8) !void {
    var doc = try yaml.parse(testing.allocator, input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const output = try emit(testing.allocator, body.*, .{});
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(expected, output);
}

test "round-trip simple key value" {
    try roundTrip("v: hi\n");
}

test "round-trip integer value" {
    try roundTrip("v: 10\n");
}

test "round-trip negative integer" {
    try roundTrip("v: -10\n");
}

test "round-trip float value" {
    try roundTrip("v: 0.1\n");
}

test "round-trip bool true" {
    try roundTrip("v: true\n");
}

test "round-trip bool false" {
    try roundTrip("v: false\n");
}

test "round-trip null" {
    try roundTrip("v: null\n");
}

test "round-trip infinity" {
    try roundTrip("v: .inf\n");
}

test "round-trip negative infinity" {
    try roundTrip("v: -.inf\n");
}

test "round-trip nan" {
    try roundTrip("v: .nan\n");
}

test "round-trip empty string" {
    try roundTrip("v: \"\"\n");
}

test "round-trip quoted true" {
    try roundTrip("v: \"true\"\n");
}

test "round-trip block sequence" {
    try roundTrip(
        \\v:
        \\- A
        \\- B
    );
}

test "round-trip flow sequence" {
    try roundTrip("v: [A, B]\n");
}

test "round-trip nested map" {
    try roundTrip(
        \\a:
        \\  b: c
    );
}

test "round-trip flow mapping" {
    try roundTrip("a: {b: c}\n");
}

test "round-trip flow mapping multiple" {
    try roundTrip("a: {b: c, d: e}\n");
}

test "round-trip literal block" {
    try roundTrip(
        \\v: |
        \\  hello
        \\  world
    );
}

test "round-trip literal block strip" {
    try roundTrip(
        \\v: |-
        \\  hello
        \\  world
    );
}

test "round-trip folded block" {
    try roundTrip(
        \\v: >
        \\  hello
        \\  world
    );
}

test "round-trip comment after value" {
    try roundTrip("a: b # comment\n");
}

test "round-trip head comment" {
    try roundTrip(
        \\# comment
        \\a: b
    );
}

test "round-trip anchor and alias" {
    try roundTrip(
        \\a: &ref hello
        \\b: *ref
    );
}

test "round-trip document header" {
    try roundTrip(
        \\---
        \\a: b
    );
}

test "round-trip document end" {
    try roundTrip(
        \\a: b
        \\...
    );
}

test "round-trip tagged value" {
    try roundTrip("v: !!binary gIGC\n");
}

test "round-trip nested sequence in map" {
    try roundTrip(
        \\a:
        \\  b:
        \\  - 1
        \\  - 2
    );
}

test "round-trip multiple keys" {
    try roundTrip(
        \\a: 1
        \\b: 2
        \\c: 3
    );
}

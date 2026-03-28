const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const ast = @import("ast.zig");
const Node = ast.Node;
const token = @import("token.zig");
const yaml = @import("yaml.zig");

pub const EmitOptions = struct {
    indent: u8 = 2,
    flow_style: bool = false,
};

const Writer = struct {
    buf: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,

    fn writeAll(self: *Writer, data: []const u8) Allocator.Error!void {
        try self.buf.appendSlice(self.allocator, data);
    }

    fn writeByte(self: *Writer, byte: u8) Allocator.Error!void {
        try self.buf.append(self.allocator, byte);
    }
};

pub fn emit(allocator: Allocator, node: Node, options: EmitOptions) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(allocator);
    var w = Writer{ .buf = &buf, .allocator = allocator };

    // Check for document markers and head comments via token chain.
    const first_tok = findFirstToken(node);
    const last_tok = findLastToken(node);

    // Emit head comments (comments before the first content token).
    if (first_tok) |ft| {
        try emitPrecedingComments(&w, ft);
    }

    // Emit document header if present.
    var has_doc_header = false;
    if (first_tok) |ft| {
        var t = ft.prev;
        while (t) |tok| : (t = tok.prev) {
            if (tok.token_type == .document_header) {
                has_doc_header = true;
                break;
            }
            if (tok.token_type != .comment) break;
        }
    }
    if (has_doc_header) {
        try w.writeAll("---\n");
    }

    // Check for document end.
    var has_doc_end = false;
    if (last_tok) |lt| {
        var t = lt.next;
        while (t) |tok| : (t = tok.next) {
            if (tok.token_type == .document_end) {
                has_doc_end = true;
                break;
            }
            if (tok.token_type != .comment) break;
        }
    }

    // Emit the body. Use inner emit to avoid top-level newline when
    // wrapped in document markers or head comments.
    const has_wrapper = has_doc_header or has_doc_end or
        (first_tok != null and hasPrecedingComments(first_tok.?));
    if (has_wrapper) {
        try emitNodeInner(&w, node, 0, options);
    } else {
        try emitNode(&w, node, 0, options);
    }

    // Emit document end if present.
    if (has_doc_end) {
        try w.writeAll("\n...");
    }

    return buf.toOwnedSlice(allocator);
}

pub fn emitTo(writer: anytype, node: Node, options: EmitOptions) !void {
    _ = writer;
    _ = node;
    _ = options;
    return error.Unimplemented;
}

fn emitNodeInner(w: *Writer, node: Node, indent: u16, options: EmitOptions) Allocator.Error!void {
    switch (node) {
        .document => |d| try emitDocument(w, d, indent, options),
        .mapping => |m| try emitMapping(w, m, indent, options),
        .mapping_value => |mv| try emitMappingValue(w, mv, indent, false, options),
        .string => |s| try emitString(w, s),
        .integer => |i| try emitTokenValue(w, i.token),
        .float_value => |f| try emitTokenValue(w, f.token),
        .boolean => |b| try emitTokenValue(w, b.token),
        .null_value => |n| try emitTokenValue(w, n.token),
        .infinity => |i| try emitTokenValue(w, i.token),
        .nan => |n| try emitTokenValue(w, n.token),
        .literal => |l| try emitLiteral(w, l, indent, options),
        .sequence => |s| try emitSequence(w, s, indent, options),
        .anchor => |a| try emitAnchor(w, a, indent, options),
        .alias => |a| try emitAlias(w, a),
        .tag => |t| try emitTag(w, t, indent, options),
        .comment => {},
        .comment_group => {},
        .merge_key => try w.writeAll("<<"),
        .mapping_key => {},
        .directive => {},
    }
}

fn emitNode(w: *Writer, node: Node, indent: u16, options: EmitOptions) Allocator.Error!void {
    switch (node) {
        .document => |d| try emitDocument(w, d, indent, options),
        .mapping => |m| try emitMapping(w, m, indent, options),
        .mapping_value => |mv| try emitMappingValue(w, mv, indent, true, options),
        .string => |s| try emitString(w, s),
        .integer => |i| try emitTokenValue(w, i.token),
        .float_value => |f| try emitTokenValue(w, f.token),
        .boolean => |b| try emitTokenValue(w, b.token),
        .null_value => |n| try emitTokenValue(w, n.token),
        .infinity => |i| try emitTokenValue(w, i.token),
        .nan => |n| try emitTokenValue(w, n.token),
        .literal => |l| try emitLiteral(w, l, indent, options),
        .sequence => |s| try emitSequence(w, s, indent, options),
        .anchor => |a| try emitAnchor(w, a, indent, options),
        .alias => |a| try emitAlias(w, a),
        .tag => |t| try emitTag(w, t, indent, options),
        .comment => {},
        .comment_group => {},
        .merge_key => try w.writeAll("<<"),
        .mapping_key => {},
        .directive => {},
    }
}

fn emitDocument(
    w: *Writer,
    doc: ast.DocumentNode,
    indent: u16,
    options: EmitOptions,
) Allocator.Error!void {
    if (doc.body) |body| {
        try emitNodeInner(w, body.*, indent, options);
    }
}

fn emitMapping(
    w: *Writer,
    mapping: ast.MappingNode,
    indent: u16,
    options: EmitOptions,
) Allocator.Error!void {
    if (mapping.is_flow) {
        try emitFlowMapping(w, mapping, options);
    } else {
        for (mapping.values, 0..) |mv, i| {
            if (i > 0) try w.writeAll("\n");
            try emitMappingValue(w, mv.*, indent, false, options);
        }
    }
}

fn emitFlowMapping(
    w: *Writer,
    mapping: ast.MappingNode,
    options: EmitOptions,
) Allocator.Error!void {
    try w.writeAll("{");
    for (mapping.values, 0..) |mv, i| {
        if (i > 0) try w.writeAll(", ");
        if (mv.key) |key| {
            try emitNode(w, key.*, 0, options);
        }
        try w.writeAll(": ");
        if (mv.value) |val| {
            try emitNode(w, val.*, 0, options);
        }
    }
    try w.writeAll("}");
}

fn emitMappingValue(
    w: *Writer,
    mv: ast.MappingValueNode,
    indent: u16,
    is_top_level: bool,
    options: EmitOptions,
) Allocator.Error!void {
    // Check for head comment (comment on a line before the key).
    const has_head_comment = blk: {
        if (mv.node_comment) |cg| {
            if (cg.comments.len > 0) {
                if (mv.key) |key| {
                    if (key.getToken()) |key_tok| {
                        if (cg.comments[0].token) |ct| {
                            if (ct.position.line < key_tok.position.line) {
                                break :blk true;
                            }
                        }
                    }
                }
            }
        }
        break :blk false;
    };

    // Emit head comments.
    if (has_head_comment) {
        if (mv.node_comment) |cg| {
            for (cg.comments) |c| {
                if (c.token) |ct| {
                    if (mv.key) |key| {
                        if (key.getToken()) |key_tok| {
                            if (ct.position.line < key_tok.position.line) {
                                try writeIndent(w, indent);
                                try w.writeAll("#");
                                try w.writeAll(c.value);
                                try w.writeAll("\n");
                            }
                        }
                    }
                }
            }
        }
    }

    // Write indent.
    try writeIndent(w, indent);

    // Emit key.
    if (mv.key) |key| {
        try emitNode(w, key.*, indent, options);
    }

    // Determine if value is block-style (goes on next line).
    const value_is_block = isBlockValue(mv.value);

    if (value_is_block) {
        try w.writeAll(":\n");
        if (mv.value) |val| {
            const child_indent = getBlockValueIndent(val.*, indent, options);
            try emitNodeInner(w, val.*, child_indent, options);
        }
    } else {
        try w.writeAll(": ");
        if (mv.value) |val| {
            try emitNode(w, val.*, indent, options);
        }
        // Emit inline comment.
        if (!has_head_comment) {
            try emitInlineComment(w, mv.node_comment, mv.key);
        }
        // Add trailing newline for top-level single-line values.
        // Don't add for multi-line values like block scalars.
        if (is_top_level and !isMultilineValue(mv.value)) {
            try w.writeAll("\n");
        }
    }
}

fn emitInlineComment(
    w: *Writer,
    node_comment: ?*const ast.CommentGroupNode,
    key: ?*const Node,
) Allocator.Error!void {
    const cg = node_comment orelse return;
    for (cg.comments) |c| {
        if (c.token) |ct| {
            var is_inline = true;
            if (key) |k| {
                if (k.getToken()) |key_tok| {
                    if (ct.position.line < key_tok.position.line) {
                        is_inline = false;
                    }
                }
            }
            if (is_inline) {
                try w.writeAll(" #");
                try w.writeAll(c.value);
            }
        }
    }
}

fn isMultilineValue(value: ?*const Node) bool {
    const val = value orelse return false;
    return val.* == .literal;
}

fn isBlockValue(value: ?*const Node) bool {
    const val = value orelse return false;
    return switch (val.*) {
        .sequence => |s| !s.is_flow,
        .mapping => |m| !m.is_flow,
        .mapping_value => true,
        else => false,
    };
}

fn getBlockValueIndent(val: Node, parent_indent: u16, options: EmitOptions) u16 {
    return switch (val) {
        .sequence => |s| if (!s.is_flow) parent_indent else parent_indent + options.indent,
        .mapping, .mapping_value => parent_indent + options.indent,
        .literal => parent_indent + options.indent,
        else => parent_indent + options.indent,
    };
}

fn emitString(w: *Writer, s: ast.StringNode) Allocator.Error!void {
    if (s.token) |tok| {
        if (tok.token_type == .double_quote) {
            try w.writeAll("\"");
            try w.writeAll(tok.value);
            try w.writeAll("\"");
        } else if (tok.token_type == .single_quote) {
            try w.writeAll("'");
            try w.writeAll(tok.value);
            try w.writeAll("'");
        } else {
            try w.writeAll(tok.value);
        }
    } else {
        try w.writeAll(s.value);
    }
}

fn emitTokenValue(w: *Writer, tok: ?*const token.Token) Allocator.Error!void {
    if (tok) |t| {
        try w.writeAll(t.value);
    }
}

fn emitLiteral(
    w: *Writer,
    lit: ast.LiteralNode,
    indent: u16,
    options: EmitOptions,
) Allocator.Error!void {
    // Write block scalar header.
    switch (lit.block_style) {
        .literal => try w.writeAll("|"),
        .folded => try w.writeAll(">"),
    }
    switch (lit.chomping) {
        .clip => {},
        .strip => try w.writeAll("-"),
        .keep => try w.writeAll("+"),
    }
    try w.writeAll("\n");

    // Get the raw content lines from the token's origin (for folded round-trip).
    var content: []const u8 = "";
    if (lit.token) |tok| {
        if (tok.origin.len > 0) {
            content = tok.origin;
        } else {
            content = tok.value;
        }
    }
    if (content.len == 0) {
        content = lit.value;
    }

    // Content is indented relative to the parent.
    const content_indent = indent + options.indent;

    // Emit each line with indent.
    var first = true;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (!first) try w.writeAll("\n");
        first = false;
        if (line.len > 0) {
            try writeIndent(w, content_indent);
            try w.writeAll(line);
        }
    }
}

fn emitSequence(
    w: *Writer,
    seq: ast.SequenceNode,
    indent: u16,
    options: EmitOptions,
) Allocator.Error!void {
    if (seq.is_flow) {
        try emitFlowSequence(w, seq, options);
    } else {
        for (seq.values, 0..) |val, i| {
            if (i > 0) try w.writeAll("\n");
            try writeIndent(w, indent);
            try w.writeAll("- ");
            try emitNode(w, val.*, indent + 2, options);
        }
    }
}

fn emitFlowSequence(w: *Writer, seq: ast.SequenceNode, options: EmitOptions) Allocator.Error!void {
    try w.writeAll("[");
    for (seq.values, 0..) |val, i| {
        if (i > 0) try w.writeAll(", ");
        try emitNode(w, val.*, 0, options);
    }
    try w.writeAll("]");
}

fn emitAnchor(
    w: *Writer,
    anchor: ast.AnchorNode,
    indent: u16,
    options: EmitOptions,
) Allocator.Error!void {
    try w.writeAll("&");
    try w.writeAll(anchor.name);
    if (anchor.value) |val| {
        try w.writeAll(" ");
        try emitNode(w, val.*, indent, options);
    }
}

fn emitAlias(w: *Writer, alias: ast.AliasNode) Allocator.Error!void {
    try w.writeAll("*");
    try w.writeAll(alias.name);
}

fn emitTag(w: *Writer, t: ast.TagNode, indent: u16, options: EmitOptions) Allocator.Error!void {
    try w.writeAll(t.tag);
    if (t.value) |val| {
        try w.writeAll(" ");
        try emitNode(w, val.*, indent, options);
    }
}

fn findFirstToken(node: Node) ?*const token.Token {
    return switch (node) {
        .mapping => |m| {
            if (m.values.len > 0) {
                if (m.values[0].key) |key| return findFirstToken(key.*);
                return m.values[0].token;
            }
            return m.token;
        },
        .mapping_value => |mv| {
            if (mv.key) |key| return findFirstToken(key.*);
            return mv.token;
        },
        .sequence => |s| {
            if (s.values.len > 0) return findFirstToken(s.values[0].*);
            return s.token;
        },
        .anchor => |a| a.token,
        .tag => |t| t.token,
        inline else => |n| n.token,
    };
}

fn findLastToken(node: Node) ?*const token.Token {
    return switch (node) {
        .mapping => |m| {
            if (m.values.len > 0) {
                const last_mv = m.values[m.values.len - 1];
                if (last_mv.value) |val| return findLastToken(val.*);
                if (last_mv.key) |key| return findLastToken(key.*);
            }
            return m.token;
        },
        .mapping_value => |mv| {
            if (mv.value) |val| return findLastToken(val.*);
            if (mv.key) |key| return findLastToken(key.*);
            return mv.token;
        },
        .sequence => |s| {
            if (s.values.len > 0) return findLastToken(s.values[s.values.len - 1].*);
            return s.token;
        },
        .anchor => |a| {
            if (a.value) |val| return findLastToken(val.*);
            return a.token;
        },
        .tag => |t| {
            if (t.value) |val| return findLastToken(val.*);
            return t.token;
        },
        .literal => |l| l.token,
        inline else => |n| n.token,
    };
}

fn hasPrecedingComments(tok: *const token.Token) bool {
    var t = tok.prev;
    while (t) |prev| : (t = prev.prev) {
        if (prev.token_type == .comment) return true;
        break;
    }
    return false;
}

fn emitPrecedingComments(w: *Writer, tok: *const token.Token) Allocator.Error!void {
    // Collect all preceding comment tokens (in reverse), then emit in order.
    var comments: [64]*const token.Token = undefined;
    var count: usize = 0;
    var t = tok.prev;
    while (t) |prev| : (t = prev.prev) {
        if (prev.token_type == .comment) {
            if (count < 64) {
                comments[count] = prev;
                count += 1;
            }
        } else if (prev.token_type == .document_header) {
            break;
        } else {
            break;
        }
    }
    // Emit in correct order (reverse of how we collected).
    var i = count;
    while (i > 0) {
        i -= 1;
        try w.writeAll("#");
        try w.writeAll(comments[i].value);
        try w.writeAll("\n");
    }
}

fn writeIndent(w: *Writer, indent: u16) Allocator.Error!void {
    for (0..indent) |_| {
        try w.writeByte(' ');
    }
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

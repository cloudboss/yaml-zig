const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const ast = @import("ast.zig");
const Node = ast.Node;
const Detail = @import("error.zig").Detail;
const token = @import("token.zig");
const Token = token.Token;
const TokenType = token.TokenType;
const Position = token.Position;
const toNumber = token.toNumber;
const yaml = @import("yaml.zig");

const ParseErr = error{
    SyntaxError,
    DuplicateKey,
    OutOfMemory,
};

pub const Parser = struct {
    allocator: Allocator,
    tokens: []const Token = &.{},
    pos: usize = 0,
    last_error: ?Detail = null,

    pub fn init(allocator: Allocator) Parser {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Parser) void {
        _ = self;
    }

    pub fn parse(self: *Parser, tokens: []const Token) !Node {
        self.tokens = tokens;
        self.pos = 0;
        self.skipComments();
        if (self.pos >= self.tokens.len) {
            return Node{ .document = .{} };
        }
        // Handle directive.
        if (self.current().token_type == .directive) {
            // Check for content markers in the directive value.
            const dir_val = self.current().value;
            for (dir_val) |c| {
                if (c == '{' or c == '}' or c == '[' or c == ']') {
                    return self.syntaxError("unexpected content in directive");
                }
            }
            self.advance();
            self.skipComments();
            // After directive, expect document header or end.
            if (self.pos < self.tokens.len and
                self.current().token_type == .document_header)
            {
                self.advance();
                self.skipComments();
            } else if (self.pos < self.tokens.len and
                self.isContentToken(self.current().token_type))
            {
                return self.syntaxError("expected document header after directive");
            }
            if (self.pos >= self.tokens.len) {
                return Node{ .document = .{} };
            }
        }
        // Handle document header.
        if (self.pos < self.tokens.len and
            self.current().token_type == .document_header)
        {
            self.advance();
            self.skipComments();
        }
        if (self.pos >= self.tokens.len) {
            return Node{ .document = .{} };
        }
        const body = try self.parseNode(0, false);
        // Skip any trailing comments.
        self.skipComments();
        // Check for unconsumed tokens (indicates syntax error).
        if (self.pos < self.tokens.len) {
            const tok = self.current();
            if (tok.token_type != .document_end and
                tok.token_type != .document_header)
            {
                return self.syntaxError("unexpected content after value");
            }
        }
        if (body) |b| {
            return b.*;
        }
        return Node{ .document = .{} };
    }

    pub fn lastError(self: *const Parser) ?Detail {
        return self.last_error;
    }

    fn current(self: *const Parser) Token {
        return self.tokens[self.pos];
    }

    fn peek(self: *const Parser, offset: usize) ?Token {
        const idx = self.pos + offset;
        if (idx < self.tokens.len) return self.tokens[idx];
        return null;
    }

    fn advance(self: *Parser) void {
        if (self.pos < self.tokens.len) self.pos += 1;
    }

    fn tokenIndent(self: *const Parser, idx: usize) u32 {
        if (idx < self.tokens.len) return self.tokens[idx].position.indent_num;
        return 0;
    }

    fn currentIndent(self: *const Parser) u32 {
        return self.tokenIndent(self.pos);
    }

    fn currentColumn(self: *const Parser) u32 {
        if (self.pos < self.tokens.len) return self.tokens[self.pos].position.column;
        return 0;
    }

    fn skipComments(self: *Parser) void {
        while (self.pos < self.tokens.len and
            self.tokens[self.pos].token_type == .comment)
        {
            self.advance();
        }
    }

    fn collectComments(self: *Parser) !?*const ast.CommentGroupNode {
        var comments = std.ArrayListUnmanaged(*const ast.CommentNode){};
        while (self.pos < self.tokens.len and
            self.tokens[self.pos].token_type == .comment)
        {
            const c = try self.createNode(Node{ .comment = .{
                .token = &self.tokens[self.pos],
                .value = self.tokens[self.pos].value,
            } });
            try comments.append(self.allocator, &c.comment);
            self.advance();
        }
        if (comments.items.len > 0) {
            const group = try self.createNode(Node{ .comment_group = .{
                .comments = try self.dupeSlice(*const ast.CommentNode, comments.items),
            } });
            return &group.comment_group;
        }
        return null;
    }

    fn collectInlineComment(self: *Parser) !?*const ast.CommentGroupNode {
        if (self.pos < self.tokens.len and
            self.tokens[self.pos].token_type == .comment)
        {
            const c = try self.createNode(Node{ .comment = .{
                .token = &self.tokens[self.pos],
                .value = self.tokens[self.pos].value,
            } });
            self.advance();
            const group = try self.createNode(Node{ .comment_group = .{
                .comments = try self.dupeSlice(*const ast.CommentNode, &.{&c.comment}),
            } });
            return &group.comment_group;
        }
        return null;
    }

    fn mergeComments(
        self: *Parser,
        a: ?*const ast.CommentGroupNode,
        b: ?*const ast.CommentGroupNode,
    ) !?*const ast.CommentGroupNode {
        if (a == null) return b;
        if (b == null) return a;
        var all = std.ArrayListUnmanaged(*const ast.CommentNode){};
        for (a.?.comments) |c| try all.append(self.allocator, c);
        for (b.?.comments) |c| try all.append(self.allocator, c);
        const group = try self.createNode(Node{ .comment_group = .{
            .comments = try self.dupeSlice(*const ast.CommentNode, all.items),
        } });
        return &group.comment_group;
    }

    fn syntaxError(self: *Parser, msg: []const u8) error{SyntaxError} {
        var pos: ?Position = null;
        if (self.pos < self.tokens.len) {
            pos = self.tokens[self.pos].position;
        }
        self.last_error = .{ .message = msg, .position = pos };
        return error.SyntaxError;
    }

    fn duplicateKeyError(self: *Parser, msg: []const u8) error{DuplicateKey} {
        var pos: ?Position = null;
        if (self.pos < self.tokens.len) {
            pos = self.tokens[self.pos].position;
        }
        self.last_error = .{ .message = msg, .position = pos };
        return error.DuplicateKey;
    }

    fn createNode(self: *Parser, node: Node) !*Node {
        const n = try self.allocator.create(Node);
        n.* = node;
        return n;
    }

    fn dupeSlice(self: *Parser, comptime T: type, items: []const T) ![]const T {
        const slice = try self.allocator.alloc(T, items.len);
        @memcpy(slice, items);
        return slice;
    }

    fn isContentToken(self: *const Parser, tt: TokenType) bool {
        _ = self;
        return switch (tt) {
            .string,
            .integer,
            .float,
            .bool_value,
            .null_value,
            .infinity,
            .nan,
            .single_quote,
            .double_quote,
            .mapping_start,
            .sequence_start,
            .sequence_entry,
            .literal,
            .folded,
            .anchor,
            .alias,
            .tag,
            .merge_key,
            .mapping_key,
            => true,
            else => false,
        };
    }

    fn isKeyToken(self: *const Parser, tt: TokenType) bool {
        _ = self;
        return switch (tt) {
            .string,
            .integer,
            .float,
            .bool_value,
            .null_value,
            .infinity,
            .nan,
            .single_quote,
            .double_quote,
            .merge_key,
            .mapping_key,
            .anchor,
            .alias,
            .tag,
            => true,
            else => false,
        };
    }

    fn isScalarToken(self: *const Parser, tt: TokenType) bool {
        _ = self;
        return switch (tt) {
            .string,
            .integer,
            .float,
            .bool_value,
            .null_value,
            .infinity,
            .nan,
            .single_quote,
            .double_quote,
            => true,
            else => false,
        };
    }

    fn parseNode(self: *Parser, min_indent: u32, in_flow: bool) ParseErr!?*Node {
        self.skipComments();
        if (self.pos >= self.tokens.len) return null;
        const tok = self.current();
        const tt = tok.token_type;

        // Document end or next document header stops parsing.
        if (tt == .document_end or tt == .document_header) return null;

        // Flow collections.
        if (tt == .mapping_start) return try self.parseFlowMapping();
        if (tt == .sequence_start) return try self.parseFlowSequence();

        // Unexpected close brackets.
        if (tt == .mapping_end or tt == .sequence_end) {
            return self.syntaxError("unexpected close bracket");
        }

        // Block sequence.
        if (tt == .sequence_entry) {
            return try self.parseBlockSequence(min_indent);
        }

        // Tag.
        if (tt == .tag) return try self.parseTag(min_indent, in_flow);

        // Anchor.
        if (tt == .anchor) return try self.parseAnchor(min_indent, in_flow);

        // Alias.
        if (tt == .alias) return try self.parseAlias();

        // Merge key.
        if (tt == .merge_key) {
            return try self.parseMergeKeyValue(min_indent, in_flow);
        }

        // Mapping key (explicit `?`).
        if (tt == .mapping_key) return try self.parseExplicitKey(min_indent, in_flow);

        // Block scalar.
        if (tt == .literal or tt == .folded) {
            return try self.parseBlockScalar();
        }

        // Directive in the wrong place.
        if (tt == .directive) {
            return self.syntaxError("unexpected directive");
        }

        // Scalar or mapping value.
        if (self.isScalarToken(tt)) {
            return try self.parseScalarOrMapping(min_indent, in_flow);
        }

        // Bare mapping_value ':' without a key is a syntax error at non-flow level.
        if (tt == .mapping_value and !in_flow) {
            return self.syntaxError("unexpected ':'");
        }

        // Collect entry and mapping_value are handled by callers.
        if (tt == .collect_entry or tt == .mapping_value) return null;

        return null;
    }

    fn parseScalarOrMapping(self: *Parser, min_indent: u32, in_flow: bool) ParseErr!?*Node {
        const key_col = self.currentColumn();
        const key_indent = self.currentIndent();
        const key_node = try self.parseScalarValue();

        // In flow context, don't consume ':' here, let the flow collection handle it.
        if (in_flow) return key_node;

        // Peek through comments to check for mapping_value ':'.
        // Don't consume comments yet, parseMappingValue will handle them.
        if (self.peekThroughComments(.mapping_value)) {
            const pre_comment = try self.collectComments();
            const mv_node = try self.parseMappingValue(
                key_node,
                key_col,
                key_indent,
                false,
                pre_comment,
                min_indent,
            );

            // Check for sibling key-value pairs at the same column.
            self.skipComments();
            if (!in_flow and self.pos < self.tokens.len) {
                const next = self.current();
                if (self.isKeyToken(next.token_type) and
                    next.position.column == key_col and
                    key_col >= min_indent)
                {
                    if (self.peekForMappingValue(next.position.column)) {
                        const mv = mv_node.*.mapping_value;
                        return try self.parseMappingWithFirst(
                            key_node,
                            mv.value.?,
                            key_col,
                            min_indent,
                            mv.node_comment,
                        );
                    }
                }
            }
            return mv_node;
        }

        // Don't skip comments here, leave them for the caller to collect
        // as inline comments on the mapping value node.

        // Check past any comments for error conditions.
        // Only check when the scalar is at a "top-level" position (column matches indent).
        const check_pos = self.skipCommentsPos();
        if (check_pos < self.tokens.len and key_col == key_indent) {
            const next_tok = self.tokens[check_pos];
            const next_indent = next_tok.position.indent_num;
            if (next_tok.token_type == .sequence_entry and next_indent > key_indent) {
                self.pos = check_pos;
                return self.syntaxError("unexpected sequence after scalar");
            }
            if (self.isScalarToken(next_tok.token_type) and next_indent > key_indent) {
                if (self.lookAheadMappingValueFrom(check_pos)) {
                    self.pos = check_pos;
                    return self.syntaxError("unexpected mapping after scalar");
                }
            }
        }

        return key_node;
    }

    fn skipCommentsPos(self: *const Parser) usize {
        var i = self.pos;
        while (i < self.tokens.len and self.tokens[i].token_type == .comment) {
            i += 1;
        }
        return i;
    }

    fn peekThroughComments(self: *const Parser, expected: TokenType) bool {
        var i = self.pos;
        while (i < self.tokens.len and self.tokens[i].token_type == .comment) {
            i += 1;
        }
        return i < self.tokens.len and self.tokens[i].token_type == expected;
    }

    fn lookAheadMappingValue(self: *const Parser) bool {
        return self.lookAheadMappingValueFrom(self.pos);
    }

    fn lookAheadMappingValueFrom(self: *const Parser, from: usize) bool {
        var i = from;
        while (i < self.tokens.len) {
            const tt = self.tokens[i].token_type;
            if (tt == .mapping_value) return true;
            if (tt == .comment) {
                i += 1;
                continue;
            }
            break;
        }
        return false;
    }

    fn parseMappingValue(
        self: *Parser,
        key_node: *Node,
        key_col: u32,
        key_indent: u32,
        in_flow: bool,
        pre_comment: ?*const ast.CommentGroupNode,
        min_indent: u32,
    ) ParseErr!*Node {
        // Save colon position for validation.
        const colon_line = self.current().position.line;
        // Consume the ':'
        self.advance();

        // Collect inline comment after ':'.
        var inline_comment = try self.collectInlineComment();

        self.skipComments();

        // Parse the value.
        var value_node: ?*Node = null;
        if (self.pos < self.tokens.len) {
            const val_tok = self.current();
            const val_tt = val_tok.token_type;
            if (in_flow) {
                if (val_tt != .mapping_end and val_tt != .collect_entry and
                    val_tt != .sequence_end)
                {
                    value_node = try self.parseNode(0, true);
                }
            } else if (val_tt == .sequence_entry) {
                const seq_indent = val_tok.position.indent_num;
                // Sequence entry on same line as ':' is a syntax error,
                // e.g., "a: -" or "a: - 1".
                if (val_tok.position.line == colon_line) {
                    return self.syntaxError("unexpected sequence entry after ':'");
                }
                if (seq_indent <= key_indent and seq_indent >= min_indent) {
                    value_node = try self.parseBlockSequence(min_indent);
                } else if (seq_indent > key_indent) {
                    value_node = try self.parseBlockSequence(key_col + 1);
                }
            } else if (val_tt == .literal or val_tt == .folded) {
                value_node = try self.parseBlockScalar();
            } else if (val_tt == .mapping_start) {
                value_node = try self.parseFlowMapping();
            } else if (val_tt == .sequence_start) {
                value_node = try self.parseFlowSequence();
            } else if (val_tt == .anchor) {
                value_node = try self.parseAnchor(key_col + 1, false);
            } else if (val_tt == .alias) {
                value_node = try self.parseAlias();
            } else if (val_tt == .tag) {
                value_node = try self.parseTag(key_col + 1, false);
            } else if (val_tt == .merge_key) {
                value_node = try self.parseMergeKeyValue(key_col + 1, false);
            } else if (self.isScalarToken(val_tt)) {
                const val_indent = val_tok.position.indent_num;
                if (val_indent > key_indent or val_indent > key_col or
                    val_tok.position.line == self.tokens[self.pos -| 1].position.line)
                {
                    value_node = try self.parseScalarOrMapping(key_col + 1, false);
                }
            } else if (val_tt == .document_header or val_tt == .document_end) {
                // Empty value.
            } else if (val_tt == .mapping_key) {
                value_node = try self.parseExplicitKey(key_col + 1, false);
            }
        }

        if (value_node == null) {
            value_node = try self.createNode(Node{ .null_value = .{} });
        }

        // Collect post-value inline comment.
        const post_comment = try self.collectInlineComment();
        inline_comment = try self.mergeComments(inline_comment, post_comment);

        // If the value is a mapping_value with a flow collection value and a comment,
        // propagate the comment up (for cases like "b: {} # comment").
        if (value_node != null and inline_comment == null) {
            switch (value_node.?.*) {
                .mapping_value => |*mv| {
                    if (mv.node_comment != null and mv.value != null) {
                        const val_type: ast.NodeType = mv.value.?.*;
                        if (val_type == .mapping or val_type == .sequence) {
                            const inner_val = switch (mv.value.?.*) {
                                .mapping => |m| m.is_flow,
                                .sequence => |s| s.is_flow,
                                else => false,
                            };
                            if (inner_val) {
                                inline_comment = mv.node_comment;
                                mv.node_comment = null;
                            }
                        }
                    }
                },
                else => {},
            }
        }

        const mv_comment = try self.mergeComments(pre_comment, inline_comment);
        const mv = try self.createNode(Node{ .mapping_value = .{
            .token = key_node.getToken(),
            .key = key_node,
            .value = value_node,
            .node_comment = mv_comment,
        } });
        return mv;
    }

    fn peekForMappingValue(self: *const Parser, col: u32) bool {
        var i = self.pos;
        while (i < self.tokens.len) {
            const tt = self.tokens[i].token_type;
            if (tt == .mapping_value) return true;
            if (tt == .comment) {
                i += 1;
                continue;
            }
            if (self.isScalarToken(tt) and self.tokens[i].position.column == col) {
                i += 1;
                continue;
            }
            if ((tt == .anchor or tt == .alias or tt == .tag or tt == .merge_key) and
                self.tokens[i].position.column == col)
            {
                i += 1;
                continue;
            }
            break;
        }
        return false;
    }

    fn parseMappingWithFirst(
        self: *Parser,
        first_key: *const Node,
        first_value: *const Node,
        indent: u32,
        min_indent: u32,
        first_comment: ?*const ast.CommentGroupNode,
    ) ParseErr!*Node {
        var entries = std.ArrayListUnmanaged(*const ast.MappingValueNode){};
        var key_set = std.StringHashMap(void).init(self.allocator);

        // Add first entry and check for dup.
        const first_key_str = self.nodeKeyString(first_key);
        if (first_key_str) |ks| {
            try key_set.put(ks, {});
        }

        const first_mv_node = try self.createNode(Node{ .mapping_value = .{
            .token = first_key.getToken(),
            .key = first_key,
            .value = first_value,
            .node_comment = first_comment,
        } });
        try entries.append(self.allocator, &first_mv_node.mapping_value);

        // Parse remaining entries at the same indent.
        while (self.pos < self.tokens.len) {
            self.skipComments();
            if (self.pos >= self.tokens.len) break;

            const tok = self.current();
            if (tok.token_type == .document_end or tok.token_type == .document_header)
                break;

            const tok_col = tok.position.column;
            if (tok_col < indent) break;
            if (tok_col != indent) break;

            // Must be a key token.
            if (!self.isScalarToken(tok.token_type) and
                tok.token_type != .merge_key and
                tok.token_type != .mapping_key and
                tok.token_type != .anchor and
                tok.token_type != .alias and
                tok.token_type != .tag)
            {
                break;
            }

            // Must have a mapping value ahead.
            if (!self.peekForMappingValue(indent)) {
                // Could be a bare string at the same indent that's NOT a key.
                // This is an error: e.g., "a: 1\nb".
                if (self.isScalarToken(tok.token_type)) {
                    return self.syntaxError("expected mapping value");
                }
                break;
            }

            const entry_comment = try self.collectComments();
            if (self.pos >= self.tokens.len) break;

            const entry = try self.parseMappingEntry(min_indent) orelse break;

            const ks = self.nodeKeyString(entry.key);
            if (ks) |k| {
                if (key_set.get(k) != null) {
                    return self.duplicateKeyError("duplicate key");
                }
                try key_set.put(k, {});
            }
            if (entry_comment != null and entry.node_comment == null) {
                @constCast(entry).node_comment = entry_comment;
            } else if (entry_comment != null) {
                @constCast(entry).node_comment = try self.mergeComments(
                    entry_comment,
                    entry.node_comment,
                );
            }
            try entries.append(self.allocator, entry);
        }

        const mapping = try self.createNode(Node{ .mapping = .{
            .values = try self.dupeSlice(*const ast.MappingValueNode, entries.items),
        } });
        return mapping;
    }

    fn parseMappingEntry(self: *Parser, min_indent: u32) ParseErr!?*const ast.MappingValueNode {
        const col = self.currentColumn();
        const ind = self.currentIndent();
        const tt = self.current().token_type;

        var node: ?*Node = null;
        if (tt == .merge_key) {
            node = try self.parseMergeKeyEntry(min_indent);
        } else if (tt == .mapping_key) {
            node = try self.parseExplicitKey(min_indent, false);
        } else if (tt == .anchor) {
            const anchor = try self.parseAnchor(min_indent, false);
            if (self.pos < self.tokens.len and
                self.tokens[self.pos].token_type == .mapping_value)
            {
                node = try self.parseMappingValue(
                    anchor,
                    col,
                    ind,
                    false,
                    null,
                    min_indent,
                );
            } else {
                node = anchor;
            }
        } else if (tt == .alias) {
            const alias = try self.parseAlias();
            if (self.pos < self.tokens.len and
                self.tokens[self.pos].token_type == .mapping_value)
            {
                node = try self.parseMappingValue(
                    alias,
                    col,
                    ind,
                    false,
                    null,
                    min_indent,
                );
            } else {
                node = alias;
            }
        } else if (tt == .tag) {
            node = try self.parseTag(min_indent, false);
        } else {
            const key = try self.parseScalarValue();
            self.skipComments();
            if (self.pos < self.tokens.len and
                self.tokens[self.pos].token_type == .mapping_value)
            {
                node = try self.parseMappingValue(
                    key,
                    col,
                    ind,
                    false,
                    null,
                    min_indent,
                );
            } else {
                return null;
            }
        }

        if (node == null) return null;
        return switch (node.?.*) {
            .mapping_value => |*mv| mv,
            else => null,
        };
    }

    fn nodeKeyString(self: *const Parser, node: ?*const Node) ?[]const u8 {
        _ = self;
        if (node == null) return null;
        return switch (node.?.*) {
            .string => |s| s.value,
            .integer => |i| blk: {
                _ = i;
                if (node.?.getToken()) |t| break :blk t.value;
                break :blk null;
            },
            .boolean => |b| if (b.value) "true" else "false",
            .null_value => "null",
            .merge_key => "<<",
            else => null,
        };
    }

    fn parseBlockSequence(self: *Parser, min_indent: u32) ParseErr!?*Node {
        _ = min_indent;
        if (self.pos >= self.tokens.len or
            self.tokens[self.pos].token_type != .sequence_entry)
            return null;

        const seq_col = self.tokens[self.pos].position.column;
        var items = std.ArrayListUnmanaged(*const Node){};

        while (self.pos < self.tokens.len) {
            self.skipComments();
            if (self.pos >= self.tokens.len) break;

            const tok = self.current();
            if (tok.token_type != .sequence_entry) break;
            if (tok.position.column != seq_col) break;
            if (tok.token_type == .document_end or
                tok.token_type == .document_header)
                break;

            self.advance(); // Consume '-'.

            // Skip comments after '-'.
            _ = try self.collectInlineComment();
            self.skipComments();

            // Parse entry value.
            if (self.pos < self.tokens.len) {
                const next = self.current();
                if (next.token_type == .sequence_entry and
                    next.position.column > seq_col)
                {
                    // Nested sequence.
                    const nested = try self.parseBlockSequence(seq_col + 1);
                    if (nested) |n| try items.append(self.allocator, n);
                } else if (next.token_type == .document_end or
                    next.token_type == .document_header)
                {
                    const null_node = try self.createNode(Node{ .null_value = .{} });
                    try items.append(self.allocator, null_node);
                } else if (next.token_type == .sequence_entry and
                    next.position.column == seq_col)
                {
                    const null_node = try self.createNode(Node{ .null_value = .{} });
                    try items.append(self.allocator, null_node);
                } else {
                    const entry = try self.parseNode(seq_col + 1, false);
                    if (entry) |e| {
                        try items.append(self.allocator, e);
                    } else {
                        const null_node = try self.createNode(Node{ .null_value = .{} });
                        try items.append(self.allocator, null_node);
                    }
                }
            } else {
                // EOF after '-'.
                const null_node = try self.createNode(Node{ .null_value = .{} });
                try items.append(self.allocator, null_node);
            }
        }

        const seq = try self.createNode(Node{ .sequence = .{
            .values = try self.dupeSlice(*const Node, items.items),
        } });
        return seq;
    }

    fn parseFlowMapping(self: *Parser) ParseErr!*Node {
        self.advance(); // Consume '{'.
        var entries = std.ArrayListUnmanaged(*const ast.MappingValueNode){};

        while (self.pos < self.tokens.len) {
            self.skipComments();
            if (self.pos >= self.tokens.len) {
                return self.syntaxError("unclosed flow mapping");
            }

            const tok = self.current();
            if (tok.token_type == .mapping_end) {
                self.advance();
                break;
            }

            if (tok.token_type == .collect_entry) {
                self.advance();
                continue;
            }

            // Parse key.
            var key_node: ?*Node = null;
            if (tok.token_type == .mapping_key) {
                self.advance(); // Consume '?'.
                self.skipComments();
                if (self.pos < self.tokens.len and
                    self.tokens[self.pos].token_type != .mapping_value and
                    self.tokens[self.pos].token_type != .mapping_end and
                    self.tokens[self.pos].token_type != .collect_entry)
                {
                    key_node = try self.parseNode(0, true);
                }
            } else if (self.isScalarToken(tok.token_type) or
                tok.token_type == .anchor or
                tok.token_type == .alias or
                tok.token_type == .tag or
                tok.token_type == .merge_key or
                tok.token_type == .null_value)
            {
                key_node = try self.parseNode(0, true);
            } else if (tok.token_type == .mapping_start or
                tok.token_type == .sequence_start)
            {
                return self.syntaxError("flow collection as key");
            } else {
                return self.syntaxError("unexpected token in flow mapping");
            }

            self.skipComments();

            // Check for ':'.
            if (self.pos < self.tokens.len and
                self.tokens[self.pos].token_type == .mapping_value)
            {
                self.advance(); // Consume ':'.
                self.skipComments();

                // Parse value.
                var value_node: ?*Node = null;
                if (self.pos < self.tokens.len) {
                    const vt = self.tokens[self.pos].token_type;
                    if (vt != .mapping_end and vt != .collect_entry) {
                        value_node = try self.parseNode(0, true);
                    }
                }
                if (value_node == null) {
                    value_node = try self.createNode(Node{ .null_value = .{} });
                }

                const mv = try self.createNode(Node{ .mapping_value = .{
                    .key = key_node,
                    .value = value_node,
                } });
                try entries.append(self.allocator, &mv.mapping_value);
            } else {
                // Bare key (no value).
                const null_val = try self.createNode(Node{ .null_value = .{} });
                const mv = try self.createNode(Node{ .mapping_value = .{
                    .key = key_node,
                    .value = null_val,
                } });
                try entries.append(self.allocator, &mv.mapping_value);
            }
        } else {
            return self.syntaxError("unclosed flow mapping");
        }

        // Check if this flow mapping is used as a key (followed by ':').
        if (self.pos < self.tokens.len and
            self.tokens[self.pos].token_type == .mapping_value)
        {
            return self.syntaxError("flow mapping as key");
        }

        const mapping = try self.createNode(Node{ .mapping = .{
            .values = try self.dupeSlice(*const ast.MappingValueNode, entries.items),
            .is_flow = true,
        } });
        return mapping;
    }

    fn parseFlowSequence(self: *Parser) ParseErr!*Node {
        self.advance(); // Consume '['.
        var items = std.ArrayListUnmanaged(*const Node){};

        while (self.pos < self.tokens.len) {
            self.skipComments();
            if (self.pos >= self.tokens.len) {
                return self.syntaxError("unclosed flow sequence");
            }

            const tok = self.current();
            if (tok.token_type == .sequence_end) {
                self.advance();
                break;
            }

            if (tok.token_type == .collect_entry) {
                self.advance();
                continue;
            }

            const item = try self.parseNode(0, true);
            if (item) |node| {
                // Check if this scalar is followed by ':' (inline mapping).
                self.skipComments();
                if (self.pos < self.tokens.len and
                    self.tokens[self.pos].token_type == .mapping_value and
                    node.* != .mapping_value)
                {
                    // This is an inline mapping entry in a flow sequence.
                    self.advance(); // Consume ':'.
                    self.skipComments();
                    var val: ?*Node = null;
                    if (self.pos < self.tokens.len) {
                        const vt = self.tokens[self.pos].token_type;
                        if (vt != .sequence_end and
                            vt != .collect_entry)
                        {
                            val = try self.parseNode(0, true);
                        }
                    }
                    if (val == null) {
                        val = try self.createNode(
                            Node{ .null_value = .{} },
                        );
                    }
                    const mv = try self.createNode(Node{
                        .mapping_value = .{
                            .key = node,
                            .value = val,
                        },
                    });
                    try items.append(self.allocator, mv);
                } else {
                    try items.append(self.allocator, node);
                }
                // After appending, expect comma or close bracket.
                self.skipComments();
                if (self.pos < self.tokens.len) {
                    const nt = self.tokens[self.pos].token_type;
                    if (nt != .sequence_end and nt != .collect_entry) {
                        return self.syntaxError("expected ',' or ']' in flow sequence");
                    }
                }
            } else {
                break;
            }
        } else {
            return self.syntaxError("unclosed flow sequence");
        }

        // Check if flow seq used as key.
        if (self.pos < self.tokens.len and
            self.tokens[self.pos].token_type == .mapping_value)
        {
            return self.syntaxError("flow sequence as key");
        }

        const seq = try self.createNode(Node{ .sequence = .{
            .values = try self.dupeSlice(*const Node, items.items),
            .is_flow = true,
        } });
        return seq;
    }

    fn parseScalarValue(self: *Parser) ParseErr!*Node {
        const tok = self.current();
        self.advance();
        return switch (tok.token_type) {
            .string => try self.createNode(Node{ .string = .{
                .token = &self.tokens[self.pos - 1],
                .value = tok.value,
            } }),
            .single_quote, .double_quote => try self.createNode(Node{ .string = .{
                .token = &self.tokens[self.pos - 1],
                .value = tok.value,
            } }),
            .integer => blk: {
                // If the integer token ends with '_', it's not a valid YAML integer;
                // treat it as a plain string instead.
                if (tok.value.len > 0 and tok.value[tok.value.len - 1] == '_') {
                    break :blk try self.createNode(Node{ .string = .{
                        .token = &self.tokens[self.pos - 1],
                        .value = tok.value,
                    } });
                }
                break :blk try self.createNode(Node{ .integer = .{
                    .token = &self.tokens[self.pos - 1],
                    .value = self.parseIntegerValue(tok.value),
                } });
            },
            .float => try self.createNode(Node{ .float_value = .{
                .token = &self.tokens[self.pos - 1],
                .value = self.parseFloatValue(tok.value),
                .precision = self.computePrecision(tok.value),
            } }),
            .bool_value => try self.createNode(Node{ .boolean = .{
                .token = &self.tokens[self.pos - 1],
                .value = std.mem.eql(u8, tok.value, "true") or
                    std.mem.eql(u8, tok.value, "True") or
                    std.mem.eql(u8, tok.value, "TRUE"),
            } }),
            .null_value => try self.createNode(Node{ .null_value = .{
                .token = &self.tokens[self.pos - 1],
            } }),
            .infinity => try self.createNode(Node{ .infinity = .{
                .token = &self.tokens[self.pos - 1],
                .negative = tok.value.len > 0 and tok.value[0] == '-',
            } }),
            .nan => try self.createNode(Node{ .nan = .{
                .token = &self.tokens[self.pos - 1],
            } }),
            else => try self.createNode(Node{ .string = .{
                .token = &self.tokens[self.pos - 1],
                .value = tok.value,
            } }),
        };
    }

    fn parseIntegerValue(self: *const Parser, val: []const u8) i64 {
        _ = self;
        const num = toNumber(val) orelse return 0;
        return switch (num) {
            .int => |i| i,
            .float => |f| @intFromFloat(f),
        };
    }

    fn parseFloatValue(self: *const Parser, val: []const u8) f64 {
        _ = self;
        const num = toNumber(val) orelse return 0;
        return switch (num) {
            .float => |f| f,
            .int => |i| @floatFromInt(i),
        };
    }

    fn computePrecision(self: *const Parser, val: []const u8) u8 {
        _ = self;
        var prec: u8 = 0;
        var after_dot = false;
        for (val) |c| {
            if (c == '.') {
                after_dot = true;
            } else if (after_dot) {
                if (c == 'e' or c == 'E') break;
                if (c != '_') prec += 1;
            }
        }
        return prec;
    }

    fn parseBlockScalar(self: *Parser) ParseErr!*Node {
        const header_tok = self.current();
        const header = header_tok.value;
        const is_literal = header_tok.token_type == .literal;

        // Parse header for chomping and indent.
        var chomping: ast.ChompingStyle = .clip;
        var valid = true;
        for (header[1..]) |c| {
            if (c == '-') {
                chomping = .strip;
            } else if (c == '+') {
                chomping = .keep;
            } else if (c >= '1' and c <= '9') {
                // Explicit indent indicator - accepted.
            } else {
                valid = false;
                break;
            }
        }

        if (!valid) {
            return self.syntaxError("invalid block scalar option");
        }

        self.advance(); // Consume literal/folded token.

        // Skip comment after header.
        self.skipComments();

        // Get content string token (if present). The scanner produces the
        // content string with the same line as the header. A regular string
        // on the next line is not block scalar content.
        var content: []const u8 = "";
        if (self.pos < self.tokens.len and
            self.tokens[self.pos].token_type == .string and
            self.tokens[self.pos].position.line == header_tok.position.line)
        {
            content = self.tokens[self.pos].value;
            self.advance();
        }

        // Validate: block scalar at root level followed by another block scalar is an error,
        // e.g., ">\n>" or "|\n|"
        if (content.len == 0 and self.pos < self.tokens.len) {
            const next = self.current();
            if (next.position.indent_num == 0 and
                (next.token_type == .literal or next.token_type == .folded))
            {
                return self.syntaxError("unexpected content after block scalar");
            }
        }

        const style: ast.BlockScalarStyle = if (is_literal) .literal else .folded;

        const node = try self.createNode(Node{ .literal = .{
            .token = &self.tokens[self.pos - 1],
            .value = content,
            .block_style = style,
            .chomping = chomping,
        } });
        return node;
    }

    fn parseAnchor(self: *Parser, min_indent: u32, in_flow: bool) ParseErr!*Node {
        const tok = self.current();
        const name = tok.origin; // Anchor name stored in origin by scanner.
        self.advance();

        self.skipComments();

        const anchor_line = tok.position.line;
        var value_node: ?*Node = null;
        if (self.pos < self.tokens.len) {
            const next = self.current();
            if (next.token_type == .mapping_start) {
                value_node = try self.parseFlowMapping();
            } else if (next.token_type == .sequence_start) {
                value_node = try self.parseFlowSequence();
            } else if (self.isScalarToken(next.token_type)) {
                // Only parse as anchor value if on same line or in flow.
                if (in_flow or next.position.line == anchor_line) {
                    value_node = try self.parseScalarOrMapping(min_indent, in_flow);
                }
            } else if (next.token_type == .literal or next.token_type == .folded) {
                value_node = try self.parseBlockScalar();
            } else if (next.token_type == .sequence_entry) {
                // Anchor on sequence.
            } else if (next.token_type == .mapping_value) {
                // Anchor without value (key: &anchor).
            }
        }

        // Check for mapping value after anchor's value,
        // e.g., "- &anchor\n  key: val" where the anchor wraps a mapping.
        if (value_node == null and !in_flow and self.pos < self.tokens.len) {
            const next = self.current();
            // Only parse if on a deeper indent.
            if ((self.isScalarToken(next.token_type) or
                next.token_type == .mapping_key) and
                next.position.column >= min_indent)
            {
                value_node = try self.parseNode(min_indent, false);
            }
        }

        const node = try self.createNode(Node{ .anchor = .{
            .token = &self.tokens[self.pos - 1],
            .name = name,
            .value = value_node,
        } });
        return node;
    }

    fn parseAlias(self: *Parser) ParseErr!*Node {
        const tok = self.current();
        const name = tok.origin; // Alias name stored in origin by scanner.
        self.advance();
        const node = try self.createNode(Node{ .alias = .{
            .token = &self.tokens[self.pos - 1],
            .name = name,
        } });
        return node;
    }

    // Parse a scalar value after a tag, re-classifying string tokens that
    // the scanner forced to .string (because they follow a tag).
    fn parseTagScalarValue(self: *Parser, min_indent: u32, in_flow: bool) ParseErr!?*Node {
        // If the token is a .string that the scanner forced (after tag),
        // try to re-parse it as its natural type.
        if (self.pos < self.tokens.len and
            self.tokens[self.pos].token_type == .string)
        {
            const tok = self.current();
            const val = tok.value;
            if (toNumber(val)) |num| {
                self.advance();
                return switch (num) {
                    .int => |i| try self.createNode(Node{ .integer = .{
                        .token = &self.tokens[self.pos - 1],
                        .value = i,
                    } }),
                    .float => |f| try self.createNode(Node{ .float_value = .{
                        .token = &self.tokens[self.pos - 1],
                        .value = f,
                        .precision = self.computePrecision(val),
                    } }),
                };
            }
        }
        return try self.parseScalarOrMapping(min_indent, in_flow);
    }

    fn parseTag(self: *Parser, min_indent: u32, in_flow: bool) ParseErr!*Node {
        const tok = self.current();
        const tag_str = tok.value;
        self.advance();

        self.skipComments();

        var value_node: ?*Node = null;
        if (self.pos < self.tokens.len) {
            const next = self.current();
            if (next.token_type == .mapping_start) {
                value_node = try self.parseFlowMapping();
            } else if (next.token_type == .sequence_start) {
                value_node = try self.parseFlowSequence();
            } else if (next.token_type == .literal or next.token_type == .folded) {
                value_node = try self.parseBlockScalar();
            } else if (self.isScalarToken(next.token_type)) {
                value_node = try self.parseTagScalarValue(min_indent, in_flow);
            } else if (next.token_type == .sequence_entry) {
                value_node = try self.parseBlockSequence(min_indent);
            } else if (next.token_type == .anchor) {
                value_node = try self.parseAnchor(min_indent, in_flow);
            } else if (next.token_type == .mapping_key) {
                value_node = try self.parseExplicitKey(min_indent, in_flow);
            }
        }

        const node = try self.createNode(Node{ .tag = .{
            .token = &self.tokens[self.pos -| 1],
            .tag = tag_str,
            .value = value_node,
        } });
        return node;
    }

    fn parseExplicitKey(self: *Parser, min_indent: u32, in_flow: bool) ParseErr!*Node {
        self.advance(); // Consume '?'.
        self.skipComments();

        var key_node: ?*Node = null;
        if (self.pos < self.tokens.len and
            self.tokens[self.pos].token_type != .mapping_value)
        {
            key_node = try self.parseNode(min_indent, in_flow);
        }

        self.skipComments();

        // Expect ':'.
        if (self.pos < self.tokens.len and
            self.tokens[self.pos].token_type == .mapping_value)
        {
            self.advance();
            self.skipComments();
        }

        var value_node: ?*Node = null;
        if (self.pos < self.tokens.len) {
            const vt = self.tokens[self.pos].token_type;
            if (in_flow) {
                if (vt != .mapping_end and vt != .collect_entry and
                    vt != .sequence_end)
                {
                    value_node = try self.parseNode(min_indent, in_flow);
                }
            } else {
                if (vt != .document_end and vt != .document_header) {
                    value_node = try self.parseNode(min_indent, in_flow);
                }
            }
        }

        const mv = try self.createNode(Node{ .mapping_value = .{
            .key = key_node,
            .value = value_node,
        } });
        return mv;
    }

    fn parseMergeKeyValue(self: *Parser, min_indent: u32, in_flow: bool) ParseErr!*Node {
        const mk_col = self.currentColumn();
        const mk_indent = self.currentIndent();
        const mk_node = try self.createNode(Node{ .merge_key = .{
            .token = &self.tokens[self.pos],
        } });
        self.advance();

        self.skipComments();

        // Merge key followed by ':'.
        if (self.pos < self.tokens.len and
            self.tokens[self.pos].token_type == .mapping_value)
        {
            const mv = try self.parseMappingValue(
                mk_node,
                mk_col,
                mk_indent,
                in_flow,
                null,
                min_indent,
            );
            // Check for siblings at same column (e.g., <<: *a\nbar: 2).
            self.skipComments();
            if (!in_flow and self.pos < self.tokens.len) {
                const next = self.current();
                if (self.isKeyToken(next.token_type) and
                    next.position.column == mk_col and
                    mk_col >= min_indent)
                {
                    if (self.peekForMappingValue(next.position.column)) {
                        const mvv = mv.*.mapping_value;
                        return try self.parseMappingWithFirst(
                            mk_node,
                            mvv.value.?,
                            mk_col,
                            min_indent,
                            mvv.node_comment,
                        );
                    }
                }
            }
            return mv;
        }

        return mk_node;
    }

    fn parseMergeKeyEntry(self: *Parser, min_indent: u32) ParseErr!?*Node {
        const mk_col = self.currentColumn();
        const mk_indent = self.currentIndent();
        const mk_node = try self.createNode(Node{ .merge_key = .{
            .token = &self.tokens[self.pos],
        } });
        self.advance();
        self.skipComments();
        if (self.pos < self.tokens.len and
            self.tokens[self.pos].token_type == .mapping_value)
        {
            return try self.parseMappingValue(
                mk_node,
                mk_col,
                mk_indent,
                false,
                null,
                min_indent,
            );
        }
        return mk_node;
    }
};

fn testParse(source: []const u8) !yaml.Document {
    return yaml.parse(testing.allocator, source);
}

fn expectString(node: *const Node, expected: []const u8) !void {
    switch (node.*) {
        .string => |s| try testing.expectEqualStrings(
            expected,
            s.value,
        ),
        else => return error.TestUnexpectedResult,
    }
}

fn expectInteger(node: *const Node, expected: i64) !void {
    switch (node.*) {
        .integer => |i| try testing.expectEqual(expected, i.value),
        else => return error.TestUnexpectedResult,
    }
}

fn expectFloat(node: *const Node, expected: f64) !void {
    switch (node.*) {
        .float_value => |f| try testing.expectEqual(
            expected,
            f.value,
        ),
        else => return error.TestUnexpectedResult,
    }
}

fn expectBool(node: *const Node, expected: bool) !void {
    switch (node.*) {
        .boolean => |b| try testing.expectEqual(expected, b.value),
        else => return error.TestUnexpectedResult,
    }
}

fn expectNull(node: *const Node) !void {
    switch (node.*) {
        .null_value => {},
        else => return error.TestUnexpectedResult,
    }
}

fn expectNodeType(
    node: *const Node,
    expected: ast.NodeType,
) !void {
    try testing.expectEqual(expected, @as(ast.NodeType, node.*));
}

fn expectMapping(node: *const Node) !ast.MappingNode {
    return switch (node.*) {
        .mapping => |m| m,
        else => return error.TestUnexpectedResult,
    };
}

fn expectMappingValue(node: *const Node) !ast.MappingValueNode {
    return switch (node.*) {
        .mapping_value => |mv| mv,
        else => return error.TestUnexpectedResult,
    };
}

fn expectSequence(node: *const Node) !ast.SequenceNode {
    return switch (node.*) {
        .sequence => |s| s,
        else => return error.TestUnexpectedResult,
    };
}

fn expectAnchor(node: *const Node) !ast.AnchorNode {
    return switch (node.*) {
        .anchor => |a| a,
        else => return error.TestUnexpectedResult,
    };
}

fn expectAlias(node: *const Node) !ast.AliasNode {
    return switch (node.*) {
        .alias => |a| a,
        else => return error.TestUnexpectedResult,
    };
}

fn expectTag(node: *const Node) !ast.TagNode {
    return switch (node.*) {
        .tag => |t| t,
        else => return error.TestUnexpectedResult,
    };
}

fn expectLiteral(node: *const Node) !ast.LiteralNode {
    return switch (node.*) {
        .literal => |l| l,
        else => return error.TestUnexpectedResult,
    };
}

fn expectInfinity(node: *const Node) !ast.InfinityNode {
    return switch (node.*) {
        .infinity => |i| i,
        else => return error.TestUnexpectedResult,
    };
}

test "parse empty string" {
    var doc = try testParse("");
    defer doc.deinit();
    try testing.expect(doc.body == null);
}

test "parse null" {
    var doc = try testParse("null\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    try expectNull(body);
}

test "parse 0_" {
    var doc = try testParse("0_");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    try expectString(body, "0_");
}

test "parse empty flow mapping" {
    var doc = try testParse("{}\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expect(m.is_flow);
    try testing.expectEqual(@as(usize, 0), m.values.len);
}

test "parse integer scalar" {
    var doc = try testParse("123\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    try expectInteger(body, 123);
}

test "parse float scalar" {
    var doc = try testParse("3.14\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    try expectFloat(body, 3.14);
}

test "parse string scalar" {
    var doc = try testParse("hello\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    try expectString(body, "hello");
}

test "parse true" {
    var doc = try testParse("true\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    try expectBool(body, true);
}

test "parse false" {
    var doc = try testParse("false\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    try expectBool(body, false);
}

test "parse infinity" {
    var doc = try testParse(".inf\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const inf = try expectInfinity(body);
    try testing.expect(!inf.negative);
    try expectNodeType(body, .infinity);
}

test "parse nan" {
    var doc = try testParse(".nan\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    try expectNodeType(body, .nan);
}

test "parse v hi" {
    var doc = try testParse("v: hi\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    try expectString(mv.value.?, "hi");
}

test "parse v quoted true" {
    var doc = try testParse("v: \"true\"\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    try expectString(mv.value.?, "true");
}

test "parse v quoted false" {
    var doc = try testParse("v: \"false\"\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    try expectString(mv.value.?, "false");
}

test "parse v true" {
    var doc = try testParse("v: true\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    try expectBool(mv.value.?, true);
}

test "parse v false" {
    var doc = try testParse("v: false\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    try expectBool(mv.value.?, false);
}

test "parse v 10" {
    var doc = try testParse("v: 10\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    try expectInteger(mv.value.?, 10);
}

test "parse v -10" {
    var doc = try testParse("v: -10\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    try expectInteger(mv.value.?, -10);
}

test "parse v 42" {
    var doc = try testParse("v: 42\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    try expectInteger(mv.value.?, 42);
}

test "parse v 4294967296" {
    var doc = try testParse("v: 4294967296\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    try expectInteger(mv.value.?, 4294967296);
}

test "parse v quoted 10" {
    var doc = try testParse("v: \"10\"\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    try expectString(mv.value.?, "10");
}

test "parse v 0.1" {
    var doc = try testParse("v: 0.1\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    try expectFloat(mv.value.?, 0.1);
}

test "parse v 0.99" {
    var doc = try testParse("v: 0.99\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    try expectFloat(mv.value.?, 0.99);
}

test "parse v -0.1" {
    var doc = try testParse("v: -0.1\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    try expectFloat(mv.value.?, -0.1);
}

test "parse v .inf" {
    var doc = try testParse("v: .inf\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    const inf = try expectInfinity(mv.value.?);
    try testing.expect(!inf.negative);
}

test "parse v -.inf" {
    var doc = try testParse("v: -.inf\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    const inf = try expectInfinity(mv.value.?);
    try testing.expect(inf.negative);
}

test "parse v .nan" {
    var doc = try testParse("v: .nan\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    try expectNodeType(mv.value.?, .nan);
}

test "parse v null" {
    var doc = try testParse("v: null\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    try expectNull(mv.value.?);
}

test "parse v empty string" {
    var doc = try testParse("v: \"\"\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    try expectString(mv.value.?, "");
}

test "parse block sequence A B" {
    const input =
        \\v:
        \\- A
        \\- B
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    const seq = try expectSequence(mv.value.?);
    try testing.expectEqual(@as(usize, 2), seq.values.len);
    try expectString(seq.values[0], "A");
    try expectString(seq.values[1], "B");
}

test "parse single quoted dash" {
    var doc = try testParse("a: '-'\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    try expectString(mv.value.?, "-");
}

test "parse bare integer" {
    var doc = try testParse("123\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    try expectInteger(body, 123);
}

test "parse hello world" {
    var doc = try testParse("hello: world\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "hello");
    try expectString(mv.value.?, "world");
}

test "parse a null" {
    var doc = try testParse("a: null\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    try expectNull(mv.value.?);
}

test "parse nested sequence in map" {
    const input =
        \\v:
        \\- A
        \\- 1
        \\- B:
        \\  - 2
        \\  - 3
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    const seq = try expectSequence(mv.value.?);
    try testing.expectEqual(@as(usize, 3), seq.values.len);
    try expectString(seq.values[0], "A");
    try expectInteger(seq.values[1], 1);
    const inner_mv = try expectMappingValue(seq.values[2]);
    try expectString(inner_mv.key.?, "B");
    const inner_seq = try expectSequence(inner_mv.value.?);
    try testing.expectEqual(@as(usize, 2), inner_seq.values.len);
    try expectInteger(inner_seq.values[0], 2);
    try expectInteger(inner_seq.values[1], 3);
}

test "parse nested map a b c" {
    const input =
        \\a:
        \\  b: c
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const inner = try expectMappingValue(mv.value.?);
    try expectString(inner.key.?, "b");
    try expectString(inner.value.?, "c");
}

test "parse flow mapping a x 1" {
    var doc = try testParse("a: {x: 1}\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const m = try expectMapping(mv.value.?);
    try testing.expect(m.is_flow);
    try testing.expectEqual(@as(usize, 1), m.values.len);
    try expectString(m.values[0].key.?, "x");
    try expectInteger(m.values[0].value.?, 1);
}

test "parse timestamps" {
    const input =
        \\t2: 2018-01-09T10:40:47Z
        \\t4: 2098-01-09T10:40:47Z
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "t2");
    try expectString(m.values[0].value.?, "2018-01-09T10:40:47Z");
    try expectString(m.values[1].key.?, "t4");
    try expectString(m.values[1].value.?, "2098-01-09T10:40:47Z");
}

test "parse flow sequence a 1 2" {
    var doc = try testParse("a: [1, 2]\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const seq = try expectSequence(mv.value.?);
    try testing.expect(seq.is_flow);
    try testing.expectEqual(@as(usize, 2), seq.values.len);
    try expectInteger(seq.values[0], 1);
    try expectInteger(seq.values[1], 2);
}

test "parse flow mapping multiple keys" {
    var doc = try testParse("a: {b: c, d: e}\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const m = try expectMapping(mv.value.?);
    try testing.expect(m.is_flow);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "b");
    try expectString(m.values[0].value.?, "c");
    try expectString(m.values[1].key.?, "d");
    try expectString(m.values[1].value.?, "e");
}

test "parse duration-like string" {
    var doc = try testParse("a: 3s\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    try expectString(mv.value.?, "3s");
}

test "parse angle bracket string" {
    var doc = try testParse("a: <foo>\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    try expectString(mv.value.?, "<foo>");
}

test "parse quoted colon string" {
    var doc = try testParse("a: \"1:1\"\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    try expectString(mv.value.?, "1:1");
}

test "parse ip address string" {
    var doc = try testParse("a: 1.2.3.4\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    try expectString(mv.value.?, "1.2.3.4");
}

test "parse quoted timestamp" {
    var doc = try testParse("a: \"2015-02-24T18:19:39Z\"\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    try expectString(mv.value.?, "2015-02-24T18:19:39Z");
}

test "parse single quoted colon string" {
    var doc = try testParse("a: 'b: c'\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    try expectString(mv.value.?, "b: c");
}

test "parse single quoted hash string" {
    var doc = try testParse("a: 'Hello #comment'\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    try expectString(mv.value.?, "Hello #comment");
}

test "parse abc shift def ghi" {
    var doc = try testParse("a: abc <<def>> ghi");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    try expectString(mv.value.?, "abc <<def>> ghi");
}

test "parse shift abcd" {
    var doc = try testParse("a: <<abcd");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    try expectString(mv.value.?, "<<abcd");
}

test "parse shift colon abcd" {
    var doc = try testParse("a: <<:abcd");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    try expectString(mv.value.?, "<<:abcd");
}

test "parse shift space colon abcd" {
    var doc = try testParse("a: <<  :abcd");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    try expectString(mv.value.?, "<<  :abcd");
}

test "parse float 100.5" {
    var doc = try testParse("a: 100.5\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    try expectFloat(mv.value.?, 100.5);
}

test "parse bogus string" {
    var doc = try testParse("a: bogus\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    try expectString(mv.value.?, "bogus");
}

test "parse null byte escape" {
    var doc = try testParse("a: \"\\0\"\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    try expectString(mv.value.?, "\x00");
}

test "parse multiple keys with sub map" {
    const input =
        \\b: 2
        \\a: 1
        \\d: 4
        \\c: 3
        \\sub:
        \\  e: 5
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 5), m.values.len);
    try expectString(m.values[0].key.?, "b");
    try expectInteger(m.values[0].value.?, 2);
    try expectString(m.values[1].key.?, "a");
    try expectInteger(m.values[1].value.?, 1);
    try expectString(m.values[2].key.?, "d");
    try expectInteger(m.values[2].value.?, 4);
    try expectString(m.values[3].key.?, "c");
    try expectInteger(m.values[3].value.?, 3);
    try expectString(m.values[4].key.?, "sub");
    const sub_mv = try expectMappingValue(m.values[4].value.?);
    try expectString(sub_mv.key.?, "e");
    try expectInteger(sub_mv.value.?, 5);
}

test "parse whitespace around key value" {
    var doc = try testParse("       a       :          b        \n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    try expectString(mv.value.?, "b");
}

test "parse comment after value" {
    const input =
        \\a: b # comment
        \\b: c
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "a");
    try expectString(m.values[0].value.?, "b");
    try testing.expect(m.values[0].node_comment != null);
    try expectString(m.values[1].key.?, "b");
    try expectString(m.values[1].value.?, "c");
}

test "parse document header" {
    const input =
        \\---
        \\a: b
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    try expectString(mv.value.?, "b");
}

test "parse document end" {
    const input =
        \\a: b
        \\...
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    try expectString(mv.value.?, "b");
}

test "parse yaml directive" {
    const input =
        \\%YAML 1.2
        \\---
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
}

test "parse tag binary" {
    var doc = try testParse("a: !!binary gIGC\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const tag = try expectTag(mv.value.?);
    try testing.expectEqualStrings("!!binary", tag.tag);
    try testing.expect(tag.value != null);
    try expectString(tag.value.?, "gIGC");
}

test "parse tag binary literal block" {
    const input =
        \\a: !!binary |
        \\  kJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJ
        \\  CQ
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const tag = try expectTag(mv.value.?);
    try testing.expectEqualStrings("!!binary", tag.tag);
    try testing.expect(tag.value != null);
    try expectNodeType(tag.value.?, .literal);
}

test "parse v foo 1" {
    var doc = try testParse("v: !!foo 1");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    const tag = try expectTag(mv.value.?);
    try testing.expectEqualStrings("!!foo", tag.tag);
    try testing.expect(tag.value != null);
    try expectInteger(tag.value.?, 1);
}

test "parse sequence with literal strip" {
    const input =
        \\v:
        \\- A
        \\- |-
        \\  B
        \\  C
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    const seq = try expectSequence(mv.value.?);
    try testing.expectEqual(@as(usize, 2), seq.values.len);
    try expectString(seq.values[0], "A");
    try expectNodeType(seq.values[1], .literal);
    const lit = try expectLiteral(seq.values[1]);
    try testing.expectEqualStrings("B\nC", lit.value);
}

test "parse sequence with folded strip" {
    const input =
        \\v:
        \\- A
        \\- >-
        \\  B
        \\  C
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    const seq = try expectSequence(mv.value.?);
    try testing.expectEqual(@as(usize, 2), seq.values.len);
    try expectString(seq.values[0], "A");
    try expectNodeType(seq.values[1], .literal);
    const lit = try expectLiteral(seq.values[1]);
    try testing.expectEqualStrings("B C", lit.value);
}

test "parse literal strip 0" {
    const input =
        \\v: |-
        \\  0
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    const lit = try expectLiteral(mv.value.?);
    try testing.expectEqualStrings("0", lit.value);
}

test "parse literal strip 0 with next key" {
    const input =
        \\v: |-
        \\  0
        \\x: 0
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "v");
    const lit = try expectLiteral(m.values[0].value.?);
    try testing.expectEqualStrings("0", lit.value);
    try expectString(m.values[1].key.?, "x");
    try expectInteger(m.values[1].value.?, 0);
}

test "parse double quoted with newlines" {
    var doc = try testParse("\"a\\n1\\nb\"");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    try expectString(body, "a\n1\nb");
}

test "parse json style mapping" {
    var doc = try testParse("{\"a\":\"b\"}");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expect(m.is_flow);
    try testing.expectEqual(@as(usize, 1), m.values.len);
    try expectString(m.values[0].key.?, "a");
    try expectString(m.values[0].value.?, "b");
}

test "parse explicit typed map" {
    const input =
        \\!!map {
        \\  ? !!str "explicit":!!str "entry",
        \\  ? !!str "implicit" : !!str "entry",
        \\  ? !!null "" : !!null "",
        \\}
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const tag = try expectTag(body);
    try testing.expectEqualStrings("!!map", tag.tag);
    try testing.expect(tag.value != null);
}

test "parse double quoted key" {
    var doc = try testParse("\"a\": a\n\"b\": b");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "a");
    try expectString(m.values[0].value.?, "a");
    try expectString(m.values[1].key.?, "b");
    try expectString(m.values[1].value.?, "b");
}

test "parse single quoted key" {
    var doc = try testParse("'a': a\n'b': b");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "a");
    try expectString(m.values[0].value.?, "a");
    try expectString(m.values[1].key.?, "b");
    try expectString(m.values[1].value.?, "b");
}

test "parse crlf line endings" {
    var doc = try testParse("a: \r\n  b: 1\r\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const inner = try expectMappingValue(mv.value.?);
    try expectString(inner.key.?, "b");
    try expectInteger(inner.value.?, 1);
}

test "parse cr line endings" {
    var doc = try testParse("a_ok: \r  bc: 2\r");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a_ok");
    const inner = try expectMappingValue(mv.value.?);
    try expectString(inner.key.?, "bc");
    try expectInteger(inner.value.?, 2);
}

test "parse lf line endings" {
    const input =
        \\a_mk:
        \\  bd: 3
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a_mk");
    const inner = try expectMappingValue(mv.value.?);
    try expectString(inner.key.?, "bd");
    try expectInteger(inner.value.?, 3);
}

test "parse colon value" {
    var doc = try testParse("a: :a");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    try expectString(mv.value.?, ":a");
}

test "parse flow map with empty value" {
    var doc = try testParse("{a: , b: c}");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expect(m.is_flow);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "a");
    try expectNull(m.values[0].value.?);
    try expectString(m.values[1].key.?, "b");
    try expectString(m.values[1].value.?, "c");
}

test "parse folded empty value" {
    var doc = try testParse("value: >\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "value");
    try expectNodeType(mv.value.?, .literal);
    const lit = try expectLiteral(mv.value.?);
    try testing.expectEqualStrings("", lit.value);
}

test "parse folded empty double newline" {
    const input =
        \\value: >
        \\
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "value");
    try expectNodeType(mv.value.?, .literal);
    const lit = try expectLiteral(mv.value.?);
    try testing.expectEqualStrings("", lit.value);
}

test "parse folded then other key" {
    var doc = try testParse("value: >\nother:");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "value");
    try expectNodeType(m.values[0].value.?, .literal);
    try expectString(m.values[1].key.?, "other");
}

test "parse folded empty then other key" {
    const input =
        \\value: >
        \\
        \\other:
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "value");
    try expectNodeType(m.values[0].value.?, .literal);
    try expectString(m.values[1].key.?, "other");
}

test "parse map with empty sequence entry" {
    var doc = try testParse("a:\n-");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const seq = try expectSequence(mv.value.?);
    try testing.expectEqual(@as(usize, 1), seq.values.len);
}

test "parse flow map bare key" {
    var doc = try testParse("a: {foo}");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const m = try expectMapping(mv.value.?);
    try testing.expect(m.is_flow);
    try testing.expectEqual(@as(usize, 1), m.values.len);
    try expectString(m.values[0].key.?, "foo");
}

test "parse flow map bare keys comma" {
    var doc = try testParse("a: {foo,bar}");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const m = try expectMapping(mv.value.?);
    try testing.expect(m.is_flow);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "foo");
    try expectString(m.values[1].key.?, "bar");
}

test "parse nested flow map" {
    const input =
        \\{
        \\  a: {
        \\    b: c
        \\  },
        \\  d: e
        \\}
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expect(m.is_flow);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "a");
    const inner_m = try expectMapping(m.values[0].value.?);
    try testing.expect(inner_m.is_flow);
    try testing.expectEqual(@as(usize, 1), inner_m.values.len);
    try expectString(inner_m.values[0].key.?, "b");
    try expectString(inner_m.values[0].value.?, "c");
    try expectString(m.values[1].key.?, "d");
    try expectString(m.values[1].value.?, "e");
}

test "parse flow seq with map entry" {
    const input =
        \\[
        \\  a: {
        \\    b: c
        \\  }]
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const seq = try expectSequence(body);
    try testing.expect(seq.is_flow);
    try testing.expectEqual(@as(usize, 1), seq.values.len);
    const mv = try expectMappingValue(seq.values[0]);
    try expectString(mv.key.?, "a");
    const inner_m = try expectMapping(mv.value.?);
    try testing.expect(inner_m.is_flow);
    try testing.expectEqual(@as(usize, 1), inner_m.values.len);
    try expectString(inner_m.values[0].key.?, "b");
    try expectString(inner_m.values[0].value.?, "c");
}

test "parse nested flow map no comma" {
    const input =
        \\{
        \\  a: {
        \\    b: c
        \\  }}
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expect(m.is_flow);
    try testing.expectEqual(@as(usize, 1), m.values.len);
    try expectString(m.values[0].key.?, "a");
    const inner_m = try expectMapping(m.values[0].value.?);
    try testing.expect(inner_m.is_flow);
    try testing.expectEqual(@as(usize, 1), inner_m.values.len);
    try expectString(inner_m.values[0].key.?, "b");
    try expectString(inner_m.values[0].value.?, "c");
}

test "parse tag on sequence entry" {
    const input =
        \\- !tag
        \\  a: b
        \\  c: d
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const seq = try expectSequence(body);
    try testing.expectEqual(@as(usize, 1), seq.values.len);
    const tag = try expectTag(seq.values[0]);
    try testing.expectEqualStrings("!tag", tag.tag);
    try testing.expect(tag.value != null);
    const tag_m = try expectMapping(tag.value.?);
    try testing.expectEqual(@as(usize, 2), tag_m.values.len);
    try expectString(tag_m.values[0].key.?, "a");
    try expectString(tag_m.values[0].value.?, "b");
    try expectString(tag_m.values[1].key.?, "c");
    try expectString(tag_m.values[1].value.?, "d");
}

test "parse tag on map value" {
    const input =
        \\a: !tag
        \\  b: c
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const tag = try expectTag(mv.value.?);
    try testing.expectEqualStrings("!tag", tag.tag);
    try testing.expect(tag.value != null);
    const tag_mv = try expectMappingValue(tag.value.?);
    try expectString(tag_mv.key.?, "b");
    try expectString(tag_mv.value.?, "c");
}

test "parse tag on map value multi keys" {
    const input =
        \\a: !tag
        \\  b: c
        \\  d: e
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const tag = try expectTag(mv.value.?);
    try testing.expectEqualStrings("!tag", tag.tag);
    try testing.expect(tag.value != null);
    const tag_m = try expectMapping(tag.value.?);
    try testing.expectEqual(@as(usize, 2), tag_m.values.len);
    try expectString(tag_m.values[0].key.?, "b");
    try expectString(tag_m.values[0].value.?, "c");
    try expectString(tag_m.values[1].key.?, "d");
    try expectString(tag_m.values[1].value.?, "e");
}

test "parse trailing whitespace after map value" {
    const input =
        \\a:
        \\  b: c
        \\
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const inner = try expectMappingValue(mv.value.?);
    try expectString(inner.key.?, "b");
    try expectString(inner.value.?, "c");
}

test "parse multi-doc with separator" {
    const input =
        \\foo: xxx
        \\---
        \\foo: yyy
        \\---
        \\foo: zzz
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "foo");
    try expectString(mv.value.?, "xxx");
}

test "parse tab before colon" {
    var doc = try testParse("v:\n  a\t: 'a'\n  bb\t: 'a'\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    const inner = try expectMapping(mv.value.?);
    try testing.expectEqual(@as(usize, 2), inner.values.len);
    try expectString(inner.values[0].key.?, "a");
    try expectString(inner.values[0].value.?, "a");
    try expectString(inner.values[1].key.?, "bb");
    try expectString(inner.values[1].value.?, "a");
}

test "parse mixed space tab before colon" {
    var doc = try testParse("v:\n  a : 'x'\n  b\t: 'y'\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    const inner = try expectMapping(mv.value.?);
    try testing.expectEqual(@as(usize, 2), inner.values.len);
    try expectString(inner.values[0].key.?, "a");
    try expectString(inner.values[0].value.?, "x");
    try expectString(inner.values[1].key.?, "b");
    try expectString(inner.values[1].value.?, "y");
}

test "parse multiple tabs before colon" {
    var doc = try testParse("v:\n  a\t: 'x'\n  b\t: 'y'\n  c\t\t: 'z'\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    const inner = try expectMapping(mv.value.?);
    try testing.expectEqual(@as(usize, 3), inner.values.len);
    try expectString(inner.values[0].key.?, "a");
    try expectString(inner.values[0].value.?, "x");
    try expectString(inner.values[1].key.?, "b");
    try expectString(inner.values[1].value.?, "y");
    try expectString(inner.values[2].key.?, "c");
    try expectString(inner.values[2].value.?, "z");
}

test "parse anchor and alias in flow" {
    var doc = try testParse("{a: &a c, *a : b}\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expect(m.is_flow);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "a");
    const anc = try expectAnchor(m.values[0].value.?);
    try testing.expectEqualStrings("a", anc.name);
    try expectString(anc.value.?, "c");
    const ali = try expectAlias(m.values[1].key.?);
    try testing.expectEqualStrings("a", ali.name);
    try expectString(m.values[1].value.?, "b");
}

test "parse multi-document" {
    var file = try yaml.parseAll(
        testing.allocator,
        \\---
        \\a: 1
        \\---
        \\b: 2
        \\
        ,
    );
    defer file.deinit();
    try testing.expectEqual(@as(usize, 2), file.docs.len);
}

test "parse baseball teams" {
    const input =
        \\american:
        \\  - Boston Red Sox
        \\  - Detroit Tigers
        \\  - New York Yankees
        \\national:
        \\  - New York Mets
        \\  - Chicago Cubs
        \\  - Atlanta Braves
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "american");
    const aseq = try expectSequence(m.values[0].value.?);
    try testing.expectEqual(@as(usize, 3), aseq.values.len);
    try expectString(aseq.values[0], "Boston Red Sox");
    try expectString(aseq.values[1], "Detroit Tigers");
    try expectString(aseq.values[2], "New York Yankees");
    try expectString(m.values[1].key.?, "national");
    const nseq = try expectSequence(m.values[1].value.?);
    try testing.expectEqual(@as(usize, 3), nseq.values.len);
    try expectString(nseq.values[0], "New York Mets");
    try expectString(nseq.values[1], "Chicago Cubs");
    try expectString(nseq.values[2], "Atlanta Braves");
}

test "parse deep nested map" {
    const input =
        \\a:
        \\  b: c
        \\  d: e
        \\  f: g
        \\h:
        \\  i: j
        \\  k:
        \\    l: m
        \\    n: o
        \\  p: q
        \\r: s
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 3), m.values.len);
    try expectString(m.values[0].key.?, "a");
    const a_m = try expectMapping(m.values[0].value.?);
    try testing.expectEqual(@as(usize, 3), a_m.values.len);
    try expectString(a_m.values[0].key.?, "b");
    try expectString(a_m.values[0].value.?, "c");
    try expectString(a_m.values[1].key.?, "d");
    try expectString(a_m.values[1].value.?, "e");
    try expectString(a_m.values[2].key.?, "f");
    try expectString(a_m.values[2].value.?, "g");
    try expectString(m.values[1].key.?, "h");
    const h_m = try expectMapping(m.values[1].value.?);
    try testing.expectEqual(@as(usize, 3), h_m.values.len);
    try expectString(h_m.values[0].key.?, "i");
    try expectString(h_m.values[0].value.?, "j");
    try expectString(h_m.values[1].key.?, "k");
    try expectString(h_m.values[2].key.?, "p");
    try expectString(h_m.values[2].value.?, "q");
    try expectString(m.values[2].key.?, "r");
    try expectString(m.values[2].value.?, "s");
}

test "parse sequence of sequences" {
    const input =
        \\- a:
        \\  - b
        \\  - c
        \\- d
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const seq = try expectSequence(body);
    try testing.expectEqual(@as(usize, 2), seq.values.len);
    const mv = try expectMappingValue(seq.values[0]);
    try expectString(mv.key.?, "a");
    const inner_seq = try expectSequence(mv.value.?);
    try testing.expectEqual(@as(usize, 2), inner_seq.values.len);
    try expectString(inner_seq.values[0], "b");
    try expectString(inner_seq.values[1], "c");
    try expectString(seq.values[1], "d");
}

test "parse sequence inline continuation" {
    const input =
        \\- a
        \\- b
        \\- c
        \\ - d
        \\ - e
        \\- f
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const seq = try expectSequence(body);
    try testing.expectEqual(@as(usize, 4), seq.values.len);
    try expectString(seq.values[0], "a");
    try expectString(seq.values[1], "b");
    try expectString(seq.values[2], "c - d - e");
    try expectString(seq.values[3], "f");
}

test "parse flow map under sequence" {
    const input =
        \\elem1:
        \\  - elem2:
        \\      {a: b, c: d}
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "elem1");
    const seq = try expectSequence(mv.value.?);
    try testing.expectEqual(@as(usize, 1), seq.values.len);
    const inner_mv = try expectMappingValue(seq.values[0]);
    try expectString(inner_mv.key.?, "elem2");
    const inner_m = try expectMapping(inner_mv.value.?);
    try testing.expect(inner_m.is_flow);
    try testing.expectEqual(@as(usize, 2), inner_m.values.len);
    try expectString(inner_m.values[0].key.?, "a");
    try expectString(inner_m.values[0].value.?, "b");
    try expectString(inner_m.values[1].key.?, "c");
    try expectString(inner_m.values[1].value.?, "d");
}

test "parse flow seq under sequence" {
    const input =
        \\elem1:
        \\  - elem2:
        \\      [a, b, c, d]
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "elem1");
    const seq = try expectSequence(mv.value.?);
    try testing.expectEqual(@as(usize, 1), seq.values.len);
    const inner_mv = try expectMappingValue(seq.values[0]);
    try expectString(inner_mv.key.?, "elem2");
    const inner_seq = try expectSequence(inner_mv.value.?);
    try testing.expect(inner_seq.is_flow);
    try testing.expectEqual(@as(usize, 4), inner_seq.values.len);
    try expectString(inner_seq.values[0], "a");
    try expectString(inner_seq.values[1], "b");
    try expectString(inner_seq.values[2], "c");
    try expectString(inner_seq.values[3], "d");
}

test "parse value with dash" {
    var doc = try testParse("a: 0 - 1\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    try expectString(mv.value.?, "0 - 1");
}

test "parse sequence with sub maps" {
    const input =
        \\- a:
        \\   b: c
        \\   d: e
        \\- f:
        \\  g: h
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const seq = try expectSequence(body);
    try testing.expectEqual(@as(usize, 2), seq.values.len);
    const mv0 = try expectMappingValue(seq.values[0]);
    try expectString(mv0.key.?, "a");
    const mv1 = try expectMappingValue(seq.values[1]);
    try expectString(mv1.key.?, "f");
}

test "parse multiline plain scalar" {
    const input =
        \\a:
        \\ b
        \\ c
        \\d: e
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "a");
    try expectString(m.values[0].value.?, "b c");
    try expectString(m.values[1].key.?, "d");
    try expectString(m.values[1].value.?, "e");
}

test "parse plain scalar multi-word" {
    const input =
        \\a
        \\b
        \\c
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    try expectString(body, "a b c");
}

test "parse compact sequence" {
    const input =
        \\a:
        \\ - b
        \\ - c
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const seq = try expectSequence(mv.value.?);
    try testing.expectEqual(@as(usize, 2), seq.values.len);
    try expectString(seq.values[0], "b");
    try expectString(seq.values[1], "c");
}

test "parse sequence map with padding" {
    const input =
        \\-     a     :
        \\      b: c
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const seq = try expectSequence(body);
    try testing.expectEqual(@as(usize, 1), seq.values.len);
    const mv = try expectMappingValue(seq.values[0]);
    try expectString(mv.key.?, "a");
}

test "parse sequence multiline value with sub key" {
    const input =
        \\- a:
        \\   b
        \\   c
        \\   d
        \\  hoge: fuga
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const seq = try expectSequence(body);
    try testing.expectEqual(@as(usize, 1), seq.values.len);
}

test "parse sequence with comments" {
    const input =
        \\- a # ' " # - : %
        \\- b # " # - : % '
        \\- c # # - : % ' "
        \\- d # - : % ' " #
        \\- e # : % ' " # -
        \\- f # % ' : # - :
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const seq = try expectSequence(body);
    try testing.expectEqual(@as(usize, 6), seq.values.len);
    try expectString(seq.values[0], "a");
    try expectString(seq.values[1], "b");
    try expectString(seq.values[2], "c");
    try expectString(seq.values[3], "d");
    try expectString(seq.values[4], "e");
    try expectString(seq.values[5], "f");
}

test "parse comment interleaved in map" {
    const input =
        \\# comment
        \\a: # comment
        \\ b: c # comment
        \\ # comment
        \\d: e # comment
        \\# comment
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "a");
    try testing.expect(m.values[0].node_comment != null);
    const a_inner = try expectMappingValue(m.values[0].value.?);
    try expectString(a_inner.key.?, "b");
    try expectString(a_inner.value.?, "c");
    try testing.expect(a_inner.node_comment != null);
    try expectString(m.values[1].key.?, "d");
    try expectString(m.values[1].value.?, "e");
    try testing.expect(m.values[1].node_comment != null);
}

test "parse hash without space is not comment" {
    var doc = try testParse("a: b#notcomment\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    try expectString(mv.value.?, "b#notcomment");
}

test "parse anchor and alias" {
    var doc = try testParse("anchored: &anchor foo\naliased: *anchor\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "anchored");
    const anc = try expectAnchor(m.values[0].value.?);
    try testing.expectEqualStrings("anchor", anc.name);
    try expectString(m.values[1].key.?, "aliased");
    const ali = try expectAlias(m.values[1].value.?);
    try testing.expectEqualStrings("anchor", ali.name);
}

test "parse merge key complex" {
    const input =
        \\---
        \\- &CENTER { x: 1, y: 2 }
        \\- &LEFT { x: 0, y: 2 }
        \\- &BIG { r: 10 }
        \\- &SMALL { r: 1 }
        \\- x: 1
        \\  y: 2
        \\  r: 10
        \\  label: center/big
        \\- << : *CENTER
        \\  r: 10
        \\  label: center/big
        \\- << : [ *CENTER, *BIG ]
        \\  label: center/big
        \\- << : [ *BIG, *LEFT, *SMALL ]
        \\  x: 1
        \\  label: center/big
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const seq = try expectSequence(body);
    try testing.expectEqual(@as(usize, 8), seq.values.len);
    const anc0 = try expectAnchor(seq.values[0]);
    try testing.expectEqualStrings("CENTER", anc0.name);
    const anc1 = try expectAnchor(seq.values[1]);
    try testing.expectEqualStrings("LEFT", anc1.name);
    const anc2 = try expectAnchor(seq.values[2]);
    try testing.expectEqualStrings("BIG", anc2.name);
    const anc3 = try expectAnchor(seq.values[3]);
    try testing.expectEqualStrings("SMALL", anc3.name);
}

test "parse nested sequences under map" {
    var doc = try testParse("a:\n- - b\n- - c\n  - d\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const inner_seq = try expectSequence(mv.value.?);
    try testing.expectEqual(@as(usize, 2), inner_seq.values.len);
}

test "parse sibling maps" {
    const input =
        \\a:
        \\  b:
        \\    c: d
        \\  e:
        \\    f: g
        \\    h: i
        \\j: k
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "a");
    const a_inner = try expectMapping(m.values[0].value.?);
    try testing.expectEqual(@as(usize, 2), a_inner.values.len);
    try expectString(a_inner.values[0].key.?, "b");
    try expectString(a_inner.values[1].key.?, "e");
    try expectString(m.values[1].key.?, "j");
    try expectString(m.values[1].value.?, "k");
}

test "parse doc with header and end" {
    var doc = try testParse("---\na: 1\nb: 2\n...\n---\nc: 3\nd: 4\n...\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "a");
    try expectInteger(m.values[0].value.?, 1);
    try expectString(m.values[1].key.?, "b");
    try expectInteger(m.values[1].value.?, 2);
}

test "parse literal block inside map" {
    const input =
        \\a:
        \\  b: |
        \\    {
        \\      [ 1, 2 ]
        \\    }
        \\  c: d
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const inner = try expectMapping(mv.value.?);
    try testing.expectEqual(@as(usize, 2), inner.values.len);
    try expectString(inner.values[0].key.?, "b");
    try expectNodeType(inner.values[0].value.?, .literal);
    const lit = try expectLiteral(inner.values[0].value.?);
    try testing.expectEqualStrings("{\n  [ 1, 2 ]\n}\n", lit.value);
    try expectString(inner.values[1].key.?, "c");
    try expectString(inner.values[1].value.?, "d");
}

test "parse root literal block" {
    var doc = try testParse("|\n    hoge\n    fuga\n    piyo");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    try expectNodeType(body, .literal);
    const lit = try expectLiteral(body);
    try testing.expectEqualStrings("hoge\nfuga\npiyo\n", lit.value);
}

test "parse literal block v" {
    var doc = try testParse("v: |\n a\n b\n c");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    try expectNodeType(mv.value.?, .literal);
    const lit = try expectLiteral(mv.value.?);
    try testing.expectEqualStrings("a\nb\nc\n", lit.value);
}

test "parse literal block with blank lines" {
    const input =
        \\a: |
        \\   bbbbbbb
        \\
        \\
        \\   ccccccc
        \\d: eeeeeeeeeeeeeeeee
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "a");
    try expectNodeType(m.values[0].value.?, .literal);
    const lit = try expectLiteral(m.values[0].value.?);
    try testing.expectEqualStrings("bbbbbbb\n\n\nccccccc\n", lit.value);
    try expectString(m.values[1].key.?, "d");
    try expectString(m.values[1].value.?, "eeeeeeeeeeeeeeeee");
}

test "parse trailing ws after multiline value" {
    var doc = try testParse("a: b    \n  c\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    try expectString(mv.value.?, "b c");
}

test "parse trailing ws on key-only line" {
    var doc = try testParse("a:    \n  b: c\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const inner = try expectMappingValue(mv.value.?);
    try expectString(inner.key.?, "b");
    try expectString(inner.value.?, "c");
}

test "parse trailing ws on value line" {
    var doc = try testParse("a: b    \nc: d\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "a");
    try expectString(m.values[0].value.?, "b");
    try expectString(m.values[1].key.?, "c");
    try expectString(m.values[1].value.?, "d");
}

test "parse dash in sequence values" {
    var doc = try testParse("- ab - cd\n- ef - gh\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const seq = try expectSequence(body);
    try testing.expectEqual(@as(usize, 2), seq.values.len);
    try expectString(seq.values[0], "ab - cd");
    try expectString(seq.values[1], "ef - gh");
}

test "parse sequence inline dash" {
    var doc = try testParse("- 0 - 1\n - 2 - 3\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const seq = try expectSequence(body);
    try testing.expectEqual(@as(usize, 1), seq.values.len);
    try expectString(seq.values[0], "0 - 1 - 2 - 3");
}

test "parse dash in map key" {
    var doc = try testParse("a - b - c: value\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a - b - c");
    try expectString(mv.value.?, "value");
}

test "parse sequence empty entry with sub maps" {
    const input =
        \\a:
        \\-
        \\  b: c
        \\  d: e
        \\-
        \\  f: g
        \\  h: i
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const seq = try expectSequence(mv.value.?);
    try testing.expectEqual(@as(usize, 2), seq.values.len);
    const m0 = try expectMapping(seq.values[0]);
    try testing.expectEqual(@as(usize, 2), m0.values.len);
    try expectString(m0.values[0].key.?, "b");
    try expectString(m0.values[0].value.?, "c");
    try expectString(m0.values[1].key.?, "d");
    try expectString(m0.values[1].value.?, "e");
    const m1 = try expectMapping(seq.values[1]);
    try testing.expectEqual(@as(usize, 2), m1.values.len);
    try expectString(m1.values[0].key.?, "f");
    try expectString(m1.values[0].value.?, "g");
    try expectString(m1.values[1].key.?, "h");
    try expectString(m1.values[1].value.?, "i");
}

test "parse literal strip with next key" {
    var doc = try testParse("a: |-\n  value\nb: c\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "a");
    const lit = try expectLiteral(m.values[0].value.?);
    try testing.expectEqualStrings("value", lit.value);
    try expectString(m.values[1].key.?, "b");
    try expectString(m.values[1].value.?, "c");
}

test "parse literal keep plus" {
    var doc = try testParse("a:  |+\n  value\nb: c\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "a");
    try expectNodeType(m.values[0].value.?, .literal);
    const lit = try expectLiteral(m.values[0].value.?);
    try testing.expectEqualStrings("value\n", lit.value);
    try expectString(m.values[1].key.?, "b");
    try expectString(m.values[1].value.?, "c");
}

test "parse sequence multiline value sub key" {
    const input =
        \\- key1: val
        \\  key2:
        \\    (
        \\      foo
        \\      +
        \\      bar
        \\    )
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const seq = try expectSequence(body);
    try testing.expectEqual(@as(usize, 1), seq.values.len);
    const inner_m = try expectMapping(seq.values[0]);
    try testing.expectEqual(@as(usize, 2), inner_m.values.len);
    try expectString(inner_m.values[0].key.?, "key1");
    try expectString(inner_m.values[0].value.?, "val");
    try expectString(inner_m.values[1].key.?, "key2");
}

test "parse quoted keys and values" {
    const input =
        \\"a": b
        \\'c': d
        \\"e": "f"
        \\g: "h"
        \\i: 'j'
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 5), m.values.len);
    try expectString(m.values[0].key.?, "a");
    try expectString(m.values[0].value.?, "b");
    try expectString(m.values[1].key.?, "c");
    try expectString(m.values[1].value.?, "d");
    try expectString(m.values[2].key.?, "e");
    try expectString(m.values[2].value.?, "f");
    try expectString(m.values[3].key.?, "g");
    try expectString(m.values[3].value.?, "h");
    try expectString(m.values[4].key.?, "i");
    try expectString(m.values[4].value.?, "j");
}

test "parse literal with indent 2" {
    const input =
        \\a:
        \\  - |2
        \\        b
        \\    c: d
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const seq = try expectSequence(mv.value.?);
    try testing.expectEqual(@as(usize, 1), seq.values.len);
    try expectNodeType(seq.values[0], .literal);
}

test "parse anchor without value" {
    const input =
        \\a:
        \\ b: &anchor
        \\ c: &anchor2
        \\d: e
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "a");
    const a_inner = try expectMapping(m.values[0].value.?);
    try testing.expectEqual(@as(usize, 2), a_inner.values.len);
    try expectString(a_inner.values[0].key.?, "b");
    const anc1 = try expectAnchor(a_inner.values[0].value.?);
    try testing.expectEqualStrings("anchor", anc1.name);
    try expectString(a_inner.values[1].key.?, "c");
    const anc2 = try expectAnchor(a_inner.values[1].value.?);
    try testing.expectEqualStrings("anchor2", anc2.name);
    try expectString(m.values[1].key.?, "d");
    try expectString(m.values[1].value.?, "e");
}

test "parse empty value" {
    var doc = try testParse("v:\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    try expectNull(mv.value.?);
}

test "parse deeply nested map" {
    var doc = try testParse("a:\n  b:\n    c: d\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const bv = try expectMappingValue(mv.value.?);
    try expectString(bv.key.?, "b");
    const cv = try expectMappingValue(bv.value.?);
    try expectString(cv.key.?, "c");
    try expectString(cv.value.?, "d");
}

test "parse root sequence" {
    var doc = try testParse("- A\n- B\n- C\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const seq = try expectSequence(body);
    try testing.expectEqual(@as(usize, 3), seq.values.len);
    try expectString(seq.values[0], "A");
    try expectString(seq.values[1], "B");
    try expectString(seq.values[2], "C");
}

test "parse anchor" {
    var doc = try testParse("a: &anchor value\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const anc = try expectAnchor(mv.value.?);
    try testing.expectEqualStrings("anchor", anc.name);
    try expectString(anc.value.?, "value");
}

test "parse alias" {
    const input =
        \\a: &ref hello
        \\b: *ref
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "a");
    const anc = try expectAnchor(m.values[0].value.?);
    try testing.expectEqualStrings("ref", anc.name);
    try expectString(anc.value.?, "hello");
    try expectString(m.values[1].key.?, "b");
    const ali = try expectAlias(m.values[1].value.?);
    try testing.expectEqualStrings("ref", ali.name);
}

test "parse merge key" {
    const input =
        \\a: &a
        \\  foo: 1
        \\b:
        \\  <<: *a
        \\  bar: 2
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "a");
    const anc = try expectAnchor(m.values[0].value.?);
    try testing.expectEqualStrings("a", anc.name);
    try expectString(m.values[1].key.?, "b");
    const b_inner = try expectMapping(m.values[1].value.?);
    try testing.expectEqual(@as(usize, 2), b_inner.values.len);
    try expectString(b_inner.values[1].key.?, "bar");
    try expectInteger(b_inner.values[1].value.?, 2);
}

test "parse custom tag" {
    var doc = try testParse("v: !!foo 1\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    const tag = try expectTag(mv.value.?);
    try testing.expectEqualStrings("!!foo", tag.tag);
}

test "parse comment after value in map" {
    var doc = try testParse("a: b # comment\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    try expectString(mv.value.?, "b");
    try testing.expect(mv.node_comment != null);
}

test "parse comment only line" {
    var doc = try testParse("# comment\na: b\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    try expectString(mv.value.?, "b");
}

test "parse literal block scalar" {
    const input =
        \\v: |
        \\  hello
        \\  world
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    const lit = try expectLiteral(mv.value.?);
    try testing.expectEqualStrings("hello\nworld\n", lit.value);
}

test "parse folded block scalar" {
    const input =
        \\v: >
        \\  hello
        \\  world
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "v");
    try expectNodeType(mv.value.?, .literal);
    const lit = try expectLiteral(mv.value.?);
    try testing.expectEqualStrings("hello world\n", lit.value);
}

test "parse with lf line endings" {
    var doc = try testParse("a: b\nc: d\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "a");
    try expectString(m.values[0].value.?, "b");
    try expectString(m.values[1].key.?, "c");
    try expectString(m.values[1].value.?, "d");
}

test "parse with crlf line endings" {
    var doc = try testParse("a: b\r\nc: d\r\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "a");
    try expectString(m.values[0].value.?, "b");
    try expectString(m.values[1].key.?, "c");
    try expectString(m.values[1].value.?, "d");
}

test "parse whitespace blank lines in map" {
    var doc = try testParse("a: b\n\nc: d\n\n\ne: f\ng: h\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 4), m.values.len);
    try expectString(m.values[0].key.?, "a");
    try expectString(m.values[0].value.?, "b");
    try expectString(m.values[1].key.?, "c");
    try expectString(m.values[1].value.?, "d");
    try expectString(m.values[2].key.?, "e");
    try expectString(m.values[2].value.?, "f");
    try expectString(m.values[3].key.?, "g");
    try expectString(m.values[3].value.?, "h");
}

test "parse seq with blank line between entries" {
    const input =
        \\a:
        \\  - b: c
        \\    d: e
        \\
        \\  - f: g
        \\    h: i
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const seq = try expectSequence(mv.value.?);
    try testing.expectEqual(@as(usize, 2), seq.values.len);
    const m0 = try expectMapping(seq.values[0]);
    try testing.expectEqual(@as(usize, 2), m0.values.len);
    try expectString(m0.values[0].key.?, "b");
    try expectString(m0.values[0].value.?, "c");
    try expectString(m0.values[1].key.?, "d");
    try expectString(m0.values[1].value.?, "e");
}

test "parse block seq with blank line" {
    const input =
        \\a:
        \\- b: c
        \\  d: e
        \\
        \\- f: g
        \\  h: i
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const seq = try expectSequence(mv.value.?);
    try testing.expectEqual(@as(usize, 2), seq.values.len);
    const m0 = try expectMapping(seq.values[0]);
    try testing.expectEqual(@as(usize, 2), m0.values.len);
    try expectString(m0.values[0].key.?, "b");
    try expectString(m0.values[0].value.?, "c");
}

test "parse seq with comments and blanks" {
    const input =
        \\a:
        \\# comment 1
        \\- b: c
        \\  d: e
        \\
        \\# comment 2
        \\- f: g
        \\  h: i
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const seq = try expectSequence(mv.value.?);
    try testing.expectEqual(@as(usize, 2), seq.values.len);
    const m0 = try expectMapping(seq.values[0]);
    try testing.expectEqual(@as(usize, 2), m0.values.len);
    try expectString(m0.values[0].key.?, "b");
    try expectString(m0.values[0].value.?, "c");
}

test "parse seq nested comments" {
    const input =
        \\a:
        \\  # comment 1
        \\  - b: c
        \\    # comment 2
        \\    d: e
        \\
        \\  # comment 3
        \\  # comment 4
        \\  - f: g
        \\    h: i # comment 5
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const seq = try expectSequence(mv.value.?);
    try testing.expectEqual(@as(usize, 2), seq.values.len);
    const m0 = try expectMapping(seq.values[0]);
    try testing.expectEqual(@as(usize, 2), m0.values.len);
    try expectString(m0.values[0].key.?, "b");
    try expectString(m0.values[0].value.?, "c");
    try expectString(m0.values[1].key.?, "d");
    try expectString(m0.values[1].value.?, "e");
}

test "parse seq with literal and comments" {
    const input =
        \\a:
        \\  # comment 1
        \\  - b: c
        \\    # comment 2
        \\    d: e
        \\
        \\  # comment 3
        \\  # comment 4
        \\  - f: |
        \\      g
        \\      g
        \\    h: i # comment 5
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const seq = try expectSequence(mv.value.?);
    try testing.expectEqual(@as(usize, 2), seq.values.len);
    const m0 = try expectMapping(seq.values[0]);
    try testing.expectEqual(@as(usize, 2), m0.values.len);
    try expectString(m0.values[0].key.?, "b");
    try expectString(m0.values[0].value.?, "c");
    const m1 = try expectMapping(seq.values[1]);
    try testing.expectEqual(@as(usize, 2), m1.values.len);
    try expectString(m1.values[0].key.?, "f");
    try expectNodeType(m1.values[0].value.?, .literal);
    try expectString(m1.values[1].key.?, "h");
    try expectString(m1.values[1].value.?, "i");
}

test "parse literal with blank and comments" {
    const input =
        \\a:
        \\  # comment 1
        \\  - b: c
        \\    # comment 2
        \\    d: e
        \\
        \\  # comment 3
        \\  # comment 4
        \\  - f: |
        \\      asd
        \\      def
        \\
        \\    h: i # comment 5
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    const seq = try expectSequence(mv.value.?);
    try testing.expectEqual(@as(usize, 2), seq.values.len);
    const m0 = try expectMapping(seq.values[0]);
    try testing.expectEqual(@as(usize, 2), m0.values.len);
    try expectString(m0.values[0].key.?, "b");
    try expectString(m0.values[0].value.?, "c");
    const m1 = try expectMapping(seq.values[1]);
    try testing.expectEqual(@as(usize, 2), m1.values.len);
    try expectString(m1.values[0].key.?, "f");
    try expectNodeType(m1.values[0].value.?, .literal);
    try expectString(m1.values[1].key.?, "h");
    try expectString(m1.values[1].value.?, "i");
}

test "parse root seq with blank line" {
    const input =
        \\- b: c
        \\  d: e
        \\
        \\- f: g
        \\  h: i # comment 4
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const seq = try expectSequence(body);
    try testing.expectEqual(@as(usize, 2), seq.values.len);
    const m0 = try expectMapping(seq.values[0]);
    try testing.expectEqual(@as(usize, 2), m0.values.len);
    try expectString(m0.values[0].key.?, "b");
    try expectString(m0.values[0].value.?, "c");
    try expectString(m0.values[1].key.?, "d");
    try expectString(m0.values[1].value.?, "e");
    const m1 = try expectMapping(seq.values[1]);
    try testing.expectEqual(@as(usize, 2), m1.values.len);
    try expectString(m1.values[0].key.?, "f");
    try expectString(m1.values[0].value.?, "g");
    try expectString(m1.values[1].key.?, "h");
    try expectString(m1.values[1].value.?, "i");
}

test "parse null values with blank line" {
    var doc = try testParse("a: null\nb: null\n\nd: e\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 3), m.values.len);
    try expectString(m.values[0].key.?, "a");
    try expectNull(m.values[0].value.?);
    try expectString(m.values[1].key.?, "b");
    try expectNull(m.values[1].value.?);
    try expectString(m.values[2].key.?, "d");
    try expectString(m.values[2].value.?, "e");
}

test "parse null with comment and blank" {
    const input =
        \\foo:
        \\  bar: null # comment
        \\
        \\  baz: 1
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "foo");
    const inner = try expectMapping(mv.value.?);
    try testing.expectEqual(@as(usize, 2), inner.values.len);
    try expectString(inner.values[0].key.?, "bar");
    try expectNull(inner.values[0].value.?);
    try testing.expect(inner.values[0].node_comment != null);
    try expectString(inner.values[1].key.?, "baz");
    try expectInteger(inner.values[1].value.?, 1);
}

test "parse null with comment top-level blank" {
    const input =
        \\foo:
        \\  bar: null # comment
        \\
        \\baz: 1
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "foo");
    const foo_inner = try expectMappingValue(m.values[0].value.?);
    try expectString(foo_inner.key.?, "bar");
    try expectNull(foo_inner.value.?);
    try testing.expect(foo_inner.node_comment != null);
    try expectString(m.values[1].key.?, "baz");
    try expectInteger(m.values[1].value.?, 1);
}

test "parse json deployment" {
    const input =
        "{\n" ++
        "\t\"apiVersion\": \"apps/v1\",\n" ++
        "\t\"kind\": \"Deployment\",\n" ++
        "\t\"metadata\": {\n" ++
        "\t\t\"name\": \"foo\",\n" ++
        "\t\t\"labels\": {\n" ++
        "\t\t\t\"app\": \"bar\"\n" ++
        "\t\t}\n" ++
        "\t},\n" ++
        "\t\"spec\": {\n" ++
        "\t\t\"replicas\": 3,\n" ++
        "\t\t\"selector\": {\n" ++
        "\t\t\t\"matchLabels\": {\n" ++
        "\t\t\t\t\"app\": \"bar\"\n" ++
        "\t\t\t}\n" ++
        "\t\t},\n" ++
        "\t\t\"template\": {\n" ++
        "\t\t\t\"metadata\": {\n" ++
        "\t\t\t\t\"labels\": {\n" ++
        "\t\t\t\t\t\"app\": \"bar\"\n" ++
        "\t\t\t\t}\n" ++
        "\t\t\t}\n" ++
        "\t\t}\n" ++
        "\t}\n" ++
        "}\n";
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expect(m.is_flow);
    try testing.expectEqual(@as(usize, 4), m.values.len);
    try expectString(m.values[0].key.?, "apiVersion");
    try expectString(m.values[0].value.?, "apps/v1");
    try expectString(m.values[1].key.?, "kind");
    try expectString(m.values[1].value.?, "Deployment");
    try expectString(m.values[2].key.?, "metadata");
    try expectString(m.values[3].key.?, "spec");
}

test "parse lf yml" {
    var doc = try testParse("a: \"a\"\n\nb: 1\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "a");
    try expectString(m.values[0].value.?, "a");
    try expectString(m.values[1].key.?, "b");
    try expectInteger(m.values[1].value.?, 1);
}

test "parse cr yml" {
    var doc = try testParse("a: \"a\"\r\rb: 1\r");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "a");
    try expectString(m.values[0].value.?, "a");
    try expectString(m.values[1].key.?, "b");
    try expectInteger(m.values[1].value.?, 1);
}

test "parse crlf yml" {
    var doc = try testParse("a: \"a\"\r\n\r\nb: 1\r\n");
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "a");
    try expectString(m.values[0].value.?, "a");
    try expectString(m.values[1].key.?, "b");
    try expectInteger(m.values[1].value.?, 1);
}

test "parse syntax error colons" {
    const input =
        \\:
        \\  :
        \\    :
    ;
    const doc = testParse(input);
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error sequence after string" {
    const doc = testParse("a\n- b: c");
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error directive with content" {
    const doc = testParse("%YAML 1.1 {}");
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error invalid flow map" {
    const doc = testParse("{invalid");
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error unclosed flow map" {
    const doc = testParse("{ \"key\": \"value\" ");
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error invalid literal option" {
    const input =
        \\a: |invalidopt
        \\  foo
        \\
    ;
    const doc = testParse(input);
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error non-map value" {
    const input =
        \\a: 1
        \\b
        \\
    ;
    const doc = testParse(input);
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error value after quoted" {
    const input =
        \\a: 'b'
        \\  c: d
        \\
    ;
    const doc = testParse(input);
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error seq after quoted" {
    const input =
        \\a: 'b'
        \\  - c
        \\
    ;
    const doc = testParse(input);
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error seq after quoted comment" {
    const input =
        \\a: 'b'
        \\  # comment
        \\  - c
        \\
    ;
    const doc = testParse(input);
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error non-map after seq" {
    const input =
        \\a: 1
        \\b
        \\- c
        \\
    ;
    const doc = testParse(input);
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error unclosed flow seq" {
    const doc = testParse("a: [");
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error unexpected close bracket" {
    const doc = testParse("a: ]");
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error seq without comma" {
    const doc = testParse("a: [ [1] [2] [3] ]");
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error dash after colon" {
    const input =
        \\a: -
        \\b: -
        \\
    ;
    const doc = testParse(input);
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error dash value after colon" {
    const input =
        \\a: - 1
        \\b: - 2
        \\
    ;
    const doc = testParse(input);
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error unclosed single quote" {
    const doc = testParse("a: 'foobarbaz");
    try testing.expectError(error.UnexpectedEof, doc);
}

test "parse syntax error unclosed double quote" {
    const doc = testParse("a: \"\\\"key\\\": \\\"value:\\\"");
    try testing.expectError(error.UnexpectedEof, doc);
}

test "parse syntax error dollar brace in seq" {
    const doc = testParse("foo: [${should not be allowed}]");
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error dollar bracket in seq" {
    const doc = testParse("foo: [$[should not be allowed]]");
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error folded then folded" {
    const doc = testParse(">\n>");
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error folded then number" {
    const doc = testParse(">\n1");
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error literal then number" {
    const doc = testParse("|\n1");
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error invalid indent count" {
    const doc = testParse("a: >3\n  1");
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error value after literal" {
    const input =
        \\a:
        \\  - |
        \\        b
        \\    c: d
        \\
    ;
    const doc = testParse(input);
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error map after literal" {
    const input =
        \\a:
        \\  - |
        \\        b
        \\    c:
        \\      d: e
        \\
    ;
    const doc = testParse(input);
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error reserved at" {
    const doc = testParse("key: [@val]");
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error reserved backtick" {
    const doc = testParse("key: [`val]");
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error flow map as key" {
    const doc = testParse("{a: b}: v");
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error flow seq as key" {
    const doc = testParse("[a]: v");
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error duplicate key top" {
    const input =
        \\foo:
        \\  bar:
        \\    foo: 2
        \\  baz:
        \\    foo: 3
        \\foo: 2
        \\
    ;
    const doc = testParse(input);
    try testing.expectError(error.DuplicateKey, doc);
}

test "parse syntax error duplicate key nested" {
    const input =
        \\foo:
        \\  bar:
        \\    foo: 2
        \\  baz:
        \\    foo: 3
        \\    foo: 4
        \\
    ;
    const doc = testParse(input);
    try testing.expectError(error.DuplicateKey, doc);
}

test "parse syntax error flow map trailing comma" {
    const doc = testParse("{\"000\":0000A,");
    try testing.expectError(error.SyntaxError, doc);
}

test "parse syntax error seq in value ctx" {
    const input =
        \\a:
        \\- b
        \\  c: d
        \\  e: f
        \\  g: h
    ;
    const doc = testParse(input);
    try testing.expectError(error.SyntaxError, doc);
}

test "parse tab in indentation returns error" {
    const doc = testParse("a:\n\tb: c");
    try testing.expectError(error.TabInIndent, doc);
}

test "parse unclosed flow mapping returns error" {
    const doc = testParse("{a: b");
    try testing.expectError(error.SyntaxError, doc);
}

test "parse unclosed flow sequence returns error" {
    const doc = testParse("[a, b");
    try testing.expectError(error.SyntaxError, doc);
}

test "parse comment with null same line" {
    const input =
        \\foo:
        \\  bar: # comment
        \\  baz: 1
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "foo");
    const inner = try expectMapping(mv.value.?);
    try testing.expectEqual(@as(usize, 2), inner.values.len);
    try expectString(inner.values[0].key.?, "bar");
    try expectNull(inner.values[0].value.?);
    try testing.expect(inner.values[0].node_comment != null);
    try expectString(inner.values[1].key.?, "baz");
    try expectInteger(inner.values[1].value.?, 1);
}

test "parse comment with null next line" {
    const input =
        \\foo:
        \\  bar:
        \\    # comment
        \\  baz: 1
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "foo");
    const inner = try expectMapping(mv.value.?);
    try testing.expectEqual(@as(usize, 2), inner.values.len);
    try expectString(inner.values[0].key.?, "bar");
    try expectNull(inner.values[0].value.?);
    try expectString(inner.values[1].key.?, "baz");
    try expectInteger(inner.values[1].value.?, 1);
}

test "parse comment different indent" {
    const input =
        \\foo:
        \\  bar:
        \\ # comment
        \\baz: 1
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "foo");
    const foo_mv = try expectMappingValue(m.values[0].value.?);
    try expectString(foo_mv.key.?, "bar");
    try expectNull(foo_mv.value.?);
    try expectString(m.values[1].key.?, "baz");
    try expectInteger(m.values[1].value.?, 1);
}

test "parse sequence comment" {
    const input =
        \\foo:
        \\  - # comment
        \\    bar: 1
        \\baz:
        \\  - xxx
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "foo");
    const foo_seq = try expectSequence(m.values[0].value.?);
    try testing.expectEqual(@as(usize, 1), foo_seq.values.len);
    try expectString(m.values[1].key.?, "baz");
    const baz_seq = try expectSequence(m.values[1].value.?);
    try testing.expectEqual(@as(usize, 1), baz_seq.values.len);
    try expectString(baz_seq.values[0], "xxx");
}

test "parse comment with map" {
    const input =
        \\single:
        \\  # foo comment
        \\  foo: bar
        \\
        \\multiple:
        \\    # a comment
        \\    a: b
        \\    # c comment
        \\    c: d
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "single");
    const s_mv = try expectMappingValue(m.values[0].value.?);
    try expectString(s_mv.key.?, "foo");
    try expectString(s_mv.value.?, "bar");
    try expectString(m.values[1].key.?, "multiple");
    const mult = try expectMapping(m.values[1].value.?);
    try testing.expectEqual(@as(usize, 2), mult.values.len);
    try expectString(mult.values[0].key.?, "a");
    try expectString(mult.values[0].value.?, "b");
    try expectString(mult.values[1].key.?, "c");
    try expectString(mult.values[1].value.?, "d");
}

test "parse flow style sequence" {
    const input =
        \\- foo
        \\- bar
        \\- baz
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const seq = try expectSequence(body);
    try testing.expectEqual(@as(usize, 3), seq.values.len);
    try expectString(seq.values[0], "foo");
    try expectString(seq.values[1], "bar");
    try expectString(seq.values[2], "baz");
}

test "parse flow style map" {
    const input =
        \\foo: bar
        \\baz: fizz
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "foo");
    try expectString(m.values[0].value.?, "bar");
    try expectString(m.values[1].key.?, "baz");
    try expectString(m.values[1].value.?, "fizz");
}

test "parse flow style mixed" {
    const input =
        \\foo:
        \\  - bar
        \\  - baz
        \\  - fizz: buzz
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "foo");
    const seq = try expectSequence(mv.value.?);
    try testing.expectEqual(@as(usize, 3), seq.values.len);
    try expectString(seq.values[0], "bar");
    try expectString(seq.values[1], "baz");
    const inner_mv = try expectMappingValue(seq.values[2]);
    try expectString(inner_mv.key.?, "fizz");
    try expectString(inner_mv.value.?, "buzz");
}

test "parse map with comment nodes" {
    const input =
        \\# commentA
        \\a: #commentB
        \\  # commentC
        \\  b: c # commentD
        \\  # commentE
        \\  d: e # commentF
        \\  # commentG
        \\  f: g # commentH
        \\# commentI
        \\f: g # commentJ
        \\# commentK
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "a");
    try testing.expect(m.values[0].node_comment != null);
    const a_inner = try expectMapping(m.values[0].value.?);
    try testing.expectEqual(@as(usize, 3), a_inner.values.len);
    try expectString(a_inner.values[0].key.?, "b");
    try expectString(a_inner.values[0].value.?, "c");
    try testing.expect(a_inner.values[0].node_comment != null);
    try expectString(a_inner.values[1].key.?, "d");
    try expectString(a_inner.values[1].value.?, "e");
    try testing.expect(a_inner.values[1].node_comment != null);
    try expectString(a_inner.values[2].key.?, "f");
    try expectString(a_inner.values[2].value.?, "g");
    try testing.expect(a_inner.values[2].node_comment != null);
    try expectString(m.values[1].key.?, "f");
    try expectString(m.values[1].value.?, "g");
    try testing.expect(m.values[1].node_comment != null);
}

test "parse sequence comment nodes" {
    const input =
        \\# commentA
        \\- a # commentB
        \\# commentC
        \\- b: # commentD
        \\  # commentE
        \\  - d # commentF
        \\  - e # commentG
        \\# commentH
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const seq = try expectSequence(body);
    try testing.expectEqual(@as(usize, 2), seq.values.len);
    try expectString(seq.values[0], "a");
    const mv = try expectMappingValue(seq.values[1]);
    try expectString(mv.key.?, "b");
    const inner_seq = try expectSequence(mv.value.?);
    try testing.expectEqual(@as(usize, 2), inner_seq.values.len);
    try expectString(inner_seq.values[0], "d");
    try expectString(inner_seq.values[1], "e");
}

test "parse anchor alias with comments" {
    const input =
        \\a: &x b # commentA
        \\c: *x # commentB
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "a");
    const anc = try expectAnchor(m.values[0].value.?);
    try testing.expectEqualStrings("x", anc.name);
    try expectString(anc.value.?, "b");
    try testing.expect(m.values[0].node_comment != null);
    try expectString(m.values[1].key.?, "c");
    const ali = try expectAlias(m.values[1].value.?);
    try testing.expectEqualStrings("x", ali.name);
    try testing.expect(m.values[1].node_comment != null);
}

test "parse multiline comment" {
    const input =
        \\# foo comment
        \\# foo comment2
        \\foo: # map key comment
        \\  # bar above comment
        \\  # bar above comment2
        \\  bar: 10 # comment for bar
        \\  # baz above comment
        \\  # baz above comment2
        \\  baz: bbbb # comment for baz
        \\  piyo: # sequence key comment
        \\  # sequence1 above comment 1
        \\  # sequence1 above comment 2
        \\  - sequence1 # sequence1
        \\  # sequence2 above comment 1
        \\  # sequence2 above comment 2
        \\  - sequence2 # sequence2
        \\  # sequence3 above comment 1
        \\  # sequence3 above comment 2
        \\  - false # sequence3
        \\# foo2 comment
        \\# foo2 comment2
        \\foo2: &anchor text # anchor comment
        \\# foo3 comment
        \\# foo3 comment2
        \\foo3: *anchor # alias comment
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 3), m.values.len);
    try expectString(m.values[0].key.?, "foo");
    try testing.expect(m.values[0].node_comment != null);
    const foo_inner = try expectMapping(m.values[0].value.?);
    try testing.expectEqual(@as(usize, 3), foo_inner.values.len);
    try expectString(foo_inner.values[0].key.?, "bar");
    try expectInteger(foo_inner.values[0].value.?, 10);
    try expectString(foo_inner.values[1].key.?, "baz");
    try expectString(foo_inner.values[1].value.?, "bbbb");
    try expectString(foo_inner.values[2].key.?, "piyo");
    try expectString(m.values[1].key.?, "foo2");
    try testing.expect(m.values[1].node_comment != null);
    const anc = try expectAnchor(m.values[1].value.?);
    try testing.expectEqualStrings("anchor", anc.name);
    try expectString(anc.value.?, "text");
    try expectString(m.values[2].key.?, "foo3");
    try testing.expect(m.values[2].node_comment != null);
    const ali = try expectAlias(m.values[2].value.?);
    try testing.expectEqualStrings("anchor", ali.name);
}

test "parse flow map with inline key comment" {
    const input =
        \\elem1:
        \\  - elem2: # comment
        \\      {a: b, c: d}
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "elem1");
    const seq = try expectSequence(mv.value.?);
    try testing.expectEqual(@as(usize, 1), seq.values.len);
    const inner_mv = try expectMappingValue(seq.values[0]);
    try expectString(inner_mv.key.?, "elem2");
    const inner_m = try expectMapping(inner_mv.value.?);
    try testing.expect(inner_m.is_flow);
    try testing.expectEqual(@as(usize, 2), inner_m.values.len);
    try expectString(inner_m.values[0].key.?, "a");
    try expectString(inner_m.values[0].value.?, "b");
}

test "parse flow seq with inline key comment" {
    const input =
        \\elem1:
        \\  - elem2: # comment
        \\      [a, b, c, d]
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "elem1");
    const seq = try expectSequence(mv.value.?);
    try testing.expectEqual(@as(usize, 1), seq.values.len);
    const inner_mv = try expectMappingValue(seq.values[0]);
    try expectString(inner_mv.key.?, "elem2");
    const inner_seq = try expectSequence(inner_mv.value.?);
    try testing.expect(inner_seq.is_flow);
    try testing.expectEqual(@as(usize, 4), inner_seq.values.len);
    try expectString(inner_seq.values[0], "a");
    try expectString(inner_seq.values[1], "b");
}

test "parse flow map with inline value comment" {
    const input =
        \\a:
        \\  b: {} # comment
        \\c: d
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "a");
    const a_inner = try expectMappingValue(m.values[0].value.?);
    try expectString(a_inner.key.?, "b");
    const inner_m = try expectMapping(a_inner.value.?);
    try testing.expect(inner_m.is_flow);
    try testing.expectEqual(@as(usize, 0), inner_m.values.len);
    try testing.expect(m.values[0].node_comment != null);
    try expectString(m.values[1].key.?, "c");
    try expectString(m.values[1].value.?, "d");
}

test "parse flow array with inline value comment" {
    const input =
        \\a:
        \\  b: [] # comment
        \\c: d
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const m = try expectMapping(body);
    try testing.expectEqual(@as(usize, 2), m.values.len);
    try expectString(m.values[0].key.?, "a");
    const a_inner = try expectMappingValue(m.values[0].value.?);
    try expectString(a_inner.key.?, "b");
    const inner_seq = try expectSequence(a_inner.value.?);
    try testing.expect(inner_seq.is_flow);
    try testing.expectEqual(@as(usize, 0), inner_seq.values.len);
    try testing.expect(m.values[0].node_comment != null);
    try expectString(m.values[1].key.?, "c");
    try expectString(m.values[1].value.?, "d");
}

test "parse literal with comment" {
    const input =
        \\foo: | # comment
        \\  x: 42
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "foo");
    try expectNodeType(mv.value.?, .literal);
    const lit = try expectLiteral(mv.value.?);
    try testing.expectEqualStrings("x: 42\n", lit.value);
}

test "parse folded with comment" {
    const input =
        \\foo: > # comment
        \\  x: 42
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "foo");
    try expectNodeType(mv.value.?, .literal);
    const lit = try expectLiteral(mv.value.?);
    try testing.expectEqualStrings("x: 42\n", lit.value);
}

test "parse unattached comment" {
    const input =
        \\# This comment is in its own document
        \\---
        \\a: b
        \\
    ;
    var doc = try testParse(input);
    defer doc.deinit();
    const body = doc.body orelse return error.TestExpectedValue;
    const mv = try expectMappingValue(body);
    try expectString(mv.key.?, "a");
    try expectString(mv.value.?, "b");
}

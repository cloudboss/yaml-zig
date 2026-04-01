//! YAML abstract syntax tree types.
//!
//! These types represent the parsed structure of a YAML document. Use
//! `parser.parse` or `parser.parseAll` to produce them, and `emitter.emit`
//! to serialize them back to YAML text.

const std = @import("std");

const Token = @import("token.zig").Token;

/// A single YAML document, optionally backed by an arena allocator.
///
/// When returned by `parser.parse`, the arena owns all AST nodes and tokens.
/// Call `deinit()` to free everything.
pub const Document = struct {
    arena: ?std.heap.ArenaAllocator = null,
    /// The root AST node of the document, or null for an empty document.
    body: ?*Node = null,

    /// Free all memory owned by this document.
    pub fn deinit(self: *Document) void {
        if (self.arena) |*a| {
            a.deinit();
        }
    }
};

/// A stream of multiple YAML documents from a single input.
///
/// Returned by `parser.parseAll`. Call `deinit()` to free everything.
pub const Stream = struct {
    arena: ?std.heap.ArenaAllocator = null,
    /// The documents in the stream, in order.
    docs: []Document = &.{},

    /// Free all memory owned by this stream.
    pub fn deinit(self: *Stream) void {
        if (self.arena) |*a| {
            a.deinit();
        }
    }
};

/// Discriminator for the `Node` tagged union.
pub const NodeType = enum {
    document,
    null_value,
    boolean,
    integer,
    float_value,
    infinity,
    nan,
    string,
    literal,
    mapping,
    mapping_value,
    mapping_key,
    sequence,
    anchor,
    alias,
    directive,
    tag,
    comment,
    comment_group,
    merge_key,
};

/// A tagged union representing any YAML AST node.
///
/// Each variant holds a node-specific struct with a `token` pointer back to
/// the source, an optional `node_comment`, a `path` string, and
/// variant-specific data (e.g. `value` for scalars, `values` for collections).
pub const Node = union(NodeType) {
    document: DocumentNode,
    null_value: NullNode,
    boolean: BoolNode,
    integer: IntegerNode,
    float_value: FloatNode,
    infinity: InfinityNode,
    nan: NanNode,
    string: StringNode,
    literal: LiteralNode,
    mapping: MappingNode,
    mapping_value: MappingValueNode,
    mapping_key: MappingKeyNode,
    sequence: SequenceNode,
    anchor: AnchorNode,
    alias: AliasNode,
    directive: DirectiveNode,
    tag: TagNode,
    comment: CommentNode,
    comment_group: CommentGroupNode,
    merge_key: MergeKeyNode,

    /// Return the source token for this node, if any.
    pub fn getToken(self: Node) ?*const Token {
        return switch (self) {
            inline else => |n| n.token,
        };
    }

    /// Return the comment group attached to this node, if any.
    pub fn getComment(self: Node) ?*const CommentGroupNode {
        return switch (self) {
            inline else => |n| if (@hasField(
                @TypeOf(n),
                "node_comment",
            )) n.node_comment else null,
        };
    }

    /// Return the dotted key path to this node (e.g. `"a.b.c"`), or empty string.
    pub fn getPath(self: Node) []const u8 {
        return switch (self) {
            inline else => |n| if (@hasField(
                @TypeOf(n),
                "path",
            )) n.path else "",
        };
    }
};

pub const DocumentNode = struct {
    token: ?*const Token = null,
    node_comment: ?*const CommentGroupNode = null,
    path: []const u8 = "",
    body: ?*const Node = null,
};

pub const NullNode = struct {
    token: ?*const Token = null,
    node_comment: ?*const CommentGroupNode = null,
    path: []const u8 = "",
};

pub const BoolNode = struct {
    token: ?*const Token = null,
    node_comment: ?*const CommentGroupNode = null,
    path: []const u8 = "",
    value: bool = false,
};

pub const IntegerNode = struct {
    token: ?*const Token = null,
    node_comment: ?*const CommentGroupNode = null,
    path: []const u8 = "",
    value: i64 = 0,
};

pub const FloatNode = struct {
    token: ?*const Token = null,
    node_comment: ?*const CommentGroupNode = null,
    path: []const u8 = "",
    value: f64 = 0,
    precision: u8 = 0,
};

pub const InfinityNode = struct {
    token: ?*const Token = null,
    node_comment: ?*const CommentGroupNode = null,
    path: []const u8 = "",
    negative: bool = false,
};

pub const NanNode = struct {
    token: ?*const Token = null,
    node_comment: ?*const CommentGroupNode = null,
    path: []const u8 = "",
};

pub const StringNode = struct {
    token: ?*const Token = null,
    node_comment: ?*const CommentGroupNode = null,
    path: []const u8 = "",
    value: []const u8 = "",
};

pub const LiteralNode = struct {
    token: ?*const Token = null,
    node_comment: ?*const CommentGroupNode = null,
    path: []const u8 = "",
    value: []const u8 = "",
    block_style: BlockScalarStyle = .literal,
    chomping: ChompingStyle = .clip,
};

/// Block scalar style: `|` (literal) preserves newlines, `>` (folded) joins lines.
pub const BlockScalarStyle = enum {
    /// `|` — preserves newlines as-is.
    literal,
    /// `>` — folds newlines into spaces.
    folded,
};

/// Block scalar chomping indicator controlling trailing newlines.
pub const ChompingStyle = enum {
    /// Default: single trailing newline.
    clip,
    /// `-` suffix: strip all trailing newlines.
    strip,
    /// `+` suffix: keep all trailing newlines.
    keep,
};

pub const MappingNode = struct {
    token: ?*const Token = null,
    node_comment: ?*const CommentGroupNode = null,
    path: []const u8 = "",
    values: []const *const MappingValueNode = &.{},
    is_flow: bool = false,
};

pub const MappingValueNode = struct {
    token: ?*const Token = null,
    node_comment: ?*const CommentGroupNode = null,
    path: []const u8 = "",
    key: ?*const Node = null,
    value: ?*const Node = null,
};

pub const MappingKeyNode = struct {
    token: ?*const Token = null,
    node_comment: ?*const CommentGroupNode = null,
    path: []const u8 = "",
    value: ?*const Node = null,
};

pub const SequenceNode = struct {
    token: ?*const Token = null,
    node_comment: ?*const CommentGroupNode = null,
    path: []const u8 = "",
    values: []const *const Node = &.{},
    is_flow: bool = false,
};

pub const AnchorNode = struct {
    token: ?*const Token = null,
    node_comment: ?*const CommentGroupNode = null,
    path: []const u8 = "",
    name: []const u8 = "",
    value: ?*const Node = null,
};

pub const AliasNode = struct {
    token: ?*const Token = null,
    node_comment: ?*const CommentGroupNode = null,
    path: []const u8 = "",
    name: []const u8 = "",
};

pub const DirectiveNode = struct {
    token: ?*const Token = null,
    node_comment: ?*const CommentGroupNode = null,
    path: []const u8 = "",
    value: []const u8 = "",
};

pub const TagNode = struct {
    token: ?*const Token = null,
    node_comment: ?*const CommentGroupNode = null,
    path: []const u8 = "",
    value: ?*const Node = null,
    tag: []const u8 = "",
};

pub const CommentNode = struct {
    token: ?*const Token = null,
    value: []const u8 = "",
};

pub const CommentGroupNode = struct {
    token: ?*const Token = null,
    comments: []const *const CommentNode = &.{},
};

pub const MergeKeyNode = struct {
    token: ?*const Token = null,
    node_comment: ?*const CommentGroupNode = null,
    path: []const u8 = "",
};

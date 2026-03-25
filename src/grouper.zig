const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;

pub const TokenGroupType = enum {
    document,
    directive,
    anchor,
    alias,
    literal,
    folded,
    scalar_tag,
    map_key,
    map_key_value,
    line_comment,
    head_comment,
    foot_comment,
    comment_only,
};

pub const TokenGroup = struct {
    group_type: TokenGroupType,
    tokens: []const *const Token = &.{},
};

pub fn createGroupedTokens(allocator: Allocator, tokens: []const Token) ![]TokenGroup {
    _ = allocator;
    _ = tokens;
    return error.Unimplemented;
}

fn makeToken(tt: TokenType, value: []const u8) Token {
    return .{ .token_type = tt, .value = value };
}

test "group simple document" {
    const tokens = [_]Token{
        makeToken(.document_header, "---"),
        makeToken(.string, "hello"),
    };
    const groups = try createGroupedTokens(testing.allocator, &tokens);
    try testing.expectEqual(@as(usize, 1), groups.len);
    try testing.expectEqual(TokenGroupType.document, groups[0].group_type);
}

test "group anchor tokens" {
    const tokens = [_]Token{
        makeToken(.anchor, "ref"),
        makeToken(.string, "value"),
    };
    const groups = try createGroupedTokens(testing.allocator, &tokens);
    try testing.expectEqual(@as(usize, 1), groups.len);
    try testing.expectEqual(TokenGroupType.anchor, groups[0].group_type);
}

test "group map key value" {
    const tokens = [_]Token{
        makeToken(.string, "key"),
        makeToken(.mapping_value, ":"),
        makeToken(.string, "value"),
    };
    const groups = try createGroupedTokens(testing.allocator, &tokens);
    try testing.expectEqual(@as(usize, 1), groups.len);
    try testing.expectEqual(TokenGroupType.map_key_value, groups[0].group_type);
}

test "group literal block" {
    const tokens = [_]Token{
        makeToken(.string, "key"),
        makeToken(.mapping_value, ":"),
        makeToken(.literal, "|"),
        makeToken(.string, "text"),
    };
    const groups = try createGroupedTokens(testing.allocator, &tokens);
    try testing.expectEqual(@as(usize, 2), groups.len);
    try testing.expectEqual(TokenGroupType.map_key_value, groups[0].group_type);
    try testing.expectEqual(TokenGroupType.literal, groups[1].group_type);
}

test "group directive" {
    const tokens = [_]Token{
        makeToken(.directive, "%YAML 1.2"),
        makeToken(.document_header, "---"),
    };
    const groups = try createGroupedTokens(testing.allocator, &tokens);
    try testing.expectEqual(@as(usize, 2), groups.len);
    try testing.expectEqual(TokenGroupType.directive, groups[0].group_type);
    try testing.expectEqual(TokenGroupType.document, groups[1].group_type);
}

test "group comment tokens" {
    const tokens = [_]Token{
        makeToken(.comment, "# a comment"),
        makeToken(.string, "key"),
        makeToken(.mapping_value, ":"),
        makeToken(.string, "value"),
    };
    const groups = try createGroupedTokens(testing.allocator, &tokens);
    try testing.expectEqual(@as(usize, 2), groups.len);
    try testing.expectEqual(TokenGroupType.head_comment, groups[0].group_type);
    try testing.expectEqual(TokenGroupType.map_key_value, groups[1].group_type);
}

test "group tag tokens" {
    const tokens = [_]Token{
        makeToken(.tag, "!!str"),
        makeToken(.string, "value"),
    };
    const groups = try createGroupedTokens(testing.allocator, &tokens);
    try testing.expectEqual(@as(usize, 1), groups.len);
    try testing.expectEqual(TokenGroupType.scalar_tag, groups[0].group_type);
}

test "group alias tokens" {
    const tokens = [_]Token{
        makeToken(.alias, "ref"),
    };
    const groups = try createGroupedTokens(testing.allocator, &tokens);
    try testing.expectEqual(@as(usize, 1), groups.len);
    try testing.expectEqual(TokenGroupType.alias, groups[0].group_type);
}

test "group empty token list" {
    const groups = try createGroupedTokens(testing.allocator, &.{});
    try testing.expectEqual(@as(usize, 0), groups.len);
}

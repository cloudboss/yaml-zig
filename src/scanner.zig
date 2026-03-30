const std = @import("std");
const Allocator = std.mem.Allocator;

const token_mod = @import("token.zig");
const Token = token_mod.Token;
const TokenType = token_mod.TokenType;

const Buf = std.ArrayListUnmanaged(u8);
const LineBuf = std.ArrayListUnmanaged([]const u8);

pub const Scanner = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    source: []const u8,
    pos: usize,
    line: u32,
    column: u32,
    flow_level: u32,
    tokens: std.ArrayListUnmanaged(Token),
    line_indent: u32 = 0,
    flow_indent: u32 = 0,
    at_line_start: bool = true,
    token_line: u32 = 1,
    token_column: u32 = 0,
    token_offset: u32 = 0,
    token_indent: u32 = 0,
    last_key_indent: u32 = 0,
    block_indent: ?u32 = null,
    tag_directives: std.StringHashMapUnmanaged([]const u8) = .empty,
    pending_tag_directives: std.StringHashMapUnmanaged([]const u8) = .empty,
    has_pending_tags: bool = false,

    pub fn init(allocator: Allocator, source: []const u8) Scanner {
        const arena = std.heap.ArenaAllocator.init(allocator);
        return .{
            .allocator = allocator,
            .arena = arena,
            .source = source,
            .pos = 0,
            .line = 1,
            .column = 0,
            .flow_level = 0,
            .tokens = .empty,
            .line_indent = 0,
            .at_line_start = true,
        };
    }

    pub fn deinit(self: *Scanner) void {
        self.arena.deinit();
    }

    fn a(self: *Scanner) Allocator {
        return self.arena.allocator();
    }

    pub fn scan(self: *Scanner) ![]Token {
        while (self.pos < self.source.len) {
            try self.skipWhitespaceAndNewlines();
            if (self.pos >= self.source.len) break;
            self.token_line = self.line;
            self.token_column = self.column;
            self.token_offset = @intCast(self.pos);
            self.token_indent = self.line_indent;
            const c = self.source[self.pos];

            if (c == '%' and self.column == 0) {
                try self.scanDirective();
            } else if (c == '-' and self.column == 0 and self.matchDocMarker("---")) {
                // Document markers are invalid inside flow collections.
                if (self.flow_level > 0) return error.SyntaxError;
                self.activateTagDirectives();
                try self.addToken(.document_header, "---");
                self.advance(3);
                self.skipInlineWhitespace();
            } else if (c == '.' and self.column == 0 and self.matchDocMarker("...")) {
                // Document markers are invalid inside flow collections.
                if (self.flow_level > 0) return error.SyntaxError;
                try self.addToken(.document_end, "...");
                self.advance(3);
                self.skipInlineWhitespace();
                // Only comments or newlines are valid after document end marker.
                if (self.pos < self.source.len and !isNewline(self.source[self.pos]) and
                    self.source[self.pos] != '#')
                {
                    return error.SyntaxError;
                }
            } else if (c == '#' and (self.column == 0 or self.isPrecededByWhitespace())) {
                try self.scanComment();
            } else if (c == '#' and self.flow_level > 0 and
                self.lastTokenType() == .collect_entry)
            {
                // '#' immediately after ',' without whitespace is invalid.
                return error.SyntaxError;
            } else if (c == '\'') {
                try self.scanSingleQuoted();
            } else if (c == '"') {
                try self.scanDoubleQuoted();
            } else if (c == '{') {
                if (self.flow_level == 0) self.setFlowIndent();
                self.flow_level += 1;
                try self.addToken(.mapping_start, "{");
                self.advance(1);
            } else if (c == '}') {
                if (self.flow_level > 0) self.flow_level -= 1;
                try self.addToken(.mapping_end, "}");
                self.advance(1);
            } else if (c == '[') {
                if (self.flow_level == 0) self.setFlowIndent();
                self.flow_level += 1;
                try self.addToken(.sequence_start, "[");
                self.advance(1);
            } else if (c == ']') {
                if (self.flow_level > 0) self.flow_level -= 1;
                try self.addToken(.sequence_end, "]");
                self.advance(1);
            } else if (c == ',') {
                // Reject consecutive commas or leading comma in flow context.
                if (self.flow_level > 0) {
                    const last = self.lastTokenType();
                    if (last == .collect_entry or last == .sequence_start or
                        last == .mapping_start)
                    {
                        return error.SyntaxError;
                    }
                }
                try self.addToken(.collect_entry, ",");
                self.advance(1);
            } else if (c == '?' and (self.pos + 1 >= self.source.len or
                isWhitespaceOrNewline(self.source[self.pos + 1])))
            {
                try self.addToken(.mapping_key, "?");
                self.advance(1);
                if (self.flow_level == 0) try self.rejectTabAfterIndicator();
            } else if (c == ':' and self.isMappingValue()) {
                try self.addToken(.mapping_value, ":");
                self.advance(1);
                if (self.flow_level == 0) try self.rejectTabAfterIndicator();
            } else if (c == '-' and self.isSequenceEntry()) {
                try self.addToken(.sequence_entry, "-");
                self.advance(1);
                if (self.flow_level == 0) try self.rejectTabAfterIndicator();
            } else if (c == '|' or c == '>') {
                try self.scanBlockScalar();
            } else if (c == '&') {
                try self.scanAnchor();
            } else if (c == '*') {
                try self.scanAlias();
            } else if (c == '!') {
                try self.scanTag();
            } else if (c == '@' or c == '`') {
                return error.SyntaxError;
            } else {
                try self.scanPlainScalar();
            }
        }
        return self.tokens.items;
    }

    fn advance(self: *Scanner, n: usize) void {
        for (0..n) |_| {
            if (self.pos < self.source.len) {
                if (self.source[self.pos] == '\n') {
                    self.line += 1;
                    self.column = 0;
                } else if (self.source[self.pos] == '\r') {
                    self.line += 1;
                    self.column = 0;
                    if (self.pos + 1 < self.source.len and
                        self.source[self.pos + 1] == '\n')
                    {
                        self.pos += 1;
                    }
                } else {
                    self.column += 1;
                }
                self.pos += 1;
            }
        }
    }

    fn addToken(self: *Scanner, tt: TokenType, val: []const u8) !void {
        if (tt == .mapping_value) {
            // Track the key's column for multiline continuation. Use the
            // key token's column so that keys inside sequence entries like
            // `- key: value` get the correct continuation threshold.
            if (self.tokens.items.len > 0) {
                const prev = self.tokens.items[self.tokens.items.len - 1];
                // For explicit keys (preceded by '?'), the mapping indent is
                // the line indent where ':' appears, not the key's column.
                self.last_key_indent = if (self.hasExplicitKeyBefore())
                    self.line_indent
                else
                    prev.position.column;
            }
            // In block context, quoted continuations must indent past the key.
            self.block_indent = if (self.flow_level == 0)
                self.last_key_indent
            else
                null;
        } else if (tt != .comment) {
            self.block_indent = null;
        }
        try self.tokens.append(self.a(), .{
            .token_type = tt,
            .value = val,
            .position = .{
                .line = self.token_line,
                .column = self.token_column,
                .offset = self.token_offset,
                .indent_num = self.token_indent,
            },
        });
    }

    fn addTokenWithOrigin(
        self: *Scanner,
        tt: TokenType,
        val: []const u8,
        origin: []const u8,
    ) !void {
        try self.tokens.append(self.a(), .{
            .token_type = tt,
            .value = val,
            .origin = origin,
            .position = .{
                .line = self.token_line,
                .column = self.token_column,
                .offset = self.token_offset,
                .indent_num = self.token_indent,
            },
        });
    }

    fn bufAppend(self: *Scanner, buf: *Buf, ch: u8) !void {
        try buf.append(self.a(), ch);
    }

    fn bufAppendSlice(self: *Scanner, buf: *Buf, slice: []const u8) !void {
        try buf.appendSlice(self.a(), slice);
    }

    fn lineAppend(self: *Scanner, lines: *LineBuf, val: []const u8) !void {
        try lines.append(self.a(), val);
    }

    fn isWhitespace(c: u8) bool {
        return c == ' ' or c == '\t';
    }

    fn isNewline(c: u8) bool {
        return c == '\n' or c == '\r';
    }

    fn isWhitespaceOrNewline(c: u8) bool {
        return isWhitespace(c) or isNewline(c);
    }

    fn isFlowIndicator(c: u8) bool {
        return c == '{' or c == '}' or c == '[' or c == ']' or c == ',';
    }

    fn isPrecededByWhitespace(self: *Scanner) bool {
        if (self.pos == 0) return true;
        const prev = self.source[self.pos - 1];
        return isWhitespace(prev) or isNewline(prev);
    }

    fn skipWhitespaceAndNewlines(self: *Scanner) !void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (isNewline(c)) {
                self.advance(1);
                self.at_line_start = true;
                self.line_indent = 0;
            } else if (isWhitespace(c)) {
                if (self.at_line_start and c == '\t' and self.flow_level == 0) {
                    // Tabs are never valid as indentation in block YAML.
                    // Allow on blank lines, after spaces (separation), and
                    // before flow indicators/comments at column 0.
                    var p = self.pos;
                    while (p < self.source.len and isWhitespace(self.source[p]))
                        p += 1;
                    const is_blank = p >= self.source.len or isNewline(self.source[p]);
                    if (!is_blank and self.line_indent == 0) {
                        const nc = self.source[p];
                        if (nc != '{' and nc != '}' and nc != '[' and
                            nc != ']' and nc != '#')
                        {
                            return error.TabInIndent;
                        }
                    }
                }
                if (self.at_line_start and c == ' ') {
                    self.line_indent += 1;
                }
                self.advance(1);
            } else {
                // In flow context, reject content that is not indented
                // past the block indent where the flow started.
                if (self.at_line_start and self.flow_level > 0 and
                    self.line_indent < self.flow_indent and
                    c != ']' and c != '}')
                {
                    return error.SyntaxError;
                }
                self.at_line_start = false;
                break;
            }
        }
    }

    /// Set the minimum indent for flow content. If the flow indicator
    /// is the first token on its line, content may be at the same indent.
    /// Otherwise, content must be indented past the current block indent.
    fn setFlowIndent(self: *Scanner) void {
        if (self.column == self.line_indent)
            self.flow_indent = self.line_indent
        else
            self.flow_indent = self.line_indent + 1;
    }

    fn skipInlineWhitespace(self: *Scanner) void {
        while (self.pos < self.source.len and isWhitespace(self.source[self.pos])) {
            self.advance(1);
        }
    }

    /// Reject a tab after a block indicator when it precedes another
    /// block indicator or mapping key. Only called in block context.
    fn rejectTabAfterIndicator(self: *Scanner) !void {
        var p = self.pos;
        var has_tab = false;
        while (p < self.source.len and
            (self.source[p] == ' ' or self.source[p] == '\t'))
        {
            if (self.source[p] == '\t') has_tab = true;
            p += 1;
        }
        if (!has_tab) return;
        if (p >= self.source.len or isNewline(self.source[p])) return;
        const nc = self.source[p];
        // Tab before another block indicator is invalid indentation.
        if (nc == '-' or nc == '?') {
            if (p + 1 >= self.source.len or
                isWhitespaceOrNewline(self.source[p + 1]))
            {
                return error.TabInIndent;
            }
        }
        // Tab before a mapping key (text followed by ':') is invalid.
        if (!isFlowIndicator(nc) and nc != '#') {
            var q = p;
            while (q < self.source.len and !isNewline(self.source[q])) {
                if (self.source[q] == ':') {
                    if (q + 1 >= self.source.len or
                        isWhitespaceOrNewline(self.source[q + 1]))
                    {
                        return error.TabInIndent;
                    }
                }
                q += 1;
            }
        }
    }

    fn matchDocMarker(self: *Scanner, marker: []const u8) bool {
        if (self.pos + marker.len > self.source.len) return false;
        if (!std.mem.eql(u8, self.source[self.pos .. self.pos + marker.len], marker))
            return false;
        if (self.pos + marker.len >= self.source.len) return true;
        const after = self.source[self.pos + marker.len];
        return isWhitespaceOrNewline(after);
    }

    fn isMappingValue(self: *Scanner) bool {
        if (self.flow_level > 0) {
            if (self.pos + 1 >= self.source.len) return true;
            const next = self.source[self.pos + 1];
            const standard = next != ':' and (isWhitespace(next) or isNewline(next) or
                isFlowIndicator(next) or next == '"' or next == '\'' or
                next == '!' or next == '&' or next == '*');
            if (standard) return true;
            // JSON-like keys: ':' after quote/flow-end is a value indicator.
            if (self.pos > 0) {
                const prev = self.source[self.pos - 1];
                if (prev == '"' or prev == '\'' or prev == ']' or prev == '}')
                    return true;
            }
            return false;
        }
        if (self.pos + 1 >= self.source.len) return true;
        const next = self.source[self.pos + 1];
        return isWhitespace(next) or isNewline(next);
    }

    fn isSequenceEntry(self: *Scanner) bool {
        if (self.pos + 1 >= self.source.len) return true;
        const next = self.source[self.pos + 1];
        return isWhitespace(next) or isNewline(next);
    }

    fn scanDirective(self: *Scanner) !void {
        const start = self.pos;
        while (self.pos < self.source.len and !isNewline(self.source[self.pos])) {
            self.advance(1);
        }
        const text = self.source[start..self.pos];
        if (text.len >= 4 and std.mem.eql(u8, text[0..4], "%TAG") and
            (text.len == 4 or isWhitespace(text[4])))
        {
            try self.registerTagDirective(text);
        } else if (text.len >= 5 and std.mem.eql(u8, text[0..5], "%YAML") and
            (text.len == 5 or isWhitespace(text[5])))
        {
            try self.validateYamlDirective(text);
        }
        try self.addToken(.directive, text);
    }

    fn validateYamlDirective(self: *Scanner, text: []const u8) !void {
        _ = self;
        var i: usize = 5;
        while (i < text.len and isWhitespace(text[i])) i += 1;
        const ver_start = i;
        while (i < text.len and !isWhitespace(text[i]) and text[i] != '#') i += 1;
        const ver = text[ver_start..i];
        if (ver.len == 0) return error.SyntaxError;
        for (ver) |vc| {
            if (vc != '.' and !std.ascii.isDigit(vc)) return error.SyntaxError;
        }
        const after_ver = i;
        while (i < text.len and isWhitespace(text[i])) i += 1;
        if (i < text.len and text[i] == '#' and i == after_ver)
            return error.SyntaxError;
        if (i < text.len and text[i] != '#') return error.SyntaxError;
    }

    fn registerTagDirective(self: *Scanner, text: []const u8) !void {
        var i: usize = 4;
        while (i < text.len and isWhitespace(text[i])) i += 1;
        if (i >= text.len or text[i] != '!') return error.SyntaxError;
        const handle_start = i;
        i += 1;
        // Named handles: !name! — scan until second '!'.
        if (i < text.len and text[i] != ' ') {
            while (i < text.len and text[i] != '!') i += 1;
            if (i >= text.len) return error.SyntaxError;
            i += 1; // consume closing '!'.
        }
        const handle = text[handle_start..i];
        while (i < text.len and isWhitespace(text[i])) i += 1;
        if (i >= text.len) return error.SyntaxError;
        const prefix_start = i;
        while (i < text.len and !isWhitespace(text[i])) i += 1;
        const prefix = text[prefix_start..i];
        try self.pending_tag_directives.put(self.a(), handle, prefix);
        self.has_pending_tags = true;
    }

    fn scanComment(self: *Scanner) !void {
        self.advance(1); // skip #
        const start = self.pos;
        while (self.pos < self.source.len and !isNewline(self.source[self.pos])) {
            self.advance(1);
        }
        try self.addToken(.comment, self.source[start..self.pos]);
    }

    fn scanSingleQuoted(self: *Scanner) !void {
        self.advance(1); // skip opening '
        var buf: Buf = .empty;
        var closed = false;
        while (self.pos < self.source.len) {
            // Document markers at column 0 terminate the quoted scalar.
            if (self.column == 0 and self.looksLikeDocMarker()) return error.SyntaxError;
            const c = self.source[self.pos];
            if (c == '\'') {
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '\'') {
                    try self.bufAppend(&buf, '\'');
                    self.advance(2);
                } else {
                    self.advance(1);
                    closed = true;
                    break;
                }
            } else {
                try self.bufAppend(&buf, c);
                self.advance(1);
            }
        }
        if (!closed) return error.UnexpectedEof;
        try self.addToken(.single_quote, buf.items);
    }

    fn scanDoubleQuoted(self: *Scanner) !void {
        self.advance(1); // skip opening "
        var buf: Buf = .empty;
        var closed = false;
        while (self.pos < self.source.len) {
            // Document markers at column 0 terminate the quoted scalar.
            if (self.column == 0 and self.looksLikeDocMarker()) return error.SyntaxError;
            const c = self.source[self.pos];
            if (c == '"') {
                self.advance(1);
                closed = true;
                break;
            } else if (c == '\\') {
                if (self.pos + 1 < self.source.len) {
                    const next = self.source[self.pos + 1];
                    if (isNewline(next)) {
                        self.advance(1); // skip backslash
                        self.advance(1); // skip newline
                        while (self.pos < self.source.len and
                            isWhitespace(self.source[self.pos]))
                            self.advance(1);
                    } else {
                        self.advance(1); // skip backslash
                        try self.appendEscapeChar(&buf, next);
                        self.advance(1);
                    }
                } else {
                    try self.bufAppend(&buf, c);
                    self.advance(1);
                }
            } else if (isNewline(c)) {
                self.advance(1);
                var blank_lines: usize = 0;
                while (self.pos < self.source.len) {
                    while (self.pos < self.source.len and
                        isWhitespace(self.source[self.pos]))
                        self.advance(1);
                    if (self.pos < self.source.len and isNewline(self.source[self.pos])) {
                        blank_lines += 1;
                        self.advance(1);
                    } else {
                        break;
                    }
                }
                try self.validateQuotedContinuation();
                if (blank_lines > 0) {
                    for (0..blank_lines) |_| try self.bufAppend(&buf, '\n');
                } else {
                    try self.bufAppend(&buf, ' ');
                }
            } else {
                try self.bufAppend(&buf, c);
                self.advance(1);
            }
        }
        if (!closed) return error.UnexpectedEof;
        try self.addToken(.double_quote, buf.items);
    }

    /// Validate that a quoted scalar continuation line is properly indented
    /// relative to the enclosing block mapping key.
    fn validateQuotedContinuation(self: *Scanner) !void {
        const indent = self.block_indent orelse return;
        if (self.pos >= self.source.len) return;
        // Count leading spaces from the start of the line. Tabs don't count
        // as indentation, so only spaces contribute to the indent level.
        const line_start = self.findLineStart();
        var spaces: u32 = 0;
        for (self.source[line_start..self.pos]) |ch| {
            if (ch == ' ') {
                spaces += 1;
            } else break;
        }
        if (spaces <= indent) return error.SyntaxError;
    }

    fn findLineStart(self: *Scanner) usize {
        var i = self.pos;
        while (i > 0) {
            if (self.source[i - 1] == '\n' or self.source[i - 1] == '\r') break;
            i -= 1;
        }
        return i;
    }

    fn appendEscapeChar(self: *Scanner, buf: *Buf, c: u8) !void {
        switch (c) {
            'n' => try self.bufAppend(buf, '\n'),
            't' => try self.bufAppend(buf, '\t'),
            'r' => try self.bufAppend(buf, '\r'),
            '\\' => try self.bufAppend(buf, '\\'),
            '"' => try self.bufAppend(buf, '"'),
            '0' => try self.bufAppend(buf, 0),
            'a' => try self.bufAppend(buf, 0x07),
            'b' => try self.bufAppend(buf, 0x08),
            'f' => try self.bufAppend(buf, 0x0C),
            'v' => try self.bufAppend(buf, 0x0B),
            'e' => try self.bufAppend(buf, 0x1B),
            ' ', '\t' => try self.bufAppend(buf, c),
            '/' => try self.bufAppend(buf, '/'),
            'N', '_', 'L', 'P' => {
                // Unicode escapes handled by decoder.
                try self.bufAppend(buf, '\\');
                try self.bufAppend(buf, c);
            },
            'x', 'u', 'U' => {
                // Hex/unicode escapes handled by decoder.
                try self.bufAppend(buf, '\\');
                try self.bufAppend(buf, c);
            },
            else => return error.SyntaxError,
        }
    }

    fn scanBlockScalar(self: *Scanner) !void {
        const is_literal = self.source[self.pos] == '|';
        const tt: TokenType = if (is_literal) .literal else .folded;
        const header_start = self.pos;
        // Check if a document header precedes this block scalar.
        const after_doc_header = self.lastTokenType() == .document_header;
        self.advance(1);

        var chomp: enum { clip, strip, keep } = .clip;
        var explicit_indent: ?u32 = null;

        while (self.pos < self.source.len and
            !isNewline(self.source[self.pos]) and
            !isWhitespace(self.source[self.pos]) and
            self.source[self.pos] != '#')
        {
            const c = self.source[self.pos];
            if (c == '-') {
                chomp = .strip;
                self.advance(1);
            } else if (c == '+') {
                chomp = .keep;
                self.advance(1);
            } else if (c >= '1' and c <= '9') {
                explicit_indent = c - '0';
                self.advance(1);
            } else {
                return error.SyntaxError;
            }
        }

        const header_val = self.source[header_start..self.pos];
        try self.addToken(tt, header_val);

        // A comment after the header requires preceding whitespace.
        if (self.pos < self.source.len and self.source[self.pos] == '#') {
            return error.SyntaxError;
        }
        self.skipInlineWhitespace();
        if (self.pos < self.source.len and self.source[self.pos] == '#') {
            try self.scanComment();
        }

        // Reject non-comment, non-newline content after the header.
        if (self.pos < self.source.len and !isNewline(self.source[self.pos])) {
            return error.SyntaxError;
        }

        if (self.pos < self.source.len and isNewline(self.source[self.pos])) {
            self.advance(1);
            self.at_line_start = true;
            self.line_indent = 0;
        } else {
            return;
        }

        var content_lines: LineBuf = .empty;
        var trailing_blank_lines: usize = 0;
        var has_trailing_newline = false;
        var content_indent: ?u32 = null;

        if (explicit_indent) |ei| {
            content_indent = ei;
        }

        // Collect lines: each iteration processes one line
        // pending_blanks tracks blank lines seen since last content line
        var pending_blanks: usize = 0;

        while (self.pos < self.source.len) {
            // Count leading spaces. Tabs in indentation are invalid.
            var line_spaces: u32 = 0;
            var tmp_pos = self.pos;
            while (tmp_pos < self.source.len and self.source[tmp_pos] == ' ') {
                line_spaces += 1;
                tmp_pos += 1;
            }
            // Tabs in the indentation area of block scalar content are invalid.
            if (tmp_pos < self.source.len and self.source[tmp_pos] == '\t' and
                content_indent != null and line_spaces < content_indent.?)
            {
                return error.TabInIndent;
            }

            // Check if rest of line is blank (spaces/tabs before newline/EOF).
            var eol_check = tmp_pos;
            while (eol_check < self.source.len and
                isWhitespace(self.source[eol_check]))
            {
                eol_check += 1;
            }
            const at_eol = eol_check >= self.source.len or
                isNewline(self.source[eol_check]);

            // Before content_indent is known, blank lines are just pending.
            if (content_indent == null) {
                if (at_eol) {
                    // Reject tab-only indentation on blank lines.
                    if (line_spaces == 0 and tmp_pos < self.source.len and
                        self.source[tmp_pos] == '\t')
                    {
                        return error.TabInIndent;
                    }
                    pending_blanks += 1;
                    self.pos = tmp_pos;
                    if (self.pos < self.source.len) self.advance(1);
                    continue;
                }
                if (line_spaces == 0) {
                    // Zero-indent content is valid only when the block
                    // scalar follows a document header (--- >). Detect
                    // this by checking if a document_header token
                    // precedes the block scalar header.
                    if (after_doc_header) {
                        // Still stop at doc markers and comments.
                        if (tmp_pos < self.source.len and
                            (self.looksLikeDocMarkerAt(tmp_pos) or
                                self.source[tmp_pos] == '#'))
                        {
                            break;
                        }
                        content_indent = 0;
                    } else {
                        break;
                    }
                } else {
                    content_indent = line_spaces;
                }
            }

            const ci = content_indent.?;

            // Lines with < ci spaces that are blank → pending blank
            // Lines with < ci spaces that are NOT blank → end of block
            if (line_spaces < ci) {
                if (at_eol) {
                    pending_blanks += 1;
                    self.pos = tmp_pos;
                    if (self.pos < self.source.len) self.advance(1);
                    continue;
                }
                break;
            }

            // Lines with >= ci spaces: content line (even if only whitespace after indent)
            for (0..pending_blanks) |_| try self.lineAppend(&content_lines, "");
            pending_blanks = 0;

            self.pos += ci;
            self.column = ci;

            const content_start = self.pos;
            while (self.pos < self.source.len and !isNewline(self.source[self.pos])) {
                self.pos += 1;
                self.column += 1;
            }
            try self.lineAppend(&content_lines, self.source[content_start..self.pos]);

            if (self.pos < self.source.len) {
                self.advance(1);
                has_trailing_newline = true;
            } else {
                has_trailing_newline = false;
            }
        }

        // pending_blanks at end = trailing blank lines after last content
        trailing_blank_lines = pending_blanks;

        // Restore line-start state after block scalar processing.
        self.at_line_start = true;
        self.line_indent = 0;

        if (content_lines.items.len == 0) return;

        // Build raw (literal-style) content for round-trip of folded blocks.
        var raw_buf: Buf = .empty;
        for (content_lines.items, 0..) |line, idx| {
            if (idx > 0) try self.bufAppend(&raw_buf, '\n');
            try self.bufAppendSlice(&raw_buf, line);
        }

        var buf: Buf = .empty;

        if (is_literal) {
            for (content_lines.items, 0..) |line, idx| {
                if (idx > 0) try self.bufAppend(&buf, '\n');
                try self.bufAppendSlice(&buf, line);
            }
        } else {
            // Folded: same-indent lines joined with space,
            // more-indented lines preserve newlines.
            // Between each pair of lines, we add a separator:
            //   blank line → \n (already counted)
            //   either line more-indented → \n
            //   both normal → space
            for (content_lines.items, 0..) |line, idx| {
                if (idx > 0) {
                    const prev = content_lines.items[idx - 1];
                    const prev_blank = prev.len == 0;
                    const prev_mi = prev.len > 0 and prev[0] == ' ';
                    const cur_blank = line.len == 0;
                    const cur_mi = line.len > 0 and line[0] == ' ';

                    if (prev_blank or cur_blank) {
                        try self.bufAppend(&buf, '\n');
                    } else if (prev_mi or cur_mi) {
                        try self.bufAppend(&buf, '\n');
                    } else {
                        try self.bufAppend(&buf, ' ');
                    }
                }
                try self.bufAppendSlice(&buf, line);
            }
        }

        // Determine if the block had any trailing newline
        const had_newline = has_trailing_newline or trailing_blank_lines > 0 or
            content_lines.items.len > 1;

        // Apply chomping
        switch (chomp) {
            .clip => {
                while (buf.items.len > 0 and buf.items[buf.items.len - 1] == '\n')
                    buf.items.len -= 1;
                if (had_newline) try self.bufAppend(&buf, '\n');
            },
            .strip => {
                while (buf.items.len > 0 and buf.items[buf.items.len - 1] == '\n')
                    buf.items.len -= 1;
            },
            .keep => {
                while (buf.items.len > 0 and buf.items[buf.items.len - 1] == '\n')
                    buf.items.len -= 1;
                const total = 1 + trailing_blank_lines;
                for (0..total) |_| try self.bufAppend(&buf, '\n');
            },
        }

        try self.addTokenWithOrigin(.string, buf.items, raw_buf.items);
    }

    fn scanAnchor(self: *Scanner) !void {
        const name_start = self.pos + 1;
        self.advance(1);
        while (self.pos < self.source.len and !isWhitespaceOrNewline(self.source[self.pos]) and
            !isFlowIndicator(self.source[self.pos]))
            self.advance(1);
        try self.addTokenWithOrigin(.anchor, "&", self.source[name_start..self.pos]);
    }

    fn scanAlias(self: *Scanner) !void {
        const name_start = self.pos + 1;
        self.advance(1);
        while (self.pos < self.source.len and
            !isWhitespaceOrNewline(self.source[self.pos]) and
            !isFlowIndicator(self.source[self.pos]))
        {
            // Stop at ':' only when it is a mapping value indicator.
            if (self.source[self.pos] == ':') {
                if (self.pos + 1 >= self.source.len or
                    isWhitespaceOrNewline(self.source[self.pos + 1]) or
                    (self.flow_level > 0 and
                        isFlowIndicator(self.source[self.pos + 1])))
                    break;
            }
            self.advance(1);
        }
        try self.addTokenWithOrigin(.alias, "*", self.source[name_start..self.pos]);
    }

    fn scanTag(self: *Scanner) !void {
        const start = self.pos;
        self.advance(1);
        // Verbatim tags !<...> can contain flow indicators.
        if (self.pos < self.source.len and self.source[self.pos] == '<') {
            self.advance(1);
            while (self.pos < self.source.len and self.source[self.pos] != '>') {
                if (isNewline(self.source[self.pos])) return error.SyntaxError;
                self.advance(1);
            }
            if (self.pos < self.source.len) self.advance(1); // consume >
        } else {
            while (self.pos < self.source.len and
                !isWhitespaceOrNewline(self.source[self.pos]) and
                !isFlowIndicator(self.source[self.pos]))
                self.advance(1);
        }
        const tag = self.source[start..self.pos];
        try self.validateTagHandle(tag);
        try self.addToken(.tag, tag);
    }

    fn hasExplicitKeyBefore(self: *Scanner) bool {
        var i = self.tokens.items.len;
        while (i > 0) {
            i -= 1;
            const tt = self.tokens.items[i].token_type;
            if (tt == .mapping_key) return true;
            // Stop at tokens that can't be part of the key expression.
            if (tt == .mapping_value or tt == .sequence_entry or
                tt == .document_header or tt == .document_end) return false;
        }
        return false;
    }

    fn activateTagDirectives(self: *Scanner) void {
        if (self.has_pending_tags) {
            self.tag_directives = self.pending_tag_directives;
            self.pending_tag_directives = .empty;
            self.has_pending_tags = false;
        } else {
            self.tag_directives.clearRetainingCapacity();
        }
    }

    fn validateTagHandle(self: *Scanner, tag: []const u8) !void {
        // Extract the handle portion from the tag.
        // Verbatim (!<...>) and primary (! alone or !suffix) need no directive.
        if (tag.len < 2) return;
        if (tag[1] == '<') return;
        // Find second '!' for named handles like !name!suffix.
        if (std.mem.indexOfScalar(u8, tag[1..], '!')) |second| {
            const handle = tag[0 .. second + 2];
            // !! is the default secondary handle, always valid.
            if (std.mem.eql(u8, handle, "!!")) return;
            if (!self.tag_directives.contains(handle)) return error.SyntaxError;
        }
    }

    fn scanPlainScalar(self: *Scanner) !void {
        if (self.isMergeKey()) {
            try self.addToken(.merge_key, "<<");
            self.advance(2);
            return;
        }
        if (self.flow_level > 0) try self.rejectAmbiguousFlowIndicator();

        const start = self.pos;
        const in_flow = self.flow_level > 0;
        const ctx = PlainContext{
            .in_flow = in_flow,
            .after_mapping_value = self.lastTokenType() == .mapping_value,
            .after_seq_entry = self.lastTokenType() == .sequence_entry,
            .base_indent = if (self.lastTokenType() == .mapping_value)
                self.last_key_indent
            else
                self.line_indent,
        };

        var end = self.scanPlainLine(in_flow);
        while (end > start and isWhitespace(self.source[end - 1])) end -= 1;

        if (self.pos >= self.source.len or !isNewline(self.source[self.pos])) {
            try self.addPlainToken(self.source[start..end]);
            return;
        }

        var buf: Buf = .empty;
        try self.bufAppendSlice(&buf, self.source[start..end]);

        while (self.pos < self.source.len and isNewline(self.source[self.pos])) {
            const saved = self.savePos();
            self.advance(1);
            const blank_count = self.skipBlankLines();
            const next_indent = self.measureIndent();

            if (!self.plainContinues(ctx, next_indent)) {
                self.restorePos(saved);
                break;
            }

            try self.bufAppend(&buf, if (blank_count > 0) '\n' else ' ');
            const cont_start = self.pos;
            end = self.scanPlainLine(in_flow);
            while (end > cont_start and isWhitespace(self.source[end - 1])) end -= 1;
            try self.bufAppendSlice(&buf, self.source[cont_start..end]);
        }

        try self.addPlainToken(buf.items);
    }

    const PlainContext = struct {
        in_flow: bool,
        after_mapping_value: bool,
        after_seq_entry: bool,
        base_indent: u32,
    };

    const SavedPos = struct { pos: usize, line: u32, column: u32 };

    fn savePos(self: *const Scanner) SavedPos {
        return .{ .pos = self.pos, .line = self.line, .column = self.column };
    }

    fn restorePos(self: *Scanner, saved: SavedPos) void {
        self.pos = saved.pos;
        self.line = saved.line;
        self.column = saved.column;
    }

    fn rejectAmbiguousFlowIndicator(self: *const Scanner) !void {
        const c = self.source[self.pos];
        if (c != '-' and c != '?' and c != ':') return;
        const has_next = self.pos + 1 < self.source.len;
        if (!has_next or isWhitespaceOrNewline(self.source[self.pos + 1]) or
            isFlowIndicator(self.source[self.pos + 1]))
            return error.SyntaxError;
    }

    fn skipBlankLines(self: *Scanner) usize {
        var count: usize = 0;
        while (self.pos < self.source.len) {
            const bpos = self.pos;
            const bcol = self.column;
            while (self.pos < self.source.len and isWhitespace(self.source[self.pos]))
                self.advance(1);
            if (self.pos < self.source.len and isNewline(self.source[self.pos])) {
                count += 1;
                self.advance(1);
            } else {
                self.pos = bpos;
                self.column = bcol;
                break;
            }
        }
        return count;
    }

    fn measureIndent(self: *Scanner) u32 {
        var indent: u32 = 0;
        while (self.pos < self.source.len and isWhitespace(self.source[self.pos])) {
            indent += 1;
            self.advance(1);
        }
        return indent;
    }

    fn plainContinues(self: *Scanner, ctx: PlainContext, next_indent: u32) bool {
        if (self.pos >= self.source.len or isNewline(self.source[self.pos])) return false;
        if (ctx.in_flow) {
            const nc = self.source[self.pos];
            return !isFlowIndicator(nc) and nc != '#' and !self.looksLikeDocMarker();
        }
        if ((ctx.after_mapping_value or ctx.after_seq_entry) and
            next_indent <= ctx.base_indent) return false;
        if (!ctx.after_mapping_value and !ctx.after_seq_entry and
            next_indent < ctx.base_indent) return false;
        if (self.source[self.pos] == '#' or self.looksLikeNewKey() or
            self.looksLikeDocMarker()) return false;
        if (self.looksLikeSequenceEntry() and next_indent <= ctx.base_indent) return false;
        return true;
    }

    fn scanPlainLine(self: *Scanner, in_flow: bool) usize {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (isNewline(c)) break;
            if (in_flow and isFlowIndicator(c)) break;
            if (c == ':' and self.isMappingValue()) break;
            if (c == '#' and self.isPrecededByWhitespace()) break;
            self.advance(1);
        }
        return self.pos;
    }

    fn addPlainToken(self: *Scanner, val: []const u8) !void {
        // After a tag, plain values are always strings
        if (self.lastTokenType() == .tag) {
            try self.addToken(.string, val);
            return;
        }
        if (token_mod.reservedKeyword(val)) |kw_type| {
            try self.addToken(kw_type, val);
        } else if (isInvalidLeadingZero(val)) {
            try self.addToken(.string, val);
        } else if (token_mod.toNumber(val) != null) {
            const num = token_mod.toNumber(val).?;
            switch (num) {
                .int => try self.addToken(.integer, val),
                .float => try self.addToken(.float, val),
            }
        } else {
            try self.addToken(.string, val);
        }
    }

    fn lastTokenType(self: *Scanner) ?TokenType {
        if (self.tokens.items.len == 0) return null;
        return self.tokens.items[self.tokens.items.len - 1].token_type;
    }

    fn isInvalidLeadingZero(val: []const u8) bool {
        // Reject "0" followed by digits that look like bad octal (e.g. "098765")
        if (val.len < 2) return false;
        var s = val;
        if (s[0] == '+' or s[0] == '-') s = s[1..];
        if (s.len < 2 or s[0] != '0') return false;
        // Valid prefixes: 0x, 0o, 0b, 0. (float), 0e (float)
        if (s.len >= 2) {
            const c = s[1];
            if (c == 'x' or c == 'X' or c == 'o' or c == 'O' or
                c == 'b' or c == 'B' or c == '.' or c == 'e' or c == 'E')
                return false;
        }
        // If second char is a digit (not 0x/0o/0b prefix), it's legacy octal territory
        // Check if all remaining chars are valid octal digits/underscores
        if (!std.ascii.isDigit(s[1])) return false;
        for (s[1..]) |c| {
            if (c == '_') continue;
            if (c < '0' or c > '7') return true; // has non-octal digit → invalid
        }
        return false;
    }

    fn isMergeKey(self: *Scanner) bool {
        if (self.pos + 1 >= self.source.len) return false;
        if (self.source[self.pos] != '<' or self.source[self.pos + 1] != '<') return false;
        if (self.pos + 2 >= self.source.len) return false;
        var p = self.pos + 2;
        while (p < self.source.len and isWhitespace(self.source[p])) p += 1;
        if (p >= self.source.len) return false;
        if (self.source[p] != ':') return false;
        if (p + 1 >= self.source.len) return true;
        const after_colon = self.source[p + 1];
        return isWhitespace(after_colon) or isNewline(after_colon) or
            isFlowIndicator(after_colon);
    }

    fn looksLikeNewKey(self: *Scanner) bool {
        var p = self.pos;
        while (p < self.source.len and !isNewline(self.source[p])) {
            const c = self.source[p];
            if (c == ':') {
                if (p + 1 >= self.source.len) return true;
                const next = self.source[p + 1];
                if (isWhitespace(next) or isNewline(next)) return true;
            }
            if (c == '\'' or c == '"') {
                // Skip past closing quote to check for ':'
                const q = c;
                p += 1;
                while (p < self.source.len and self.source[p] != q)
                    p += 1;
                if (p < self.source.len) p += 1; // skip close
                continue;
            }
            p += 1;
        }
        return false;
    }

    fn looksLikeSequenceEntry(self: *Scanner) bool {
        if (self.pos >= self.source.len) return false;
        if (self.source[self.pos] != '-') return false;
        if (self.pos + 1 >= self.source.len) return true;
        return isWhitespace(self.source[self.pos + 1]) or
            isNewline(self.source[self.pos + 1]);
    }

    fn looksLikeDocMarkerAt(self: *Scanner, p: usize) bool {
        if (p + 2 >= self.source.len) return false;
        const slice = self.source[p .. p + 3];
        if (std.mem.eql(u8, slice, "---") or std.mem.eql(u8, slice, "...")) {
            if (p + 3 >= self.source.len) return true;
            return isWhitespaceOrNewline(self.source[p + 3]);
        }
        return false;
    }

    fn looksLikeDocMarker(self: *Scanner) bool {
        return self.looksLikeDocMarkerAt(self.pos);
    }
};

fn expectTokenTypes(source: []const u8, expected: []const TokenType) !void {
    var s = Scanner.init(std.testing.allocator, source);
    defer s.deinit();
    const tokens = try s.scan();
    try std.testing.expectEqual(expected.len, tokens.len);
    for (tokens, expected) |tok, exp| {
        try std.testing.expectEqual(exp, tok.token_type);
    }
}

fn expectTokenTypesAndValues(
    source: []const u8,
    expected_types: []const TokenType,
    expected_values: []const []const u8,
) !void {
    var s = Scanner.init(std.testing.allocator, source);
    defer s.deinit();
    const tokens = try s.scan();
    try std.testing.expectEqual(expected_types.len, tokens.len);
    for (tokens, expected_types, expected_values) |tok, et, ev| {
        try std.testing.expectEqual(et, tok.token_type);
        try std.testing.expectEqualStrings(ev, tok.value);
    }
}

test "scan null" {
    try expectTokenTypesAndValues("null\n  ", &.{.null_value}, &.{"null"});
}

test "scan integer with underscore" {
    try expectTokenTypesAndValues("0_", &.{.integer}, &.{"0_"});
}

test "scan double quoted with tab escape" {
    try expectTokenTypesAndValues("\"hello\\tworld\"", &.{.double_quote}, &.{"hello\tworld"});
}

test "scan hex integer with underscores" {
    try expectTokenTypesAndValues("0x_1A_2B_3C", &.{.integer}, &.{"0x_1A_2B_3C"});
}

test "scan positive binary integer" {
    try expectTokenTypesAndValues("+0b1010", &.{.integer}, &.{"+0b1010"});
}

test "scan legacy octal integer 0100" {
    try expectTokenTypesAndValues("0100", &.{.integer}, &.{"0100"});
}

test "scan octal integer 0o10" {
    try expectTokenTypesAndValues("0o10", &.{.integer}, &.{"0o10"});
}

test "scan scientific notation" {
    try expectTokenTypesAndValues("0.123e+123", &.{.float}, &.{"0.123e+123"});
}

test "scan empty mapping braces" {
    try expectTokenTypesAndValues("{}\n  ", &.{ .mapping_start, .mapping_end }, &.{ "{", "}" });
}

test "scan key value v hi" {
    try expectTokenTypesAndValues(
        "v: hi",
        &.{ .string, .mapping_value, .string },
        &.{ "v", ":", "hi" },
    );
}

test "scan key with tab separated value" {
    try expectTokenTypesAndValues(
        "v:\ta",
        &.{ .string, .mapping_value, .string },
        &.{ "v", ":", "a" },
    );
}

test "scan key with quoted true value" {
    try expectTokenTypesAndValues(
        "v: \"true\"",
        &.{ .string, .mapping_value, .double_quote },
        &.{ "v", ":", "true" },
    );
}

test "scan key with quoted false value" {
    try expectTokenTypesAndValues(
        "v: \"false\"",
        &.{ .string, .mapping_value, .double_quote },
        &.{ "v", ":", "false" },
    );
}

test "scan key with bool true" {
    try expectTokenTypesAndValues(
        "v: true",
        &.{ .string, .mapping_value, .bool_value },
        &.{ "v", ":", "true" },
    );
}

test "scan key with bool false" {
    try expectTokenTypesAndValues(
        "v: false",
        &.{ .string, .mapping_value, .bool_value },
        &.{ "v", ":", "false" },
    );
}

test "scan key with integer 10" {
    try expectTokenTypesAndValues(
        "v: 10",
        &.{ .string, .mapping_value, .integer },
        &.{ "v", ":", "10" },
    );
}

test "scan key with negative integer -10" {
    try expectTokenTypesAndValues(
        "v: -10",
        &.{ .string, .mapping_value, .integer },
        &.{ "v", ":", "-10" },
    );
}

test "scan key with integer 42" {
    try expectTokenTypesAndValues(
        "v: 42",
        &.{ .string, .mapping_value, .integer },
        &.{ "v", ":", "42" },
    );
}

test "scan key with large integer" {
    try expectTokenTypesAndValues(
        "v: 4294967296",
        &.{ .string, .mapping_value, .integer },
        &.{ "v", ":", "4294967296" },
    );
}

test "scan key with quoted integer" {
    try expectTokenTypesAndValues(
        "v: \"10\"",
        &.{ .string, .mapping_value, .double_quote },
        &.{ "v", ":", "10" },
    );
}

test "scan key with float 0.1" {
    try expectTokenTypesAndValues(
        "v: 0.1",
        &.{ .string, .mapping_value, .float },
        &.{ "v", ":", "0.1" },
    );
}

test "scan key with float 0.99" {
    try expectTokenTypesAndValues(
        "v: 0.99",
        &.{ .string, .mapping_value, .float },
        &.{ "v", ":", "0.99" },
    );
}

test "scan key with negative float" {
    try expectTokenTypesAndValues(
        "v: -0.1",
        &.{ .string, .mapping_value, .float },
        &.{ "v", ":", "-0.1" },
    );
}

test "scan key with infinity" {
    try expectTokenTypesAndValues(
        "v: .inf",
        &.{ .string, .mapping_value, .infinity },
        &.{ "v", ":", ".inf" },
    );
}

test "scan key with negative infinity" {
    try expectTokenTypesAndValues(
        "v: -.inf",
        &.{ .string, .mapping_value, .infinity },
        &.{ "v", ":", "-.inf" },
    );
}

test "scan key with nan" {
    try expectTokenTypesAndValues(
        "v: .nan",
        &.{ .string, .mapping_value, .nan },
        &.{ "v", ":", ".nan" },
    );
}

test "scan multiline double quoted string" {
    try expectTokenTypesAndValues(
        \\
        \\a:
        \\  "bbb  \
        \\      ccc
        \\
        \\      ddd eee\n\
        \\  \ \ fff ggg\nhhh iii\n
        \\  jjj kkk
        \\  "
        \\
    ,
        &.{ .string, .mapping_value, .double_quote },
        &.{
            "a",
            ":",
            "bbb  ccc\nddd eee\n  fff ggg\nhhh iii\n jjj kkk ",
        },
    );
}

test "scan key with null value" {
    try expectTokenTypesAndValues(
        "v: null",
        &.{ .string, .mapping_value, .null_value },
        &.{ "v", ":", "null" },
    );
}

test "scan key with empty double quote" {
    try expectTokenTypesAndValues(
        "v: \"\"",
        &.{ .string, .mapping_value, .double_quote },
        &.{ "v", ":", "" },
    );
}

test "scan block sequence under map" {
    try expectTokenTypesAndValues(
        \\
        \\v:
        \\- A
        \\- B
    ,
        &.{
            .string,
            .mapping_value,
            .sequence_entry,
            .string,
            .sequence_entry,
            .string,
        },
        &.{ "v", ":", "-", "A", "-", "B" },
    );
}

test "scan sequence with literal block" {
    try expectTokenTypesAndValues(
        \\
        \\v:
        \\- A
        \\- |-
        \\ B
        \\ C
    ,
        &.{
            .string,
            .mapping_value,
            .sequence_entry,
            .string,
            .sequence_entry,
            .literal,
            .string,
        },
        &.{ "v", ":", "-", "A", "-", "|-", "B\nC" },
    );
}

test "scan nested sequence with map" {
    try expectTokenTypesAndValues(
        \\
        \\v:
        \\- A
        \\- 1
        \\- B:
        \\ - 2
        \\ - 3
    ,
        &.{
            .string,
            .mapping_value,
            .sequence_entry,
            .string,
            .sequence_entry,
            .integer,
            .sequence_entry,
            .string,
            .mapping_value,
            .sequence_entry,
            .integer,
            .sequence_entry,
            .integer,
        },
        &.{ "v", ":", "-", "A", "-", "1", "-", "B", ":", "-", "2", "-", "3" },
    );
}

test "scan nested map" {
    try expectTokenTypesAndValues(
        \\
        \\a:
        \\ b: c
    ,
        &.{
            .string,
            .mapping_value,
            .string,
            .mapping_value,
            .string,
        },
        &.{ "a", ":", "b", ":", "c" },
    );
}

test "scan single quoted dash" {
    try expectTokenTypesAndValues(
        "a: '-'",
        &.{ .string, .mapping_value, .single_quote },
        &.{ "a", ":", "-" },
    );
}

test "scan bare integer 123" {
    try expectTokenTypesAndValues("123", &.{.integer}, &.{"123"});
}

test "scan hello world mapping" {
    try expectTokenTypesAndValues(
        "hello: world\n",
        &.{ .string, .mapping_value, .string },
        &.{ "hello", ":", "world" },
    );
}

test "scan a null mapping" {
    try expectTokenTypesAndValues(
        "a: null",
        &.{ .string, .mapping_value, .null_value },
        &.{ "a", ":", "null" },
    );
}

test "scan flow mapping a x 1" {
    try expectTokenTypesAndValues(
        "a: {x: 1}",
        &.{
            .string,
            .mapping_value,
            .mapping_start,
            .string,
            .mapping_value,
            .integer,
            .mapping_end,
        },
        &.{ "a", ":", "{", "x", ":", "1", "}" },
    );
}

test "scan flow sequence a 1 2" {
    try expectTokenTypesAndValues(
        "a: [1, 2]",
        &.{
            .string,
            .mapping_value,
            .sequence_start,
            .integer,
            .collect_entry,
            .integer,
            .sequence_end,
        },
        &.{ "a", ":", "[", "1", ",", "2", "]" },
    );
}

test "scan timestamp values" {
    try expectTokenTypesAndValues(
        \\
        \\t2: 2018-01-09T10:40:47Z
        \\t4: 2098-01-09T10:40:47Z
        \\
    ,
        &.{
            .string,
            .mapping_value,
            .string,
            .string,
            .mapping_value,
            .string,
        },
        &.{ "t2", ":", "2018-01-09T10:40:47Z", "t4", ":", "2098-01-09T10:40:47Z" },
    );
}

test "scan flow mapping with multiple keys" {
    try expectTokenTypesAndValues(
        "a: {b: c, d: e}",
        &.{
            .string,
            .mapping_value,
            .mapping_start,
            .string,
            .mapping_value,
            .string,
            .collect_entry,
            .string,
            .mapping_value,
            .string,
            .mapping_end,
        },
        &.{ "a", ":", "{", "b", ":", "c", ",", "d", ":", "e", "}" },
    );
}

test "scan duration-like string" {
    try expectTokenTypesAndValues(
        "a: 3s",
        &.{ .string, .mapping_value, .string },
        &.{ "a", ":", "3s" },
    );
}

test "scan angle bracket string" {
    try expectTokenTypesAndValues(
        "a: <foo>",
        &.{ .string, .mapping_value, .string },
        &.{ "a", ":", "<foo>" },
    );
}

test "scan quoted colon string" {
    try expectTokenTypesAndValues(
        "a: \"1:1\"",
        &.{ .string, .mapping_value, .double_quote },
        &.{ "a", ":", "1:1" },
    );
}

test "scan null byte in double quote" {
    try expectTokenTypesAndValues(
        "a: \"\\0\"",
        &.{ .string, .mapping_value, .double_quote },
        &.{ "a", ":", "\x00" },
    );
}

test "scan tag binary" {
    try expectTokenTypesAndValues(
        "a: !!binary gIGC",
        &.{ .string, .mapping_value, .tag, .string },
        &.{ "a", ":", "!!binary", "gIGC" },
    );
}

test "scan tag binary with literal block" {
    try expectTokenTypesAndValues(
        \\
        \\a: !!binary |
        \\ kJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJ
        \\ CQ
        \\
    ,
        &.{
            .string,
            .mapping_value,
            .tag,
            .literal,
            .string,
        },
        &.{
            "a",
            ":",
            "!!binary",
            "|",
            "kJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJ\nCQ\n",
        },
    );
}

test "scan multiple keys with sub map" {
    try expectTokenTypesAndValues(
        \\
        \\b: 2
        \\a: 1
        \\d: 4
        \\c: 3
        \\sub:
        \\  e: 5
    ,
        &.{
            .string,        .mapping_value, .integer,
            .string,        .mapping_value, .integer,
            .string,        .mapping_value, .integer,
            .string,        .mapping_value, .integer,
            .string,        .mapping_value, .string,
            .mapping_value, .integer,
        },
        &.{ "b", ":", "2", "a", ":", "1", "d", ":", "4", "c", ":", "3", "sub", ":", "e", ":", "5" },
    );
}

test "scan ip address as string" {
    try expectTokenTypesAndValues(
        "a: 1.2.3.4",
        &.{ .string, .mapping_value, .string },
        &.{ "a", ":", "1.2.3.4" },
    );
}

test "scan quoted timestamp" {
    try expectTokenTypesAndValues(
        "a: \"2015-02-24T18:19:39Z\"",
        &.{ .string, .mapping_value, .double_quote },
        &.{ "a", ":", "2015-02-24T18:19:39Z" },
    );
}

test "scan single quoted with colon" {
    try expectTokenTypesAndValues(
        "a: 'b: c'",
        &.{ .string, .mapping_value, .single_quote },
        &.{ "a", ":", "b: c" },
    );
}

test "scan single quoted with hash" {
    try expectTokenTypesAndValues(
        "a: 'Hello #comment'",
        &.{ .string, .mapping_value, .single_quote },
        &.{ "a", ":", "Hello #comment" },
    );
}

test "scan float 100.5" {
    try expectTokenTypesAndValues(
        "a: 100.5",
        &.{ .string, .mapping_value, .float },
        &.{ "a", ":", "100.5" },
    );
}

test "scan bogus string value" {
    try expectTokenTypesAndValues(
        "a: bogus",
        &.{ .string, .mapping_value, .string },
        &.{ "a", ":", "bogus" },
    );
}

test "scan double quoted map key" {
    try expectTokenTypesAndValues(
        "\"a\": double quoted map key",
        &.{ .double_quote, .mapping_value, .string },
        &.{ "a", ":", "double quoted map key" },
    );
}

test "scan single quoted map key" {
    try expectTokenTypesAndValues(
        "'a': single quoted map key",
        &.{ .single_quote, .mapping_value, .string },
        &.{ "a", ":", "single quoted map key" },
    );
}

test "scan double quoted key value pairs" {
    try expectTokenTypesAndValues(
        \\
        \\a: "double quoted"
        \\b: "value map"
    ,
        &.{
            .string, .mapping_value, .double_quote,
            .string, .mapping_value, .double_quote,
        },
        &.{ "a", ":", "double quoted", "b", ":", "value map" },
    );
}

test "scan single quoted key value pairs" {
    try expectTokenTypesAndValues(
        \\
        \\a: 'single quoted'
        \\b: 'value map'
    ,
        &.{
            .string, .mapping_value, .single_quote,
            .string, .mapping_value, .single_quote,
        },
        &.{ "a", ":", "single quoted", "b", ":", "value map" },
    );
}

test "scan single quoted json expression" {
    try expectTokenTypesAndValues(
        "json: '\\\"expression\\\": \\\"thi:\\\"'",
        &.{ .string, .mapping_value, .single_quote },
        &.{ "json", ":", "\\\"expression\\\": \\\"thi:\\\"" },
    );
}

test "scan double quoted json expression" {
    try expectTokenTypesAndValues(
        "json: \"\\\"expression\\\": \\\"thi:\\\"\"",
        &.{ .string, .mapping_value, .double_quote },
        &.{ "json", ":", "\"expression\": \"thi:\"" },
    );
}

test "scan multiline plain scalar" {
    try expectTokenTypesAndValues(
        \\
        \\a:
        \\ b
        \\
        \\ c
    ,
        &.{ .string, .mapping_value, .string },
        &.{ "a", ":", "b\nc" },
    );
}

test "scan multiline plain scalar with trailing ws" {
    try expectTokenTypesAndValues(
        "\na:   \n b   \n\n  \n c\n d \ne: f\n",
        &.{
            .string, .mapping_value, .string,
            .string, .mapping_value, .string,
        },
        &.{ "a", ":", "b\nc d", "e", ":", "f" },
    );
}

test "scan literal block with whitespace" {
    try expectTokenTypesAndValues(
        "\na: |\n b   \n\n  \n c\n d \ne: f\n",
        &.{
            .string, .mapping_value, .literal, .string,
            .string, .mapping_value, .string,
        },
        &.{
            "a",                  ":", "|",
            "b   \n\n \nc\nd \n", "e", ":",
            "f",
        },
    );
}

test "scan folded block with whitespace" {
    try expectTokenTypesAndValues(
        "\na: >\n b   \n\n  \n c\n d \ne: f\n",
        &.{
            .string, .mapping_value, .folded, .string,
            .string, .mapping_value, .string,
        },
        &.{
            "a",                 ":", ">",
            "b   \n\n \nc d \n", "e", ":",
            "f",
        },
    );
}

test "scan folded block simple text" {
    try expectTokenTypesAndValues(
        "\na: >\n  Text",
        &.{
            .string,
            .mapping_value,
            .folded,
            .string,
        },
        &.{ "a", ":", ">", "Text" },
    );
}

test "scan folded block with string-like content" {
    try expectTokenTypesAndValues(
        \\
        \\s: >
        \\        1s
    ,
        &.{
            .string,
            .mapping_value,
            .folded,
            .string,
        },
        &.{ "s", ":", ">", "1s" },
    );
}

test "scan folded with indent and comment" {
    try expectTokenTypesAndValues(
        \\
        \\s: >1        # comment
        \\        1s
    ,
        &.{
            .string,
            .mapping_value,
            .folded,
            .comment,
            .string,
        },
        &.{ "s", ":", ">1", " comment", "       1s" },
    );
}

test "scan folded with keep and indent" {
    try expectTokenTypesAndValues(
        \\
        \\s: >+2
        \\        1s
    ,
        &.{
            .string,
            .mapping_value,
            .folded,
            .string,
        },
        &.{ "s", ":", ">+2", "      1s\n" },
    );
}

test "scan folded with strip and indent" {
    try expectTokenTypesAndValues(
        \\
        \\s: >-3
        \\        1s
    ,
        &.{
            .string,
            .mapping_value,
            .folded,
            .string,
        },
        &.{ "s", ":", ">-3", "     1s" },
    );
}

test "scan folded two lines same indent" {
    try expectTokenTypesAndValues(
        \\
        \\s: >
        \\    1s
        \\    2s
    ,
        &.{
            .string,
            .mapping_value,
            .folded,
            .string,
        },
        &.{ "s", ":", ">", "1s 2s\n" },
    );
}

test "scan folded three lines mixed indent" {
    try expectTokenTypesAndValues(
        \\
        \\s: >
        \\    1s
        \\      2s
        \\    3s
    ,
        &.{
            .string,
            .mapping_value,
            .folded,
            .string,
        },
        &.{ "s", ":", ">", "1s\n  2s\n3s\n" },
    );
}

test "scan folded five lines mixed indent" {
    try expectTokenTypesAndValues(
        \\
        \\s: >
        \\    1s
        \\      2s
        \\      3s
        \\    4s
        \\    5s
        \\
    ,
        &.{
            .string,
            .mapping_value,
            .folded,
            .string,
        },
        &.{
            "s",
            ":",
            ">",
            "1s\n  2s\n  3s\n4s 5s\n",
        },
    );
}

test "scan folded strip with indent five lines" {
    try expectTokenTypesAndValues(
        \\
        \\s: >-3
        \\    1s
        \\      2s
        \\      3s
        \\    4s
        \\    5s
        \\
    ,
        &.{
            .string,
            .mapping_value,
            .folded,
            .string,
        },
        &.{
            "s",
            ":",
            ">-3",
            " 1s\n   2s\n   3s\n 4s\n 5s",
        },
    );
}

test "scan literal with strip and indent" {
    try expectTokenTypesAndValues(
        \\
        \\|2-
        \\
        \\                  text
    ,
        &.{ .literal, .string },
        &.{ "|2-", "\n                text" },
    );
}

test "scan literal with trailing newlines" {
    try expectTokenTypesAndValues(
        \\
        \\|
        \\  a
        \\
        \\
        \\
    ,
        &.{ .literal, .string },
        &.{ "|", "a\n" },
    );
}

test "scan literal with comment after header" {
    try expectTokenTypesAndValues(
        "\n|  \t\t  # comment\n  foo\n",
        &.{ .literal, .comment, .string },
        &.{ "|", " comment", "foo\n" },
    );
}

test "scan invalid number 1x0 as string" {
    try expectTokenTypesAndValues("1x0", &.{.string}, &.{"1x0"});
}

test "scan invalid binary 0b98765 as string" {
    try expectTokenTypesAndValues("0b98765", &.{.string}, &.{"0b98765"});
}

test "scan invalid octal 098765 as string" {
    try expectTokenTypesAndValues("098765", &.{.string}, &.{"098765"});
}

test "scan invalid octal 0o98765 as string" {
    try expectTokenTypesAndValues("0o98765", &.{.string}, &.{"0o98765"});
}

test "scan document header" {
    try expectTokenTypesAndValues(
        "---\na: b",
        &.{
            .document_header,
            .string,
            .mapping_value,
            .string,
        },
        &.{ "---", "a", ":", "b" },
    );
}

test "scan document end" {
    try expectTokenTypesAndValues(
        "a: b\n...",
        &.{
            .string,
            .mapping_value,
            .string,
            .document_end,
        },
        &.{ "a", ":", "b", "..." },
    );
}

test "scan sequence entries" {
    try expectTokenTypesAndValues(
        "- A\n- B",
        &.{
            .sequence_entry,
            .string,
            .sequence_entry,
            .string,
        },
        &.{ "-", "A", "-", "B" },
    );
}

test "scan flow sequence" {
    try expectTokenTypesAndValues(
        "[A, B]",
        &.{
            .sequence_start,
            .string,
            .collect_entry,
            .string,
            .sequence_end,
        },
        &.{ "[", "A", ",", "B", "]" },
    );
}

test "scan flow mapping" {
    try expectTokenTypesAndValues(
        "{a: b, c: d}",
        &.{
            .mapping_start,
            .string,
            .mapping_value,
            .string,
            .collect_entry,
            .string,
            .mapping_value,
            .string,
            .mapping_end,
        },
        &.{
            "{", "a", ":", "b", ",", "c", ":", "d", "}",
        },
    );
}

test "scan anchor" {
    try expectTokenTypesAndValues("&anchor value", &.{ .anchor, .string }, &.{ "&", "value" });
}

test "scan alias" {
    try expectTokenTypesAndValues("*anchor", &.{.alias}, &.{"*"});
}

test "scan tag" {
    try expectTokenTypesAndValues("!!str value", &.{ .tag, .string }, &.{ "!!str", "value" });
}

test "scan comment" {
    try expectTokenTypesAndValues("# this is a comment", &.{.comment}, &.{" this is a comment"});
}

test "scan literal block scalar" {
    try expectTokenTypesAndValues(
        \\v: |
        \\  hello
        \\  world
    ,
        &.{
            .string,
            .mapping_value,
            .literal,
            .string,
        },
        &.{ "v", ":", "|", "hello\nworld\n" },
    );
}

test "scan folded block scalar" {
    try expectTokenTypesAndValues(
        \\v: >
        \\  hello
        \\  world
    ,
        &.{
            .string,
            .mapping_value,
            .folded,
            .string,
        },
        &.{ "v", ":", ">", "hello world\n" },
    );
}

test "scan single quoted string" {
    try expectTokenTypesAndValues("'hello world'", &.{.single_quote}, &.{"hello world"});
}

test "scan directive" {
    try expectTokenTypesAndValues("%YAML 1.2", &.{.directive}, &.{"%YAML 1.2"});
}

test "scan merge key" {
    try expectTokenTypesAndValues(
        "<<: *alias",
        &.{
            .merge_key,
            .mapping_value,
            .alias,
        },
        &.{ "<<", ":", "*" },
    );
}

test "scan deeply nested map" {
    try expectTokenTypesAndValues(
        \\a:
        \\  b: c
    ,
        &.{
            .string,
            .mapping_value,
            .string,
            .mapping_value,
            .string,
        },
        &.{ "a", ":", "b", ":", "c" },
    );
}

test "scan nested sequence in map" {
    try expectTokenTypesAndValues(
        \\v:
        \\- A
        \\- B
    ,
        &.{
            .string,
            .mapping_value,
            .sequence_entry,
            .string,
            .sequence_entry,
            .string,
        },
        &.{ "v", ":", "-", "A", "-", "B" },
    );
}

test "scan explicit mapping key" {
    try expectTokenTypesAndValues(
        \\? key
        \\: value
    ,
        &.{
            .mapping_key,
            .string,
            .mapping_value,
            .string,
        },
        &.{ "?", "key", ":", "value" },
    );
}

test "scan key with flow sequence value" {
    try expectTokenTypesAndValues(
        "a: [1, 2]",
        &.{
            .string,
            .mapping_value,
            .sequence_start,
            .integer,
            .collect_entry,
            .integer,
            .sequence_end,
        },
        &.{ "a", ":", "[", "1", ",", "2", "]" },
    );
}

test "scan key with flow mapping value" {
    try expectTokenTypesAndValues(
        "a: {x: 1}",
        &.{
            .string,
            .mapping_value,
            .mapping_start,
            .string,
            .mapping_value,
            .integer,
            .mapping_end,
        },
        &.{ "a", ":", "{", "x", ":", "1", "}" },
    );
}

test "scan multi-document" {
    try expectTokenTypesAndValues(
        \\---
        \\a: 1
        \\---
        \\b: 2
    ,
        &.{
            .document_header,
            .string,
            .mapping_value,
            .integer,
            .document_header,
            .string,
            .mapping_value,
            .integer,
        },
        &.{ "---", "a", ":", "1", "---", "b", ":", "2" },
    );
}

test "scan tagged value" {
    try expectTokenTypesAndValues(
        "v: !!binary gIGC",
        &.{
            .string,
            .mapping_value,
            .tag,
            .string,
        },
        &.{ "v", ":", "!!binary", "gIGC" },
    );
}

test "scan block scalar strip" {
    try expectTokenTypesAndValues(
        \\v: |-
        \\  hello
    ,
        &.{
            .string,
            .mapping_value,
            .literal,
            .string,
        },
        &.{ "v", ":", "|-", "hello" },
    );
}

test "scan single quote with escape" {
    try expectTokenTypesAndValues("'it''s'", &.{.single_quote}, &.{"it's"});
}

test "scan anchor with value" {
    try expectTokenTypesAndValues(
        "a: &ref value",
        &.{
            .string,
            .mapping_value,
            .anchor,
            .string,
        },
        &.{ "a", ":", "&", "value" },
    );
}

test "scan triple nested map" {
    try expectTokenTypesAndValues(
        \\a:
        \\  b:
        \\    c: d
    ,
        &.{
            .string,
            .mapping_value,
            .string,
            .mapping_value,
            .string,
            .mapping_value,
            .string,
        },
        &.{ "a", ":", "b", ":", "c", ":", "d" },
    );
}

test "scan null bare" {
    try expectTokenTypesAndValues("null", &.{.null_value}, &.{"null"});
}

test "scan integer bare" {
    try expectTokenTypesAndValues("42", &.{.integer}, &.{"42"});
}

test "scan float bare" {
    try expectTokenTypesAndValues("3.14", &.{.float}, &.{"3.14"});
}

test "scan true bare" {
    try expectTokenTypesAndValues("true", &.{.bool_value}, &.{"true"});
}

test "scan false bare" {
    try expectTokenTypesAndValues("false", &.{.bool_value}, &.{"false"});
}

test "scan infinity bare" {
    try expectTokenTypesAndValues(".inf", &.{.infinity}, &.{".inf"});
}

test "scan negative infinity bare" {
    try expectTokenTypesAndValues("-.inf", &.{.infinity}, &.{"-.inf"});
}

test "scan nan bare" {
    try expectTokenTypesAndValues(".nan", &.{.nan}, &.{".nan"});
}

test "scan v foo 1" {
    try expectTokenTypesAndValues(
        "v: !!foo 1",
        &.{ .string, .mapping_value, .tag, .string },
        &.{ "v", ":", "!!foo", "1" },
    );
}

test "scan folded strip in sequence" {
    try expectTokenTypesAndValues(
        \\
        \\v:
        \\- A
        \\- >-
        \\ B
        \\ C
    ,
        &.{
            .string,
            .mapping_value,
            .sequence_entry,
            .string,
            .sequence_entry,
            .folded,
            .string,
        },
        &.{ "v", ":", "-", "A", "-", ">-", "B C" },
    );
}

test "scan literal strip 0" {
    try expectTokenTypesAndValues(
        \\v: |-
        \\  0
    ,
        &.{
            .string,
            .mapping_value,
            .literal,
            .string,
        },
        &.{ "v", ":", "|-", "0" },
    );
}

test "scan literal strip 0 with next key" {
    try expectTokenTypesAndValues(
        \\v: |-
        \\  0
        \\x: 0
    ,
        &.{
            .string,
            .mapping_value,
            .literal,
            .string,
            .string,
            .mapping_value,
            .integer,
        },
        &.{ "v", ":", "|-", "0", "x", ":", "0" },
    );
}

test "scan double quoted newline" {
    try expectTokenTypesAndValues("\"a\\n1\\nb\"", &.{.double_quote}, &.{"a\n1\nb"});
}

test "scan json style mapping" {
    try expectTokenTypesAndValues(
        "{\"a\":\"b\"}",
        &.{
            .mapping_start,
            .double_quote,
            .mapping_value,
            .double_quote,
            .mapping_end,
        },
        &.{ "{", "a", ":", "b", "}" },
    );
}

test "scan explicit typed map" {
    try expectTokenTypesAndValues(
        std.mem.trimRight(u8,
            \\!!map {
            \\  ? !!str "explicit":!!str "entry",
            \\  ? !!str "implicit" : !!str "entry",
            \\  ? !!null "" : !!null "",
            \\}
            \\
        , "\n"),
        &.{
            .tag,
            .mapping_start,
            .mapping_key,
            .tag,
            .double_quote,
            .mapping_value,
            .tag,
            .double_quote,
            .collect_entry,
            .mapping_key,
            .tag,
            .double_quote,
            .mapping_value,
            .tag,
            .double_quote,
            .collect_entry,
            .mapping_key,
            .tag,
            .double_quote,
            .mapping_value,
            .tag,
            .double_quote,
            .collect_entry,
            .mapping_end,
        },
        &.{
            "!!map",    "{",
            "?",        "!!str",
            "explicit", ":",
            "!!str",    "entry",
            ",",        "?",
            "!!str",    "implicit",
            ":",        "!!str",
            "entry",    ",",
            "?",        "!!null",
            "",         ":",
            "!!null",   "",
            ",",        "}",
        },
    );
}

test "scan double quoted keys" {
    try expectTokenTypesAndValues(
        \\"a": a
        \\"b": b
    ,
        &.{
            .double_quote,
            .mapping_value,
            .string,
            .double_quote,
            .mapping_value,
            .string,
        },
        &.{ "a", ":", "a", "b", ":", "b" },
    );
}

test "scan single quoted keys" {
    try expectTokenTypesAndValues(
        "'a': a\n'b': b",
        &.{
            .single_quote,
            .mapping_value,
            .string,
            .single_quote,
            .mapping_value,
            .string,
        },
        &.{ "a", ":", "a", "b", ":", "b" },
    );
}

test "scan crlf line endings" {
    try expectTokenTypesAndValues(
        "a: \r\n  b: 1\r\n",
        &.{
            .string,
            .mapping_value,
            .string,
            .mapping_value,
            .integer,
        },
        &.{ "a", ":", "b", ":", "1" },
    );
}

test "scan cr line endings" {
    try expectTokenTypesAndValues(
        "a_ok: \r  bc: 2\r",
        &.{
            .string,
            .mapping_value,
            .string,
            .mapping_value,
            .integer,
        },
        &.{ "a_ok", ":", "bc", ":", "2" },
    );
}

test "scan lf line endings" {
    try expectTokenTypesAndValues(
        \\a_mk: 
        \\  bd: 3
        \\
    ,
        &.{
            .string,
            .mapping_value,
            .string,
            .mapping_value,
            .integer,
        },
        &.{ "a_mk", ":", "bd", ":", "3" },
    );
}

test "scan colon value" {
    try expectTokenTypesAndValues(
        "a: :a",
        &.{ .string, .mapping_value, .string },
        &.{ "a", ":", ":a" },
    );
}

test "scan flow map with empty value" {
    try expectTokenTypesAndValues(
        "{a: , b: c}",
        &.{
            .mapping_start,
            .string,
            .mapping_value,
            .collect_entry,
            .string,
            .mapping_value,
            .string,
            .mapping_end,
        },
        &.{ "{", "a", ":", ",", "b", ":", "c", "}" },
    );
}

test "scan folded empty value" {
    try expectTokenTypesAndValues(
        "value: >\n",
        &.{
            .string,
            .mapping_value,
            .folded,
        },
        &.{ "value", ":", ">" },
    );
}

test "scan folded empty value double newline" {
    try expectTokenTypesAndValues(
        \\value: >
        \\
    ,
        &.{
            .string,
            .mapping_value,
            .folded,
        },
        &.{ "value", ":", ">" },
    );
}

test "scan folded followed by key" {
    try expectTokenTypesAndValues(
        \\value: >
        \\other:
    ,
        &.{
            .string,
            .mapping_value,
            .folded,
            .string,
            .mapping_value,
        },
        &.{ "value", ":", ">", "other", ":" },
    );
}

test "scan folded empty then key" {
    try expectTokenTypesAndValues(
        \\value: >
        \\
        \\other:
    ,
        &.{
            .string,
            .mapping_value,
            .folded,
            .string,
            .mapping_value,
        },
        &.{ "value", ":", ">", "other", ":" },
    );
}

test "scan map with empty sequence" {
    try expectTokenTypesAndValues(
        "a:\n-",
        &.{
            .string,
            .mapping_value,
            .sequence_entry,
        },
        &.{ "a", ":", "-" },
    );
}

test "scan flow map bare key" {
    try expectTokenTypesAndValues(
        "a: {foo}",
        &.{
            .string,
            .mapping_value,
            .mapping_start,
            .string,
            .mapping_end,
        },
        &.{ "a", ":", "{", "foo", "}" },
    );
}

test "scan flow map bare keys comma" {
    try expectTokenTypesAndValues(
        "a: {foo,bar}",
        &.{
            .string,
            .mapping_value,
            .mapping_start,
            .string,
            .collect_entry,
            .string,
            .mapping_end,
        },
        &.{ "a", ":", "{", "foo", ",", "bar", "}" },
    );
}

test "scan nested flow map" {
    try expectTokenTypesAndValues(
        \\
        \\{
        \\  a: {
        \\    b: c
        \\  },
        \\  d: e
        \\}
    ,
        &.{
            .mapping_start,
            .string,
            .mapping_value,
            .mapping_start,
            .string,
            .mapping_value,
            .string,
            .mapping_end,
            .collect_entry,
            .string,
            .mapping_value,
            .string,
            .mapping_end,
        },
        &.{ "{", "a", ":", "{", "b", ":", "c", "}", ",", "d", ":", "e", "}" },
    );
}

test "scan flow sequence with map entry" {
    try expectTokenTypesAndValues(
        \\
        \\[
        \\  a: {
        \\    b: c
        \\  }]
    ,
        &.{
            .sequence_start,
            .string,
            .mapping_value,
            .mapping_start,
            .string,
            .mapping_value,
            .string,
            .mapping_end,
            .sequence_end,
        },
        &.{ "[", "a", ":", "{", "b", ":", "c", "}", "]" },
    );
}

test "scan nested flow map no trailing comma" {
    try expectTokenTypesAndValues(
        \\
        \\{
        \\  a: {
        \\    b: c
        \\  }}
    ,
        &.{
            .mapping_start,
            .string,
            .mapping_value,
            .mapping_start,
            .string,
            .mapping_value,
            .string,
            .mapping_end,
            .mapping_end,
        },
        &.{ "{", "a", ":", "{", "b", ":", "c", "}", "}" },
    );
}

test "scan tag on sequence entry" {
    try expectTokenTypesAndValues(
        \\
        \\- !tag
        \\  a: b
        \\  c: d
    ,
        &.{
            .sequence_entry,
            .tag,
            .string,
            .mapping_value,
            .string,
            .string,
            .mapping_value,
            .string,
        },
        &.{ "-", "!tag", "a", ":", "b", "c", ":", "d" },
    );
}

test "scan tag on map value" {
    try expectTokenTypesAndValues(
        \\
        \\a: !tag
        \\  b: c
    ,
        &.{
            .string,
            .mapping_value,
            .tag,
            .string,
            .mapping_value,
            .string,
        },
        &.{ "a", ":", "!tag", "b", ":", "c" },
    );
}

test "scan tag on map value multi keys" {
    try expectTokenTypesAndValues(
        \\
        \\a: !tag
        \\  b: c
        \\  d: e
    ,
        &.{
            .string,
            .mapping_value,
            .tag,
            .string,
            .mapping_value,
            .string,
            .string,
            .mapping_value,
            .string,
        },
        &.{ "a", ":", "!tag", "b", ":", "c", "d", ":", "e" },
    );
}

test "scan multiline doc separator" {
    try expectTokenTypesAndValues(
        \\
        \\foo: xxx
        \\---
        \\foo: yyy
        \\---
        \\foo: zzz
    ,
        &.{
            .string,
            .mapping_value,
            .string,
            .document_header,
            .string,
            .mapping_value,
            .string,
            .document_header,
            .string,
            .mapping_value,
            .string,
        },
        &.{
            "foo", ":", "xxx", "---",
            "foo", ":", "yyy", "---",
            "foo", ":", "zzz",
        },
    );
}

test "scan tab before colon in map" {
    try expectTokenTypesAndValues(
        "\nv:\n  a\t: 'a'\n  bb\t: 'a'\n",
        &.{
            .string,
            .mapping_value,
            .string,
            .mapping_value,
            .single_quote,
            .string,
            .mapping_value,
            .single_quote,
        },
        &.{ "v", ":", "a", ":", "a", "bb", ":", "a" },
    );
}

test "scan mixed space tab before colon" {
    try expectTokenTypesAndValues(
        "\nv:\n  a : 'x'\n  b\t: 'y'\n",
        &.{
            .string,
            .mapping_value,
            .string,
            .mapping_value,
            .single_quote,
            .string,
            .mapping_value,
            .single_quote,
        },
        &.{ "v", ":", "a", ":", "x", "b", ":", "y" },
    );
}

test "scan multiple tabs before colon" {
    try expectTokenTypesAndValues(
        "\nv:\n  a\t: 'x'\n  b\t: 'y'\n  c\t\t: 'z'\n",
        &.{
            .string,
            .mapping_value,
            .string,
            .mapping_value,
            .single_quote,
            .string,
            .mapping_value,
            .single_quote,
            .string,
            .mapping_value,
            .single_quote,
        },
        &.{ "v", ":", "a", ":", "x", "b", ":", "y", "c", ":", "z" },
    );
}

test "scan anchor and alias in flow" {
    try expectTokenTypesAndValues(
        "{a: &a c, *a : b}",
        &.{
            .mapping_start,
            .string,
            .mapping_value,
            .anchor,
            .string,
            .collect_entry,
            .alias,
            .mapping_value,
            .string,
            .mapping_end,
        },
        &.{ "{", "a", ":", "&", "c", ",", "*", ":", "b", "}" },
    );
}

test "scan whitespace around key value" {
    try expectTokenTypesAndValues(
        "       a       :          b        \n",
        &.{ .string, .mapping_value, .string },
        &.{ "a", ":", "b" },
    );
}

test "scan comment after value" {
    try expectTokenTypesAndValues(
        \\a: b # comment
        \\b: c
    ,
        &.{
            .string,
            .mapping_value,
            .string,
            .comment,
            .string,
            .mapping_value,
            .string,
        },
        &.{ "a", ":", "b", " comment", "b", ":", "c" },
    );
}

test "scan abc shift def ghi" {
    try expectTokenTypesAndValues(
        "a: abc <<def>> ghi",
        &.{ .string, .mapping_value, .string },
        &.{ "a", ":", "abc <<def>> ghi" },
    );
}

test "scan shift abcd" {
    try expectTokenTypesAndValues(
        "a: <<abcd",
        &.{ .string, .mapping_value, .string },
        &.{ "a", ":", "<<abcd" },
    );
}

test "scan shift colon abcd" {
    try expectTokenTypesAndValues(
        "a: <<:abcd",
        &.{ .string, .mapping_value, .string },
        &.{ "a", ":", "<<:abcd" },
    );
}

test "scan shift space colon abcd" {
    try expectTokenTypesAndValues(
        "a: <<  :abcd",
        &.{ .string, .mapping_value, .string },
        &.{ "a", ":", "<<  :abcd" },
    );
}

test "scan anchor without value" {
    try expectTokenTypesAndValues(
        \\
        \\a:
        \\ b: &anchor
        \\ c: &anchor2
        \\d: e
    ,
        &.{
            .string,
            .mapping_value,
            .string,
            .mapping_value,
            .anchor,
            .string,
            .mapping_value,
            .anchor,
            .string,
            .mapping_value,
            .string,
        },
        &.{ "a", ":", "b", ":", "&", "c", ":", "&", "d", ":", "e" },
    );
}

test "scan literal keep plus" {
    try expectTokenTypesAndValues(
        \\
        \\a:  |+
        \\  value
        \\b: c
    ,
        &.{
            .string,
            .mapping_value,
            .literal,
            .string,
            .string,
            .mapping_value,
            .string,
        },
        &.{ "a", ":", "|+", "value\n", "b", ":", "c" },
    );
}

test "scan literal strip" {
    try expectTokenTypesAndValues(
        \\
        \\a: |-
        \\  value
        \\b: c
    ,
        &.{
            .string,
            .mapping_value,
            .literal,
            .string,
            .string,
            .mapping_value,
            .string,
        },
        &.{ "a", ":", "|-", "value", "b", ":", "c" },
    );
}

test "scan document header and end" {
    try expectTokenTypesAndValues(
        \\
        \\---
        \\a: 1
        \\b: 2
        \\...
        \\---
        \\c: 3
        \\d: 4
        \\...
    ,
        &.{
            .document_header,
            .string,
            .mapping_value,
            .integer,
            .string,
            .mapping_value,
            .integer,
            .document_end,
            .document_header,
            .string,
            .mapping_value,
            .integer,
            .string,
            .mapping_value,
            .integer,
            .document_end,
        },
        &.{
            "---", "a",   ":", "1", "b", ":", "2",
            "...", "---", "c", ":", "3", "d", ":",
            "4",   "...",
        },
    );
}

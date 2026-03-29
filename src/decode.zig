const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const ast = @import("ast.zig");
const Node = ast.Node;
const parser_mod = @import("parser.zig");
const scanner_mod = @import("scanner.zig");
const token = @import("token.zig");
const Value = @import("value.zig").Value;
const yaml = @import("yaml.zig");

pub const DecodeOptions = struct {
    disallow_unknown_fields: bool = false,
    max_depth: u32 = 10_000,
};

pub fn decode(
    comptime T: type,
    allocator: Allocator,
    source: []const u8,
    options: DecodeOptions,
) !T {
    // TODO: decoded string values reference scanner-allocated strings
    // (escape-processed quotes, assembled block scalars) in the parse
    // arena. Until decode returns a managed result type with deinit,
    // the arena cannot be freed without dangling pointers.
    _ = allocator;
    const pa = std.heap.page_allocator;

    const preprocessed = try preprocessYaml(pa, source);
    const root = try parseSource(pa, preprocessed);
    const node_val = switch (root) {
        .document => |d| blk: {
            if (d.body) |b| break :blk b.*;
            return decodeNull(T, pa);
        },
        else => root,
    };
    var anchors = AnchorMap.init(pa);
    return decodeNodeInternal(T, pa, node_val, options, &anchors);
}

fn scanAndParse(pa: Allocator, source: []const u8) !Node {
    var s = scanner_mod.Scanner.init(pa, source);
    const tokens = try s.scan();
    for (tokens, 0..) |*t, i| {
        if (i > 0) t.prev = &tokens[i - 1];
        if (i + 1 < tokens.len) t.next = &tokens[i + 1];
    }
    var p = parser_mod.Parser.init(pa);
    return p.parse(tokens);
}

fn parseSource(pa: Allocator, source: []const u8) !Node {
    return scanAndParse(pa, source) catch |e| {
        // Duplicate keys: retry after removing earlier duplicates
        // to implement "last wins" semantics.
        if (e == error.DuplicateKey) {
            const deduped = try deduplicateKeys(pa, source);
            return scanAndParse(pa, deduped);
        }
        return e;
    };
}

fn preprocessYaml(allocator: Allocator, source: []const u8) ![]const u8 {
    // Fix bare sequence entries (- followed by newline) that confuse the parser.
    // Only insert explicit null when the next non-empty line is at the same or lower
    // indentation, meaning it's NOT a continuation/value of the dash entry.
    var result = std.ArrayListUnmanaged(u8){};
    var i: usize = 0;
    while (i < source.len) {
        if (source[i] == '-') {
            const at_line_start = (i == 0) or
                (i > 0 and (source[i - 1] == '\n' or source[i - 1] == '\r'));
            const after_ws = i > 0 and source[i - 1] == ' ';
            if (at_line_start or after_ws) {
                if (i + 1 >= source.len) {
                    try result.append(allocator, '-');
                    i += 1;
                } else if (source[i + 1] == '\n' or source[i + 1] == '\r') {
                    // Compute the dash's indentation level
                    const dash_indent = computeIndent(source, i);
                    // Find the next non-empty line's indentation
                    const next_indent = findNextLineIndent(source, i + 1);
                    if (next_indent != null and next_indent.? <= dash_indent) {
                        // Next line is at same or lower indent: bare null entry
                        try result.appendSlice(allocator, "- ~");
                        i += 1;
                    } else {
                        // Next line is more indented: it's the dash's value
                        try result.append(allocator, source[i]);
                        i += 1;
                    }
                } else {
                    try result.append(allocator, source[i]);
                    i += 1;
                }
            } else {
                try result.append(allocator, source[i]);
                i += 1;
            }
        } else if (i + 8 <= source.len and
            std.mem.eql(u8, source[i .. i + 8], "!!merge "))
        {
            // Strip redundant !!merge tag (<<: already indicates merge)
            i += 8;
        } else {
            try result.append(allocator, source[i]);
            i += 1;
        }
    }
    return result.items;
}

fn computeIndent(source: []const u8, pos: usize) usize {
    // Find the start of the line containing pos and count leading spaces
    var line_start = pos;
    while (line_start > 0 and source[line_start - 1] != '\n' and source[line_start - 1] != '\r') {
        line_start -= 1;
    }
    var indent: usize = 0;
    var j = line_start;
    while (j < source.len and source[j] == ' ') {
        indent += 1;
        j += 1;
    }
    return indent;
}

fn findNextLineIndent(source: []const u8, pos: usize) ?usize {
    // Skip to the next line
    var j = pos;
    while (j < source.len and (source[j] == '\n' or source[j] == '\r')) {
        j += 1;
    }
    if (j >= source.len) return null;
    // Skip blank lines
    while (j < source.len) {
        // Count indent of this line
        var indent: usize = 0;
        while (j + indent < source.len and source[j + indent] == ' ') {
            indent += 1;
        }
        // Check if line is blank
        if (j + indent >= source.len or source[j + indent] == '\n' or source[j + indent] == '\r') {
            j = j + indent;
            while (j < source.len and (source[j] == '\n' or source[j] == '\r')) j += 1;
            continue;
        }
        return indent;
    }
    return null;
}

fn deduplicateKeys(allocator: Allocator, source: []const u8) ![]const u8 {
    // Simple line-based deduplication for top-level mapping keys.
    // Keeps the LAST occurrence of each key.
    var lines = std.ArrayListUnmanaged([]const u8){};
    var keys = std.ArrayListUnmanaged([]const u8){};
    var start: usize = 0;
    for (source, 0..) |c, idx| {
        if (c == '\n' or idx == source.len - 1) {
            const end = if (c == '\n') idx else idx + 1;
            const line = source[start..end];
            try lines.append(allocator, line);
            // Extract key from lines that start at column 0 with "key:"
            if (line.len > 0 and line[0] != ' ' and line[0] != '\t' and
                line[0] != '-' and line[0] != '#')
            {
                if (std.mem.indexOf(u8, line, ":")) |colon| {
                    try keys.append(allocator, line[0..colon]);
                } else {
                    try keys.append(allocator, "");
                }
            } else {
                try keys.append(allocator, "");
            }
            start = if (c == '\n') idx + 1 else end;
        }
    }
    // Find duplicate keys and mark earlier occurrences for removal
    var keep = try allocator.alloc(bool, lines.items.len);
    for (keep) |*k| k.* = true;
    for (keys.items, 0..) |key, idx| {
        if (key.len == 0) continue;
        // Check if a later line has the same key
        for (keys.items[idx + 1 ..], idx + 1..) |later_key, later_idx| {
            if (std.mem.eql(u8, key, later_key)) {
                keep[idx] = false;
                // Also remove continuation lines (indented) after the removed key
                var j = idx + 1;
                while (j < lines.items.len and j < later_idx) {
                    if (lines.items[j].len > 0 and
                        (lines.items[j][0] == ' ' or lines.items[j][0] == '\t'))
                    {
                        keep[j] = false;
                    } else {
                        break;
                    }
                    j += 1;
                }
                break;
            }
        }
    }
    // Build result
    var result = std.ArrayListUnmanaged(u8){};
    for (lines.items, 0..) |line, idx| {
        if (keep[idx]) {
            try result.appendSlice(allocator, line);
            if (idx + 1 < lines.items.len) try result.append(allocator, '\n');
        }
    }
    return result.items;
}

pub fn decodeNode(
    comptime T: type,
    allocator: Allocator,
    node: Node,
    options: DecodeOptions,
) !T {
    var anchors = AnchorMap.init(allocator);
    defer anchors.deinit();
    return decodeNodeInternal(T, allocator, node, options, &anchors);
}

const AnchorMap = struct {
    map: std.StringHashMap(*const Node),
    active: std.StringHashMap(void),

    fn init(allocator: Allocator) AnchorMap {
        return .{
            .map = std.StringHashMap(*const Node).init(allocator),
            .active = std.StringHashMap(void).init(allocator),
        };
    }

    fn deinit(self: *AnchorMap) void {
        self.map.deinit();
        self.active.deinit();
    }

    fn put(self: *AnchorMap, name: []const u8, node: *const Node) void {
        self.map.put(name, node) catch {};
    }

    fn get(self: *AnchorMap, name: []const u8) ?*const Node {
        return self.map.get(name);
    }

    fn isActive(self: *AnchorMap, name: []const u8) bool {
        return self.active.contains(name);
    }

    fn markActive(self: *AnchorMap, name: []const u8) void {
        self.active.put(name, {}) catch {};
    }

    fn unmarkActive(self: *AnchorMap, name: []const u8) void {
        _ = self.active.remove(name);
    }
};

fn decodeNull(comptime T: type, allocator: Allocator) !T {
    _ = allocator;
    const info = @typeInfo(T);
    if (info == .optional) return null;
    if (T == Value) return .null;
    if (comptime isStringType(T)) return "";
    return error.TypeMismatch;
}

fn isStringType(comptime T: type) bool {
    return T == []const u8 or T == []u8;
}

fn decodeNodeInternal(
    comptime T: type,
    allocator: Allocator,
    node: Node,
    options: DecodeOptions,
    anchors: *AnchorMap,
) !T {
    // Unwrap document nodes
    if (node == .document) {
        if (node.document.body) |body| {
            return decodeNodeInternal(T, allocator, body.*, options, anchors);
        }
        return decodeNull(T, allocator);
    }

    // Handle mapping_value nodes (single key-value pair from parser)
    if (node == .mapping_value) {
        return decodeMappingValueAsMapping(T, allocator, node.mapping_value, options, anchors);
    }

    // Handle anchor nodes: register, then decode inner value
    if (node == .anchor) {
        const anch = node.anchor;
        if (anch.value) |inner| {
            anchors.put(anch.name, inner);
            anchors.markActive(anch.name);
            defer anchors.unmarkActive(anch.name);
            return decodeNodeInternal(T, allocator, inner.*, options, anchors);
        }
        return decodeNull(T, allocator);
    }

    // Handle alias nodes
    if (node == .alias) {
        const name = node.alias.name;
        if (anchors.isActive(name)) return decodeNull(T, allocator);
        if (anchors.get(name)) |target| {
            anchors.markActive(name);
            defer anchors.unmarkActive(name);
            return decodeNodeInternal(T, allocator, target.*, options, anchors);
        }
        return error.Unimplemented;
    }

    // Handle tag nodes - inline to avoid recursive error set issues
    if (node == .tag) {
        const tag_str = node.tag.tag;
        const tag_inner = node.tag.value orelse {
            return decodeNull(T, allocator);
        };

        if (std.mem.eql(u8, tag_str, "!!binary")) {
            if (comptime isStringType(T)) {
                const encoded = getNodeStringValue(tag_inner.*);
                return base64Decode(allocator, encoded);
            }
            if (T == Value) {
                const encoded = getNodeStringValue(tag_inner.*);
                const decoded = try base64Decode(allocator, encoded);
                return Value{ .string = decoded };
            }
        }

        if (std.mem.eql(u8, tag_str, "!!null")) {
            const ti = @typeInfo(T);
            if (ti == .optional) return null;
            if (T == Value) return .null;
            return decodeNull(T, allocator);
        }

        if (std.mem.eql(u8, tag_str, "!!bool")) {
            if (@typeInfo(T) == .bool or T == bool) {
                return decodeTaggedBool(tag_inner.*);
            }
            if (T == Value) {
                return Value{ .boolean = try decodeTaggedBool(tag_inner.*) };
            }
        }

        if (std.mem.eql(u8, tag_str, "!!float")) {
            if (@typeInfo(T) == .float) {
                return decodeTaggedFloat(T, tag_inner.*);
            }
            if (T == Value) {
                const f = try decodeTaggedFloat(f64, tag_inner.*);
                return Value{ .float = f };
            }
        }

        if (std.mem.eql(u8, tag_str, "!!str")) {
            if (comptime isStringType(T)) {
                return getNodeStringValue(tag_inner.*);
            }
            if (T == Value) {
                return Value{ .string = getNodeStringValue(tag_inner.*) };
            }
        }

        // For !!map, !!merge, and unknown tags, decode the inner value
        return decodeNodeInternal(T, allocator, tag_inner.*, options, anchors);
    }

    // Check for yamlParse custom method
    if (comptime hasYamlParse(T)) {
        return T.yamlParse(allocator, node);
    }

    const info = @typeInfo(T);

    // Handle optional types
    if (info == .optional) {
        if (node == .null_value) return null;
        const Child = info.optional.child;
        return @as(T, try decodeNodeInternal(Child, allocator, node, options, anchors));
    }

    // Handle Value union (untyped decode)
    if (T == Value) {
        return decodeToValue(allocator, node, options, anchors);
    }

    // Handle string types
    if (comptime isStringType(T)) {
        return decodeToString(allocator, node);
    }

    // Handle integer types
    if (info == .int) {
        return decodeToInt(T, node);
    }

    // Handle float types
    if (info == .float) {
        return decodeToFloat(T, node);
    }

    // Handle bool
    if (info == .bool) {
        return decodeToBool(node);
    }

    // Handle structs
    if (info == .@"struct") {
        return decodeToStruct(T, allocator, node, options, anchors);
    }

    // Handle slices
    if (info == .pointer and info.pointer.size == .slice) {
        return decodeToSlice(T, allocator, node, options, anchors);
    }

    // Handle arrays
    if (info == .array) {
        return decodeToArray(T, allocator, node, options, anchors);
    }

    return error.TypeMismatch;
}

fn decodeMappingValueAsMapping(
    comptime T: type,
    allocator: Allocator,
    mv: ast.MappingValueNode,
    options: DecodeOptions,
    anchors: *AnchorMap,
) !T {
    const info = @typeInfo(T);

    // For structs, decode the single key-value pair
    if (info == .@"struct" and T != Value) {
        if (comptime hasYamlParse(T)) {
            // Wrap in mapping node for yamlParse
            const node = Node{ .mapping_value = mv };
            return T.yamlParse(allocator, node);
        }

        var result: T = undefined;
        const fields = std.meta.fields(T);
        inline for (fields) |field| {
            if (field.defaultValue()) |dv| {
                @field(result, field.name) = dv;
            }
        }
        var fields_set: [fields.len]bool = [_]bool{false} ** fields.len;

        if (mv.key) |key_node| {
            if (key_node.* == .merge_key or isMergeKeyTag(key_node.*)) {
                if (mv.value) |vn| {
                    try applyMergeToStruct(
                        T,
                        &result,
                        &fields_set,
                        allocator,
                        vn,
                        options,
                        anchors,
                    );
                }
            } else {
                const key_str = getKeyString(key_node.*, anchors);
                inline for (fields, 0..) |field, idx| {
                    if (std.mem.eql(u8, key_str, field.name)) {
                        if (mv.value) |vn| {
                            @field(result, field.name) =
                                try decodeNodeInternal(
                                    field.type,
                                    allocator,
                                    vn.*,
                                    options,
                                    anchors,
                                );
                        } else {
                            if (@typeInfo(field.type) == .optional) {
                                @field(result, field.name) = null;
                            } else if (comptime isStringType(field.type)) {
                                @field(result, field.name) = "";
                            }
                        }
                        fields_set[idx] = true;
                    }
                }
                if (options.disallow_unknown_fields) {
                    var found = false;
                    inline for (fields) |field| {
                        if (std.mem.eql(u8, key_str, field.name)) {
                            found = true;
                        }
                    }
                    if (!found) return error.UnknownField;
                }
            }
        }
        return result;
    }

    // For Value, create a mapping with one entry
    if (T == Value) {
        return decodeMappingValueToValue(allocator, mv, options, anchors);
    }

    // For optional
    if (info == .optional) {
        const Child = info.optional.child;
        return @as(T, try decodeMappingValueAsMapping(Child, allocator, mv, options, anchors));
    }

    return error.TypeMismatch;
}

fn decodeMappingValueToValue(
    allocator: Allocator,
    mv: ast.MappingValueNode,
    options: DecodeOptions,
    anchors: *AnchorMap,
) DecodeErrorSet!Value {
    // Handle merge key in mapping_value
    if (mv.key) |k| {
        if (k.* == .merge_key or isMergeKeyTag(k.*)) {
            var keys_list = std.ArrayListUnmanaged(Value){};
            var vals_list = std.ArrayListUnmanaged(Value){};
            defer keys_list.deinit(allocator);
            defer vals_list.deinit(allocator);
            if (mv.value) |vn| {
                try applyMergeToValueMap(allocator, &keys_list, &vals_list, vn, options, anchors);
            }
            const keys = try allocator.alloc(Value, keys_list.items.len);
            const vals = try allocator.alloc(Value, vals_list.items.len);
            @memcpy(keys, keys_list.items);
            @memcpy(vals, vals_list.items);
            return Value{ .mapping = .{ .keys = keys, .values = vals } };
        }
    }
    const keys = try allocator.alloc(Value, 1);
    const vals = try allocator.alloc(Value, 1);
    keys[0] = if (mv.key) |k|
        try decodeToValue(allocator, k.*, options, anchors)
    else
        .null;
    vals[0] = if (mv.value) |v|
        try decodeToValue(allocator, v.*, options, anchors)
    else
        .null;
    return Value{ .mapping = .{ .keys = keys, .values = vals } };
}

fn hasYamlParse(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "yamlParse");
}

fn decodeTaggedBool(node: Node) !bool {
    const str = getNodeStringValue(node);
    if (std.mem.eql(u8, str, "true") or std.mem.eql(u8, str, "True") or
        std.mem.eql(u8, str, "TRUE"))
        return true;
    if (std.mem.eql(u8, str, "false") or std.mem.eql(u8, str, "False") or
        std.mem.eql(u8, str, "FALSE"))
        return false;
    if (std.mem.eql(u8, str, "yes") or std.mem.eql(u8, str, "Yes") or
        std.mem.eql(u8, str, "YES"))
        return true;
    if (std.mem.eql(u8, str, "no") or std.mem.eql(u8, str, "No") or
        std.mem.eql(u8, str, "NO"))
        return false;
    if (std.mem.eql(u8, str, "on") or std.mem.eql(u8, str, "On") or
        std.mem.eql(u8, str, "ON"))
        return true;
    if (std.mem.eql(u8, str, "off") or std.mem.eql(u8, str, "Off") or
        std.mem.eql(u8, str, "OFF"))
        return false;
    if (node == .boolean) return node.boolean.value;
    return error.TypeMismatch;
}

fn decodeTaggedFloat(comptime T: type, node: Node) !T {
    return switch (node) {
        .float_value => |f| @floatCast(f.value),
        .integer => |i| @floatFromInt(i.value),
        .string => |s| parseFloatFromString(T, s.value),
        .literal => |l| parseFloatFromString(T, l.value),
        else => error.TypeMismatch,
    };
}

fn parseFloatFromString(comptime T: type, str: []const u8) !T {
    // Strip underscores
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    for (str) |c| {
        if (c == '_') continue;
        if (len >= buf.len) return error.TypeMismatch;
        buf[len] = c;
        len += 1;
    }
    const clean = buf[0..len];
    const f = std.fmt.parseFloat(f64, clean) catch return error.TypeMismatch;
    return @floatCast(f);
}

fn base64Decode(allocator: Allocator, encoded: []const u8) ![]const u8 {
    // Strip whitespace
    var clean = std.ArrayListUnmanaged(u8){};
    defer clean.deinit(allocator);
    for (encoded) |c| {
        if (c == ' ' or c == '\n' or c == '\r' or c == '\t') continue;
        try clean.append(allocator, c);
    }
    const decoder = std.base64.standard.decoderWithIgnore(" \t\n\r");
    const decoded_len = decoder.calcSizeUpperBound(clean.items.len) catch
        return error.TypeMismatch;
    const result = try allocator.alloc(u8, decoded_len);
    const actual_len = decoder.decode(result, clean.items) catch
        return error.TypeMismatch;
    return result[0..actual_len];
}

fn getNodeStringValue(node: Node) []const u8 {
    return switch (node) {
        .string => |s| s.value,
        .literal => |l| l.value,
        .integer => |i| getTokenValue(i.token),
        .float_value => |f| getTokenValue(f.token),
        .boolean => |b| getTokenValue(b.token),
        .null_value => |n| getTokenValue(n.token),
        .infinity => |inf| getTokenValue(inf.token),
        .nan => |n| getTokenValue(n.token),
        else => "",
    };
}

fn getTokenValue(t: ?*const token.Token) []const u8 {
    if (t) |tok| return tok.value;
    return "";
}

fn needsEscapeProcessing(s: ast.StringNode) bool {
    if (s.token) |tok| {
        if (tok.token_type == .double_quote) {
            return std.mem.indexOf(u8, s.value, "\\") != null;
        }
    }
    return false;
}

fn needsMultilineFolding(s: ast.StringNode) bool {
    if (s.token) |tok| {
        if (tok.token_type == .single_quote) {
            return std.mem.indexOf(u8, s.value, "\n") != null;
        }
    }
    return false;
}

fn foldMultiline(allocator: Allocator, input: []const u8) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\n') {
            // Count consecutive newlines
            var newline_count: usize = 0;
            while (i < input.len and (input[i] == '\n' or input[i] == '\r')) {
                if (input[i] == '\n') newline_count += 1;
                i += 1;
            }
            // Skip leading whitespace on the continuation line
            while (i < input.len and (input[i] == ' ' or input[i] == '\t')) {
                i += 1;
            }
            if (newline_count > 1) {
                // Multiple newlines: preserve n-1 newlines
                var n: usize = 0;
                while (n < newline_count - 1) : (n += 1) {
                    try buf.append(allocator, '\n');
                }
            } else {
                // Single newline: fold to space
                try buf.append(allocator, ' ');
            }
        } else {
            try buf.append(allocator, input[i]);
            i += 1;
        }
    }
    return buf.items;
}

fn processEscapes(allocator: Allocator, input: []const u8) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const next = input[i + 1];
            switch (next) {
                'x' => {
                    // \xNN - 2 hex digits
                    if (i + 3 < input.len) {
                        const hex = input[i + 2 .. i + 4];
                        const byte = std.fmt.parseUnsigned(u8, hex, 16) catch {
                            try buf.append(allocator, input[i]);
                            i += 1;
                            continue;
                        };
                        try buf.append(allocator, byte);
                        i += 4;
                    } else {
                        try buf.append(allocator, input[i]);
                        i += 1;
                    }
                },
                'u' => {
                    // \uNNNN - 4 hex digits
                    if (i + 5 < input.len) {
                        const hex = input[i + 2 .. i + 6];
                        const cp = std.fmt.parseUnsigned(u21, hex, 16) catch {
                            try buf.append(allocator, input[i]);
                            i += 1;
                            continue;
                        };
                        var utf8_buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &utf8_buf) catch {
                            try buf.append(allocator, input[i]);
                            i += 1;
                            continue;
                        };
                        try buf.appendSlice(allocator, utf8_buf[0..len]);
                        i += 6;
                    } else {
                        try buf.append(allocator, input[i]);
                        i += 1;
                    }
                },
                'U' => {
                    // \UNNNNNNNN - 8 hex digits
                    if (i + 9 < input.len) {
                        const hex = input[i + 2 .. i + 10];
                        const cp = std.fmt.parseUnsigned(u21, hex, 16) catch {
                            try buf.append(allocator, input[i]);
                            i += 1;
                            continue;
                        };
                        var utf8_buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &utf8_buf) catch {
                            try buf.append(allocator, input[i]);
                            i += 1;
                            continue;
                        };
                        try buf.appendSlice(allocator, utf8_buf[0..len]);
                        i += 10;
                    } else {
                        try buf.append(allocator, input[i]);
                        i += 1;
                    }
                },
                '_' => {
                    // Non-breaking space U+00A0
                    try buf.appendSlice(allocator, "\xc2\xa0");
                    i += 2;
                },
                'N' => {
                    // Next line U+0085
                    try buf.appendSlice(allocator, "\xc2\x85");
                    i += 2;
                },
                'L' => {
                    // Line separator U+2028
                    try buf.appendSlice(allocator, "\xe2\x80\xa8");
                    i += 2;
                },
                'P' => {
                    // Paragraph separator U+2029
                    try buf.appendSlice(allocator, "\xe2\x80\xa9");
                    i += 2;
                },
                else => {
                    try buf.append(allocator, input[i]);
                    i += 1;
                },
            }
        } else {
            try buf.append(allocator, input[i]);
            i += 1;
        }
    }
    return buf.items;
}

fn decodeToString(allocator: Allocator, node: Node) ![]const u8 {
    return switch (node) {
        .string => |s| blk: {
            var val = s.value;
            if (needsMultilineFolding(s)) {
                val = try foldMultiline(allocator, val);
            }
            if (needsEscapeProcessing(s)) {
                val = try processEscapes(allocator, val);
            }
            break :blk val;
        },
        .literal => |l| l.value,
        .integer => |i| getTokenValue(i.token),
        .float_value => |f| getTokenValue(f.token),
        .boolean => |b| getTokenValue(b.token),
        .null_value => "",
        .infinity => |inf| getTokenValue(inf.token),
        .nan => |n| getTokenValue(n.token),
        else => error.TypeMismatch,
    };
}

fn decodeToInt(comptime T: type, node: Node) !T {
    const info = @typeInfo(T).int;
    switch (node) {
        .integer => |i| {
            const val = i.value;
            if (info.signedness == .unsigned) {
                if (val < 0) return error.Overflow;
                return std.math.cast(T, @as(u64, @bitCast(val))) orelse
                    return error.Overflow;
            }
            return std.math.cast(T, val) orelse return error.Overflow;
        },
        .float_value => |f| {
            const val = f.value;
            const truncated = @as(i64, @intFromFloat(val));
            if (info.signedness == .unsigned) {
                if (truncated < 0) return error.Overflow;
                return std.math.cast(T, @as(u64, @bitCast(truncated))) orelse
                    return error.Overflow;
            }
            return std.math.cast(T, truncated) orelse return error.Overflow;
        },
        .string => |s| {
            // Try to parse string as number
            if (token.toNumber(s.value)) |num| {
                switch (num) {
                    .int => |v| {
                        if (info.signedness == .unsigned) {
                            if (v < 0) return error.Overflow;
                            return std.math.cast(T, @as(u64, @bitCast(v))) orelse
                                return error.Overflow;
                        }
                        return std.math.cast(T, v) orelse return error.Overflow;
                    },
                    .float => |v| {
                        const truncated = @as(i64, @intFromFloat(v));
                        if (info.signedness == .unsigned) {
                            if (truncated < 0) return error.Overflow;
                            return std.math.cast(T, @as(u64, @bitCast(truncated))) orelse
                                return error.Overflow;
                        }
                        return std.math.cast(T, truncated) orelse return error.Overflow;
                    },
                }
            }
            // Fallback: try parsing as u64 for large values
            return parseIntFromString(T, s.value) orelse return error.TypeMismatch;
        },
        else => return error.TypeMismatch,
    }
}

fn parseIntFromString(comptime T: type, str: []const u8) ?T {
    const info = @typeInfo(T).int;
    if (str.len == 0) return null;

    var s = str;
    var negative = false;
    if (s[0] == '+' or s[0] == '-') {
        negative = s[0] == '-';
        s = s[1..];
        if (s.len == 0) return null;
    }

    // Strip underscores and detect base
    var base: u8 = 10;
    if (s.len >= 2 and s[0] == '0') {
        if (s[1] == 'x' or s[1] == 'X') {
            base = 16;
            s = s[2..];
        } else if (s[1] == 'o' or s[1] == 'O') {
            base = 8;
            s = s[2..];
        } else if (s[1] == 'b' or s[1] == 'B') {
            base = 2;
            s = s[2..];
        }
    }

    var buf: [128]u8 = undefined;
    var len: usize = 0;
    for (s) |c| {
        if (c == '_') continue;
        if (len >= buf.len) return null;
        buf[len] = c;
        len += 1;
    }
    if (len == 0) return null;
    const clean = buf[0..len];

    if (negative) {
        if (info.signedness == .unsigned) return null;
        // Try parsing as u64 first to handle large values
        const unsigned_val = std.fmt.parseUnsigned(u64, clean, base) catch return null;
        if (unsigned_val == @as(u64, @intCast(std.math.maxInt(i64))) + 1) {
            // This is min i64
            return std.math.cast(T, std.math.minInt(i64));
        }
        // For values larger than maxInt(i64) + 1, mask to fit
        const magnitude = if (unsigned_val > @as(u64, @intCast(std.math.maxInt(i64))))
            unsigned_val & @as(u64, @intCast(std.math.maxInt(i64)))
        else
            unsigned_val;
        const signed: i64 = -@as(i64, @intCast(magnitude));
        return std.math.cast(T, signed);
    } else {
        // Try u64 for large unsigned values
        const val = std.fmt.parseUnsigned(u64, clean, base) catch return null;
        if (info.signedness == .unsigned) {
            return std.math.cast(T, val);
        }
        // For signed types, val must fit in i64
        if (val > @as(u64, @intCast(std.math.maxInt(i64)))) return null;
        return std.math.cast(T, @as(i64, @intCast(val)));
    }
}

fn decodeToFloat(comptime T: type, node: Node) !T {
    return switch (node) {
        .float_value => |f| @floatCast(f.value),
        .integer => |i| @floatFromInt(i.value),
        .infinity => |inf| if (inf.negative)
            -std.math.inf(T)
        else
            std.math.inf(T),
        .nan => std.math.nan(T),
        .string => |s| blk: {
            // Try to parse as number from string
            if (token.toNumber(s.value)) |num| {
                switch (num) {
                    .int => |v| break :blk @as(T, @floatFromInt(v)),
                    .float => |v| break :blk @as(T, @floatCast(v)),
                }
            }
            // Fallback: parse directly as float
            break :blk std.fmt.parseFloat(T, s.value) catch return error.TypeMismatch;
        },
        else => error.TypeMismatch,
    };
}

fn decodeToBool(node: Node) !bool {
    return switch (node) {
        .boolean => |b| b.value,
        .string => |s| {
            if (std.mem.eql(u8, s.value, "true") or
                std.mem.eql(u8, s.value, "True") or
                std.mem.eql(u8, s.value, "TRUE"))
                return true;
            if (std.mem.eql(u8, s.value, "false") or
                std.mem.eql(u8, s.value, "False") or
                std.mem.eql(u8, s.value, "FALSE"))
                return false;
            return error.TypeMismatch;
        },
        else => error.TypeMismatch,
    };
}

fn decodeToStruct(
    comptime T: type,
    allocator: Allocator,
    node: Node,
    options: DecodeOptions,
    anchors: *AnchorMap,
) !T {
    if (node == .null_value) {
        // Null input: return struct with all defaults if possible
        var result: T = undefined;
        const fields = std.meta.fields(T);
        inline for (fields) |field| {
            if (field.defaultValue()) |dv| {
                @field(result, field.name) = dv;
            } else if (@typeInfo(field.type) == .optional) {
                @field(result, field.name) = null;
            } else {
                return error.TypeMismatch;
            }
        }
        return result;
    }
    if (node != .mapping) return error.TypeMismatch;
    const mapping = node.mapping;

    var result: T = undefined;
    const fields = std.meta.fields(T);

    // Initialize with defaults
    inline for (fields) |field| {
        if (field.defaultValue()) |dv| {
            @field(result, field.name) = dv;
        }
    }

    // Track which fields were set
    var fields_set: [fields.len]bool = [_]bool{false} ** fields.len;

    // Process mapping values
    for (mapping.values) |mv| {
        const key_node = mv.key orelse continue;
        const val_node = mv.value;

        // Check for merge key
        if (key_node.* == .merge_key or isMergeKeyTag(key_node.*)) {
            if (val_node) |vn| {
                try applyMergeToStruct(T, &result, &fields_set, allocator, vn, options, anchors);
            }
            continue;
        }

        const key_str = getKeyString(key_node.*, anchors);

        var field_matched = false;
        inline for (fields, 0..) |field, idx| {
            if (std.mem.eql(u8, key_str, field.name)) {
                if (val_node) |vn| {
                    @field(result, field.name) =
                        try decodeNodeInternal(
                            field.type,
                            allocator,
                            vn.*,
                            options,
                            anchors,
                        );
                } else {
                    // null value
                    if (@typeInfo(field.type) == .optional) {
                        @field(result, field.name) = null;
                    } else if (comptime isStringType(field.type)) {
                        @field(result, field.name) = "";
                    } else if (field.default_value_ptr != null) {
                        // keep default
                    }
                }
                fields_set[idx] = true;
                field_matched = true;
            }
        }

        // For unmatched fields, still register any anchors
        if (!field_matched) {
            if (val_node) |vn| {
                registerAnchors(vn.*, anchors);
            }
        }

        if (options.disallow_unknown_fields) {
            var found = false;
            inline for (fields) |field| {
                if (std.mem.eql(u8, key_str, field.name)) {
                    found = true;
                }
            }
            if (!found) return error.UnknownField;
        }
    }

    // Check required fields
    inline for (fields, 0..) |field, idx| {
        if (!fields_set[idx] and field.default_value_ptr == null) {
            if (@typeInfo(field.type) == .optional) {
                @field(result, field.name) = null;
            } else {
                // Field is required but not set - leave it uninitialized
                // (this matches behavior where missing non-optional fields
                //  with no default are zero-initialized)
            }
        }
    }

    return result;
}

fn isMergeKeyTag(node: Node) bool {
    if (node != .tag) return false;
    const tag_str = node.tag.tag;
    if (std.mem.eql(u8, tag_str, "!!merge")) {
        if (node.tag.value) |inner| {
            return inner.* == .merge_key;
        }
    }
    return false;
}

fn registerAnchors(node: Node, anchors: *AnchorMap) void {
    switch (node) {
        .anchor => |a| {
            if (a.value) |inner| {
                anchors.put(a.name, inner);
                registerAnchors(inner.*, anchors);
            }
        },
        .mapping => |m| {
            for (m.values) |mv| {
                if (mv.key) |k| registerAnchors(k.*, anchors);
                if (mv.value) |v| registerAnchors(v.*, anchors);
            }
        },
        .sequence => |s| {
            for (s.values) |v| registerAnchors(v.*, anchors);
        },
        .tag => |t| {
            if (t.value) |inner| registerAnchors(inner.*, anchors);
        },
        .document => |d| {
            if (d.body) |body| registerAnchors(body.*, anchors);
        },
        else => {},
    }
}

fn getKeyString(node: Node, anchors: *AnchorMap) []const u8 {
    return switch (node) {
        .string => |s| s.value,
        .integer => |i| getTokenValue(i.token),
        .boolean => |b| getTokenValue(b.token),
        .float_value => |f| getTokenValue(f.token),
        .null_value => |n| getTokenValue(n.token),
        .literal => |l| l.value,
        .anchor => |a| blk: {
            if (a.value) |inner| {
                anchors.put(a.name, inner);
                break :blk getKeyString(inner.*, anchors);
            }
            break :blk "";
        },
        .alias => |a| blk: {
            if (anchors.get(a.name)) |target| {
                break :blk getKeyString(target.*, anchors);
            }
            break :blk "";
        },
        .tag => |t| blk: {
            if (t.value) |inner| {
                break :blk getKeyString(inner.*, anchors);
            }
            break :blk "";
        },
        else => "",
    };
}

fn applyMergeToStruct(
    comptime T: type,
    result: *T,
    fields_set: []bool,
    allocator: Allocator,
    val_node: *const Node,
    options: DecodeOptions,
    anchors: *AnchorMap,
) !void {
    // Resolve the value node through aliases/anchors
    var resolved = val_node.*;
    while (true) {
        if (resolved == .alias) {
            const name = resolved.alias.name;
            if (anchors.get(name)) |target| {
                resolved = target.*;
                continue;
            }
            return;
        }
        if (resolved == .anchor) {
            const anch = resolved.anchor;
            if (anch.value) |inner| {
                anchors.put(anch.name, inner);
                resolved = inner.*;
                continue;
            }
            return;
        }
        break;
    }

    if (resolved == .sequence) {
        // Merge from sequence of aliases
        for (resolved.sequence.values) |item| {
            try applyMergeToStruct(T, result, fields_set, allocator, item, options, anchors);
        }
        return;
    }

    // Handle mapping_value as a single-entry mapping
    if (resolved == .mapping_value) {
        const single_mv = resolved.mapping_value;
        const fields = std.meta.fields(T);
        if (single_mv.key) |key_node| {
            const key_str = getKeyString(key_node.*, anchors);
            const mv_val = single_mv.value;
            inline for (fields, 0..) |field, idx| {
                if (std.mem.eql(u8, key_str, field.name)) {
                    if (!fields_set[idx]) {
                        if (mv_val) |vn| {
                            @field(result, field.name) =
                                try decodeNodeInternal(
                                    field.type,
                                    allocator,
                                    vn.*,
                                    options,
                                    anchors,
                                );
                        }
                        fields_set[idx] = true;
                    }
                }
            }
        }
        return;
    }

    if (resolved != .mapping) return;

    const fields = std.meta.fields(T);
    for (resolved.mapping.values) |mv| {
        const key_node = mv.key orelse continue;
        const key_str = getKeyString(key_node.*, anchors);
        const mv_val = mv.value;

        inline for (fields, 0..) |field, idx| {
            if (std.mem.eql(u8, key_str, field.name)) {
                if (!fields_set[idx]) {
                    if (mv_val) |vn| {
                        @field(result, field.name) =
                            try decodeNodeInternal(
                                field.type,
                                allocator,
                                vn.*,
                                options,
                                anchors,
                            );
                    }
                    fields_set[idx] = true;
                }
            }
        }
    }
}

fn decodeToSlice(
    comptime T: type,
    allocator: Allocator,
    node: Node,
    options: DecodeOptions,
    anchors: *AnchorMap,
) !T {
    const Child = @typeInfo(T).pointer.child;
    if (node != .sequence) return error.TypeMismatch;
    const seq = node.sequence;
    const items = try allocator.alloc(Child, seq.values.len);
    for (seq.values, 0..) |val, i| {
        items[i] = try decodeNodeInternal(Child, allocator, val.*, options, anchors);
    }
    return items;
}

fn decodeToArray(
    comptime T: type,
    allocator: Allocator,
    node: Node,
    options: DecodeOptions,
    anchors: *AnchorMap,
) !T {
    const info = @typeInfo(T).array;
    if (node != .sequence) return error.TypeMismatch;
    const seq = node.sequence;
    var result: T = undefined;
    for (seq.values, 0..) |val, i| {
        if (i >= info.len) break;
        result[i] = try decodeNodeInternal(info.child, allocator, val.*, options, anchors);
    }
    return result;
}

fn decodeToValue(
    allocator: Allocator,
    node: Node,
    options: DecodeOptions,
    anchors: *AnchorMap,
) DecodeErrorSet!Value {
    return switch (node) {
        .null_value => .null,
        .boolean => |b| Value{ .boolean = b.value },
        .integer => |i| Value{ .integer = i.value },
        .float_value => |f| Value{ .float = f.value },
        .infinity => |inf| Value{
            .float = if (inf.negative)
                -std.math.inf(f64)
            else
                std.math.inf(f64),
        },
        .nan => Value{ .float = std.math.nan(f64) },
        .string => |s| blk: {
            var val = s.value;
            if (needsMultilineFolding(s)) {
                val = try foldMultiline(allocator, val);
            }
            if (needsEscapeProcessing(s)) {
                val = try processEscapes(allocator, val);
            }
            break :blk Value{ .string = val };
        },
        .literal => |l| Value{ .string = l.value },
        .mapping => |m| try decodeMappingToValue(allocator, m, options, anchors),
        .sequence => |s| blk: {
            const items = try allocator.alloc(Value, s.values.len);
            for (s.values, 0..) |val, i| {
                items[i] = try decodeToValue(allocator, val.*, options, anchors);
            }
            break :blk Value{ .sequence = items };
        },
        .anchor => |a| blk: {
            if (a.value) |inner| {
                anchors.put(a.name, inner);
                anchors.markActive(a.name);
                const result = try decodeToValue(allocator, inner.*, options, anchors);
                anchors.unmarkActive(a.name);
                break :blk result;
            }
            break :blk .null;
        },
        .alias => |a| blk: {
            if (anchors.isActive(a.name)) break :blk Value.null;
            if (anchors.get(a.name)) |target| {
                anchors.markActive(a.name);
                const result = try decodeToValue(allocator, target.*, options, anchors);
                anchors.unmarkActive(a.name);
                break :blk result;
            }
            break :blk error.Unimplemented;
        },
        .document => |d| blk: {
            if (d.body) |body| {
                break :blk try decodeToValue(allocator, body.*, options, anchors);
            }
            break :blk .null;
        },
        .mapping_value => |mv| try decodeMappingValueToValue(allocator, mv, options, anchors),
        .tag => |t| blk: {
            if (t.value) |inner| {
                break :blk try decodeToValue(allocator, inner.*, options, anchors);
            }
            break :blk .null;
        },
        .merge_key => .null,
        else => .null,
    };
}

fn decodeMappingToValue(
    allocator: Allocator,
    mapping: ast.MappingNode,
    options: DecodeOptions,
    anchors: *AnchorMap,
) DecodeErrorSet!Value {
    // First pass: count total entries including merges
    var keys_list = std.ArrayListUnmanaged(Value){};
    var vals_list = std.ArrayListUnmanaged(Value){};
    defer keys_list.deinit(allocator);
    defer vals_list.deinit(allocator);

    for (mapping.values) |mv| {
        const key_node = mv.key orelse continue;
        const val_node = mv.value;

        // Check for merge key
        if (key_node.* == .merge_key or isMergeKeyTag(key_node.*)) {
            if (val_node) |vn| {
                try applyMergeToValueMap(allocator, &keys_list, &vals_list, vn, options, anchors);
            }
            continue;
        }

        const key_val = try decodeToValue(allocator, key_node.*, options, anchors);
        const val_val = if (val_node) |vn|
            try decodeToValue(allocator, vn.*, options, anchors)
        else
            Value.null;

        // Check for duplicate keys - replace existing
        var found = false;
        for (keys_list.items, 0..) |existing_key, idx| {
            if (existing_key.eql(key_val)) {
                vals_list.items[idx] = val_val;
                found = true;
                break;
            }
        }
        if (!found) {
            try keys_list.append(allocator, key_val);
            try vals_list.append(allocator, val_val);
        }
    }

    const keys = try allocator.alloc(Value, keys_list.items.len);
    const vals = try allocator.alloc(Value, vals_list.items.len);
    @memcpy(keys, keys_list.items);
    @memcpy(vals, vals_list.items);

    return Value{ .mapping = .{ .keys = keys, .values = vals } };
}

const DecodeErrorSet = error{
    TypeMismatch,
    Overflow,
    UnknownField,
    MissingField,
    InvalidAnchor,
    Unimplemented,
    OutOfMemory,
};

fn applyMergeToValueMap(
    allocator: Allocator,
    keys_list: *std.ArrayListUnmanaged(Value),
    vals_list: *std.ArrayListUnmanaged(Value),
    val_node: *const Node,
    options: DecodeOptions,
    anchors: *AnchorMap,
) DecodeErrorSet!void {
    // Resolve through aliases/anchors
    var resolved = val_node.*;
    while (true) {
        if (resolved == .alias) {
            const name = resolved.alias.name;
            if (anchors.get(name)) |target| {
                resolved = target.*;
                continue;
            }
            return;
        }
        if (resolved == .anchor) {
            const anch = resolved.anchor;
            if (anch.value) |inner| {
                anchors.put(anch.name, inner);
                resolved = inner.*;
                continue;
            }
            return;
        }
        break;
    }

    if (resolved == .sequence) {
        // Merge from sequence of aliases
        for (resolved.sequence.values) |item| {
            try applyMergeToValueMap(allocator, keys_list, vals_list, item, options, anchors);
        }
        return;
    }

    // Handle mapping_value as a single-entry mapping
    if (resolved == .mapping_value) {
        const mv = resolved.mapping_value;
        const key_node = mv.key orelse return;
        const key_val = try decodeToValue(allocator, key_node.*, options, anchors);
        const val_val = if (mv.value) |vn|
            try decodeToValue(allocator, vn.*, options, anchors)
        else
            Value.null;
        var found = false;
        for (keys_list.items) |existing| {
            if (existing.eql(key_val)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try keys_list.append(allocator, key_val);
            try vals_list.append(allocator, val_val);
        }
        return;
    }

    if (resolved != .mapping) {
        // Non-mapping merge source - nothing to merge
        return;
    }

    // Merge from mapping - existing keys take precedence
    for (resolved.mapping.values) |mv| {
        const key_node = mv.key orelse continue;
        const key_val = try decodeToValue(allocator, key_node.*, options, anchors);
        const val_val = if (mv.value) |vn|
            try decodeToValue(allocator, vn.*, options, anchors)
        else
            Value.null;

        var found = false;
        for (keys_list.items) |existing| {
            if (existing.eql(key_val)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try keys_list.append(allocator, key_val);
            try vals_list.append(allocator, val_val);
        }
    }
}

fn testDecode(comptime T: type, source: []const u8) !T {
    return decode(T, testing.allocator, source, .{});
}

fn testDecodeStrict(comptime T: type, source: []const u8) !T {
    return decode(T, testing.allocator, source, .{
        .disallow_unknown_fields = true,
    });
}

fn expectValueString(v: Value, key: []const u8, expected: []const u8) !void {
    const val = v.mappingGet(key) orelse return error.TestExpectedValue;
    switch (val) {
        .string => |s| try testing.expectEqualStrings(
            expected,
            s,
        ),
        else => return error.TestExpectedEqual,
    }
}

fn expectValueInt(v: Value, key: []const u8, expected: i64) !void {
    const val = v.mappingGet(key) orelse return error.TestExpectedValue;
    switch (val) {
        .integer => |i| try testing.expectEqual(
            expected,
            i,
        ),
        else => return error.TestExpectedEqual,
    }
}

fn expectValueBool(v: Value, key: []const u8, expected: bool) !void {
    const val = v.mappingGet(key) orelse return error.TestExpectedValue;
    switch (val) {
        .boolean => |b| try testing.expectEqual(
            expected,
            b,
        ),
        else => return error.TestExpectedEqual,
    }
}

fn expectValueNull(v: Value, key: []const u8) !void {
    const val = v.mappingGet(key) orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(std.meta.Tag(Value), .null), @as(std.meta.Tag(Value), val));
}

fn expectValueFloat(v: Value, key: []const u8, expected: f64, tolerance: f64) !void {
    const val = v.mappingGet(key) orelse return error.TestExpectedValue;
    switch (val) {
        .float => |f| try testing.expectApproxEqAbs(
            expected,
            f,
            tolerance,
        ),
        else => return error.TestExpectedEqual,
    }
}

fn expectValuePosInf(v: Value, key: []const u8) !void {
    const val = v.mappingGet(key) orelse return error.TestExpectedValue;
    switch (val) {
        .float => |f| try testing.expect(
            std.math.isPositiveInf(f),
        ),
        else => return error.TestExpectedEqual,
    }
}

fn expectValueNegInf(v: Value, key: []const u8) !void {
    const val = v.mappingGet(key) orelse return error.TestExpectedValue;
    switch (val) {
        .float => |f| try testing.expect(
            std.math.isNegativeInf(f),
        ),
        else => return error.TestExpectedEqual,
    }
}

fn expectValueNan(v: Value, key: []const u8) !void {
    const val = v.mappingGet(key) orelse return error.TestExpectedValue;
    switch (val) {
        .float => |f| try testing.expect(
            std.math.isNan(f),
        ),
        else => return error.TestExpectedEqual,
    }
}

test "v: hi decoded as string" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: hi\n");
    try testing.expectEqualStrings("hi", r.v);
}

test "v: quoted true as string" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: \"true\"\n");
    try testing.expectEqualStrings("true", r.v);
}

test "v: quoted false as string" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: \"false\"\n");
    try testing.expectEqualStrings("false", r.v);
}

test "v: true as Value bool" {
    const r = try testDecode(Value, "v: true\n");
    try expectValueBool(r, "v", true);
}

test "v: true as string yields true" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: true\n");
    try testing.expectEqualStrings("true", r.v);
}

test "v: 10 as string" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: 10\n");
    try testing.expectEqualStrings("10", r.v);
}

test "v: -10 as string" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: -10\n");
    try testing.expectEqualStrings("-10", r.v);
}

test "v: 1.234 as string" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: 1.234\n");
    try testing.expectEqualStrings("1.234", r.v);
}

test "v: leading space string" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: \" foo\"\n");
    try testing.expectEqualStrings(" foo", r.v);
}

test "v: trailing space string" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: \"foo \"\n");
    try testing.expectEqualStrings("foo ", r.v);
}

test "v: both space string" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: \" foo \"\n");
    try testing.expectEqualStrings(" foo ", r.v);
}

test "v: false as bool" {
    const S = struct { v: bool };
    const r = try testDecode(S, "v: false\n");
    try testing.expect(!r.v);
}

test "v: 10 as int" {
    const S = struct { v: i64 };
    const r = try testDecode(S, "v: 10\n");
    try testing.expectEqual(@as(i64, 10), r.v);
}

test "decode integer from string" {
    const r = try testDecode(i64, "42");
    try testing.expectEqual(@as(i64, 42), r);
}

test "v: 10 as Value integer" {
    const r = try testDecode(Value, "v: 10");
    try expectValueInt(r, "v", 10);
}

test "v: 0b10 as Value" {
    const r = try testDecode(Value, "v: 0b10");
    try expectValueInt(r, "v", 2);
}

test "v: -0b101010 as Value" {
    const r = try testDecode(Value, "v: -0b101010");
    try expectValueInt(r, "v", -42);
}

test "v: min i64 via binary" {
    const S = struct { v: i64 };
    const r = try testDecode(
        S,
        "v: -0b1000000000000000000000000000000000000000000000000000000000000000",
    );
    try testing.expectEqual(std.math.minInt(i64), r.v);
}

test "v: 0xA as Value" {
    const r = try testDecode(Value, "v: 0xA");
    try expectValueInt(r, "v", 10);
}

test "v: .1 as Value float" {
    const r = try testDecode(Value, "v: .1");
    try expectValueFloat(r, "v", 0.1, 0.001);
}

test "v: -.1 as Value float" {
    const r = try testDecode(Value, "v: -.1");
    try expectValueFloat(r, "v", -0.1, 0.001);
}

test "decode negative integer" {
    const r = try testDecode(i64, "-10");
    try testing.expectEqual(@as(i64, -10), r);
}

test "v: -10 as struct int" {
    const S = struct { v: i64 };
    const r = try testDecode(S, "v: -10\n");
    try testing.expectEqual(@as(i64, -10), r.v);
}

test "decode large integer" {
    const r = try testDecode(i64, "4294967296");
    try testing.expectEqual(@as(i64, 4294967296), r);
}

test "v: 0.1 as Value float" {
    const r = try testDecode(Value, "v: 0.1\n");
    try expectValueFloat(r, "v", 0.1, 0.001);
}

test "v: 0.99 as f32" {
    const S = struct { v: f32 };
    const r = try testDecode(S, "v: 0.99\n");
    try testing.expectApproxEqAbs(@as(f32, 0.99), r.v, 0.01);
}

test "v: -0.1 as f64" {
    const S = struct { v: f64 };
    const r = try testDecode(S, "v: -0.1\n");
    try testing.expectApproxEqAbs(@as(f64, -0.1), r.v, 0.001);
}

test "v: 6.8523e+5 as Value" {
    const r = try testDecode(Value, "v: 6.8523e+5");
    try expectValueFloat(r, "v", 685230.0, 0.1);
}

test "v: 685.230_15e+03 as Value" {
    const r = try testDecode(Value, "v: 685.230_15e+03");
    try expectValueFloat(r, "v", 685230.15, 0.1);
}

test "v: 685_230.15 as Value" {
    const r = try testDecode(Value, "v: 685_230.15");
    try expectValueFloat(r, "v", 685230.15, 0.01);
}

test "v: 685_230.15 as f64" {
    const S = struct { v: f64 };
    const r = try testDecode(S, "v: 685_230.15");
    try testing.expectApproxEqAbs(@as(f64, 685230.15), r.v, 0.01);
}

test "v: 685230 as Value integer" {
    const r = try testDecode(Value, "v: 685230");
    try expectValueInt(r, "v", 685230);
}

test "v: +685_230 as Value" {
    const r = try testDecode(Value, "v: +685_230");
    try expectValueInt(r, "v", 685230);
}

test "v: 02472256 octal as Value" {
    const r = try testDecode(Value, "v: 02472256");
    try expectValueInt(r, "v", 685230);
}

test "v: 0x_0A_74_AE as Value" {
    const r = try testDecode(Value, "v: 0x_0A_74_AE");
    try expectValueInt(r, "v", 685230);
}

test "v: binary with underscores as Value" {
    const r = try testDecode(Value, "v: 0b1010_0111_0100_1010_1110");
    try expectValueInt(r, "v", 685230);
}

test "v: +685_230 as int" {
    const S = struct { v: i64 };
    const r = try testDecode(S, "v: +685_230");
    try testing.expectEqual(@as(i64, 685230), r.v);
}

test "v: True as Value bool" {
    const r = try testDecode(Value, "v: True");
    try expectValueBool(r, "v", true);
}

test "v: TRUE as Value bool" {
    const r = try testDecode(Value, "v: TRUE");
    try expectValueBool(r, "v", true);
}

test "v: False as Value bool" {
    const r = try testDecode(Value, "v: False");
    try expectValueBool(r, "v", false);
}

test "v: FALSE as Value bool" {
    const r = try testDecode(Value, "v: FALSE");
    try expectValueBool(r, "v", false);
}

test "v: y is string not bool" {
    const r = try testDecode(Value, "v: y");
    try expectValueString(r, "v", "y");
}

test "v: NO is string not bool" {
    const r = try testDecode(Value, "v: NO");
    try expectValueString(r, "v", "NO");
}

test "v: on is string not bool" {
    const r = try testDecode(Value, "v: on");
    try expectValueString(r, "v", "on");
}

test "v: 42 as u32" {
    const S = struct { v: u32 };
    const r = try testDecode(S, "v: 42");
    try testing.expectEqual(@as(u32, 42), r.v);
}

test "v: 4294967296 as u64" {
    const S = struct { v: u64 };
    const r = try testDecode(S, "v: 4294967296");
    try testing.expectEqual(@as(u64, 4294967296), r.v);
}

test "v: max i32" {
    const S = struct { v: i32 };
    const r = try testDecode(S, "v: 2147483647");
    try testing.expectEqual(std.math.maxInt(i32), r.v);
}

test "v: min i32" {
    const S = struct { v: i32 };
    const r = try testDecode(S, "v: -2147483648");
    try testing.expectEqual(std.math.minInt(i32), r.v);
}

test "decode max i64" {
    const r = try testDecode(i64, "9223372036854775807");
    try testing.expectEqual(std.math.maxInt(i64), r);
}

test "v: max i64 via binary" {
    const S = struct { v: i64 };
    const r = try testDecode(
        S,
        "v: 0b111111111111111111111111111111111111111111111111111111111111111",
    );
    try testing.expectEqual(std.math.maxInt(i64), r.v);
}

test "decode min i64" {
    const r = try testDecode(i64, "-9223372036854775808");
    try testing.expectEqual(std.math.minInt(i64), r);
}

test "v: negative max i64 via binary" {
    const S = struct { v: i64 };
    const r = try testDecode(
        S,
        "v: -0b1111111111111111111111111111111111111111111111111111111111111111",
    );
    try testing.expectEqual(-std.math.maxInt(i64), r.v);
}

test "v: 0 as u32" {
    const S = struct { v: u32 };
    const r = try testDecode(S, "v: 0");
    try testing.expectEqual(@as(u32, 0), r.v);
}

test "v: max u32" {
    const S = struct { v: u32 };
    const r = try testDecode(S, "v: 4294967295");
    try testing.expectEqual(std.math.maxInt(u32), r.v);
}

test "v: 1e3 as u32" {
    const S = struct { v: u32 };
    const r = try testDecode(S, "v: 1e3");
    try testing.expectEqual(@as(u32, 1000), r.v);
}

test "v: max u64" {
    const S = struct { v: u64 };
    const r = try testDecode(S, "v: 18446744073709551615");
    try testing.expectEqual(std.math.maxInt(u64), r.v);
}

test "v: max u64 via binary" {
    const S = struct { v: u64 };
    const r = try testDecode(
        S,
        "v: 0b1111111111111111111111111111111111111111111111111111111111111111",
    );
    try testing.expectEqual(std.math.maxInt(u64), r.v);
}

test "v: max i64 as u64" {
    const S = struct { v: u64 };
    const r = try testDecode(S, "v: 9223372036854775807");
    try testing.expectEqual(@as(u64, std.math.maxInt(i64)), r.v);
}

test "v: 1e3 as u64" {
    const S = struct { v: u64 };
    const r = try testDecode(S, "v: 1e3");
    try testing.expectEqual(@as(u64, 1000), r.v);
}

test "v: 1e-06 as f32" {
    const S = struct { v: f32 };
    const r = try testDecode(S, "v: 1e-06");
    try testing.expectApproxEqAbs(@as(f32, 1e-6), r.v, 1e-8);
}

test "v: 1e-06 as f64" {
    const S = struct { v: f64 };
    const r = try testDecode(S, "v: 1e-06");
    try testing.expectApproxEqAbs(@as(f64, 1e-06), r.v, 1e-10);
}

test "decode hex integer" {
    const r = try testDecode(i64, "0xA");
    try testing.expectEqual(@as(i64, 10), r);
}

test "decode hex with underscores" {
    const r = try testDecode(i64, "0x_0A_74_AE");
    try testing.expectEqual(@as(i64, 685230), r);
}

test "decode octal 0o prefix" {
    const r = try testDecode(i64, "0o2472256");
    try testing.expectEqual(@as(i64, 685230), r);
}

test "decode octal legacy prefix" {
    const r = try testDecode(i64, "02472256");
    try testing.expectEqual(@as(i64, 685230), r);
}

test "decode binary integer" {
    const r = try testDecode(i64, "0b1010");
    try testing.expectEqual(@as(i64, 10), r);
}

test "decode negative binary" {
    const r = try testDecode(i64, "-0b101010");
    try testing.expectEqual(@as(i64, -42), r);
}

test "decode i32" {
    const r = try testDecode(i32, "42");
    try testing.expectEqual(@as(i32, 42), r);
}

test "decode u16" {
    const r = try testDecode(u16, "8080");
    try testing.expectEqual(@as(u16, 8080), r);
}

test "decode float" {
    const r = try testDecode(f64, "3.14");
    try testing.expectApproxEqAbs(@as(f64, 3.14), r, 0.001);
}

test "decode negative float" {
    const r = try testDecode(f64, "-0.1");
    try testing.expectApproxEqAbs(@as(f64, -0.1), r, 0.001);
}

test "decode leading dot float" {
    const r = try testDecode(f64, ".1");
    try testing.expectApproxEqAbs(@as(f64, 0.1), r, 0.001);
}

test "decode negative leading dot" {
    const r = try testDecode(f64, "-.1");
    try testing.expectApproxEqAbs(@as(f64, -0.1), r, 0.001);
}

test "decode scientific notation" {
    const r = try testDecode(f64, "6.8523e+5");
    try testing.expectApproxEqAbs(@as(f64, 685230.0), r, 0.1);
}

test "decode float with underscores" {
    const r = try testDecode(f64, "685_230.15");
    try testing.expectApproxEqAbs(@as(f64, 685230.15), r, 0.01);
}

test "decode f32" {
    const r = try testDecode(f32, "0.99");
    try testing.expectApproxEqAbs(@as(f32, 0.99), r, 0.01);
}

test "decode bool true" {
    const r = try testDecode(bool, "true");
    try testing.expect(r);
}

test "decode bool True" {
    const r = try testDecode(bool, "True");
    try testing.expect(r);
}

test "decode bool TRUE" {
    const r = try testDecode(bool, "TRUE");
    try testing.expect(r);
}

test "decode bool false" {
    const r = try testDecode(bool, "false");
    try testing.expect(!r);
}

test "decode bool False" {
    const r = try testDecode(bool, "False");
    try testing.expect(!r);
}

test "decode bool FALSE" {
    const r = try testDecode(bool, "FALSE");
    try testing.expect(!r);
}

test "decode string" {
    const r = try testDecode([]const u8, "hello");
    try testing.expectEqualStrings("hello", r);
}

test "decode quoted string" {
    const r = try testDecode([]const u8, "\"hello world\"");
    try testing.expectEqualStrings("hello world", r);
}

test "decode null to optional" {
    const r = try testDecode(?i64, "null");
    try testing.expect(r == null);
}

test "decode Null to optional" {
    const r = try testDecode(?i64, "Null");
    try testing.expect(r == null);
}

test "decode NULL to optional" {
    const r = try testDecode(?i64, "NULL");
    try testing.expect(r == null);
}

test "decode tilde to optional" {
    const r = try testDecode(?i64, "~");
    try testing.expect(r == null);
}

test "decode empty to optional" {
    const r = try testDecode(?[]const u8, "");
    try testing.expect(r == null);
}

test "null as pointer" {
    const r = try testDecode(?i64, "null");
    try testing.expect(r == null);
}

test "tilde as pointer" {
    const r = try testDecode(?i64, "~");
    try testing.expect(r == null);
}

test "v: empty value as null in Value" {
    const r = try testDecode(Value, "v:");
    try expectValueNull(r, "v");
}

test "v: tilde as null in Value" {
    const r = try testDecode(Value, "v: ~");
    try expectValueNull(r, "v");
}

test "v: null as Value" {
    const r = try testDecode(Value, "v: null");
    try expectValueNull(r, "v");
}

test "v: Null as Value" {
    const r = try testDecode(Value, "v: Null");
    try expectValueNull(r, "v");
}

test "v: NULL as Value" {
    const r = try testDecode(Value, "v: NULL");
    try expectValueNull(r, "v");
}

test "v: null to optional string is null" {
    const S = struct { v: ?[]const u8 };
    const r = try testDecode(S, "v: null");
    try testing.expect(r.v == null);
}

test "v: null to string is empty" {
    const S = struct { v: []const u8 = "" };
    const r = try testDecode(S, "v: null");
    try testing.expectEqualStrings("", r.v);
}

test "v: tilde to optional string is null" {
    const S = struct { v: ?[]const u8 };
    const r = try testDecode(S, "v: ~");
    try testing.expect(r.v == null);
}

test "v: tilde to string is empty" {
    const S = struct { v: []const u8 = "" };
    const r = try testDecode(S, "v: ~");
    try testing.expectEqualStrings("", r.v);
}

test "decode simple struct" {
    const Config = struct {
        name: []const u8,
        port: u16,
    };
    const r = try testDecode(Config, "name: app\nport: 8080");
    try testing.expectEqualStrings("app", r.name);
    try testing.expectEqual(@as(u16, 8080), r.port);
}

test "decode nested struct" {
    const Inner = struct { b: []const u8 };
    const Outer = struct { a: Inner };
    const r = try testDecode(Outer, "a:\n  b: c");
    try testing.expectEqualStrings("c", r.a.b);
}

test "decode struct with optional field" {
    const Config = struct {
        name: []const u8,
        port: ?u16 = null,
    };
    const r = try testDecode(Config, "name: app");
    try testing.expectEqualStrings("app", r.name);
    try testing.expect(r.port == null);
}

test "decode struct with default value" {
    const Config = struct {
        name: []const u8,
        port: u16 = 3000,
    };
    const r = try testDecode(Config, "name: app");
    try testing.expectEqualStrings("app", r.name);
    try testing.expectEqual(@as(u16, 3000), r.port);
}

test "decode struct with custom yamlParse" {
    const Config = struct {
        api_key: []const u8,
        max_retries: i64,

        pub fn yamlParse(allocator: Allocator, node: Node) !@This() {
            const v = try decodeNode(Value, allocator, node, .{});
            return .{
                .api_key = (v.mappingGet("apiKey") orelse
                    return error.MissingField).string,
                .max_retries = (v.mappingGet("maxRetries") orelse
                    return error.MissingField).integer,
            };
        }
    };
    const r = try testDecode(Config,
        \\apiKey: secret123
        \\maxRetries: 5
        \\
    );
    try testing.expectEqualStrings("secret123", r.api_key);
    try testing.expectEqual(@as(i64, 5), r.max_retries);
}

test "decode struct hello world" {
    const S = struct { hello: []const u8 };
    const r = try testDecode(S, "hello: world");
    try testing.expectEqualStrings("world", r.hello);
}

test "decode struct nested flow mapping" {
    const Inner = struct { b: []const u8 };
    const Outer = struct { a: Inner };
    const r = try testDecode(Outer, "a: {b: c}");
    try testing.expectEqualStrings("c", r.a.b);
}

test "decode struct empty map field" {
    const S = struct { a: ?[]const u8 = null };
    const r = try testDecode(S, "a:");
    try testing.expect(r.a == null);
}

test "decode struct a: 1 as int" {
    const S = struct { a: i64 };
    const r = try testDecode(S, "a: 1");
    try testing.expectEqual(@as(i64, 1), r.a);
}

test "decode struct a: 1 as f64" {
    const S = struct { a: f64 };
    const r = try testDecode(S, "a: 1");
    try testing.expectApproxEqAbs(
        @as(f64, 1.0),
        r.a,
        0.001,
    );
}

test "decode struct a: 1.0 as int" {
    const S = struct { a: i64 };
    const r = try testDecode(S, "a: 1.0");
    try testing.expectEqual(@as(i64, 1), r.a);
}

test "decode struct a: 1.0 as u32" {
    const S = struct { a: u32 };
    const r = try testDecode(S, "a: 1.0");
    try testing.expectEqual(@as(u32, 1), r.a);
}

test "decode struct with int slice" {
    const S = struct { a: []const i64 };
    const r = try testDecode(S, "a: [1, 2]");
    try testing.expectEqual(@as(usize, 2), r.a.len);
    try testing.expectEqual(@as(i64, 1), r.a[0]);
    try testing.expectEqual(@as(i64, 2), r.a[1]);
}

test "decode struct unmatched field" {
    const S = struct { b: i64 = 0 };
    const r = try testDecode(S, "a: 1");
    try testing.expectEqual(@as(i64, 0), r.b);
}

test "decode struct with default field override" {
    const S = struct {
        a: []const u8,
        b: i64 = 0,
    };
    const r = try testDecode(S,
        \\a: b
        \\b: 2
        \\
    );
    try testing.expectEqualStrings("b", r.a);
    try testing.expectEqual(@as(i64, 2), r.b);
}

test "decode slice of strings" {
    const result = try testDecode(
        []const []const u8,
        \\- a
        \\- b
        \\- c
        ,
    );
    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqualStrings("a", result[0]);
    try testing.expectEqualStrings("b", result[1]);
    try testing.expectEqualStrings("c", result[2]);
}

test "decode slice of integers" {
    const result = try testDecode(
        []const i64,
        \\- 1
        \\- 2
        \\- 3
        ,
    );
    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqual(@as(i64, 1), result[0]);
    try testing.expectEqual(@as(i64, 2), result[1]);
    try testing.expectEqual(@as(i64, 3), result[2]);
}

test "decode flow sequence" {
    const r = try testDecode([]const []const u8, "[A, B, C]");
    try testing.expectEqual(@as(usize, 3), r.len);
    try testing.expectEqualStrings("A", r[0]);
}

test "flow sequence with trailing comma" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(S, "v: [A,B,C,]");
    try testing.expectEqual(@as(usize, 3), r.v.len);
    try testing.expectEqualStrings("A", r.v[0]);
    try testing.expectEqualStrings("B", r.v[1]);
    try testing.expectEqualStrings("C", r.v[2]);
}

test "flow sequence mixed types as strings" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(S, "v: [A,1,C]");
    try testing.expectEqual(@as(usize, 3), r.v.len);
    try testing.expectEqualStrings("A", r.v[0]);
    try testing.expectEqualStrings("1", r.v[1]);
    try testing.expectEqualStrings("C", r.v[2]);
}

test "flow sequence mixed as Value" {
    const r = try testDecode(Value, "v: [A,1,C]");
    const seq = r.mappingGet("v") orelse return error.TestExpectedValue;
    switch (seq) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 3), s.len);
            try testing.expectEqualStrings("A", s[0].string);
            try testing.expectEqual(@as(i64, 1), s[1].integer);
            try testing.expectEqualStrings("C", s[2].string);
        },
        else => return error.TestExpectedEqual,
    }
}

test "flow sequence of mappings" {
    const r = try testDecode(Value, "v: [a: b, c: d]");
    const seq = r.mappingGet("v") orelse return error.TestExpectedValue;
    switch (seq) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 2), s.len);
            const m0 = s[0].mappingGet("a") orelse return error.TestExpectedValue;
            try testing.expectEqualStrings("b", m0.string);
            const m1 = s[1].mappingGet("c") orelse return error.TestExpectedValue;
            try testing.expectEqualStrings("d", m1.string);
        },
        else => return error.TestExpectedEqual,
    }
}

test "flow sequence of flow mappings" {
    const r = try testDecode(Value, "v: [{a: b}, {c: d, e: f}]");
    const seq = r.mappingGet("v") orelse return error.TestExpectedValue;
    switch (seq) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 2), s.len);
            const m0 = s[0].mappingGet("a") orelse return error.TestExpectedValue;
            try testing.expectEqualStrings("b", m0.string);
            const m1 = s[1].mappingGet("c") orelse return error.TestExpectedValue;
            try testing.expectEqualStrings("d", m1.string);
            const m2 = s[1].mappingGet("e") orelse return error.TestExpectedValue;
            try testing.expectEqualStrings("f", m2.string);
        },
        else => return error.TestExpectedEqual,
    }
}

test "block sequence as Value" {
    const r = try testDecode(
        Value,
        \\v:
        \\ - A
        \\ - B
        ,
    );
    const seq = r.mappingGet("v") orelse return error.TestExpectedValue;
    switch (seq) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 2), s.len);
            try testing.expectEqualStrings("A", s[0].string);
            try testing.expectEqualStrings("B", s[1].string);
        },
        else => return error.TestExpectedEqual,
    }
}

test "block sequence of strings" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(
        S,
        \\v:
        \\ - A
        \\ - B
        \\ - C
        ,
    );
    try testing.expectEqual(@as(usize, 3), r.v.len);
    try testing.expectEqualStrings("A", r.v[0]);
}

test "block sequence mixed as strings" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(
        S,
        \\v:
        \\ - A
        \\ - 1
        \\ - C
        ,
    );
    try testing.expectEqual(@as(usize, 3), r.v.len);
    try testing.expectEqualStrings("1", r.v[1]);
}

test "block sequence mixed as Value" {
    const r = try testDecode(
        Value,
        \\v:
        \\ - A
        \\ - 1
        \\ - C
        ,
    );
    const seq = r.mappingGet("v") orelse return error.TestExpectedValue;
    switch (seq) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 3), s.len);
            try testing.expectEqualStrings("A", s[0].string);
            try testing.expectEqual(@as(i64, 1), s[1].integer);
            try testing.expectEqualStrings("C", s[2].string);
        },
        else => return error.TestExpectedEqual,
    }
}

test "nested flow mapping as Value" {
    const r = try testDecode(Value, "a: {b: c}");
    const inner = r.mappingGet("a") orelse return error.TestExpectedValue;
    const val = inner.mappingGet("b") orelse return error.TestExpectedValue;
    try testing.expectEqualStrings("c", val.string);
}

test "decode simple mapping to Value" {
    const r = try testDecode(Value, "a: 1\nb: 2");
    try expectValueInt(r, "a", 1);
    try expectValueInt(r, "b", 2);
}

test "decode key value string map" {
    const r = try testDecode(Value, "v: hi");
    try expectValueString(r, "v", "hi");
}

test "v: empty string" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: \"\"\n");
    try testing.expectEqualStrings("", r.v);
}

test "v: block sequence strings" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(S,
        \\v:
        \\- A
        \\- B
        \\
    );
    try testing.expectEqual(@as(usize, 2), r.v.len);
    try testing.expectEqualStrings("A", r.v[0]);
}

test "a: dash in single quotes" {
    const S = struct { a: []const u8 };
    const r = try testDecode(S, "a: '-'\n");
    try testing.expectEqualStrings("-", r.a);
}

test "decode bare integer 123" {
    const r = try testDecode(i64, "123\n");
    try testing.expectEqual(@as(i64, 123), r);
}

test "decode hello: world string" {
    const S = struct { hello: []const u8 };
    const r = try testDecode(S, "hello: world\n");
    try testing.expectEqualStrings("world", r.hello);
}

test "decode with crlf line endings" {
    const r = try testDecode(Value, "hello: world\r\nfoo: bar");
    try expectValueString(r, "hello", "world");
    try expectValueString(r, "foo", "bar");
}

test "decode with cr line endings" {
    const r = try testDecode(Value, "hello: world\rZig: Ziguana");
    try expectValueString(r, "hello", "world");
    try expectValueString(r, "Zig", "Ziguana");
}

test "decode infinity to f64" {
    const r = try testDecode(f64, ".inf");
    try testing.expect(std.math.isPositiveInf(r));
}

test "decode negative infinity to f64" {
    const r = try testDecode(f64, "-.inf");
    try testing.expect(std.math.isNegativeInf(r));
}

test "decode nan to f64" {
    const r = try testDecode(f64, ".nan");
    try testing.expect(std.math.isNan(r));
}

test "decode Inf case insensitive" {
    const r = try testDecode(f64, ".Inf");
    try testing.expect(std.math.isPositiveInf(r));
}

test "decode INF uppercase" {
    const r = try testDecode(f64, ".INF");
    try testing.expect(std.math.isPositiveInf(r));
}

test "decode neg Inf" {
    const r = try testDecode(f64, "-.Inf");
    try testing.expect(std.math.isNegativeInf(r));
}

test "decode neg INF" {
    const r = try testDecode(f64, "-.INF");
    try testing.expect(std.math.isNegativeInf(r));
}

test "decode NaN mixed case" {
    const r = try testDecode(f64, ".NaN");
    try testing.expect(std.math.isNan(r));
}

test "decode NAN uppercase" {
    const r = try testDecode(f64, ".NAN");
    try testing.expect(std.math.isNan(r));
}

test "v: .inf as Value" {
    const r = try testDecode(Value, "v: .inf\n");
    try expectValuePosInf(r, "v");
}

test "v: .Inf as Value" {
    const r = try testDecode(Value, "v: .Inf\n");
    try expectValuePosInf(r, "v");
}

test "v: .INF as Value" {
    const r = try testDecode(Value, "v: .INF\n");
    try expectValuePosInf(r, "v");
}

test "v: -.inf as Value" {
    const r = try testDecode(Value, "v: -.inf\n");
    try expectValueNegInf(r, "v");
}

test "v: -.Inf as Value" {
    const r = try testDecode(Value, "v: -.Inf\n");
    try expectValueNegInf(r, "v");
}

test "v: -.INF as Value" {
    const r = try testDecode(Value, "v: -.INF\n");
    try expectValueNegInf(r, "v");
}

test "v: .nan as Value" {
    const r = try testDecode(Value, "v: .nan\n");
    try expectValueNan(r, "v");
}

test "v: .NaN as Value" {
    const r = try testDecode(Value, "v: .NaN\n");
    try expectValueNan(r, "v");
}

test "v: .NAN as Value" {
    const r = try testDecode(Value, "v: .NAN\n");
    try expectValueNan(r, "v");
}

test "decode tagged float" {
    const r = try testDecode(f64, "!!float '1.1'");
    try testing.expectApproxEqAbs(
        @as(f64, 1.1),
        r,
        0.001,
    );
}

test "decode tagged float zero" {
    const r = try testDecode(f64, "!!float 0");
    try testing.expectApproxEqAbs(
        @as(f64, 0.0),
        r,
        0.001,
    );
}

test "decode tagged float negative" {
    const r = try testDecode(f64, "!!float -1");
    try testing.expectApproxEqAbs(
        @as(f64, -1.0),
        r,
        0.001,
    );
}

test "decode tagged null" {
    const r = try testDecode(?[]const u8, "!!null ''");
    try testing.expect(r == null);
}

test "decode tagged bool yes" {
    const r = try testDecode(bool, "!!bool yes");
    try testing.expect(r);
}

test "decode tagged bool False" {
    const r = try testDecode(bool, "!!bool False");
    try testing.expect(!r);
}

test "single quote 1: 2" {
    const r = try testDecode(Value, "'1': '2'");
    try expectValueString(r, "1", "2");
}

test "single quote with double quotes inside" {
    const r = try testDecode(Value, "'1': '\"2\"'");
    try expectValueString(r, "1", "\"2\"");
}

test "single quote escaped apostrophe" {
    const r = try testDecode([]const u8, "'it''s'");
    try testing.expectEqualStrings("it's", r);
}

test "single quote solo apostrophe" {
    const r = try testDecode(Value, "'1': ''''");
    try expectValueString(r, "1", "'");
}

test "single quote wrapped apostrophes" {
    const r = try testDecode(Value, "'1': '''2'''");
    try expectValueString(r, "1", "'2'");
}

test "single quote mid apostrophe" {
    const r = try testDecode(Value, "'1': 'B''z'");
    try expectValueString(r, "1", "B'z");
}

test "single quote backslash literal" {
    const r = try testDecode([]const u8, "'\\'");
    try testing.expectEqualStrings("\\", r);
}

test "single quote double backslash" {
    const r = try testDecode(Value, "'1': '\\\\'");
    try expectValueString(r, "1", "\\\\");
}

test "single quote escaped double quotes" {
    const r = try testDecode(Value, "'1': '\\\"2\\\"'");
    try expectValueString(r, "1", "\\\"2\\\"");
}

test "double quote 1: 2" {
    const r = try testDecode(Value, "\"1\": \"2\"");
    try expectValueString(r, "1", "2");
}

test "double quote escaped quotes" {
    const r = try testDecode(Value, "\"1\": \"\\\"2\\\"\"");
    try expectValueString(r, "1", "\"2\"");
}

test "double quote single escaped quote" {
    const r = try testDecode(Value, "\"1\": \"\\\"\"");
    try expectValueString(r, "1", "\"");
}

test "double quote backslash" {
    const r = try testDecode(Value, "\"1\": \"\\\\\"");
    try expectValueString(r, "1", "\\");
}

test "double quote with newline escape" {
    const r = try testDecode([]const u8, "\"hello\\nworld\"");
    try testing.expectEqualStrings("hello\nworld", r);
}

test "double quote with tab escape" {
    const r = try testDecode([]const u8, "\"hello\\tworld\"");
    try testing.expectEqualStrings("hello\tworld", r);
}

test "double quote with hex escape" {
    const r = try testDecode([]const u8, "\"a\\x2Fb\"");
    try testing.expectEqualStrings("a/b", r);
}

test "double quote with unicode escape" {
    const r = try testDecode([]const u8, "\"a\\u002Fb\"");
    try testing.expectEqualStrings("a/b", r);
}

test "double quote multi unicode escapes" {
    const r = try testDecode(Value, "\"1\": \"a\\x2Fb\\u002Fc\\U0000002Fd\"");
    try expectValueString(r, "1", "a/b/c/d");
}

test "double quote newline escape n" {
    const r = try testDecode(Value, "'1': \"2\\n3\"");
    try expectValueString(r, "1", "2\n3");
}

test "double quote carriage return newline" {
    const r = try testDecode(Value, "'1': \"2\\r\\n3\"");
    try expectValueString(r, "1", "2\r\n3");
}

test "double quote line continuation" {
    const r = try testDecode(Value, "'1': \"a\\\nb\\\nc\"");
    try expectValueString(r, "1", "abc");
}

test "a: -b_c is string" {
    const r = try testDecode(Value, "a: -b_c");
    try expectValueString(r, "a", "-b_c");
}

test "a: +b_c is string" {
    const r = try testDecode(Value, "a: +b_c");
    try expectValueString(r, "a", "+b_c");
}

test "a: 50cent_of_dollar is string" {
    const r = try testDecode(Value, "a: 50cent_of_dollar");
    try expectValueString(r, "a", "50cent_of_dollar");
}

test "decode with document header" {
    const r = try testDecode(Value, "---\na: b");
    try expectValueString(r, "a", "b");
}

test "decode with document end" {
    const r = try testDecode(Value, "a: b\n...");
    try expectValueString(r, "a", "b");
}

test "decode empty document" {
    const r = try testDecode(?Value, "---\n");
    try testing.expect(r == null);
}

test "decode document end only" {
    const r = try testDecode(?Value, "...");
    try testing.expect(r == null);
}

test "decode empty string as null" {
    const r = try testDecode(?Value, "");
    try testing.expect(r == null);
}

test "v: zig build test as string" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: zig build test");
    try testing.expectEqualStrings("zig build test", r.v);
}

test "v: echo --- as string" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: echo ---");
    try testing.expectEqualStrings("echo ---", r.v);
}

test "decode literal block scalar" {
    const r = try testDecode(
        Value,
        \\v: |
        \\  hello
        \\  world
        \\
        ,
    );
    try expectValueString(
        r,
        "v",
        "hello\nworld\n",
    );
}

test "literal block with dots" {
    const S = struct { v: []const u8 };
    const r = try testDecode(
        S,
        \\v: |
        \\  hello
        \\  ...
        \\  world
        \\
        ,
    );
    try testing.expectEqualStrings("hello\n...\nworld\n", r.v);
}

test "literal block crlf" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: |\r\n  hello\r\n  ...\r\n  world\r\n");
    try testing.expectEqualStrings("hello\n...\nworld\n", r.v);
}

test "literal block cr only" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: |\r  hello\r  ...\r  world\r");
    try testing.expectEqualStrings("hello\n...\nworld\n", r.v);
}

test "decode literal block scalar strip" {
    const r = try testDecode(
        Value,
        \\v: |-
        \\  hello
        \\  world
        ,
    );
    try expectValueString(r, "v", "hello\nworld");
}

test "decode folded block scalar" {
    const r = try testDecode(
        Value,
        \\v: >
        \\  hello
        \\  world
        \\
        ,
    );
    try expectValueString(r, "v", "hello world\n");
}

test "block sequence with literal strip" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(
        S,
        \\v:
        \\- A
        \\- |-
        \\  B
        \\  C
        \\
        ,
    );
    try testing.expectEqual(@as(usize, 2), r.v.len);
    try testing.expectEqualStrings("A", r.v[0]);
    try testing.expectEqualStrings("B\nC", r.v[1]);
}

test "block literal strip crlf" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(S, "v:\r\n- A\r\n- |-\r\n  B\r\n  C\r\n");
    try testing.expectEqual(@as(usize, 2), r.v.len);
    try testing.expectEqualStrings("B\nC", r.v[1]);
}

test "block literal strip cr" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(S, "v:\r- A\r- |-\r  B\r  C\r");
    try testing.expectEqual(@as(usize, 2), r.v.len);
    try testing.expectEqualStrings("B\nC", r.v[1]);
}

test "block literal strip trailing newlines" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(
        S,
        \\v:
        \\- A
        \\- |-
        \\  B
        \\  C
        \\
        \\
        \\
        ,
    );
    try testing.expectEqual(@as(usize, 2), r.v.len);
    try testing.expectEqualStrings("B\nC", r.v[1]);
}

test "block folded strip" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(
        S,
        \\v:
        \\- A
        \\- >-
        \\  B
        \\  C
        \\
        ,
    );
    try testing.expectEqual(@as(usize, 2), r.v.len);
    try testing.expectEqualStrings("B C", r.v[1]);
}

test "block folded strip crlf" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(S, "v:\r\n- A\r\n- >-\r\n  B\r\n  C\r\n");
    try testing.expectEqualStrings("B C", r.v[1]);
}

test "block folded strip cr" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(S, "v:\r- A\r- >-\r  B\r  C\r");
    try testing.expectEqualStrings("B C", r.v[1]);
}

test "block folded strip trailing newlines" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(
        S,
        \\v:
        \\- A
        \\- >-
        \\  B
        \\  C
        \\
        \\
        \\
        ,
    );
    try testing.expectEqualStrings("B C", r.v[1]);
}

test "decode anchor and alias" {
    const r = try testDecode(Value, "a: &ref hello\nb: *ref");
    try expectValueString(r, "a", "hello");
    try expectValueString(r, "b", "hello");
}

test "decode merge key" {
    const r = try testDecode(
        Value,
        \\a: &a
        \\  foo: 1
        \\b:
        \\  <<: *a
        \\  bar: 2
        ,
    );
    const a = r.mappingGet("a") orelse return error.TestExpectedValue;
    try expectValueInt(a, "foo", 1);
    const b = r.mappingGet("b") orelse return error.TestExpectedValue;
    try expectValueInt(b, "bar", 2);
    try expectValueInt(b, "foo", 1);
}

test "anchor alias integers in struct" {
    const S = struct { a: i64, b: i64, c: i64, d: i64 };
    const r = try testDecode(
        S,
        \\a: &x 1
        \\b: &y 2
        \\c: *x
        \\d: *y
        \\
        ,
    );
    try testing.expectEqual(@as(i64, 1), r.a);
    try testing.expectEqual(@as(i64, 2), r.b);
    try testing.expectEqual(@as(i64, 1), r.c);
    try testing.expectEqual(@as(i64, 2), r.d);
}

test "anchor alias flow mapping" {
    const Inner = struct { c: i64 };
    const S = struct { a: Inner, b: Inner };
    const r = try testDecode(
        S,
        \\a: &a {c: 1}
        \\b: *a
        \\
        ,
    );
    try testing.expectEqual(@as(i64, 1), r.a.c);
    try testing.expectEqual(@as(i64, 1), r.b.c);
}

test "anchor alias sequence" {
    const S = struct { b: []const i64 };
    const r = try testDecode(
        S,
        \\a: &a [1, 2]
        \\b: *a
        \\
        ,
    );
    try testing.expectEqual(@as(usize, 2), r.b.len);
    try testing.expectEqual(@as(i64, 1), r.b[0]);
    try testing.expectEqual(@as(i64, 2), r.b[1]);
}

test "anchor self reference is null" {
    const r = try testDecode(
        Value,
        \\key1: &anchor
        \\  subkey: *anchor
        \\key2: *anchor
        \\
        ,
    );
    const key1 = r.mappingGet("key1") orelse return error.TestExpectedValue;
    try expectValueNull(key1, "subkey");
}

test "anchor as key" {
    const r = try testDecode(Value, "{a: &a c, *a : b}");
    try expectValueString(r, "a", "c");
    const val = r.mappingGet("c") orelse return error.TestExpectedValue;
    try testing.expectEqualStrings("b", val.string);
}

test "struct with tags and sequence" {
    const S = struct {
        tags: []const []const u8,
        a: []const u8,
    };
    const r = try testDecode(
        S,
        \\tags:
        \\- hello-world
        \\a: foo
        ,
    );
    try testing.expectEqual(@as(usize, 1), r.tags.len);
    try testing.expectEqualStrings("hello-world", r.tags[0]);
    try testing.expectEqualStrings("foo", r.a);
}

test "decode empty struct" {
    const r = try testDecode(Value, "{}");
    try testing.expectEqual(@as(std.meta.Tag(Value), .mapping), @as(std.meta.Tag(Value), r));
    try testing.expectEqual(@as(usize, 0), r.mapping.keys.len);
}

test "flow mapping with null value" {
    const r = try testDecode(Value, "{a: , b: c}");
    try expectValueNull(r, "a");
    try expectValueString(r, "b", "c");
}

test "v: path with braces" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: /a/{b}");
    try testing.expectEqualStrings("/a/{b}", r.v);
}

test "v: special characters" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: 1[]{},!%?&*");
    try testing.expectEqualStrings("1[]{},!%?&*", r.v);
}

test "v: user's item" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: user's item");
    try testing.expectEqualStrings("user's item", r.v);
}

test "nested flow sequences" {
    const r = try testDecode(Value, "v: [1,[2,[3,[4,5],6],7],8]");
    const seq = r.mappingGet("v") orelse return error.TestExpectedValue;
    switch (seq) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 3), s.len);
            try testing.expectEqual(@as(i64, 1), s[0].integer);
            try testing.expectEqual(@as(i64, 8), s[2].integer);
            const inner = s[1].sequence;
            try testing.expectEqual(@as(usize, 3), inner.len);
            try testing.expectEqual(@as(i64, 2), inner[0].integer);
            try testing.expectEqual(@as(i64, 7), inner[2].integer);
        },
        else => return error.TestExpectedEqual,
    }
}

test "nested flow mappings" {
    const r = try testDecode(Value, "v: {a: {b: {c: {d: e},f: g},h: i},j: k}");
    const v = r.mappingGet("v") orelse return error.TestExpectedValue;
    try expectValueString(v, "j", "k");
    const a = v.mappingGet("a") orelse return error.TestExpectedValue;
    try expectValueString(a, "h", "i");
    const b = a.mappingGet("b") orelse return error.TestExpectedValue;
    try expectValueString(b, "f", "g");
    const c = b.mappingGet("c") orelse return error.TestExpectedValue;
    try expectValueString(c, "d", "e");
}

test "sequence of mappings with null" {
    const r = try testDecode(
        Value,
        \\---
        \\- a:
        \\    b:
        \\- c: d
        \\
        ,
    );
    switch (r) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 2), s.len);
            const m0 = s[0].mappingGet("a") orelse return error.TestExpectedValue;
            try expectValueNull(m0, "b");
            const m1 = s[1].mappingGet("c") orelse return error.TestExpectedValue;
            try testing.expectEqualStrings("d", m1.string);
        },
        else => return error.TestExpectedEqual,
    }
}

test "mapping with nested null" {
    const r = try testDecode(
        Value,
        \\---
        \\a:
        \\  b:
        \\c: d
        \\
        ,
    );
    const a = r.mappingGet("a") orelse return error.TestExpectedValue;
    try expectValueNull(a, "b");
    try expectValueString(r, "c", "d");
}

test "mapping all null values" {
    const r = try testDecode(
        Value,
        \\---
        \\a:
        \\b:
        \\c:
        \\
        ,
    );
    try expectValueNull(r, "a");
    try expectValueNull(r, "b");
    try expectValueNull(r, "c");
}

test "mapping with dots and nulls" {
    const r = try testDecode(
        Value,
        \\---
        \\a: zig build test
        \\b:
        \\c:
        \\
        ,
    );
    try expectValueString(
        r,
        "a",
        "zig build test",
    );
    try expectValueNull(r, "b");
    try expectValueNull(r, "c");
}

test "mapping with literal and nulls" {
    const r = try testDecode(
        Value,
        \\---
        \\a: |
        \\  hello
        \\  ...
        \\  world
        \\b:
        \\c:
        \\
        ,
    );
    try expectValueString(
        r,
        "a",
        "hello\n...\nworld\n",
    );
    try expectValueNull(r, "b");
    try expectValueNull(r, "c");
}

test "a: nested map as string" {
    const S = struct { a: Value };
    const r = try testDecode(S,
        \\a:
        \\  b: c
        \\
    );
    const inner = r.a.mappingGet("b") orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(std.meta.Tag(Value), .string), @as(std.meta.Tag(Value), inner));
    try testing.expectEqualStrings("c", inner.string);
}

test "a: flow map of int" {
    const r = try testDecode(Value, "a: {x: 1}\n");
    const a = r.mappingGet("a") orelse return error.TestExpectedValue;
    try expectValueInt(a, "x", 1);
}

test "a: flow map of strings" {
    const r = try testDecode(Value, "a: {b: c, d: e}\n");
    const a = r.mappingGet("a") orelse return error.TestExpectedValue;
    try expectValueString(a, "b", "c");
    try expectValueString(a, "d", "e");
}

test "a: string 3s" {
    const S = struct { a: []const u8 };
    const r = try testDecode(S, "a: 3s\n");
    try testing.expectEqualStrings("3s", r.a);
}

test "a: angle bracket string" {
    const S = struct { a: []const u8 };
    const r = try testDecode(S, "a: <foo>\n");
    try testing.expectEqualStrings("<foo>", r.a);
}

test "a: quoted colon string" {
    const S = struct { a: []const u8 };
    const r = try testDecode(S, "a: \"1:1\"\n");
    try testing.expectEqualStrings("1:1", r.a);
}

test "a: dotted version string" {
    const S = struct { a: []const u8 };
    const r = try testDecode(S, "a: 1.2.3.4\n");
    try testing.expectEqualStrings("1.2.3.4", r.a);
}

test "a: single quoted colon" {
    const S = struct { a: []const u8 };
    const r = try testDecode(S, "a: 'b: c'\n");
    try testing.expectEqualStrings("b: c", r.a);
}

test "a: single quoted with hash" {
    const S = struct { a: []const u8 };
    const r = try testDecode(S, "a: 'Hello #comment'\n");
    try testing.expectEqualStrings("Hello #comment", r.a);
}

test "a: 100.5 as Value float" {
    const r = try testDecode(Value, "a: 100.5\n");
    try expectValueFloat(r, "a", 100.5, 0.01);
}

test "a: null byte escape" {
    const S = struct { a: []const u8 };
    const r = try testDecode(S, "a: \"\\0\"\n");
    try testing.expectEqualStrings("\x00", r.a);
}

test "whitespace around key-value" {
    const S = struct { a: []const u8 };
    const r = try testDecode(S, "       a       :          b        \n");
    try testing.expectEqualStrings("b", r.a);
}

test "comment after value" {
    const S = struct { a: []const u8, b: []const u8 };
    const r = try testDecode(
        S,
        \\a: b # comment
        \\b: c
        \\
        ,
    );
    try testing.expectEqualStrings("b", r.a);
    try testing.expectEqualStrings("c", r.b);
}

test "document separator" {
    const S = struct { a: []const u8 };
    const r = try testDecode(S,
        \\---
        \\a: b
        \\
    );
    try testing.expectEqualStrings("b", r.a);
}

test "document end marker" {
    const S = struct { a: []const u8 };
    const r = try testDecode(S,
        \\a: b
        \\...
        \\
    );
    try testing.expectEqualStrings("b", r.a);
}

test "a: int slice from flow" {
    const r = try testDecode(Value, "a: [1, 2]\n");
    const seq = r.mappingGet("a") orelse return error.TestExpectedValue;
    switch (seq) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 2), s.len);
            try testing.expectEqual(@as(i64, 1), s[0].integer);
            try testing.expectEqual(@as(i64, 2), s[1].integer);
        },
        else => return error.TestExpectedEqual,
    }
}

test "multi-key map ordering" {
    const r = try testDecode(
        Value,
        \\b: 2
        \\a: 1
        \\d: 4
        \\c: 3
        \\sub:
        \\  e: 5
        \\
        ,
    );
    try expectValueInt(r, "b", 2);
    try expectValueInt(r, "a", 1);
    try expectValueInt(r, "d", 4);
    try expectValueInt(r, "c", 3);
    const sub = r.mappingGet("sub") orelse return error.TestExpectedValue;
    try expectValueInt(sub, "e", 5);
}

test "decode y as string not bool" {
    const r = try testDecode([]const u8, "y");
    try testing.expectEqualStrings("y", r);
}

test "decode yes as string not bool" {
    const r = try testDecode([]const u8, "yes");
    try testing.expectEqualStrings("yes", r);
}

test "decode no as string not bool" {
    const r = try testDecode([]const u8, "no");
    try testing.expectEqualStrings("no", r);
}

test "decode on as string not bool" {
    const r = try testDecode([]const u8, "on");
    try testing.expectEqualStrings("on", r);
}

test "decode off as string not bool" {
    const r = try testDecode([]const u8, "off");
    try testing.expectEqualStrings("off", r);
}

test "decode quoted string with leading space" {
    const r = try testDecode([]const u8, "\" foo\"");
    try testing.expectEqualStrings(" foo", r);
}

test "decode quoted string with trailing space" {
    const r = try testDecode([]const u8, "\"foo \"");
    try testing.expectEqualStrings("foo ", r);
}

test "decode type mismatch returns error" {
    const r = testDecode(i64, "hello");
    try testing.expectError(error.TypeMismatch, r);
}

test "decode overflow returns error" {
    const r = testDecode(u8, "999");
    try testing.expectError(error.Overflow, r);
}

test "decode unknown field strict mode" {
    const Config = struct { name: []const u8 };
    const result = decode(
        Config,
        testing.allocator,
        "name: app\nunknown: field",
        .{ .disallow_unknown_fields = true },
    );
    try testing.expectError(error.UnknownField, result);
}

test "negative to u32 overflow" {
    const S = struct { v: u32 };
    const r = testDecode(S, "v: -42");
    try testing.expectError(error.Overflow, r);
}

test "negative to u64 overflow" {
    const S = struct { v: u64 };
    const r = testDecode(S, "v: -4294967296");
    try testing.expectError(error.Overflow, r);
}

test "i32 overflow" {
    const S = struct { v: i32 };
    const r = testDecode(S, "v: 4294967297");
    try testing.expectError(error.Overflow, r);
}

test "i8 overflow" {
    const S = struct { v: i8 };
    const r = testDecode(S, "v: 128");
    try testing.expectError(error.Overflow, r);
}

test "string to int type mismatch" {
    const S = struct { a: i64 };
    const r = testDecode(S, "a: str");
    try testing.expectError(error.TypeMismatch, r);
}

test "string to u32 type mismatch" {
    const S = struct { b: u32 };
    const r = testDecode(S, "b: str");
    try testing.expectError(error.TypeMismatch, r);
}

test "string to bool type mismatch" {
    const S = struct { d: bool };
    const r = testDecode(S, "d: str");
    try testing.expectError(error.TypeMismatch, r);
}

test "string to int in flow seq error" {
    const S = struct { v: []const i64 };
    const r = testDecode(S, "v: [A,1,C]");
    try testing.expectError(error.TypeMismatch, r);
}

test "string to int in block seq error" {
    const S = struct { v: []const i64 };
    const r = testDecode(
        S,
        \\v:
        \\ - A
        \\ - 1
        \\ - C
        ,
    );
    try testing.expectError(error.TypeMismatch, r);
}

test "scientific 1e3 as i64" {
    const S = struct { v: i64 };
    const r = try testDecode(S, "v: 1e3");
    try testing.expectEqual(@as(i64, 1000), r.v);
}

test "scientific 1e-3 as i64 truncated" {
    const S = struct { v: i64 };
    const r = try testDecode(S, "v: 1e-3");
    try testing.expectEqual(@as(i64, 0), r.v);
}

test "scientific 1e3 as f32" {
    const S = struct { v: f32 };
    const r = try testDecode(S, "v: 1e3");
    try testing.expectApproxEqAbs(
        @as(f32, 1000.0),
        r.v,
        0.1,
    );
}

test "scientific 1.0e3 as f64" {
    const S = struct { v: f64 };
    const r = try testDecode(S, "v: 1.0e3");
    try testing.expectApproxEqAbs(
        @as(f64, 1000.0),
        r.v,
        0.1,
    );
}

test "scientific 1e-3 as f64" {
    const S = struct { v: f64 };
    const r = try testDecode(S, "v: 1e-3");
    try testing.expectApproxEqAbs(
        @as(f64, 0.001),
        r.v,
        0.0001,
    );
}

test "scientific 1.0e-3 as f64" {
    const S = struct { v: f64 };
    const r = try testDecode(S, "v: 1.0e-3");
    try testing.expectApproxEqAbs(
        @as(f64, 0.001),
        r.v,
        0.0001,
    );
}

test "scientific 1.0e+3 as f64" {
    const S = struct { v: f64 };
    const r = try testDecode(S, "v: 1.0e+3");
    try testing.expectApproxEqAbs(
        @as(f64, 1000.0),
        r.v,
        0.1,
    );
}

test "merge key with struct" {
    const Item = struct { b: i64, c: []const u8 };
    const T = struct { items: []const Item };
    const r = try testDecode(
        T,
        \\a: &a
        \\  b: 1
        \\  c: hello
        \\items:
        \\- <<: *a
        \\- <<: *a
        \\  c: world
        \\
        ,
    );
    try testing.expectEqual(@as(usize, 2), r.items.len);
    try testing.expectEqual(@as(i64, 1), r.items[0].b);
    try testing.expectEqualStrings("hello", r.items[0].c);
    try testing.expectEqual(@as(i64, 1), r.items[1].b);
    try testing.expectEqualStrings("world", r.items[1].c);
}

test "merge key as Value" {
    const r = try testDecode(
        Value,
        \\a: &a
        \\  b: 1
        \\  c: hello
        \\items:
        \\- <<: *a
        \\- <<: *a
        \\  c: world
        \\
        ,
    );
    const a = r.mappingGet("a") orelse return error.TestExpectedValue;
    try expectValueInt(a, "b", 1);
    try expectValueString(a, "c", "hello");
    const items = r.mappingGet("items") orelse return error.TestExpectedValue;
    switch (items) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 2), s.len);
            try expectValueInt(s[0], "b", 1);
            try expectValueString(s[0], "c", "hello");
            try expectValueInt(s[1], "b", 1);
            try expectValueString(s[1], "c", "world");
        },
        else => return error.TestExpectedEqual,
    }
}

test "merge key from sequence of aliases" {
    const r = try testDecode(
        Value,
        \\a: &a
        \\ foo: 1
        \\b: &b
        \\ bar: 2
        \\merge:
        \\ <<: [*a, *b]
        \\
        ,
    );
    const a = r.mappingGet("a") orelse return error.TestExpectedValue;
    try expectValueInt(a, "foo", 1);
    const b = r.mappingGet("b") orelse return error.TestExpectedValue;
    try expectValueInt(b, "bar", 2);
    const merge = r.mappingGet("merge") orelse return error.TestExpectedValue;
    try expectValueInt(merge, "foo", 1);
    try expectValueInt(merge, "bar", 2);
}

test "merge tag with flow mapping" {
    const r = try testDecode(
        Value,
        \\
        \\!!merge <<: { a: 1, b: 2 }
        \\c: 3
        \\
        ,
    );
    try expectValueInt(r, "a", 1);
    try expectValueInt(r, "b", 2);
    try expectValueInt(r, "c", 3);
}

test "flow sequence A B as Value" {
    const r = try testDecode(Value, "v: [A,B]");
    const seq = r.mappingGet("v") orelse return error.TestExpectedValue;
    switch (seq) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 2), s.len);
            try testing.expectEqualStrings("A", s[0].string);
            try testing.expectEqualStrings("B", s[1].string);
        },
        else => return error.TestExpectedEqual,
    }
}

test "mixed nested list" {
    const r = try testDecode(
        Value,
        \\v:
        \\- A
        \\- 1
        \\- B:
        \\  - 2
        \\  - 3
        \\
        ,
    );
    const seq = r.mappingGet("v") orelse return error.TestExpectedValue;
    switch (seq) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 3), s.len);
            try testing.expectEqualStrings("A", s[0].string);
            try testing.expectEqual(@as(i64, 1), s[1].integer);
        },
        else => return error.TestExpectedEqual,
    }
}

test "same anchor redefined" {
    const S = struct {
        a: i64,
        b: i64,
        c: i64,
        d: i64,
    };
    const r = try testDecode(
        S,
        \\a: &a 1
        \\b: &a 2
        \\c: &a 3
        \\d: *a
        \\
        ,
    );
    try testing.expectEqual(@as(i64, 1), r.a);
    try testing.expectEqual(@as(i64, 2), r.b);
    try testing.expectEqual(@as(i64, 3), r.c);
    try testing.expectEqual(@as(i64, 3), r.d);
}

test "duplicate map key with allow option" {
    const r = try testDecode(
        Value,
        \\a: b
        \\a: c
        \\
        ,
    );
    try expectValueString(r, "a", "c");
}

test "struct with string and seq" {
    const S = struct {
        a: []const u8,
        b: []const u8,
    };
    const r = try testDecode(S,
        \\a: b
        \\b: d
        \\
    );
    try testing.expectEqualStrings("b", r.a);
    try testing.expectEqualStrings("d", r.b);
}

test "empty sequence item" {
    const r = try testDecode(
        Value,
        \\args:
        \\- a
        \\-
        \\command:
        \\- python
        ,
    );
    const args = r.mappingGet("args") orelse return error.TestExpectedValue;
    switch (args) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 2), s.len);
            try testing.expectEqualStrings("a", s[0].string);
            try testing.expectEqual(
                @as(std.meta.Tag(Value), .null),
                @as(std.meta.Tag(Value), s[1]),
            );
        },
        else => return error.TestExpectedEqual,
    }
    const cmd = r.mappingGet("command") orelse return error.TestExpectedValue;
    switch (cmd) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 1), s.len);
            try testing.expectEqualStrings("python", s[0].string);
        },
        else => return error.TestExpectedEqual,
    }
}

test "indented empty sequence item" {
    const r = try testDecode(
        Value,
        \\parent:
        \\  items:
        \\    - a
        \\    -
        \\  other: val
        ,
    );
    const parent = r.mappingGet("parent") orelse return error.TestExpectedValue;
    try expectValueString(parent, "other", "val");
    const items = parent.mappingGet("items") orelse return error.TestExpectedValue;
    switch (items) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 2), s.len);
            try testing.expectEqualStrings("a", s[0].string);
            try testing.expectEqual(
                @as(std.meta.Tag(Value), .null),
                @as(std.meta.Tag(Value), s[1]),
            );
        },
        else => return error.TestExpectedEqual,
    }
}

test "empty seq item with next line value" {
    const r = try testDecode(
        Value,
        \\items:
        \\-
        \\  key: val
        \\- b
        ,
    );
    const items = r.mappingGet("items") orelse return error.TestExpectedValue;
    switch (items) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 2), s.len);
            try expectValueString(s[0], "key", "val");
            try testing.expectEqualStrings("b", s[1].string);
        },
        else => return error.TestExpectedEqual,
    }
}

test "anchor in unmapped field" {
    const Job = struct {
        name: []const u8,
    };
    const Config = struct {
        name: []const u8,
        jobs: []const Job,
    };
    const r = try testDecode(
        Config,
        \\shared:
        \\  endpoint: &base_url "http://example.com"
        \\
        \\name: Test Config
        \\jobs:
        \\- name: Job1
        \\
        ,
    );
    try testing.expectEqualStrings("Test Config", r.name);
    try testing.expectEqual(@as(usize, 1), r.jobs.len);
    try testing.expectEqualStrings("Job1", r.jobs[0].name);
}

test "sibling anchor alias simple" {
    const r = try testDecode(
        Value,
        \\a: &a
        \\  b: &b value
        \\  ref: *b
        \\
        ,
    );
    const a = r.mappingGet("a") orelse return error.TestExpectedValue;
    try expectValueString(a, "b", "value");
    try expectValueString(a, "ref", "value");
}

test "sibling anchor alias multiple" {
    const r = try testDecode(
        Value,
        \\config: &config
        \\  db: &db postgres://localhost/mydb
        \\  cache: &cache redis://localhost:6379
        \\  app:
        \\    database_url: *db
        \\    cache_url: *cache
        \\
        ,
    );
    const config = r.mappingGet("config") orelse return error.TestExpectedValue;
    try expectValueString(
        config,
        "db",
        "postgres://localhost/mydb",
    );
    try expectValueString(
        config,
        "cache",
        "redis://localhost:6379",
    );
    const app = config.mappingGet("app") orelse return error.TestExpectedValue;
    try expectValueString(
        app,
        "database_url",
        "postgres://localhost/mydb",
    );
    try expectValueString(
        app,
        "cache_url",
        "redis://localhost:6379",
    );
}

test "nested map sibling alias" {
    const r = try testDecode(
        Value,
        \\service: &service
        \\  auth: &auth
        \\    required: true
        \\    type: jwt
        \\  endpoint:
        \\    security: *auth
        \\
        ,
    );
    const svc = r.mappingGet("service") orelse return error.TestExpectedValue;
    const auth = svc.mappingGet("auth") orelse return error.TestExpectedValue;
    try expectValueBool(auth, "required", true);
    try expectValueString(auth, "type", "jwt");
    const ep = svc.mappingGet("endpoint") orelse return error.TestExpectedValue;
    const sec = ep.mappingGet("security") orelse return error.TestExpectedValue;
    try expectValueBool(sec, "required", true);
    try expectValueString(sec, "type", "jwt");
}

test "self recursion anchor is null" {
    const r = try testDecode(
        Value,
        \\a: &a
        \\  self: *a
        \\
        ,
    );
    const a = r.mappingGet("a") orelse return error.TestExpectedValue;
    try expectValueNull(a, "self");
}

test "invalid alias reference" {
    const r = testDecode(Value, "*-0");
    try testing.expectError(error.Unimplemented, r);
}

test "roundtrip merge key struct" {
    const Foo = struct {
        k1: []const u8,
        k2: []const u8,
    };
    const Bar = struct {
        k1: []const u8,
        k3: []const u8,
    };
    const Doc = struct { foo: Foo, bar: Bar };
    const r = try testDecode(
        Doc,
        \\foo:
        \\ <<: &test-anchor
        \\   k1: "One"
        \\ k2: "Two"
        \\
        \\bar:
        \\ <<: *test-anchor
        \\ k3: "Three"
        \\
        ,
    );
    try testing.expectEqualStrings("One", r.foo.k1);
    try testing.expectEqualStrings("Two", r.foo.k2);
    try testing.expectEqualStrings("One", r.bar.k1);
    try testing.expectEqualStrings("Three", r.bar.k3);
}

test "anchor with any value and alias" {
    const r = try testDecode(
        Value,
        \\def:
        \\  myenv: &my_env
        \\    - VAR1=1
        \\    - VAR2=2
        \\config:
        \\  env: *my_env
        \\
        ,
    );
    const def = r.mappingGet("def") orelse return error.TestExpectedValue;
    const myenv = def.mappingGet("myenv") orelse return error.TestExpectedValue;
    switch (myenv) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 2), s.len);
            try testing.expectEqualStrings("VAR1=1", s[0].string);
            try testing.expectEqualStrings("VAR2=2", s[1].string);
        },
        else => return error.TestExpectedEqual,
    }
    const config = r.mappingGet("config") orelse return error.TestExpectedValue;
    const env = config.mappingGet("env") orelse return error.TestExpectedValue;
    switch (env) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 2), s.len);
            try testing.expectEqualStrings("VAR1=1", s[0].string);
            try testing.expectEqualStrings("VAR2=2", s[1].string);
        },
        else => return error.TestExpectedEqual,
    }
}

test "canonical mapping" {
    const r = try testDecode(
        Value,
        \\!!map {
        \\  ? !!str "explicit":!!str "entry",
        \\  ? !!str "implicit" : !!str "entry",
        \\  ? !!null "" : !!null "",
        \\}
        \\
        ,
    );
    try expectValueString(r, "explicit", "entry");
    try expectValueString(r, "implicit", "entry");
}

test "binary tag decode" {
    const S = struct { a: []const u8 };
    const r = try testDecode(S, "a: !!binary gIGC\n");
    try testing.expectEqualStrings("\x80\x81\x82", r.a);
}

test "quoted map keys" {
    const Inner = struct { b: i64, c: bool };
    const S = struct { a: Inner };
    const r = try testDecode(S, "a:\n  \"b\"  : 2\n  'c': true\n");
    try testing.expectEqual(@as(i64, 2), r.a.b);
    try testing.expect(r.a.c);
}

test "tab after value" {
    const r = try testDecode(Value, "- a: [2 , 2] \t\t\t\n  b: [2 , 2] \t\t\t\n  c: [2 , 2]");
    switch (r) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 1), s.len);
            const a = s[0].mappingGet("a") orelse return error.TestExpectedValue;
            switch (a) {
                .sequence => |as| {
                    try testing.expectEqual(@as(usize, 2), as.len);
                    try testing.expectEqual(@as(i64, 2), as[0].integer);
                },
                else => return error.TestExpectedEqual,
            }
            const b = s[0].mappingGet("b") orelse return error.TestExpectedValue;
            switch (b) {
                .sequence => |bs| {
                    try testing.expectEqual(@as(usize, 2), bs.len);
                    try testing.expectEqual(@as(i64, 2), bs[0].integer);
                },
                else => return error.TestExpectedEqual,
            }
            const c = s[0].mappingGet("c") orelse return error.TestExpectedValue;
            switch (c) {
                .sequence => |cs| {
                    try testing.expectEqual(@as(usize, 2), cs.len);
                    try testing.expectEqual(@as(i64, 2), cs[0].integer);
                },
                else => return error.TestExpectedEqual,
            }
        },
        else => return error.TestExpectedEqual,
    }
}

test "preserve struct defaults" {
    const Nested = struct {
        val: []const u8 = "default",
    };
    const T = struct {
        first: []const u8,
        nested: Nested = .{},
    };
    const r = try testDecode(T, "first: \"Test\"\nnested:\n");
    try testing.expectEqualStrings("Test", r.first);
    try testing.expectEqualStrings("default", r.nested.val);
}

test "decode integer as string key" {
    const r = try testDecode(Value, "42: 100");
    try testing.expectEqual(@as(std.meta.Tag(Value), .mapping), @as(std.meta.Tag(Value), r));
    try testing.expectEqual(@as(usize, 1), r.mapping.keys.len);
    try testing.expectEqual(@as(i64, 42), r.mapping.keys[0].integer);
    try testing.expectEqual(@as(i64, 100), r.mapping.values[0].integer);
}

test "decode struct with two fields" {
    const S = struct { a: []const u8, c: []const u8 };
    const r = try testDecode(S,
        \\a: b
        \\c: d
        \\
    );
    try testing.expectEqualStrings("b", r.a);
    try testing.expectEqualStrings("d", r.c);
}

test "decode nested null values" {
    const r = try testDecode(
        Value,
        \\a:
        \\  b:
        \\c: d
        ,
    );
    const a = r.mappingGet("a") orelse return error.TestExpectedValue;
    try expectValueNull(a, "b");
    try expectValueString(r, "c", "d");
}

test "disallow unknown nested" {
    const Inner = struct { b: i64 };
    const S = struct { c: Inner };
    const result = decode(
        S,
        testing.allocator,
        \\---
        \\b: 1
        \\c:
        \\  b: 1
        \\
    ,
        .{ .disallow_unknown_fields = true },
    );
    try testing.expectError(error.UnknownField, result);
}

test "timestamps as string" {
    const S = struct { t2: []const u8, t4: []const u8 };
    const r = try testDecode(
        S,
        \\t2: 2018-01-09T10:40:47Z
        \\t4: 2098-01-09T10:40:47Z
        \\
        ,
    );
    try testing.expectEqualStrings("2018-01-09T10:40:47Z", r.t2);
    try testing.expectEqualStrings("2098-01-09T10:40:47Z", r.t4);
}

test "single quote multiline fold" {
    const r = try testDecode(
        Value,
        \\'1': '   1
        \\    2
        \\    3'
        ,
    );
    try expectValueString(r, "1", "   1 2 3");
}

test "single quote multiline leading" {
    const r = try testDecode(
        Value,
        \\'1': '
        \\    2
        \\    3'
        ,
    );
    try expectValueString(r, "1", " 2 3");
}

test "double quote multiline fold" {
    const r = try testDecode(Value, "'1': \"   1\n    2\n    3\"");
    try expectValueString(r, "1", "   1 2 3");
}

test "double quote multiline leading" {
    const r = try testDecode(Value, "'1': \"\n    2\n    3\"");
    try expectValueString(r, "1", " 2 3");
}

test "decode percent yaml directive" {
    const r = try testDecode(
        ?Value,
        \\%YAML 1.2
        \\---
        \\
        ,
    );
    try testing.expect(r == null);
}

test "decode bare null keyword" {
    const r = try testDecode(?Value, "null");
    try testing.expect(r == null);
}

test "decode bare tilde" {
    const r = try testDecode(?Value, "~");
    try testing.expect(r == null);
}

test "flow map A B as Value" {
    const r = try testDecode(Value, "v: [A,B]");
    const seq = r.mappingGet("v") orelse return error.TestExpectedValue;
    switch (seq) {
        .sequence => |s| {
            try testing.expectEqual(@as(usize, 2), s.len);
            try testing.expectEqualStrings("A", s[0].string);
            try testing.expectEqualStrings("B", s[1].string);
        },
        else => return error.TestExpectedEqual,
    }
}

test "decode struct with seq no dash" {
    const S = struct { v: []const []const u8 };
    const r = try testDecode(S,
        \\v:
        \\- A
        \\- B
        \\
    );
    try testing.expectEqual(@as(usize, 2), r.v.len);
}

test "f64 max float32 range" {
    const S = struct { v: f32 };
    const r = try testDecode(S, "v: 3.40282346638528859811704183484516925440e+38");
    try testing.expectApproxEqRel(std.math.floatMax(f32), r.v, 1e-6);
}

test "f64 smallest nonzero f32" {
    const S = struct { v: f32 };
    const r = try testDecode(S, "v: 1.401298464324817070923729583289916131280e-45");
    try testing.expect(r.v > 0 and r.v <= std.math.floatMin(f32));
}

test "max f64" {
    const S = struct { v: f64 };
    const r = try testDecode(S, "v: 1.797693134862315708145274237317043567981e+308");
    try testing.expectApproxEqRel(std.math.floatMax(f64), r.v, 1e-15);
}

test "smallest nonzero f64" {
    const S = struct { v: f64 };
    const r = try testDecode(S, "v: 4.940656458412465441765687928682213723651e-324");
    try testing.expect(r.v > 0 and r.v <= std.math.floatMin(f64));
}

test "large uint as f64" {
    const S = struct { v: f64 };
    const r = try testDecode(S, "v: 18446744073709551615");
    try testing.expectApproxEqRel(@as(f64, 1.8446744073709552e+19), r.v, 1e-15);
}

test "large uint+1 as f64" {
    const S = struct { v: f64 };
    const r = try testDecode(S, "v: 18446744073709551616");
    try testing.expectApproxEqRel(@as(f64, 1.8446744073709552e+19), r.v, 1e-15);
}

test "large uint as f32" {
    const S = struct { v: f32 };
    const r = try testDecode(S, "v: 18446744073709551615");
    try testing.expectApproxEqRel(@as(f32, 1.8446744e+19), r.v, 1e-6);
}

test "large uint+1 as f32" {
    const S = struct { v: f32 };
    const r = try testDecode(S, "v: 18446744073709551616");
    try testing.expectApproxEqRel(@as(f32, 1.8446744e+19), r.v, 1e-6);
}

test "scientific underscore float" {
    const r = try testDecode(f64, "685.230_15e+03");
    try testing.expectApproxEqAbs(
        @as(f64, 685230.15e+0),
        r,
        0.1,
    );
}

test "binary with underscores as i64" {
    const r = try testDecode(i64, "0b1010_0111_0100_1010_1110");
    try testing.expectEqual(@as(i64, 685230), r);
}

test "decode positive sign integer" {
    const r = try testDecode(i64, "+685_230");
    try testing.expectEqual(@as(i64, 685230), r);
}

test "decode escape bell" {
    const r = try testDecode([]const u8, "\"\\a\"\n");
    try testing.expectEqual(@as(u8, 0x07), r[0]);
}

test "decode escape backspace" {
    const r = try testDecode([]const u8, "\"\\b\"\n");
    try testing.expectEqual(@as(u8, 0x08), r[0]);
}

test "decode escape vertical tab" {
    const r = try testDecode([]const u8, "\"\\v\"\n");
    try testing.expectEqual(@as(u8, 0x0B), r[0]);
}

test "decode escape form feed" {
    const r = try testDecode([]const u8, "\"\\f\"\n");
    try testing.expectEqual(@as(u8, 0x0C), r[0]);
}

test "decode escape esc" {
    const r = try testDecode([]const u8, "\"\\e\"\n");
    try testing.expectEqual(@as(u8, 0x1B), r[0]);
}

test "decode escape non-breaking space" {
    const r = try testDecode([]const u8, "\"\\_\"\n");
    try testing.expectEqualStrings("\xc2\xa0", r);
}

test "decode escape next line" {
    const r = try testDecode([]const u8, "\"\\N\"\n");
    try testing.expectEqualStrings("\xc2\x85", r);
}

test "decode escape line separator" {
    const r = try testDecode([]const u8, "\"\\L\"\n");
    try testing.expectEqualStrings("\xe2\x80\xa8", r);
}

test "decode escape paragraph separator" {
    const r = try testDecode([]const u8, "\"\\P\"\n");
    try testing.expectEqualStrings("\xe2\x80\xa9", r);
}

test "decode multi-byte unicode string" {
    const S = struct { v: []const u8 };
    const r = try testDecode(S, "v: \xc3\xa9\xc3\xa0\xc3\xbc\n");
    try testing.expectEqualStrings("\xc3\xa9\xc3\xa0\xc3\xbc", r.v);
}

test "decode unicode escape u00e9" {
    const r = try testDecode([]const u8, "\"\\u00e9\"\n");
    try testing.expectEqualStrings("\xc3\xa9", r);
}

test "decode unicode escape U0001F600" {
    const r = try testDecode([]const u8, "\"\\U0001F600\"\n");
    try testing.expectEqualStrings("\xf0\x9f\x98\x80", r);
}

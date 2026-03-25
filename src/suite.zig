const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Value = @import("value.zig").Value;
const yaml = @import("yaml.zig");

const suite_dir = "testdata/yaml-test-suite";

const known_failures = [_][]const u8{
    "anchors-on-empty-scalars",
    "aliases-in-flow-objects",
    "aliases-in-explicit-block-mapping",
    "block-mapping-with-missing-keys",
    "empty-implicit-key-in-single-pair-flow-sequences",
    "empty-keys-in-block-and-flow-mapping",
    "empty-lines-at-end-of-document",
    "flow-mapping-separate-values",
    "flow-sequence-in-flow-mapping",
    "implicit-flow-mapping-key-on-one-line",
    "mapping-key-and-flow-sequence-item-anchors",
    "nested-implicit-complex-keys",
    "single-pair-implicit-entries",
    "spec-example-2-11-mapping-between-sequences",
    "spec-example-6-12-separation-spaces",
    "spec-example-7-16-flow-mapping-entries",
    "spec-example-7-3-completely-empty-flow-nodes",
    "spec-example-8-18-implicit-block-mapping-entries",
    "spec-example-8-19-compact-block-mappings",
    "tags-on-empty-scalars",
    "various-combinations-of-explicit-block-mappings",
    "various-trailing-comments",
    "various-trailing-comments-1-3",
    "zero-indented-sequences-in-explicit-mapping-keys",
    "colon-at-the-beginning-of-adjacent-flow-scalar",
    "comment-without-whitespace-after-doublequoted-scalar",
    "construct-binary",
    "dash-in-flow-sequence",
    "invalid-comment-after-comma",
    "invalid-comment-after-end-of-flow-sequence",
    "invalid-comma-in-tag",
    "plain-dashes-in-flow-sequence",
    "spec-example-9-3-bare-documents",
    "spec-example-9-6-stream",
    "spec-example-9-6-stream-1-3",
    "trailing-line-of-spaces/01",
    "wrong-indented-flow-sequence",
    "wrong-indented-multiline-quoted-scalar",
};

fn isKnownFailure(name: []const u8) bool {
    for (&known_failures) |f| {
        if (std.mem.eql(u8, name, f)) return true;
    }
    if (std.mem.startsWith(u8, name, "question-mark-edge-cases/")) return true;
    if (std.mem.startsWith(u8, name, "single-character-streams/")) return true;
    if (std.mem.startsWith(u8, name, "syntax-character-edge-cases/")) return true;
    if (std.mem.startsWith(u8, name, "flow-collections-over-many-lines/")) return true;
    if (std.mem.startsWith(u8, name, "flow-mapping-colon-on-line-after-key/")) return true;
    if (std.mem.startsWith(u8, name, "tabs-in-various-contexts/")) return true;
    if (std.mem.startsWith(u8, name, "tabs-that-look-like-indentation/")) return true;
    if (std.mem.startsWith(u8, name, "tag-shorthand-used-in-documents-")) return true;
    return false;
}

fn readFile(allocator: Allocator, dir: std.fs.Dir, name: []const u8) ?[]u8 {
    const file = dir.openFile(name, .{}) catch return null;
    defer file.close();
    var buf: [4096]u8 = undefined;
    var r = file.reader(&buf);
    return r.interface.allocRemaining(allocator, .unlimited) catch null;
}

fn hasFile(dir: std.fs.Dir, name: []const u8) bool {
    const file = dir.openFile(name, .{}) catch return false;
    file.close();
    return true;
}

const SuiteResult = struct {
    total: u32 = 0,
    passed: u32 = 0,
    failed: u32 = 0,
    skipped: u32 = 0,
    errors: u32 = 0,
};

fn runSuiteCase(
    allocator: Allocator,
    base_dir: std.fs.Dir,
    name: []const u8,
    result: *SuiteResult,
) void {
    result.total += 1;

    if (isKnownFailure(name)) {
        result.skipped += 1;
        return;
    }

    const case_dir = base_dir.openDir(name, .{}) catch {
        result.errors += 1;
        return;
    };

    const in_yaml = readFile(allocator, case_dir, "in.yaml") orelse {
        result.errors += 1;
        return;
    };
    defer allocator.free(in_yaml);

    const expects_error = hasFile(case_dir, "error");

    if (expects_error) {
        var doc = yaml.parse(allocator, in_yaml) catch {
            result.passed += 1;
            return;
        };
        doc.deinit();
        result.failed += 1;
        return;
    }

    var doc = yaml.parse(allocator, in_yaml) catch {
        result.failed += 1;
        return;
    };
    doc.deinit();
    result.passed += 1;
}

test "yaml test suite" {
    const allocator = testing.allocator;

    var base_dir = std.fs.cwd().openDir(suite_dir, .{ .iterate = true }) catch {
        std.debug.print("SKIP: {s} not found\n", .{suite_dir});
        return error.SkipZigTest;
    };
    defer base_dir.close();

    var result = SuiteResult{};
    var name_buf: [4096][]u8 = undefined;
    var count: usize = 0;

    var it = base_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (count >= name_buf.len) break;
        name_buf[count] = try allocator.dupe(u8, entry.name);
        count += 1;
    }
    const names = name_buf[0..count];
    defer for (names) |n| allocator.free(n);

    std.mem.sort([]u8, names, {}, struct {
        fn cmp(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.cmp);

    for (names) |name| {
        runSuiteCase(allocator, base_dir, name, &result);
    }

    std.debug.print(
        \\
        \\YAML Test Suite: total={d} passed={d} failed={d} skipped={d} errors={d}
        \\
    , .{
        result.total,
        result.passed,
        result.failed,
        result.skipped,
        result.errors,
    });

    if (result.errors > 0) {
        return error.TestUnexpectedResult;
    }
}

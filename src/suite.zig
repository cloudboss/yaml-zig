const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const yaml = @import("yaml.zig");

const suite_dir = "yaml-test-suite";

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

fn readTestName(allocator: Allocator, dir: std.fs.Dir) []const u8 {
    const raw = readFile(allocator, dir, "===") orelse return "???";
    defer allocator.free(raw);
    const trimmed = std.mem.trimRight(u8, raw, "\n\r ");
    return allocator.dupe(u8, trimmed) catch "???";
}

const SuiteResult = struct {
    total: u32 = 0,
    passed: u32 = 0,
    failed: u32 = 0,
    errors: u32 = 0,
};

fn runCase(
    allocator: Allocator,
    base_dir: std.fs.Dir,
    id: []const u8,
    result: *SuiteResult,
) void {
    var case_dir = base_dir.openDir(id, .{ .iterate = true }) catch {
        result.total += 1;
        result.errors += 1;
        std.debug.print("  ERROR {s}: cannot open directory\n", .{id});
        return;
    };
    defer case_dir.close();

    // If there is no in.yaml, recurse into numbered subdirectories.
    if (!hasFile(case_dir, "in.yaml")) {
        var sub_it = case_dir.iterate();
        while (sub_it.next() catch null) |entry| {
            if (entry.kind != .directory) continue;
            var sub_id_buf: [16]u8 = undefined;
            const sub_id = std.fmt.bufPrint(
                &sub_id_buf,
                "{s}/{s}",
                .{ id, entry.name },
            ) catch continue;
            runCase(allocator, base_dir, sub_id, result);
        }
        return;
    }

    result.total += 1;

    const test_name = readTestName(allocator, case_dir);
    defer if (!std.mem.eql(u8, test_name, "???")) allocator.free(test_name);

    const in_yaml = readFile(allocator, case_dir, "in.yaml") orelse {
        result.errors += 1;
        std.debug.print("  ERROR {s} ({s}): cannot read in.yaml\n", .{ id, test_name });
        return;
    };
    defer allocator.free(in_yaml);

    const expects_error = hasFile(case_dir, "error");

    const ok = if (expects_error) blk: {
        var doc = yaml.parse(allocator, in_yaml) catch break :blk true;
        doc.deinit();
        break :blk false;
    } else blk: {
        var doc = yaml.parse(allocator, in_yaml) catch break :blk false;
        doc.deinit();
        break :blk true;
    };

    if (ok) {
        result.passed += 1;
    } else {
        result.failed += 1;
        if (expects_error) {
            std.debug.print("  FAIL {s} ({s}): expected error but parsed OK\n", .{ id, test_name });
        } else {
            std.debug.print("  FAIL {s} ({s}): parse error on valid YAML\n", .{ id, test_name });
        }
    }
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
        if (std.mem.eql(u8, entry.name, "name")) continue;
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
        runCase(allocator, base_dir, name, &result);
    }

    std.debug.print(
        "\nYAML Test Suite: {d}/{d} passed, {d} failed, {d} errors\n",
        .{ result.passed, result.total, result.failed, result.errors },
    );

    if (result.failed > 0 or result.errors > 0) {
        return error.TestUnexpectedResult;
    }
}

# yaml

A standards compliant YAML 1.2 parser and serializer for Zig. Follows an API similar to Zig's `std.json`.

Passes the [YAML test suite](https://github.com/yaml/yaml-test-suite).

API docs are at [https://cloudboss.co/yaml-zig](https://cloudboss.co/yaml-zig/).

# Usage

Add as a dependency:

```sh
zig fetch --save git+https://github.com/cloudboss/yaml-zig
```

# Examples

```zig
const A = struct {
    x: []const u8,
    y: u16,
    b: B,
};

const B = struct {
    a: u8,
    b: u8,
    c: u8,
};
```

## Deserialization

```zig
const yaml = @import("yaml");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const doc =
        \\x: example
        \\y: 789
        \\b:
        \\  a: 1
        \\  b: 2
        \\  c: 3
    ;

    // `parsed` is of type `Parsed(A)`
    const parsed = try yaml.parseFromSlice(A, allocator, doc, .{});
    defer parsed.deinit()

    // access the `A` instance through `parsed.value`
    std.debug.print("{s}\n", .{parsed.value.x});
    std.debug.print("{d}\n", .{parsed.value.y});
    std.debug.print("{d}\n", .{parsed.value.b.a});
    std.debug.print("{d}\n", .{parsed.value.b.b});
    std.debug.print("{d}\n", .{parsed.value.b.c});
}
```

Output:

```
example
789
1
2
3
```

## Serialization

```zig
const yaml = @import("yaml");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const a = A{
        .x = "example",
        .y = 789,
        .b = .{ .a = 1, .b = 2, .c = 3 },
    };

    const string = try yaml.stringifyAlloc(allocator, a, .{});
    defer allocator.free(string);

    std.debug.print("{s}", .{string});
}
```

Output:

```yaml
x: example
y: 789
b:
  a: 1
  b: 2
  c: 3
```

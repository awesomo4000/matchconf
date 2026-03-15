# Zig 0.15.2 Library Patterns — Research Notes

Research compiled from Zig 0.15.2 `zig init` output and documentation.

## Build System (build.zig)

### Module Exposure
```zig
const mod = b.addModule("matchconf", .{
    .root_source_file = b.path("src/root.zig"),
    .target = target,
});
```

### Executable with Module Import
```zig
const exe = b.addExecutable(.{
    .name = "example",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "matchconf", .module = mod },
        },
    }),
});
```

### Test Executable
```zig
const mod_tests = b.addTest(.{
    .root_module = mod,
});
const run_mod_tests = b.addRunArtifact(mod_tests);
test_step.dependOn(&run_mod_tests.step);
```

## Package Manifest (build.zig.zon)

```zig
.{
    .name = .matchconf,
    .version = "0.0.0",
    .fingerprint = 0x...,
    .minimum_zig_version = "0.15.2",
    .dependencies = .{},
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

Key fields:
- `.name` is a Zig enum literal (`.matchconf` not `"matchconf"`)
- `.fingerprint` is auto-generated, never change after creation
- `.paths` controls what gets included in the package hash

## API Changes in 0.15.2

### ArrayList
```zig
// Init with .empty, pass allocator to methods
var list: std.ArrayList(i32) = .empty;
defer list.deinit(gpa);
try list.append(gpa, 42);
```

### Buffered Stdout
```zig
var stdout_buffer: [1024]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;
try stdout.print("Hello\n", .{});
try stdout.flush();
```

### Testing
```zig
const gpa = std.testing.allocator; // leak-detecting allocator for tests
try std.testing.expectEqual(@as(i32, 42), value);
try std.testing.expect(condition);
try std.testing.expectEqualSlices(u8, expected, actual);
```

## Memory Management Patterns

- Always accept `std.mem.Allocator` as parameter (never hardcode allocator)
- Use `ArenaAllocator` for batched allocations (e.g., parsing entire config)
- Use `defer` / `errdefer` for cleanup
- Zero-copy: store `[]const u8` slices into source buffer rather than copying
- Keep source buffer alive for lifetime of parsed result

## Library Design Conventions

- `src/root.zig` is the public API entry point
- Re-export public types from root: `pub const Parser = @import("parser.zig").Parser;`
- Use `pub` only for API surface; internal helpers stay private
- Error sets: domain-specific, composed with `||` when needed
- Diagnostics pattern: collect warnings/errors as data, not Zig error returns

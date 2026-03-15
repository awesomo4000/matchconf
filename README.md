# matchconf

A general-purpose, ssh_config-style configuration library for Zig 0.15.2.

matchconf extracts the configuration format pioneered by `ssh_config` into a reusable system. You register your own section keywords, directives, token expanders, and match conditions. The library handles parsing, glob pattern matching, first-match-wins semantics, type coercion, and diagnostics.

## Features

- **Section-based config** — Define section keywords like `Host`, `Match`, `Service`, etc.
- **Glob pattern matching** — `*` and `?` wildcards with negation (`!pattern`)
- **First-match-wins** — Earliest matching section takes precedence (just like ssh_config)
- **Accumulating directives** — Some directives collect values from all matching sections
- **Conditional sections** — Register custom match criteria (like ssh_config `Match`)
- **Token expansion** — `%h`, `%u`, etc. with user-defined expanders
- **Type coercion** — Strings, integers, booleans, paths, string lists, string pairs, enums
- **Diagnostics** — Warnings for unknown directives with typo suggestions (Levenshtein distance)
- **Include directives** — Glob-expanded file includes with cycle detection
- **Zero-copy parsing** — Slices into source buffers wherever possible; arena-allocated

## Quick Start

Add matchconf as a dependency in your `build.zig`:

```zig
const matchconf_mod = b.dependency("matchconf", .{
    .target = target,
    .optimize = optimize,
}).module("matchconf");

exe.root_module.addImport("matchconf", matchconf_mod);
```

Then use it:

```zig
const std = @import("std");
const matchconf = @import("matchconf");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // 1. Create a parser and register your schema
    var parser = matchconf.Parser.init(allocator);
    defer parser.deinit();

    try parser.section("Host", .{ .matching = .pattern });
    try parser.directive("HostName", .{ .value_type = .string });
    try parser.directive("Port", .{ .value_type = .integer });
    try parser.directive("User", .{ .value_type = .string });
    try parser.directive("IdentityFile", .{ .value_type = .path, .accumulate = true });

    // 2. Parse a config string (or file)
    var config = try parser.parseString(
        \\Host web.example.com
        \\    HostName 10.0.1.100
        \\    Port 2222
        \\    User deploy
        \\    IdentityFile ~/.ssh/id_deploy
        \\
        \\Host *
        \\    Port 22
        \\    User default
        \\    IdentityFile ~/.ssh/id_rsa
    , "my_config");
    defer config.deinit();

    // 3. Look up values for a target
    var ctx = matchconf.ExpandContext.init(allocator);
    defer ctx.deinit();

    var result = try matchconf.lookupFn(allocator, &config, "web.example.com", &ctx);
    defer result.deinit();

    // First-match-wins: Port = 2222 (from "Host web.example.com")
    std.debug.print("Port: {d}\n", .{result.getIntOr("Port", 22)});

    // Accumulated: both identity files collected
    const files = result.getStringList("IdentityFile");
    for (files) |f| {
        std.debug.print("IdentityFile: {s}\n", .{f});
    }
}
```

## API Reference

### `Parser`

The parser holds your schema definition and produces `Config` objects.

```zig
var parser = matchconf.Parser.init(allocator);
defer parser.deinit();
```

#### `parser.section(keyword, config)`

Register a section keyword. Sections group directives and control matching behavior.

```zig
// Glob-matched sections (like ssh_config "Host")
try parser.section("Host", .{ .matching = .pattern });

// Conditional sections (like ssh_config "Match")
try parser.section("Match", .{ .matching = .conditional });
```

**`MatchingMode.pattern`** — The section value is whitespace-separated glob patterns. A section matches a target if any positive pattern matches and no negated pattern matches.

**`MatchingMode.conditional`** — The section value is a list of `name value` criteria pairs. All criteria must match (AND logic). Each criteria name must have a registered matcher function.

#### `parser.directive(keyword, def)`

Register a directive with its expected type and behavior.

```zig
try parser.directive("Port", .{
    .value_type = .integer,
});

try parser.directive("IdentityFile", .{
    .value_type = .path,
    .accumulate = true,   // collect from ALL matching sections
});

try parser.directive("LogLevel", .{
    .value_type = .{ .one_of = &.{ "debug", "info", "warn", "error" } },
});
```

**Supported value types:**

| Type | Description |
|------|-------------|
| `.string` | Any string value |
| `.integer` | Parsed as `i64` |
| `.boolean` | `yes`/`no`, `true`/`false`, `on`/`off` (case-insensitive) |
| `.path` | String with `~` expanded to `$HOME` |
| `.string_list` | Whitespace-separated list of strings |
| `.string_pair` | Two whitespace-separated tokens (e.g., `KEY value`) |
| `.one_of` | Must match one of the allowed values (case-insensitive) |

**Directive options:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `value_type` | `ValueType` | required | Expected type for the directive value |
| `default` | `?Value` | `null` | Default value if not set in config |
| `accumulate` | `bool` | `false` | If true, values from all matching sections are collected instead of first-match-wins |

#### `parser.expander(char, func)`

Register a token expander. When a directive value contains `%X`, the expander for character `X` is called.

```zig
parser.expander('h', struct {
    fn expand(ctx: *const matchconf.ExpandContext) ?[]const u8 {
        return ctx.get("hostname");
    }
}.expand);
```

`%%` produces a literal `%`. Unregistered tokens are left as-is.

#### `parser.matcher(name, func)`

Register a match condition evaluator for conditional (`Match`) sections.

```zig
try parser.matcher("host", struct {
    fn match(
        criteria_value: []const u8,
        target: []const u8,
        ctx: *const matchconf.ExpandContext,
    ) bool {
        return matchconf.glob.match(criteria_value, target);
    }
}.match);
```

#### `parser.parseString(content, source_name) !Config`

Parse a config string. The `source_name` is used in diagnostic messages. The parser must outlive the returned `Config`.

#### `parser.parseFile(path) !Config`

Parse a config file from an absolute path.

---

### `Config`

The parsed configuration. Owns all parsed data via an arena allocator.

```zig
var config = try parser.parseString(content, "source_name");
defer config.deinit();
```

#### `config.hasDiagnostics() bool`

Returns true if any diagnostics (warnings or errors) were generated during parsing.

#### `config.hasErrors() bool`

Returns true if any error-level diagnostics were generated.

#### `config.diagnosticItems() []const Diagnostic`

Returns the list of diagnostics. Each diagnostic has:

```zig
pub const Diagnostic = struct {
    file: []const u8,       // source file name
    line: u32,              // 1-based line number
    column: u32,            // 0-based column
    level: Level,           // .err or .warn
    message: []const u8,    // e.g., "unknown directive"
    context: []const u8,    // the raw source line
    suggestion: ?[]const u8, // typo correction (e.g., "HostName")
};
```

Use `diagnostic.format(allocator)` to get a formatted string like:
```
test.conf:2:4: warning: unknown directive (did you mean 'HostName'?)
```

---

### `lookupFn`

Query the config for a specific target.

```zig
var ctx = matchconf.ExpandContext.init(allocator);
defer ctx.deinit();
try ctx.put("hostname", "web.example.com");

var result = try matchconf.lookupFn(allocator, &config, "web.example.com", &ctx);
defer result.deinit();
```

The `ExpandContext` provides values for token expansion during lookup. Set whatever key-value pairs your expander functions expect.

---

### `LookupResult`

The result of a lookup, with typed accessors.

#### First-match-wins accessors

These return the value from the earliest matching section:

```zig
result.getString("HostName")         // ?[]const u8
result.getInt("Port")                // ?i64
result.getBool("ForwardAgent")       // ?bool
result.getPath("CertificateFile")    // ?[]const u8

// With defaults:
result.getStringOr("User", "root")   // []const u8
result.getIntOr("Port", 22)          // i64
result.getBoolOr("Compression", false) // bool
```

#### Accumulation accessors

These return values collected from all matching sections:

```zig
result.getStringList("IdentityFile")    // []const []const u8
result.getStringPairList("EnvVar")      // []const StringPair
```

`StringPair` has `.first` and `.second` fields.

#### Unknown directives

```zig
result.getUnknowns()  // []const ParsedDirective
```

Returns directives from matching sections that were not registered in the schema.

---

### `glob`

The glob matching module is also available for direct use:

```zig
matchconf.glob.match("*.example.com", "web.example.com")  // true
matchconf.glob.match("192.168.?.*", "192.168.1.100")      // true

matchconf.glob.matchPatternList(
    &.{ "*.com", "!evil.com" },
    "good.com",
)  // true

matchconf.glob.matchCommaSeparatedList(
    "*.com, !evil.com",
    "evil.com",
)  // false
```

---

## Config File Format

The format follows ssh_config conventions:

```
# Comments start with #

# Directives before any section apply to all targets
GlobalOption value

# Sections group directives
Host web.example.com staging.example.com
    HostName 10.0.1.100
    Port 2222
    User deploy

# Glob patterns
Host *.example.com !db.example.com
    User webteam

# Wildcard section (matches everything)
Host *
    Port 22
    User default

# Conditional sections
Match host *.admin.example.com
    User root

# Include other files (supports globs)
Include /etc/myapp/conf.d/*.conf
Include extra.conf
```

**Syntax rules:**
- Keywords and values are separated by whitespace or `=`
- Values can be quoted with `"` (supports `\"` and `\\` escapes)
- Lines starting with `#` are comments
- Leading whitespace is ignored (indentation is cosmetic)
- Keywords are case-insensitive for matching purposes

**Matching rules:**
- Sections are evaluated in order against the lookup target
- For `pattern` sections: any positive glob must match, no negated glob may match
- For `conditional` sections: all criteria must match (AND logic)
- **First-match-wins**: for non-accumulating directives, the first matching section sets the value
- **Accumulating directives**: values from all matching sections are collected in order

---

## Examples

See the `examples/` directory for complete working examples:

- **`examples/ssh_config.zig`** — SSH config parser with Host/Match sections, token expanders
- **`examples/deploy_config.zig`** — Service deployment config with string pair accumulation

Build and run them:

```sh
zig build run-ssh-example
zig build run-deploy-example
```

## Running Tests

```sh
zig build test
```

This runs 70+ unit tests across all modules plus integration tests covering end-to-end parsing and lookup scenarios.

## Module Structure

```
src/
  root.zig          — Public API re-exports
  parser.zig        — Schema registration, Config builder, section parsing
  line_parser.zig   — Low-level line tokenization (keyword + value)
  glob.zig          — Glob pattern matching (* and ?)
  types.zig         — Value types, coercion, boolean/integer/path parsing
  diagnostics.zig   — Diagnostic messages, Levenshtein typo detection
  expand.zig        — %X token expansion
  lookup.zig        — Query engine (first-match-wins, accumulation)
  include.zig       — Include directive processing with cycle detection
```

## License

MIT

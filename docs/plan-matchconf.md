# matchconf — Pattern-Matched Configuration Library

## Overview

matchconf is a standalone Zig library that implements the ssh_config configuration format as a general-purpose, reusable config system. The format supports named sections with glob-matchable patterns, first-match-wins semantics, conditional matching, token expansion, include directives, and typed directive extraction.

The format has been battle-tested for decades in OpenSSH. Millions of developers already know how to read and write it. matchconf extracts the format mechanics into a library with no SSH-specific knowledge — consumers register their own section keywords, directives, token expanders, and match conditions.

## The Format

A matchconf file is structurally simple:

```
# Comments start with #

Section pattern1
    Key1 value1
    Key2 value2

Section pattern2
    Key1 different_value
    Key3 value3

Section *
    Key4 default_value
```

Lines are `keyword value` pairs, optionally indented. Sections group directives under a pattern. When querying for a specific target, sections are evaluated top to bottom. For each directive, the first matching section's value wins. Wildcard sections (`*`) provide defaults.

### Features

- **Named sections** with glob patterns (`Host web*`, `Service api-*`)
- **Pattern negation** (`Host * !staging`)
- **Comma-separated patterns** (`Host foo,bar,baz`)
- **First-match-wins** per directive, evaluated top to bottom
- **Accumulating directives** — some keys append rather than override
- **Conditional sections** (`Match` with pluggable condition handlers)
- **Include directives** with glob expansion (`Include conf.d/*`)
- **Token expansion** (`%h`, `%n`, `%u`, customizable)
- **Typed values** — string, integer, boolean, path, enum, string list, string pair
- **Case-insensitive keywords** (values are case-sensitive)

## Use Cases

The format is useful anywhere you need configuration that varies by target name:

**SSH config** (the original) — directives vary by host:
```
Host prod-*
    User deploy
    IdentityFile ~/.ssh/prod_key

Host dev-*
    User developer
    ForwardAgent yes
```

**Service deployment** — directives vary by service name:
```
Service api-*
    Port 8080
    Replicas 3
    HealthCheck /health

Service api-prod
    Replicas 10
    Region us-east
```

**Host inventory** — directives vary by hostname pattern:
```
Target 10.42.*
    ScanProfile aggressive
    Label internal

Target 10.42.3.17
    Label webserver
    Notes "Apache 2.4, needs patching"
```

**Multi-environment config** — directives vary by environment name:
```
Env production
    DatabaseUrl postgres://prod-db:5432/app
    LogLevel warn
    CacheEnabled yes

Env staging
    DatabaseUrl postgres://staging-db:5432/app
    LogLevel debug

Env *
    CacheEnabled no
    MaxWorkers 4
```

## API Design

### Parser Setup

Consumers register their schema before parsing:

```zig
const matchconf = @import("matchconf");

var parser = matchconf.Parser.init(allocator);
defer parser.deinit();

// Register section keyword — "Host" matches targets via glob
parser.section("Host", .{ .matching = .glob });

// Register directives with types
parser.directive("HostName", .{ .type = .string });
parser.directive("Port", .{ .type = .integer, .default = 22 });
parser.directive("User", .{ .type = .string });
parser.directive("Compression", .{ .type = .boolean, .default = false });
parser.directive("IdentityFile", .{ .type = .path, .accumulate = true });
parser.directive("Timeout", .{ .type = .integer, .default = 30 });

// Enum types
parser.directive("AddressFamily", .{
    .type = .{ .one_of = &.{ "any", "inet", "inet6" } },
    .default = "any",
});

// String pair types (two values per line, e.g. "remote local")
parser.directive("SyncPath", .{ .type = .string_pair, .accumulate = true });

// Custom directives — any tool can register its own
parser.directive("DeployTarget", .{ .type = .string });
parser.directive("LogDir", .{ .type = .path });
parser.directive("MaxRetries", .{ .type = .integer, .default = 3 });
```

### Token Expansion

Register `%` token expanders before parsing:

```zig
parser.expander('h', struct {
    fn expand(ctx: *const ExpandContext) []const u8 {
        return ctx.get("hostname");
    }
}.expand);

parser.expander('u', struct {
    fn expand(ctx: *const ExpandContext) []const u8 {
        return ctx.get("username");
    }
}.expand);

parser.expander('n', struct {
    fn expand(ctx: *const ExpandContext) []const u8 {
        return ctx.get("name");  // the queried target name
    }
}.expand);
```

Tokens are expanded during the query phase, not during parsing. This allows the same parsed config to be queried for different targets without re-parsing.

### Match Conditions

Register handlers for `Match` conditional sections:

```zig
parser.matcher("host", struct {
    fn match(pattern: []const u8, ctx: *const MatchContext) bool {
        return globMatch(pattern, ctx.get("hostname"));
    }
}.match);

parser.matcher("user", struct {
    fn match(pattern: []const u8, ctx: *const MatchContext) bool {
        return std.mem.eql(u8, pattern, ctx.get("username"));
    }
}.match);

parser.matcher("exec", struct {
    fn match(cmd: []const u8, ctx: *const MatchContext) bool {
        return execCommand(cmd) == 0;
    }
}.match);
```

### Parsing

`parseFile` returns a result that may contain parse diagnostics. Zig error returns are reserved for true program errors (file not found, out of memory, permission denied). A malformed config line is a parse diagnostic, not a program error — it's expected, common, and the caller needs rich context to report it.

```zig
// Parse a single file — returns config + any diagnostics
const result = parser.parseFile("/path/to/config");

// Check for hard errors (file not found, OOM)
const config = result catch |err| {
    // err is std.fs.File.OpenError, std.mem.Allocator.Error, etc.
    // actual system-level failure, not a config problem
    return err;
};

// Check for parse diagnostics (malformed lines, unknown directives, type mismatches)
if (config.hasDiagnostics()) {
    for (config.diagnostics()) |d| {
        // d.file     — "/path/to/config"
        // d.line     — 14
        // d.column   — 5
        // d.level    — .err | .warn
        // d.message  — "expected integer for Port, got 'abc'"
        // d.context  — "    Port abc"  (the raw source line)
        // d.suggestion — "did you mean 'Timeout'?" (for typos, optional)
        std.debug.print("{s}:{d}: {s}\n  {s}\n", .{
            d.file, d.line, d.message, d.context,
        });
    }
}

// Config is still usable even with warnings — valid directives are parsed,
// only the problematic lines are skipped. Errors mean the section or
// directive was dropped. The caller decides whether to proceed.
if (config.hasErrors()) {
    // at least one directive was unparseable and dropped
    // caller decides: bail out, or continue with partial config
}

// Parse multiple files (for layered configs)
// merge respects first-match-wins — earlier files take priority
try config.mergeFile("~/.config/myapp/config");
try config.mergeFile("/etc/myapp/config");
// merge also accumulates diagnostics from each file
```

### Diagnostic Type

```zig
pub const Diagnostic = struct {
    file: []const u8,
    line: u32,
    column: u32,
    level: Level,
    message: []const u8,
    context: []const u8,      // the raw source line
    suggestion: ?[]const u8,  // typo correction hint, if applicable

    pub const Level = enum {
        err,   // directive was dropped (unparseable type, invalid section)
        warn,  // directive was accepted but something looks off (deprecated, unusual)
    };
};
```

### Error vs Diagnostic Boundary

| Situation | Mechanism |
|-----------|-----------|
| File not found | Zig error return (`error.FileNotFound`) |
| Permission denied on file | Zig error return (`error.AccessDenied`) |
| Out of memory | Zig error return (`error.OutOfMemory`) |
| Unknown directive | Diagnostic (`.warn` — collected in unknowns, or `.err` if strict mode) |
| Type mismatch (`Port abc`) | Diagnostic (`.err` — directive dropped) |
| Malformed section header | Diagnostic (`.err` — section skipped) |
| Unclosed quote | Diagnostic (`.err` — line dropped) |
| Typo in directive name | Diagnostic (`.warn` with `.suggestion`) |
| Include glob matches nothing | Diagnostic (`.warn`) |
| Include target not found | Diagnostic (`.err`) or Zig error (configurable) |

The parser is lenient by default — it parses what it can and reports problems as diagnostics. The caller decides what's fatal.

### Querying

```zig
const result = config.lookup("web-prod", .{
    .hostname = "web-prod.example.com",
    .username = "deploy",
});

// Typed access
const port = result.getInt("Port");              // ?i64 → 8080
const user = result.getString("User");           // ?[]const u8 → "deploy"
const compress = result.getBool("Compression");  // ?bool → false
const keys = result.getStringList("IdentityFile"); // [][]const u8 (accumulated)

// With defaults
const port2 = result.getIntOr("Port", 22);      // i64 → 8080 or 22
const retries = result.getIntOr("MaxRetries", 3);

// String pairs (accumulated)
const syncs = result.getStringPairList("SyncPath"); // []{.first, .second}

// Unknown directives (not registered)
const unknowns = result.getUnknowns();  // []Directive{key, value}
```

### Result Type

```zig
pub const LookupResult = struct {
    /// Get a string directive value
    pub fn getString(self: *const @This(), key: []const u8) ?[]const u8;

    /// Get an integer directive value
    pub fn getInt(self: *const @This(), key: []const u8) ?i64;

    /// Get a boolean directive value (yes/no/true/false)
    pub fn getBool(self: *const @This(), key: []const u8) ?bool;

    /// Get a path directive value (tilde-expanded)
    pub fn getPath(self: *const @This(), key: []const u8) ?[]const u8;

    /// Get accumulated string list (for directives with .accumulate = true)
    pub fn getStringList(self: *const @This(), key: []const u8) []const []const u8;

    /// Get accumulated string pairs (for .type = .string_pair, .accumulate = true)
    pub fn getStringPairList(self: *const @This(), key: []const u8) []const StringPair;

    /// Get all directives that weren't registered (unknown to the consumer)
    pub fn getUnknowns(self: *const @This()) []const Directive;

    /// Get a string with a default fallback
    pub fn getStringOr(self: *const @This(), key: []const u8, default: []const u8) []const u8;

    /// Get an integer with a default fallback
    pub fn getIntOr(self: *const @This(), key: []const u8, default: i64) i64;

    /// Get a boolean with a default fallback
    pub fn getBoolOr(self: *const @This(), key: []const u8, default: bool) bool;
};
```

## Pattern Matching

### Glob Patterns

Section patterns support standard glob matching:

- `*` — matches zero or more characters
- `?` — matches exactly one character
- `!pattern` — negation (exclude matches)
- `pattern1,pattern2` — comma-separated alternatives

```
Host web*               # matches web1, webserver, web-prod
Host *.example.com      # matches anything.example.com
Host web* !web-staging  # matches web*, but not web-staging
Host jump,bounce        # matches jump OR bounce
```

### First-Match-Wins

For non-accumulating directives, the first section that matches and defines the directive wins:

```
Host prod
    Port 8080

Host *
    Port 3000
```

Querying for "prod": Port = 8080. The `Host *` block's Port 3000 is ignored because Port was already set.

### Accumulating Directives

Directives registered with `.accumulate = true` collect values from all matching sections:

```
Host prod
    SyncPath /var/data      ./data
    SyncPath /var/logs      ./logs

Host *
    SyncPath /etc/config    ./config
```

Querying for "prod": SyncPath = all three entries.

## Include Directives

```
Include ~/.config/myapp/conf.d/*
Include overrides/*.conf
```

Paths are glob-expanded. Relative paths resolve relative to the file containing the `Include` directive. Included files are parsed inline — their sections are evaluated as if they were written directly in the including file at the point of the `Include`.

## Token Expansion

Tokens use the `%` prefix followed by a single character. Registered expanders are called during query time with the lookup context:

```
Host *
    LogDir /var/log/%n
    DataDir /home/%u/%n/data
```

When querying for "myapp" with context `{name: "myapp", username: "deploy"}`:

- `%n` expands to "myapp"
- `%u` expands to "deploy"
- Result: `LogDir = /var/log/myapp`, `DataDir = /home/deploy/myapp/data`

There are no built-in tokens. The consumer registers all expanders. The library only provides the expansion mechanism. A consumer implementing ssh_config compatibility would register:

| Token | Meaning |
|-------|---------|
| `%h` | Host name (as queried) |
| `%r` | Remote user name |
| `%p` | Port |
| `%C` | Hash of %h + %p + %r |
| `%d` | Local user's home directory |
| `%u` | Local user name |
| `%%` | Literal `%` (built-in, always available) |

## What the Library Owns

- Line parsing, whitespace handling, comment stripping
- Section block parsing and pattern association
- Glob pattern matching with wildcards, negation, comma lists
- `Match` conditional dispatch via registered handlers
- `Include` with glob expansion, relative path resolution
- First-match-wins semantics per directive
- Accumulate semantics for multi-value directives
- Token expansion via registered `%` expanders
- Type coercion (string, integer, boolean, path, enum, string list, string pair)
- Tilde expansion for path types
- Multi-file merge with layered precedence
- Unknown directive collection (for extensibility)
- Parse diagnostics with file, line, column, context, and typo suggestions

## What the Library Does NOT Own

- What section keywords are valid (consumers register them)
- What directives exist or what they mean (consumers register them)
- What tokens can be expanded (consumers register expanders)
- What match conditions exist (consumers register matchers)
- What to do with the parsed results (consumers query and interpret)
- Any application-specific semantics

## Implementation Notes

### Error Reporting

Parse problems are returned as diagnostics on the config result, not as Zig error returns. See the "Parsing" section above for the `Diagnostic` type and the error vs diagnostic boundary.

Output formatting is the caller's responsibility. The `Diagnostic` struct provides all the context needed for rich error messages:

```
config:14: error: unknown directive 'Tmeout' (did you mean 'Timeout'?)
    Tmeout 30
    ^~~~~~

config:22: error: expected integer for Port, got 'abc'
    Port abc
         ^~~

~/.config/myapp/config:8: warning: Include glob 'conf.d/*' matched no files
```

Typo detection uses edit distance against registered directive names. Suggestions are attached to the diagnostic when a close match is found.

### Zero-Copy Where Possible

The parser stores references into the original file content rather than copying strings. The config file content is kept alive for the lifetime of the parsed config. This minimizes allocations for the common case of reading a file and querying it.

### Streaming Parse

The parser processes files line by line and doesn't need to hold the entire parsed tree in memory before queries. However, the common usage pattern (parse file, query multiple times) benefits from caching the parsed structure, so the default API materializes the full section tree.

### Thread Safety

A parsed config is read-only after construction and safe to query from multiple threads. The parser itself is not thread-safe (single-threaded construction, concurrent reads).

## Example: SSH Config Parser

Implementing a full ssh_config parser using matchconf:

```zig
const matchconf = @import("matchconf");

var parser = matchconf.Parser.init(allocator);
defer parser.deinit();

// Section types
parser.section("Host", .{ .matching = .glob });
parser.section("Match", .{ .matching = .conditional });

// Connection directives
parser.directive("HostName", .{ .type = .string });
parser.directive("Port", .{ .type = .integer, .default = 22 });
parser.directive("User", .{ .type = .string });
parser.directive("ProxyJump", .{ .type = .string });
parser.directive("IdentityFile", .{ .type = .path, .accumulate = true });
parser.directive("ServerAliveInterval", .{ .type = .integer });
parser.directive("Compression", .{ .type = .boolean, .default = false });
parser.directive("AddressFamily", .{
    .type = .{ .one_of = &.{ "any", "inet", "inet6" } },
    .default = "any",
});

// Token expanders (ssh conventions)
parser.expander('h', expandHostname);
parser.expander('r', expandUsername);
parser.expander('p', expandPort);
parser.expander('C', expandConnectionHash);
parser.expander('d', expandHomeDir);
parser.expander('u', expandLocalUser);

// Match handlers
parser.matcher("host", matchHostGlob);
parser.matcher("user", matchUserExact);
parser.matcher("exec", matchExecCommand);

// Parse layered config
var config = try parser.parseFile("~/.ssh/config");
try config.mergeFile("/etc/ssh/ssh_config");

if (config.hasDiagnostics()) {
    for (config.diagnostics()) |d| {
        log.warn("{s}:{d}: {s}", .{ d.file, d.line, d.message });
    }
}

// Query
const host = config.lookup("myserver", .{
    .hostname = "myserver.example.com",
    .username = "deploy",
    .port = "22",
});

const real_host = host.getStringOr("HostName", "myserver");
const port = host.getIntOr("Port", 22);
const user = host.getStringOr("User", "root");
const keys = host.getStringList("IdentityFile");
```

## Example: Deploy Tool Config

A deployment tool using matchconf for per-service configuration:

```zig
var parser = matchconf.Parser.init(allocator);

parser.section("Service", .{ .matching = .glob });
parser.directive("Port", .{ .type = .integer });
parser.directive("Replicas", .{ .type = .integer, .default = 1 });
parser.directive("Region", .{ .type = .string });
parser.directive("HealthCheck", .{ .type = .string });
parser.directive("EnvVar", .{ .type = .string_pair, .accumulate = true });

parser.expander('s', expandServiceName);

var config = try parser.parseFile("deploy.conf");

// deploy.conf:
//
// Service api-*
//     Port 8080
//     HealthCheck /health
//     Replicas 3
//     EnvVar LOG_LEVEL info
//     EnvVar NODE_ENV production
//
// Service api-prod
//     Replicas 10
//     Region us-east
//     EnvVar LOG_LEVEL warn
//
// Service *
//     Replicas 1
//     Region us-west

const svc = config.lookup("api-prod", .{ .service = "api-prod" });
const port = svc.getIntOr("Port", 3000);          // 8080 (from api-*)
const replicas = svc.getIntOr("Replicas", 1);     // 10 (from api-prod, first match)
const region = svc.getStringOr("Region", "local"); // "us-east" (from api-prod)
const env = svc.getStringPairList("EnvVar");       // all three entries (accumulated)
```

Same parser, same format, completely different domain.

## Project Structure

```
matchconf/
  src/
    parser.zig         # main parser, section/directive registration
    glob.zig           # pattern matching (*, ?, negation, comma lists)
    expand.zig         # token expansion engine
    types.zig          # type coercion (string, int, bool, path, enum)
    lookup.zig         # query engine, first-match-wins, accumulation
    include.zig        # Include directive handling, glob expansion
    diagnostics.zig    # Diagnostic type, severity levels, typo detection, context capture
  build.zig
  build.zig.zon
  README.md
  LICENSE
  tests/
    parser_test.zig
    glob_test.zig
    expand_test.zig
    lookup_test.zig
    diagnostics_test.zig
    integration_test.zig
    fixtures/
      basic.conf
      includes/
      edge_cases.conf
```

## License

MIT. Maximum reusability.

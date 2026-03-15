const std = @import("std");
const types = @import("types.zig");
const parser_mod = @import("parser.zig");
const expand_mod = @import("expand.zig");
const glob = @import("glob.zig");

const Value = types.Value;
const ValueType = types.ValueType;
const StringPair = types.StringPair;
const ParsedDirective = parser_mod.ParsedDirective;
const Section = parser_mod.Section;
const Config = parser_mod.Config;
const ExpandContext = parser_mod.ExpandContext;
const ExpanderFn = parser_mod.ExpanderFn;
const MatcherFn = parser_mod.MatcherFn;
const DirectiveDef = parser_mod.DirectiveDef;

pub const ResolvedValue = struct {
    raw: []const u8,
    expanded: []const u8,
};

pub const LookupResult = struct {
    allocator: std.mem.Allocator,
    /// Resolved directive values (first-match-wins already applied)
    resolved: std.StringArrayHashMap(ResolvedValue),
    /// Accumulated string values
    accumulated: std.StringArrayHashMap(std.ArrayList([]const u8)),
    /// Accumulated string pairs
    accumulated_pairs: std.StringArrayHashMap(std.ArrayList(StringPair)),
    /// Unknown directives from matching sections
    unknowns: std.ArrayList(ParsedDirective),
    /// Strings allocated during expansion that need freeing
    expanded_strings: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) LookupResult {
        return .{
            .allocator = allocator,
            .resolved = std.StringArrayHashMap(ResolvedValue).init(allocator),
            .accumulated = std.StringArrayHashMap(std.ArrayList([]const u8)).init(allocator),
            .accumulated_pairs = std.StringArrayHashMap(std.ArrayList(StringPair)).init(allocator),
            .unknowns = .empty,
            .expanded_strings = .empty,
        };
    }

    pub fn deinit(self: *LookupResult) void {
        // Free expanded strings
        for (self.expanded_strings.items) |s| {
            self.allocator.free(s);
        }
        self.expanded_strings.deinit(self.allocator);

        self.resolved.deinit();

        // Free accumulated lists
        {
            var it = self.accumulated.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
        }
        self.accumulated.deinit();

        // Free accumulated pairs
        {
            var it = self.accumulated_pairs.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
        }
        self.accumulated_pairs.deinit();

        self.unknowns.deinit(self.allocator);
    }

    // ---- Typed accessors ----

    pub fn getString(self: *const LookupResult, key: []const u8) ?[]const u8 {
        const rv = self.resolved.get(key) orelse return null;
        return rv.expanded;
    }

    pub fn getInt(self: *const LookupResult, key: []const u8) ?i64 {
        const rv = self.resolved.get(key) orelse return null;
        return types.parseInteger(rv.expanded);
    }

    pub fn getBool(self: *const LookupResult, key: []const u8) ?bool {
        const rv = self.resolved.get(key) orelse return null;
        return types.parseBoolean(rv.expanded);
    }

    pub fn getPath(self: *const LookupResult, key: []const u8) ?[]const u8 {
        const rv = self.resolved.get(key) orelse return null;
        return rv.expanded;
    }

    pub fn getStringList(self: *const LookupResult, key: []const u8) []const []const u8 {
        const list = self.accumulated.get(key) orelse return &.{};
        return list.items;
    }

    pub fn getStringPairList(self: *const LookupResult, key: []const u8) []const StringPair {
        const list = self.accumulated_pairs.get(key) orelse return &.{};
        return list.items;
    }

    pub fn getUnknowns(self: *const LookupResult) []const ParsedDirective {
        return self.unknowns.items;
    }

    pub fn getStringOr(self: *const LookupResult, key: []const u8, default: []const u8) []const u8 {
        return self.getString(key) orelse default;
    }

    pub fn getIntOr(self: *const LookupResult, key: []const u8, default: i64) i64 {
        return self.getInt(key) orelse default;
    }

    pub fn getBoolOr(self: *const LookupResult, key: []const u8, default: bool) bool {
        return self.getBool(key) orelse default;
    }
};

/// Perform a lookup against the config for the given target.
pub fn lookup(
    allocator: std.mem.Allocator,
    config: *const Config,
    target: []const u8,
    ctx: *const ExpandContext,
) !LookupResult {
    var result = LookupResult.init(allocator);
    errdefer result.deinit();

    for (config.sections) |section| {
        if (!sectionMatches(section, target, ctx, config.matchers)) continue;

        // This section matches — process directives
        for (section.directives) |dir| {
            // Look up directive definition
            const def = findDirectiveDef(config.directive_defs, dir.key);

            // Expand tokens in the value
            const expanded = try expand_mod.expandTokens(
                allocator,
                dir.value,
                config.expanders,
                ctx,
            );

            // Track allocated expanded strings for cleanup
            // Only track if a new string was allocated (pointer differs)
            if (expanded.ptr != dir.value.ptr) {
                try result.expanded_strings.append(allocator, expanded);
            }

            if (def) |d| {
                if (d.accumulate) {
                    // Accumulate: collect values
                    if (d.value_type == .string_pair) {
                        // Parse as string pair and accumulate
                        if (types.parseStringPair(expanded)) |pair| {
                            var list = result.accumulated_pairs.get(dir.key) orelse std.ArrayList(StringPair).empty;
                            try list.append(allocator, pair);
                            try result.accumulated_pairs.put(dir.key, list);
                        }
                    } else {
                        var list = result.accumulated.get(dir.key) orelse std.ArrayList([]const u8).empty;
                        try list.append(allocator, expanded);
                        try result.accumulated.put(dir.key, list);
                    }
                } else {
                    // First-match-wins: only store if not already set
                    if (!result.resolved.contains(dir.key)) {
                        try result.resolved.put(dir.key, .{
                            .raw = dir.value,
                            .expanded = expanded,
                        });
                    }
                }
            } else {
                // Unknown directive — collect it
                try result.unknowns.append(allocator, dir);
            }
        }
    }

    return result;
}

fn findDirectiveDef(
    defs: *const std.StringArrayHashMap(DirectiveDef),
    key: []const u8,
) ?DirectiveDef {
    // Case-insensitive lookup
    for (defs.keys(), defs.values()) |k, v| {
        if (types.asciiEqlIgnoreCase(k, key)) return v;
    }
    return null;
}

fn sectionMatches(
    section: Section,
    target: []const u8,
    ctx: *const ExpandContext,
    matchers: *const std.StringArrayHashMap(*const MatcherFn),
) bool {
    switch (section.kind) {
        .pattern => |patterns| {
            return glob.matchPatternList(patterns, target);
        },
        .conditional => |criteria| {
            // ALL criteria must match (AND logic)
            for (criteria) |criterion| {
                const matcher_fn = matchers.get(criterion.name) orelse continue;
                const matched = matcher_fn(criterion.value, target, ctx);
                const effective = if (criterion.negated) !matched else matched;
                if (!effective) return false;
            }
            return criteria.len > 0;
        },
    }
}

// ---------- Tests ----------

test "lookup - first-match-wins" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.Parser.init(allocator);
    defer parser.deinit();

    try parser.section("Host", .{ .matching = .pattern });
    try parser.directive("Port", .{ .value_type = .integer });

    var config = try parser.parseString(
        \\Host example.com
        \\    Port 2222
        \\
        \\Host *.com
        \\    Port 3333
        \\
        \\Host *
        \\    Port 22
    , "test.conf");
    defer config.deinit();

    var ctx = ExpandContext.init(allocator);
    defer ctx.deinit();

    var result = try lookup(allocator, &config, "example.com", &ctx);
    defer result.deinit();

    // First matching section wins (Port=2222)
    try std.testing.expect(result.getInt("Port").? == 2222);
}

test "lookup - accumulation" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.Parser.init(allocator);
    defer parser.deinit();

    try parser.section("Host", .{ .matching = .pattern });
    try parser.directive("IdentityFile", .{ .value_type = .path, .accumulate = true });

    var config = try parser.parseString(
        \\Host example.com
        \\    IdentityFile ~/.ssh/id_example
        \\
        \\Host *
        \\    IdentityFile ~/.ssh/id_rsa
    , "test.conf");
    defer config.deinit();

    var ctx = ExpandContext.init(allocator);
    defer ctx.deinit();

    var result = try lookup(allocator, &config, "example.com", &ctx);
    defer result.deinit();

    const files = result.getStringList("IdentityFile");
    try std.testing.expect(files.len == 2);
    try std.testing.expectEqualStrings("~/.ssh/id_example", files[0]);
    try std.testing.expectEqualStrings("~/.ssh/id_rsa", files[1]);
}

test "lookup - mixed first-match and accumulate" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.Parser.init(allocator);
    defer parser.deinit();

    try parser.section("Host", .{ .matching = .pattern });
    try parser.directive("Port", .{ .value_type = .integer });
    try parser.directive("IdentityFile", .{ .value_type = .path, .accumulate = true });
    try parser.directive("User", .{ .value_type = .string });

    var config = try parser.parseString(
        \\Host example.com
        \\    Port 2222
        \\    IdentityFile ~/.ssh/id_example
        \\    User admin
        \\
        \\Host *
        \\    Port 22
        \\    IdentityFile ~/.ssh/id_rsa
        \\    User default
    , "test.conf");
    defer config.deinit();

    var ctx = ExpandContext.init(allocator);
    defer ctx.deinit();

    var result = try lookup(allocator, &config, "example.com", &ctx);
    defer result.deinit();

    // First-match-wins
    try std.testing.expect(result.getInt("Port").? == 2222);
    try std.testing.expectEqualStrings("admin", result.getStringOr("User", "nobody"));

    // Accumulated
    const files = result.getStringList("IdentityFile");
    try std.testing.expect(files.len == 2);
}

test "lookup - no match" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.Parser.init(allocator);
    defer parser.deinit();

    try parser.section("Host", .{ .matching = .pattern });
    try parser.directive("Port", .{ .value_type = .integer });

    var config = try parser.parseString(
        \\Host example.com
        \\    Port 2222
    , "test.conf");
    defer config.deinit();

    var ctx = ExpandContext.init(allocator);
    defer ctx.deinit();

    var result = try lookup(allocator, &config, "other.com", &ctx);
    defer result.deinit();

    try std.testing.expect(result.getInt("Port") == null);
}

test "lookup - conditional section" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.Parser.init(allocator);
    defer parser.deinit();

    try parser.section("Match", .{ .matching = .conditional });
    try parser.directive("User", .{ .value_type = .string });

    const host_matcher = struct {
        fn m(criteria_value: []const u8, target: []const u8, _: *const ExpandContext) bool {
            return glob.match(criteria_value, target);
        }
    }.m;
    try parser.matcher("host", host_matcher);

    var config = try parser.parseString(
        \\Match host *.example.com
        \\    User admin
    , "test.conf");
    defer config.deinit();

    var ctx = ExpandContext.init(allocator);
    defer ctx.deinit();

    // Matches
    {
        var result = try lookup(allocator, &config, "web.example.com", &ctx);
        defer result.deinit();
        try std.testing.expectEqualStrings("admin", result.getString("User").?);
    }

    // Does not match
    {
        var result = try lookup(allocator, &config, "other.org", &ctx);
        defer result.deinit();
        try std.testing.expect(result.getString("User") == null);
    }
}

test "lookup - token expansion" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.Parser.init(allocator);
    defer parser.deinit();

    try parser.section("Host", .{ .matching = .pattern });
    try parser.directive("HostName", .{ .value_type = .string });

    const h_expander = struct {
        fn expand(ctx: *const ExpandContext) ?[]const u8 {
            return ctx.get("hostname");
        }
    }.expand;
    parser.expander('h', h_expander);

    var config = try parser.parseString(
        \\Host example
        \\    HostName %h.example.com
    , "test.conf");
    defer config.deinit();

    var ctx = ExpandContext.init(allocator);
    defer ctx.deinit();
    try ctx.put("hostname", "web");

    var result = try lookup(allocator, &config, "example", &ctx);
    defer result.deinit();

    try std.testing.expectEqualStrings("web.example.com", result.getString("HostName").?);
}

test "lookup - typed accessor defaults" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.Parser.init(allocator);
    defer parser.deinit();

    try parser.section("Host", .{ .matching = .pattern });
    try parser.directive("Port", .{ .value_type = .integer });

    var config = try parser.parseString(
        \\Host nothing
        \\    Port 22
    , "test.conf");
    defer config.deinit();

    var ctx = ExpandContext.init(allocator);
    defer ctx.deinit();

    var result = try lookup(allocator, &config, "other", &ctx);
    defer result.deinit();

    // No match — defaults apply
    try std.testing.expect(result.getInt("Port") == null);
    try std.testing.expect(result.getIntOr("Port", 22) == 22);
    try std.testing.expect(result.getBoolOr("Compress", false) == false);
    try std.testing.expectEqualStrings("nobody", result.getStringOr("User", "nobody"));
}

test "lookup - negation in pattern" {
    const allocator = std.testing.allocator;
    var parser = parser_mod.Parser.init(allocator);
    defer parser.deinit();

    try parser.section("Host", .{ .matching = .pattern });
    try parser.directive("Port", .{ .value_type = .integer });

    var config = try parser.parseString(
        \\Host *.com !evil.com
        \\    Port 443
    , "test.conf");
    defer config.deinit();

    var ctx = ExpandContext.init(allocator);
    defer ctx.deinit();

    // Matches
    {
        var result = try lookup(allocator, &config, "good.com", &ctx);
        defer result.deinit();
        try std.testing.expect(result.getInt("Port").? == 443);
    }

    // Negated
    {
        var result = try lookup(allocator, &config, "evil.com", &ctx);
        defer result.deinit();
        try std.testing.expect(result.getInt("Port") == null);
    }
}

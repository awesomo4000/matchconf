const std = @import("std");
const types = @import("types.zig");
const diagnostics_mod = @import("diagnostics.zig");
const line_parser = @import("line_parser.zig");
const glob = @import("glob.zig");

const include = @import("include.zig");

const ValueType = types.ValueType;
const Value = types.Value;
const Diagnostic = diagnostics_mod.Diagnostic;
const DiagnosticList = diagnostics_mod.DiagnosticList;

// ---- Public Types ----

pub const ExpandContext = struct {
    values: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) ExpandContext {
        return .{ .values = std.StringHashMap([]const u8).init(allocator) };
    }

    pub fn deinit(self: *ExpandContext) void {
        self.values.deinit();
    }

    pub fn get(self: *const ExpandContext, key: []const u8) ?[]const u8 {
        return self.values.get(key);
    }

    pub fn put(self: *ExpandContext, key: []const u8, value: []const u8) !void {
        try self.values.put(key, value);
    }
};

pub const ExpanderFn = fn (ctx: *const ExpandContext) ?[]const u8;
pub const MatcherFn = fn (criteria_value: []const u8, target: []const u8, ctx: *const ExpandContext) bool;

pub const MatchingMode = enum {
    /// Host-style: whitespace-separated patterns matched by glob
    pattern,
    /// Match-style: criteria-based conditional matching
    conditional,
};

pub const SectionConfig = struct {
    matching: MatchingMode,
};

pub const DirectiveDef = struct {
    value_type: ValueType,
    default: ?Value = null,
    accumulate: bool = false,
};

pub const SectionKind = union(enum) {
    /// Glob section: patterns are whitespace-separated and matched with glob
    pattern: []const []const u8,
    /// Match section: list of criteria that must all match
    conditional: []const MatchCriteria,
};

pub const MatchCriteria = struct {
    name: []const u8,
    value: []const u8,
    negated: bool,
};

pub const ParsedDirective = struct {
    key: []const u8,
    value: []const u8,
    line: u32,
    file: []const u8,
};

pub const Section = struct {
    kind: SectionKind,
    directives: []const ParsedDirective,
};

// ---- Config (output of parsing) ----

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    sections: []const Section,
    diagnostics_list: DiagnosticList,
    source_buffers: std.ArrayList([]const u8),

    // Schema refs — borrowed from Parser (Parser must outlive Config)
    directive_defs: *const std.StringArrayHashMap(DirectiveDef),
    section_keywords: *const CaseInsensitiveMap(SectionConfig),
    expanders: *const [256]?*const ExpanderFn,
    matchers: *const std.StringArrayHashMap(*const MatcherFn),

    pub fn deinit(self: *Config) void {
        const alloc = self.arena.child_allocator;
        for (self.source_buffers.items) |buf| {
            alloc.free(buf);
        }
        self.source_buffers.deinit(alloc);
        self.diagnostics_list.deinit();
        self.arena.deinit();
    }

    pub fn hasDiagnostics(self: *const Config) bool {
        return self.diagnostics_list.count() > 0;
    }

    pub fn hasErrors(self: *const Config) bool {
        return self.diagnostics_list.hasErrors();
    }

    pub fn diagnosticItems(self: *const Config) []const Diagnostic {
        return self.diagnostics_list.slice();
    }
};

// ---- Case-insensitive key map ----

fn CaseInsensitiveContext(comptime V: type) type {
    _ = V;
    return struct {
        pub fn hash(_: @This(), key: []const u8) u32 {
            var h: u32 = 0;
            for (key) |c| {
                h = h *% 31 +% @as(u32, std.ascii.toLower(c));
            }
            return h;
        }

        pub fn eql(_: @This(), a: []const u8, b: []const u8, _: usize) bool {
            return types.asciiEqlIgnoreCase(a, b);
        }
    };
}

fn CaseInsensitiveMap(comptime V: type) type {
    return std.ArrayHashMap([]const u8, V, CaseInsensitiveContext(V), true);
}

// ---- Parser ----

pub const ParseError = error{
    OutOfMemory,
    FileNotFound,
    ReadError,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,

    // Schema registration
    section_keywords: CaseInsensitiveMap(SectionConfig),
    directive_defs: std.StringArrayHashMap(DirectiveDef),
    expanders: [256]?*const ExpanderFn,
    matchers: std.StringArrayHashMap(*const MatcherFn),

    // For typo detection
    known_keywords_list: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{
            .allocator = allocator,
            .section_keywords = CaseInsensitiveMap(SectionConfig).init(allocator),
            .directive_defs = std.StringArrayHashMap(DirectiveDef).init(allocator),
            .expanders = [_]?*const ExpanderFn{null} ** 256,
            .matchers = std.StringArrayHashMap(*const MatcherFn).init(allocator),
            .known_keywords_list = .empty,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.section_keywords.deinit();
        self.directive_defs.deinit();
        self.matchers.deinit();
        self.known_keywords_list.deinit(self.allocator);
    }

    /// Register a section keyword (e.g., "Host", "Match", "Service").
    pub fn section(self: *Parser, keyword: []const u8, config: SectionConfig) !void {
        try self.section_keywords.put(keyword, config);
        try self.known_keywords_list.append(self.allocator, keyword);
    }

    /// Register a directive definition.
    pub fn directive(self: *Parser, keyword: []const u8, def: DirectiveDef) !void {
        try self.directive_defs.put(keyword, def);
        try self.known_keywords_list.append(self.allocator, keyword);
    }

    /// Register a token expander for a character (e.g., 'h' for %h).
    pub fn expander(self: *Parser, char: u8, func: *const ExpanderFn) void {
        self.expanders[char] = func;
    }

    /// Register a match condition evaluator (e.g., "host", "user", "exec").
    pub fn matcher(self: *Parser, name: []const u8, func: *const MatcherFn) !void {
        try self.matchers.put(name, func);
    }

    /// Parse a string into a Config.
    pub fn parseString(self: *Parser, content: []const u8, source_name: []const u8) !Config {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        var diags = DiagnosticList.init(self.allocator);
        var source_buffers: std.ArrayList([]const u8) = .empty;

        // Keep a copy of the source content alive for zero-copy slicing
        const content_copy = try self.allocator.dupe(u8, content);
        try source_buffers.append(self.allocator, content_copy);

        var sections_list: std.ArrayList(Section) = .empty;
        defer sections_list.deinit(arena_alloc);

        var current_directives: std.ArrayList(ParsedDirective) = .empty;
        defer current_directives.deinit(arena_alloc);
        var current_section_kind: ?SectionKind = null;

        var line_number: u32 = 0;
        var line_iter = std.mem.splitScalar(u8, content_copy, '\n');
        while (line_iter.next()) |line| {
            line_number += 1;
            const token = try line_parser.parseLine(arena_alloc, line, line_number) orelse continue;

            // Check if this keyword starts a new section
            if (self.section_keywords.get(token.keyword)) |sec_config| {
                // Flush previous section
                if (current_section_kind) |kind| {
                    const dirs = try arena_alloc.dupe(ParsedDirective, current_directives.items);
                    try sections_list.append(arena_alloc, Section{
                        .kind = kind,
                        .directives = dirs,
                    });
                    current_directives.clearRetainingCapacity();
                }

                // Parse new section
                current_section_kind = try self.parseSectionValue(
                    arena_alloc,
                    sec_config,
                    token.value.text(),
                    &diags,
                    source_name,
                    line_number,
                    token.keyword_column,
                    line,
                );
            } else if (types.asciiEqlIgnoreCase(token.keyword, "Include")) {
                // Flush current section before processing include
                if (current_section_kind) |kind| {
                    const dirs = try arena_alloc.dupe(ParsedDirective, current_directives.items);
                    try sections_list.append(arena_alloc, Section{
                        .kind = kind,
                        .directives = dirs,
                    });
                    current_directives.clearRetainingCapacity();
                    current_section_kind = null;
                }

                // Process include directive
                var include_stack: std.ArrayList([]const u8) = .empty;
                defer include_stack.deinit(self.allocator);
                try include_stack.append(self.allocator, source_name);

                _ = try include.processInclude(
                    self.allocator,
                    arena_alloc,
                    self,
                    token.value.text(),
                    source_name,
                    &include_stack,
                    &sections_list,
                    &source_buffers,
                    &diags,
                    line_number,
                    line,
                );
            } else {
                // Regular directive
                const dir = ParsedDirective{
                    .key = token.keyword,
                    .value = token.value.text(),
                    .line = line_number,
                    .file = source_name,
                };

                // Validate: check if directive is registered
                if (!self.isKnownDirective(token.keyword)) {
                    const suggestion = self.findDirectiveSuggestion(token.keyword);
                    try diags.append(.{
                        .file = source_name,
                        .line = line_number,
                        .column = token.keyword_column,
                        .level = .warn,
                        .message = "unknown directive",
                        .context = line,
                        .suggestion = suggestion,
                    });
                }

                try current_directives.append(arena_alloc, dir);
            }
        }

        // Flush last section
        if (current_section_kind) |kind| {
            const dirs = try arena_alloc.dupe(ParsedDirective, current_directives.items);
            try sections_list.append(arena_alloc, Section{
                .kind = kind,
                .directives = dirs,
            });
        } else if (current_directives.items.len > 0) {
            // Top-level directives (before any section) — create a wildcard section
            const dirs = try arena_alloc.dupe(ParsedDirective, current_directives.items);
            const wildcard = try arena_alloc.alloc([]const u8, 1);
            wildcard[0] = "*";
            try sections_list.append(arena_alloc, Section{
                .kind = .{ .pattern = wildcard },
                .directives = dirs,
            });
        }

        const sections = try arena_alloc.dupe(Section, sections_list.items);

        return Config{
            .arena = arena,
            .sections = sections,
            .diagnostics_list = diags,
            .source_buffers = source_buffers,
            .directive_defs = &self.directive_defs,
            .section_keywords = &self.section_keywords,
            .expanders = &self.expanders,
            .matchers = &self.matchers,
        };
    }

    /// Parse a file into a Config.
    pub fn parseFile(self: *Parser, path: []const u8) !Config {
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => return error.FileNotFound,
                else => return error.ReadError,
            }
        };
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch {
            return error.ReadError;
        };
        defer self.allocator.free(content);

        return try self.parseString(content, path);
    }

    fn parseSectionValue(
        self: *Parser,
        arena_alloc: std.mem.Allocator,
        sec_config: SectionConfig,
        value: []const u8,
        diags: *DiagnosticList,
        source_name: []const u8,
        line_number: u32,
        column: u32,
        raw_line: []const u8,
    ) !SectionKind {
        switch (sec_config.matching) {
            .pattern => {
                // Split value by whitespace into patterns
                var patterns: std.ArrayList([]const u8) = .empty;
                defer patterns.deinit(arena_alloc);

                var iter = std.mem.tokenizeAny(u8, value, " \t");
                while (iter.next()) |tok| {
                    try patterns.append(arena_alloc, tok);
                }

                if (patterns.items.len == 0) {
                    try diags.append(.{
                        .file = source_name,
                        .line = line_number,
                        .column = column,
                        .level = .err,
                        .message = "section has no patterns",
                        .context = raw_line,
                        .suggestion = null,
                    });
                    // Return a pattern that matches nothing
                    const empty = try arena_alloc.alloc([]const u8, 0);
                    return .{ .pattern = empty };
                }

                return .{ .pattern = try arena_alloc.dupe([]const u8, patterns.items) };
            },
            .conditional => {
                return try self.parseMatchCriteria(arena_alloc, value, diags, source_name, line_number, column, raw_line);
            },
        }
    }

    fn parseMatchCriteria(
        self: *Parser,
        arena_alloc: std.mem.Allocator,
        value: []const u8,
        diags: *DiagnosticList,
        source_name: []const u8,
        line_number: u32,
        column: u32,
        raw_line: []const u8,
    ) !SectionKind {
        _ = column;
        var criteria_list: std.ArrayList(MatchCriteria) = .empty;
        defer criteria_list.deinit(arena_alloc);

        var iter = std.mem.tokenizeAny(u8, value, " \t");
        while (iter.next()) |raw_name| {
            var name = raw_name;
            var negated = false;
            if (name.len > 0 and name[0] == '!') {
                negated = true;
                name = name[1..];
            }

            // Next token is the pattern/value
            const criteria_value = iter.next() orelse {
                try diags.append(.{
                    .file = source_name,
                    .line = line_number,
                    .column = 0,
                    .level = .err,
                    .message = "match criteria missing value",
                    .context = raw_line,
                    .suggestion = null,
                });
                break;
            };

            // Check if matcher is registered
            _ = self.matchers.get(name) orelse {
                try diags.append(.{
                    .file = source_name,
                    .line = line_number,
                    .column = 0,
                    .level = .warn,
                    .message = "unknown match criteria",
                    .context = raw_line,
                    .suggestion = null,
                });
            };

            try criteria_list.append(arena_alloc, MatchCriteria{
                .name = name,
                .value = criteria_value,
                .negated = negated,
            });
        }

        return .{ .conditional = try arena_alloc.dupe(MatchCriteria, criteria_list.items) };
    }

    fn isKnownDirective(self: *const Parser, keyword: []const u8) bool {
        // Check directive_defs (case-insensitive)
        for (self.directive_defs.keys()) |key| {
            if (types.asciiEqlIgnoreCase(key, keyword)) return true;
        }
        return false;
    }

    fn findDirectiveSuggestion(self: *const Parser, keyword: []const u8) ?[]const u8 {
        return diagnostics_mod.findClosestMatch(
            keyword,
            self.known_keywords_list.items,
            2,
        );
    }
};

// ---------- Tests ----------

test "Parser - basic section parsing" {
    const allocator = std.testing.allocator;

    var parser = Parser.init(allocator);
    defer parser.deinit();

    try parser.section("Host", .{ .matching = .pattern });
    try parser.directive("HostName", .{ .value_type = .string });
    try parser.directive("Port", .{ .value_type = .integer });
    try parser.directive("User", .{ .value_type = .string });

    var config = try parser.parseString(
        \\Host example.com
        \\    HostName 192.168.1.1
        \\    Port 22
        \\    User admin
        \\
        \\Host *.dev
        \\    User developer
    , "test.conf");
    defer config.deinit();

    try std.testing.expect(config.sections.len == 2);

    // First section
    try std.testing.expect(config.sections[0].directives.len == 3);
    try std.testing.expectEqualStrings("HostName", config.sections[0].directives[0].key);
    try std.testing.expectEqualStrings("192.168.1.1", config.sections[0].directives[0].value);

    // Second section
    try std.testing.expect(config.sections[1].directives.len == 1);
    try std.testing.expectEqualStrings("User", config.sections[1].directives[0].key);
    try std.testing.expectEqualStrings("developer", config.sections[1].directives[0].value);
}

test "Parser - pattern section patterns" {
    const allocator = std.testing.allocator;

    var parser = Parser.init(allocator);
    defer parser.deinit();

    try parser.section("Host", .{ .matching = .pattern });
    try parser.directive("User", .{ .value_type = .string });

    var config = try parser.parseString(
        \\Host example.com *.dev !evil.org
        \\    User admin
    , "test.conf");
    defer config.deinit();

    try std.testing.expect(config.sections.len == 1);
    switch (config.sections[0].kind) {
        .pattern => |patterns| {
            try std.testing.expect(patterns.len == 3);
            try std.testing.expectEqualStrings("example.com", patterns[0]);
            try std.testing.expectEqualStrings("*.dev", patterns[1]);
            try std.testing.expectEqualStrings("!evil.org", patterns[2]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "Parser - unknown directive warning" {
    const allocator = std.testing.allocator;

    var parser = Parser.init(allocator);
    defer parser.deinit();

    try parser.section("Host", .{ .matching = .pattern });
    try parser.directive("HostName", .{ .value_type = .string });

    var config = try parser.parseString(
        \\Host example.com
        \\    HosName 192.168.1.1
    , "test.conf");
    defer config.deinit();

    try std.testing.expect(config.hasDiagnostics());
    const diags = config.diagnosticItems();
    try std.testing.expect(diags.len == 1);
    try std.testing.expect(diags[0].level == .warn);
    try std.testing.expectEqualStrings("unknown directive", diags[0].message);
    // Should suggest "HostName"
    try std.testing.expect(diags[0].suggestion != null);
    try std.testing.expectEqualStrings("HostName", diags[0].suggestion.?);
}

test "Parser - conditional section (Match)" {
    const allocator = std.testing.allocator;

    var parser = Parser.init(allocator);
    defer parser.deinit();

    try parser.section("Match", .{ .matching = .conditional });
    try parser.directive("User", .{ .value_type = .string });

    const dummy_matcher = struct {
        fn m(_: []const u8, _: []const u8, _: *const ExpandContext) bool {
            return true;
        }
    }.m;
    try parser.matcher("host", dummy_matcher);

    var config = try parser.parseString(
        \\Match host *.example.com
        \\    User admin
    , "test.conf");
    defer config.deinit();

    try std.testing.expect(config.sections.len == 1);
    switch (config.sections[0].kind) {
        .conditional => |criteria| {
            try std.testing.expect(criteria.len == 1);
            try std.testing.expectEqualStrings("host", criteria[0].name);
            try std.testing.expectEqualStrings("*.example.com", criteria[0].value);
            try std.testing.expect(!criteria[0].negated);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "Parser - top-level directives become wildcard section" {
    const allocator = std.testing.allocator;

    var parser = Parser.init(allocator);
    defer parser.deinit();

    try parser.directive("GlobalOption", .{ .value_type = .string });

    var config = try parser.parseString(
        \\GlobalOption somevalue
    , "test.conf");
    defer config.deinit();

    try std.testing.expect(config.sections.len == 1);
    switch (config.sections[0].kind) {
        .pattern => |patterns| {
            try std.testing.expect(patterns.len == 1);
            try std.testing.expectEqualStrings("*", patterns[0]);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("somevalue", config.sections[0].directives[0].value);
}

test "Parser - multiple sections" {
    const allocator = std.testing.allocator;

    var parser = Parser.init(allocator);
    defer parser.deinit();

    try parser.section("Host", .{ .matching = .pattern });
    try parser.directive("Port", .{ .value_type = .integer });
    try parser.directive("User", .{ .value_type = .string });

    var config = try parser.parseString(
        \\Host alpha.com
        \\    Port 22
        \\
        \\Host beta.com
        \\    Port 2222
        \\    User beta
        \\
        \\Host *
        \\    Port 22
        \\    User default
    , "test.conf");
    defer config.deinit();

    try std.testing.expect(config.sections.len == 3);
    try std.testing.expect(config.sections[0].directives.len == 1);
    try std.testing.expect(config.sections[1].directives.len == 2);
    try std.testing.expect(config.sections[2].directives.len == 2);
}

test "Parser - empty config" {
    const allocator = std.testing.allocator;

    var parser = Parser.init(allocator);
    defer parser.deinit();

    var config = try parser.parseString("", "test.conf");
    defer config.deinit();

    try std.testing.expect(config.sections.len == 0);
    try std.testing.expect(!config.hasDiagnostics());
}

test "Parser - comments and blank lines only" {
    const allocator = std.testing.allocator;

    var parser = Parser.init(allocator);
    defer parser.deinit();

    var config = try parser.parseString(
        \\# Comment
        \\
        \\# Another comment
    , "test.conf");
    defer config.deinit();

    try std.testing.expect(config.sections.len == 0);
}

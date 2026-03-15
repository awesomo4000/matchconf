const std = @import("std");

/// Diagnostic severity level.
pub const Level = enum { err, warn };

/// A single diagnostic message with source location information.
pub const Diagnostic = struct {
    file: []const u8,
    line: u32,
    column: u32,
    level: Level,
    message: []const u8,
    context: []const u8,
    suggestion: ?[]const u8,

    /// Format the diagnostic for display.
    pub fn format(self: *const Diagnostic, allocator: std.mem.Allocator) ![]const u8 {
        const level_str = switch (self.level) {
            .err => "error",
            .warn => "warning",
        };
        const suggestion_part = if (self.suggestion) |s|
            try std.fmt.allocPrint(allocator, " (did you mean '{s}'?)", .{s})
        else
            try allocator.dupe(u8, "");
        defer allocator.free(suggestion_part);

        return try std.fmt.allocPrint(
            allocator,
            "{s}:{d}:{d}: {s}: {s}{s}",
            .{ self.file, self.line, self.column, level_str, self.message, suggestion_part },
        );
    }
};

/// A collection of diagnostics accumulated during parsing.
pub const DiagnosticList = struct {
    items: std.ArrayList(Diagnostic) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DiagnosticList {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DiagnosticList) void {
        self.items.deinit(self.allocator);
    }

    pub fn append(self: *DiagnosticList, diag: Diagnostic) !void {
        try self.items.append(self.allocator, diag);
    }

    pub fn hasErrors(self: *const DiagnosticList) bool {
        for (self.items.items) |item| {
            if (item.level == .err) return true;
        }
        return false;
    }

    pub fn hasWarnings(self: *const DiagnosticList) bool {
        for (self.items.items) |item| {
            if (item.level == .warn) return true;
        }
        return false;
    }

    pub fn slice(self: *const DiagnosticList) []const Diagnostic {
        return self.items.items;
    }

    pub fn count(self: *const DiagnosticList) usize {
        return self.items.items.len;
    }
};

/// Compute the Levenshtein edit distance between two strings.
/// Uses single-row DP: O(min(m,n)) space.
pub fn editDistance(a: []const u8, b: []const u8) usize {
    // Ensure a is the shorter string for O(min(m,n)) space
    const short = if (a.len <= b.len) a else b;
    const long = if (a.len <= b.len) b else a;

    // Allocate the work row on the stack if small enough, otherwise use a fixed buffer
    var buf: [256]usize = undefined;
    if (short.len + 1 > buf.len) {
        // Fallback: if strings are very long, just report max
        return @max(a.len, b.len);
    }
    const row = buf[0 .. short.len + 1];

    // Initialize: row[j] = j (cost of inserting j chars)
    for (row, 0..) |*cell, j| {
        cell.* = j;
    }

    for (long, 0..) |lc, i| {
        _ = i;
        var prev = row[0];
        row[0] += 1;

        for (short, 0..) |sc, j| {
            const cost: usize = if (lc == sc) 0 else 1;
            const del = row[j + 1] + 1;
            const ins = row[j] + 1;
            const sub = prev + cost;
            prev = row[j + 1];
            row[j + 1] = @min(del, @min(ins, sub));
        }
    }

    return row[short.len];
}

/// Find the closest match for `needle` in `haystack` within `max_distance`.
/// Returns null if no match is close enough.
/// Threshold: distance <= max_distance AND distance < needle.len / 2
pub fn findClosestMatch(needle: []const u8, haystack: []const []const u8, max_distance: usize) ?[]const u8 {
    if (needle.len == 0) return null;

    var best: ?[]const u8 = null;
    var best_dist: usize = max_distance + 1;
    const half_len = needle.len / 2;

    for (haystack) |candidate| {
        const dist = editDistance(needle, candidate);
        if (dist <= max_distance and dist < half_len and dist < best_dist) {
            best_dist = dist;
            best = candidate;
        }
    }

    return best;
}

// ---------- Tests ----------

test "editDistance - identical strings" {
    try std.testing.expect(editDistance("abc", "abc") == 0);
}

test "editDistance - empty strings" {
    try std.testing.expect(editDistance("", "") == 0);
    try std.testing.expect(editDistance("abc", "") == 3);
    try std.testing.expect(editDistance("", "abc") == 3);
}

test "editDistance - single edit" {
    try std.testing.expect(editDistance("abc", "ab") == 1); // deletion
    try std.testing.expect(editDistance("abc", "abcd") == 1); // insertion
    try std.testing.expect(editDistance("abc", "axc") == 1); // substitution
}

test "editDistance - multiple edits" {
    try std.testing.expect(editDistance("kitten", "sitting") == 3);
    try std.testing.expect(editDistance("saturday", "sunday") == 3);
}

test "editDistance - transposition" {
    try std.testing.expect(editDistance("ab", "ba") == 2); // Levenshtein, not Damerau
}

test "findClosestMatch" {
    const haystack = [_][]const u8{ "HostName", "Port", "User", "IdentityFile", "ForwardAgent" };

    // Close typo
    try std.testing.expectEqualStrings("HostName", findClosestMatch("HosName", &haystack, 2).?);

    // Too far
    try std.testing.expect(findClosestMatch("xyz", &haystack, 2) == null);

    // Exact match still returned (distance 0 < half_len)
    try std.testing.expectEqualStrings("Port", findClosestMatch("Port", &haystack, 2).?);
}

test "findClosestMatch - exact is returned when within threshold" {
    const haystack = [_][]const u8{ "HostName", "Port", "User" };
    const result = findClosestMatch("Port", &haystack, 2);
    try std.testing.expectEqualStrings("Port", result.?);
}

test "findClosestMatch - short strings not suggested" {
    const haystack = [_][]const u8{ "ab", "cd" };
    // "ab" with distance 1 to "ac" but half_len = 1, so 1 < 1 is false -> null
    try std.testing.expect(findClosestMatch("ac", &haystack, 2) == null);
}

test "DiagnosticList - basic operations" {
    const allocator = std.testing.allocator;
    var list = DiagnosticList.init(allocator);
    defer list.deinit();

    try list.append(.{
        .file = "test.conf",
        .line = 1,
        .column = 1,
        .level = .warn,
        .message = "unknown directive",
        .context = "Foobar value",
        .suggestion = "FooBar",
    });

    try list.append(.{
        .file = "test.conf",
        .line = 5,
        .column = 3,
        .level = .err,
        .message = "type mismatch",
        .context = "Port abc",
        .suggestion = null,
    });

    try std.testing.expect(list.count() == 2);
    try std.testing.expect(list.hasErrors());
    try std.testing.expect(list.hasWarnings());
}

test "Diagnostic format" {
    const allocator = std.testing.allocator;
    const diag = Diagnostic{
        .file = "test.conf",
        .line = 10,
        .column = 3,
        .level = .warn,
        .message = "unknown directive",
        .context = "Foobar value",
        .suggestion = "FooBar",
    };

    const formatted = try diag.format(allocator);
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings(
        "test.conf:10:3: warning: unknown directive (did you mean 'FooBar'?)",
        formatted,
    );
}

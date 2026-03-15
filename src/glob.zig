const std = @import("std");

/// Match a glob pattern against text using iterative two-pointer approach.
/// Supports `*` (zero or more chars) and `?` (exactly one char).
/// O(n*m) worst case, O(n) typical.
pub fn match(pattern: []const u8, text: []const u8) bool {
    var px: usize = 0; // pattern index
    var tx: usize = 0; // text index
    var star_px: usize = 0;
    var star_tx: usize = 0;
    var have_star = false;

    while (tx < text.len) {
        if (px < pattern.len and (pattern[px] == '?' or pattern[px] == text[tx])) {
            // Character match or ? wildcard
            px += 1;
            tx += 1;
        } else if (px < pattern.len and pattern[px] == '*') {
            // Star wildcard: record position, try zero-width match first
            have_star = true;
            star_px = px;
            star_tx = tx;
            px += 1; // try matching * with zero characters
        } else if (have_star) {
            // Backtrack: star matches one more character
            px = star_px + 1;
            star_tx += 1;
            tx = star_tx;
        } else {
            return false;
        }
    }

    // Consume any remaining stars in pattern
    while (px < pattern.len and pattern[px] == '*') {
        px += 1;
    }

    return px == pattern.len;
}

/// Evaluate whitespace-separated patterns (Host-style) against text.
/// Negation: patterns starting with `!` are negation patterns.
/// Rules:
/// - If ANY negated pattern matches → false
/// - If no positive patterns exist → false
/// - If ANY positive pattern matches AND no negation matches → true
pub fn matchPatternList(patterns: []const []const u8, text: []const u8) bool {
    var has_positive = false;
    var any_positive_match = false;

    for (patterns) |raw_pattern| {
        if (raw_pattern.len == 0) continue;

        if (raw_pattern[0] == '!') {
            // Negation pattern
            const neg_pattern = raw_pattern[1..];
            if (match(neg_pattern, text)) {
                return false; // Negation matched → reject
            }
        } else {
            has_positive = true;
            if (match(raw_pattern, text)) {
                any_positive_match = true;
            }
        }
    }

    return has_positive and any_positive_match;
}

/// Evaluate comma-separated pattern list (Match-style) against text.
/// Splits on commas, trims whitespace, then applies same rules as matchPatternList.
pub fn matchCommaSeparatedList(pattern_list: []const u8, text: []const u8) bool {
    var buf: [64][]const u8 = undefined;
    var count: usize = 0;

    var iter = std.mem.splitScalar(u8, pattern_list, ',');
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        if (count >= buf.len) break; // Safety limit
        buf[count] = trimmed;
        count += 1;
    }

    return matchPatternList(buf[0..count], text);
}

/// Split a pattern string by whitespace into individual patterns.
/// Caller owns returned slice (allocated from provided allocator).
pub fn splitPatterns(allocator: std.mem.Allocator, pattern_str: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);

    var iter = std.mem.tokenizeAny(u8, pattern_str, " \t");
    while (iter.next()) |tok| {
        try list.append(allocator, tok);
    }

    return try list.toOwnedSlice(allocator);
}

// ---------- Tests ----------

test "match - exact" {
    try std.testing.expect(match("hello", "hello"));
    try std.testing.expect(!match("hello", "world"));
}

test "match - star wildcard" {
    try std.testing.expect(match("*", "anything"));
    try std.testing.expect(match("*", ""));
    try std.testing.expect(match("foo*", "foobar"));
    try std.testing.expect(match("*bar", "foobar"));
    try std.testing.expect(match("foo*bar", "fooXYZbar"));
    try std.testing.expect(match("foo*bar", "foobar")); // * matches zero chars
    try std.testing.expect(!match("foo*bar", "foobaz"));
}

test "match - question mark" {
    try std.testing.expect(match("?", "a"));
    try std.testing.expect(!match("?", ""));
    try std.testing.expect(!match("?", "ab"));
    try std.testing.expect(match("f?o", "foo"));
    try std.testing.expect(match("f?o", "fao"));
    try std.testing.expect(!match("f?o", "fo"));
}

test "match - combined wildcards" {
    try std.testing.expect(match("*.example.com", "web.example.com"));
    try std.testing.expect(match("*.example.com", ".example.com"));
    try std.testing.expect(!match("*.example.com", "example.com"));
    try std.testing.expect(match("192.168.?.*", "192.168.1.100"));
    try std.testing.expect(!match("192.168.?.*", "192.168.10.100"));
}

test "match - multiple stars" {
    try std.testing.expect(match("**", "anything"));
    try std.testing.expect(match("*foo*", "foo"));
    try std.testing.expect(match("*foo*", "xfooy"));
    try std.testing.expect(match("*foo*bar*", "xfooybar"));
    try std.testing.expect(match("*foo*bar*", "foobarbaz"));
}

test "match - empty patterns" {
    try std.testing.expect(match("", ""));
    try std.testing.expect(!match("", "a"));
}

test "matchPatternList - basic" {
    const patterns = [_][]const u8{ "*.example.com", "192.168.*" };
    try std.testing.expect(matchPatternList(&patterns, "web.example.com"));
    try std.testing.expect(matchPatternList(&patterns, "192.168.1.1"));
    try std.testing.expect(!matchPatternList(&patterns, "evil.org"));
}

test "matchPatternList - negation" {
    const patterns = [_][]const u8{ "*.example.com", "!bad.example.com" };
    try std.testing.expect(matchPatternList(&patterns, "good.example.com"));
    try std.testing.expect(!matchPatternList(&patterns, "bad.example.com"));
}

test "matchPatternList - negation only" {
    const patterns = [_][]const u8{"!bad.example.com"};
    // No positive patterns → always false
    try std.testing.expect(!matchPatternList(&patterns, "anything.com"));
}

test "matchPatternList - empty" {
    const patterns = [_][]const u8{};
    try std.testing.expect(!matchPatternList(&patterns, "anything"));
}

test "matchCommaSeparatedList" {
    try std.testing.expect(matchCommaSeparatedList("*.example.com, 192.168.*", "web.example.com"));
    try std.testing.expect(matchCommaSeparatedList("*.example.com, 192.168.*", "192.168.1.1"));
    try std.testing.expect(!matchCommaSeparatedList("*.example.com, 192.168.*", "evil.org"));
}

test "matchCommaSeparatedList - negation" {
    try std.testing.expect(!matchCommaSeparatedList("*.example.com, !bad.example.com", "bad.example.com"));
    try std.testing.expect(matchCommaSeparatedList("*.example.com, !bad.example.com", "good.example.com"));
}

test "splitPatterns" {
    const allocator = std.testing.allocator;
    const patterns = try splitPatterns(allocator, "*.example.com  192.168.* !evil.org");
    defer allocator.free(patterns);

    try std.testing.expect(patterns.len == 3);
    try std.testing.expectEqualStrings("*.example.com", patterns[0]);
    try std.testing.expectEqualStrings("192.168.*", patterns[1]);
    try std.testing.expectEqualStrings("!evil.org", patterns[2]);
}

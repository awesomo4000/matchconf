const std = @import("std");

/// Result of parsing a single line.
pub const Token = struct {
    keyword: []const u8,
    value: ParsedValue,
    raw_line: []const u8,
    line_number: u32,
    keyword_column: u32,
    value_column: u32,
};

/// A parsed value that is either borrowed (zero-copy slice) or owned (allocated).
pub const ParsedValue = union(enum) {
    borrowed: []const u8,
    owned: []const u8,

    pub fn text(self: ParsedValue) []const u8 {
        return switch (self) {
            .borrowed => |s| s,
            .owned => |s| s,
        };
    }
};

/// Parse a single line into keyword + value.
/// Returns null for comments and blank lines.
pub fn parseLine(allocator: std.mem.Allocator, line: []const u8, line_number: u32) !?Token {
    var pos: u32 = 0;

    // 1. Strip leading whitespace (track column offset)
    while (pos < line.len and isWhitespace(line[pos])) : (pos += 1) {}
    if (pos >= line.len) return null; // blank line
    if (line[pos] == '#') return null; // comment

    // 2. Extract keyword: read until whitespace or '='
    const keyword_start = pos;
    while (pos < line.len and !isWhitespace(line[pos]) and line[pos] != '=') : (pos += 1) {}
    const keyword = line[keyword_start..pos];
    if (keyword.len == 0) return null;

    // 3. Skip separator: whitespace and/or single '='
    while (pos < line.len and isWhitespace(line[pos])) : (pos += 1) {}
    if (pos < line.len and line[pos] == '=') {
        pos += 1;
        while (pos < line.len and isWhitespace(line[pos])) : (pos += 1) {}
    }

    // 4. Extract value
    const value_start = pos;
    if (pos >= line.len) {
        // Keyword with no value
        return Token{
            .keyword = keyword,
            .value = .{ .borrowed = "" },
            .raw_line = line,
            .line_number = line_number,
            .keyword_column = keyword_start,
            .value_column = value_start,
        };
    }

    if (line[pos] == '"') {
        // Quoted string — may need to handle escape sequences
        const parsed = try parseQuotedString(allocator, line[pos..]);
        return Token{
            .keyword = keyword,
            .value = parsed,
            .raw_line = line,
            .line_number = line_number,
            .keyword_column = keyword_start,
            .value_column = value_start,
        };
    }

    // Unquoted value — read to end, trim trailing whitespace
    const raw_value = std.mem.trimRight(u8, line[pos..], " \t\r\n");
    // Strip inline comment (only if preceded by whitespace)
    const value = trimInlineComment(raw_value);

    return Token{
        .keyword = keyword,
        .value = .{ .borrowed = value },
        .raw_line = line,
        .line_number = line_number,
        .keyword_column = keyword_start,
        .value_column = value_start,
    };
}

/// Trim inline comments. Looks for '#' preceded by whitespace.
fn trimInlineComment(value: []const u8) []const u8 {
    // Don't trim # inside values. Only trim if there's whitespace before the #.
    // This is a heuristic — some config formats don't support inline comments.
    // For ssh_config compatibility, we do NOT strip inline comments.
    return value;
}

/// Parse a quoted string with escape handling.
/// Returns borrowed if no escapes; owned if escapes were processed.
fn parseQuotedString(allocator: std.mem.Allocator, input: []const u8) !ParsedValue {
    if (input.len == 0 or input[0] != '"') return .{ .borrowed = input };

    var pos: usize = 1;
    var has_escapes = false;

    // First pass: check if we need to allocate
    while (pos < input.len) {
        if (input[pos] == '\\' and pos + 1 < input.len) {
            has_escapes = true;
            pos += 2;
        } else if (input[pos] == '"') {
            break;
        } else {
            pos += 1;
        }
    }

    const end = pos;

    if (!has_escapes) {
        // Zero-copy: return slice between quotes
        return .{ .borrowed = input[1..end] };
    }

    // Second pass: build unescaped string
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    pos = 1;
    while (pos < end) {
        if (input[pos] == '\\' and pos + 1 < end) {
            const next = input[pos + 1];
            switch (next) {
                '"' => try buf.append(allocator, '"'),
                '\\' => try buf.append(allocator, '\\'),
                'n' => try buf.append(allocator, '\n'),
                't' => try buf.append(allocator, '\t'),
                else => {
                    try buf.append(allocator, '\\');
                    try buf.append(allocator, next);
                },
            }
            pos += 2;
        } else {
            try buf.append(allocator, input[pos]);
            pos += 1;
        }
    }

    return .{ .owned = try buf.toOwnedSlice(allocator) };
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

// ---------- Tests ----------

test "parseLine - simple key value" {
    const allocator = std.testing.allocator;
    const tok = (try parseLine(allocator, "HostName example.com", 1)).?;
    try std.testing.expectEqualStrings("HostName", tok.keyword);
    try std.testing.expectEqualStrings("example.com", tok.value.text());
    try std.testing.expect(tok.keyword_column == 0);
}

test "parseLine - key=value" {
    const allocator = std.testing.allocator;
    const tok = (try parseLine(allocator, "Port=22", 2)).?;
    try std.testing.expectEqualStrings("Port", tok.keyword);
    try std.testing.expectEqualStrings("22", tok.value.text());
}

test "parseLine - key = value with spaces" {
    const allocator = std.testing.allocator;
    const tok = (try parseLine(allocator, "Port = 22", 2)).?;
    try std.testing.expectEqualStrings("Port", tok.keyword);
    try std.testing.expectEqualStrings("22", tok.value.text());
}

test "parseLine - indented" {
    const allocator = std.testing.allocator;
    const tok = (try parseLine(allocator, "    HostName example.com", 3)).?;
    try std.testing.expectEqualStrings("HostName", tok.keyword);
    try std.testing.expectEqualStrings("example.com", tok.value.text());
    try std.testing.expect(tok.keyword_column == 4);
}

test "parseLine - comment" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try parseLine(allocator, "# this is a comment", 1) == null);
    try std.testing.expect(try parseLine(allocator, "  # indented comment", 2) == null);
}

test "parseLine - blank line" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try parseLine(allocator, "", 1) == null);
    try std.testing.expect(try parseLine(allocator, "   ", 2) == null);
    try std.testing.expect(try parseLine(allocator, "\t", 3) == null);
}

test "parseLine - quoted value (no escapes)" {
    const allocator = std.testing.allocator;
    const tok = (try parseLine(allocator, "HostName \"example.com\"", 1)).?;
    try std.testing.expectEqualStrings("HostName", tok.keyword);
    try std.testing.expectEqualStrings("example.com", tok.value.text());
}

test "parseLine - quoted value with escapes" {
    const allocator = std.testing.allocator;
    const tok = (try parseLine(allocator, "Command \"echo \\\"hello\\\"\"", 1)).?;
    defer {
        switch (tok.value) {
            .owned => |o| allocator.free(o),
            .borrowed => {},
        }
    }
    try std.testing.expectEqualStrings("Command", tok.keyword);
    try std.testing.expectEqualStrings("echo \"hello\"", tok.value.text());
}

test "parseLine - value with trailing whitespace" {
    const allocator = std.testing.allocator;
    const tok = (try parseLine(allocator, "Port 22   ", 1)).?;
    try std.testing.expectEqualStrings("22", tok.value.text());
}

test "parseLine - keyword with no value" {
    const allocator = std.testing.allocator;
    const tok = (try parseLine(allocator, "Keyword", 1)).?;
    try std.testing.expectEqualStrings("Keyword", tok.keyword);
    try std.testing.expectEqualStrings("", tok.value.text());
}

const std = @import("std");

/// Describes the expected type of a directive value.
pub const ValueType = union(enum) {
    string,
    integer,
    boolean,
    path,
    string_list,
    string_pair,
    one_of: []const []const u8,
};

/// A parsed and coerced directive value.
pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    boolean: bool,
    path: []const u8,
    string_list: []const []const u8,
    string_pair: StringPair,
    one_of: []const u8,
};

pub const StringPair = struct {
    first: []const u8,
    second: []const u8,
};

/// Parse a boolean from text. Accepts (case-insensitive): yes/no, true/false, on/off.
pub fn parseBoolean(text: []const u8) ?bool {
    const lower = asciiLowerBounded(text) orelse return null;
    const s = lower.slice();

    if (std.mem.eql(u8, s, "yes") or std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "on")) {
        return true;
    }
    if (std.mem.eql(u8, s, "no") or std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "off")) {
        return false;
    }
    return null;
}

/// Parse an integer from text.
pub fn parseInteger(text: []const u8) ?i64 {
    return std.fmt.parseInt(i64, text, 10) catch return null;
}

/// Expand a leading `~` to the user's home directory.
pub fn expandTilde(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (text.len == 0) return try allocator.dupe(u8, text);
    if (text[0] != '~') return try allocator.dupe(u8, text);

    const home = getHomeDir() orelse return try allocator.dupe(u8, text);
    const rest = if (text.len > 1) text[1..] else "";
    const result = try allocator.alloc(u8, home.len + rest.len);
    @memcpy(result[0..home.len], home);
    @memcpy(result[home.len..], rest);
    return result;
}

/// Split text on first whitespace into a pair.
pub fn parseStringPair(text: []const u8) ?StringPair {
    // Find the end of the first token
    var i: usize = 0;
    while (i < text.len and !isWhitespace(text[i])) : (i += 1) {}
    if (i == 0 or i == text.len) return null;

    const first = text[0..i];

    // Skip whitespace
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    if (i == text.len) return null;

    const second = std.mem.trimRight(u8, text[i..], " \t\r\n");
    if (second.len == 0) return null;

    return StringPair{ .first = first, .second = second };
}

/// Coerce a raw string value into a typed Value based on the expected ValueType.
pub fn coerce(allocator: std.mem.Allocator, raw: []const u8, value_type: ValueType) !?Value {
    switch (value_type) {
        .string => return Value{ .string = raw },
        .integer => {
            const v = parseInteger(raw) orelse return null;
            return Value{ .integer = v };
        },
        .boolean => {
            const v = parseBoolean(raw) orelse return null;
            return Value{ .boolean = v };
        },
        .path => {
            const expanded = try expandTilde(allocator, raw);
            return Value{ .path = expanded };
        },
        .string_list => {
            var list: std.ArrayList([]const u8) = .empty;
            errdefer list.deinit(allocator);
            var iter = std.mem.tokenizeAny(u8, raw, " \t");
            while (iter.next()) |tok| {
                try list.append(allocator, tok);
            }
            return Value{ .string_list = try list.toOwnedSlice(allocator) };
        },
        .string_pair => {
            const pair = parseStringPair(raw) orelse return null;
            return Value{ .string_pair = pair };
        },
        .one_of => |allowed| {
            for (allowed) |candidate| {
                if (asciiEqlIgnoreCase(raw, candidate)) {
                    return Value{ .one_of = candidate };
                }
            }
            return null;
        },
    }
}

// ---------- Helpers ----------

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn getHomeDir() ?[]const u8 {
    return std.posix.getenv("HOME");
}

/// Case-insensitive equality check for ASCII strings.
pub fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (std.ascii.toLower(ac) != std.ascii.toLower(bc)) return false;
    }
    return true;
}

/// Stack-allocated buffer for lowercasing short strings (max 64 bytes).
const AsciiLowerBuf = struct {
    buf: [64]u8,
    len: usize,

    pub fn slice(self: *const AsciiLowerBuf) []const u8 {
        return self.buf[0..self.len];
    }
};

fn asciiLowerBounded(text: []const u8) ?AsciiLowerBuf {
    if (text.len > 64) return null;
    var result = AsciiLowerBuf{ .buf = undefined, .len = text.len };
    for (text, 0..) |c, i| {
        result.buf[i] = std.ascii.toLower(c);
    }
    return result;
}

// ---------- Tests ----------

test "parseBoolean" {
    // Truthy values
    try std.testing.expect(parseBoolean("yes").? == true);
    try std.testing.expect(parseBoolean("Yes").? == true);
    try std.testing.expect(parseBoolean("YES").? == true);
    try std.testing.expect(parseBoolean("true").? == true);
    try std.testing.expect(parseBoolean("True").? == true);
    try std.testing.expect(parseBoolean("TRUE").? == true);
    try std.testing.expect(parseBoolean("on").? == true);
    try std.testing.expect(parseBoolean("ON").? == true);

    // Falsy values
    try std.testing.expect(parseBoolean("no").? == false);
    try std.testing.expect(parseBoolean("No").? == false);
    try std.testing.expect(parseBoolean("NO").? == false);
    try std.testing.expect(parseBoolean("false").? == false);
    try std.testing.expect(parseBoolean("False").? == false);
    try std.testing.expect(parseBoolean("off").? == false);
    try std.testing.expect(parseBoolean("OFF").? == false);

    // Invalid
    try std.testing.expect(parseBoolean("maybe") == null);
    try std.testing.expect(parseBoolean("1") == null);
    try std.testing.expect(parseBoolean("0") == null);
    try std.testing.expect(parseBoolean("") == null);
}

test "parseInteger" {
    try std.testing.expect(parseInteger("42").? == 42);
    try std.testing.expect(parseInteger("-1").? == -1);
    try std.testing.expect(parseInteger("0").? == 0);
    try std.testing.expect(parseInteger("99999").? == 99999);
    try std.testing.expect(parseInteger("abc") == null);
    try std.testing.expect(parseInteger("") == null);
    try std.testing.expect(parseInteger("12.34") == null);
}

test "expandTilde" {
    const allocator = std.testing.allocator;

    // No tilde
    {
        const result = try expandTilde(allocator, "/absolute/path");
        defer allocator.free(result);
        try std.testing.expectEqualStrings("/absolute/path", result);
    }

    // Tilde with path
    {
        const result = try expandTilde(allocator, "~/.ssh/config");
        defer allocator.free(result);
        // Should not start with ~ anymore (unless HOME is not set)
        if (getHomeDir()) |home| {
            try std.testing.expect(std.mem.startsWith(u8, result, home));
            try std.testing.expect(std.mem.endsWith(u8, result, "/.ssh/config"));
        }
    }

    // Just tilde
    {
        const result = try expandTilde(allocator, "~");
        defer allocator.free(result);
        if (getHomeDir()) |home| {
            try std.testing.expectEqualStrings(home, result);
        }
    }

    // Empty string
    {
        const result = try expandTilde(allocator, "");
        defer allocator.free(result);
        try std.testing.expectEqualStrings("", result);
    }
}

test "parseStringPair" {
    // Basic pair
    {
        const pair = parseStringPair("key value").?;
        try std.testing.expectEqualStrings("key", pair.first);
        try std.testing.expectEqualStrings("value", pair.second);
    }

    // Multiple spaces
    {
        const pair = parseStringPair("key   value").?;
        try std.testing.expectEqualStrings("key", pair.first);
        try std.testing.expectEqualStrings("value", pair.second);
    }

    // Tab separated
    {
        const pair = parseStringPair("key\tvalue").?;
        try std.testing.expectEqualStrings("key", pair.first);
        try std.testing.expectEqualStrings("value", pair.second);
    }

    // Value with spaces
    {
        const pair = parseStringPair("key value with spaces").?;
        try std.testing.expectEqualStrings("key", pair.first);
        try std.testing.expectEqualStrings("value with spaces", pair.second);
    }

    // No second value
    try std.testing.expect(parseStringPair("justkey") == null);

    // No first value
    try std.testing.expect(parseStringPair("") == null);

    // Only whitespace after key
    try std.testing.expect(parseStringPair("key   ") == null);
}

test "coerce string" {
    const allocator = std.testing.allocator;
    const result = (try coerce(allocator, "hello", .string)).?;
    try std.testing.expectEqualStrings("hello", result.string);
}

test "coerce integer" {
    const allocator = std.testing.allocator;
    const result = (try coerce(allocator, "42", .integer)).?;
    try std.testing.expect(result.integer == 42);

    const bad = try coerce(allocator, "abc", .integer);
    try std.testing.expect(bad == null);
}

test "coerce boolean" {
    const allocator = std.testing.allocator;
    const result = (try coerce(allocator, "yes", .boolean)).?;
    try std.testing.expect(result.boolean == true);
}

test "coerce path" {
    const allocator = std.testing.allocator;
    const result = (try coerce(allocator, "/absolute/path", .path)).?;
    defer allocator.free(result.path);
    try std.testing.expectEqualStrings("/absolute/path", result.path);
}

test "coerce one_of" {
    const allocator = std.testing.allocator;
    const allowed = [_][]const u8{ "debug", "info", "warn", "error" };
    const result = (try coerce(allocator, "Info", .{ .one_of = &allowed })).?;
    try std.testing.expectEqualStrings("info", result.one_of);

    const bad = try coerce(allocator, "trace", .{ .one_of = &allowed });
    try std.testing.expect(bad == null);
}

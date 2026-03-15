const std = @import("std");
const parser_mod = @import("parser.zig");

const ExpandContext = parser_mod.ExpandContext;
const ExpanderFn = parser_mod.ExpanderFn;

/// Expand all %X tokens in a string value.
/// - %% → literal %
/// - %X where X has a registered expander → call expander and splice result
/// - %X with no expander → left as-is
///
/// Only allocates if any expansion actually happened.
pub fn expandTokens(
    allocator: std.mem.Allocator,
    value: []const u8,
    expanders: *const [256]?*const ExpanderFn,
    ctx: *const ExpandContext,
) ![]const u8 {
    // Quick scan: check if any expansion is needed
    var has_percent = false;
    for (value) |c| {
        if (c == '%') {
            has_percent = true;
            break;
        }
    }
    if (!has_percent) return value; // No allocation needed

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var i: usize = 0;
    while (i < value.len) {
        if (value[i] == '%' and i + 1 < value.len) {
            const next = value[i + 1];
            if (next == '%') {
                // Literal %
                try buf.append(allocator, '%');
                i += 2;
            } else if (expanders[next]) |exp_fn| {
                // Call expander
                if (exp_fn(ctx)) |expanded| {
                    try buf.appendSlice(allocator, expanded);
                } else {
                    // Expander returned null — leave token as-is
                    try buf.append(allocator, '%');
                    try buf.append(allocator, next);
                }
                i += 2;
            } else {
                // No expander registered — leave as-is
                try buf.append(allocator, '%');
                try buf.append(allocator, next);
                i += 2;
            }
        } else {
            try buf.append(allocator, value[i]);
            i += 1;
        }
    }

    return try allocator.dupe(u8, buf.items);
}

// ---------- Tests ----------

test "expandTokens - no tokens" {
    const allocator = std.testing.allocator;
    var expanders = [_]?*const ExpanderFn{null} ** 256;
    var ctx = ExpandContext.init(allocator);
    defer ctx.deinit();

    const result = try expandTokens(allocator, "hello world", &expanders, &ctx);
    // No allocation happened — same pointer
    try std.testing.expectEqualStrings("hello world", result);
}

test "expandTokens - literal percent" {
    const allocator = std.testing.allocator;
    var expanders = [_]?*const ExpanderFn{null} ** 256;
    var ctx = ExpandContext.init(allocator);
    defer ctx.deinit();

    const result = try expandTokens(allocator, "100%%", &expanders, &ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("100%", result);
}

test "expandTokens - registered expander" {
    const allocator = std.testing.allocator;
    var expanders = [_]?*const ExpanderFn{null} ** 256;

    const h_expander = struct {
        fn expand(ctx: *const ExpandContext) ?[]const u8 {
            return ctx.get("hostname");
        }
    }.expand;
    expanders['h'] = h_expander;

    var ctx = ExpandContext.init(allocator);
    defer ctx.deinit();
    try ctx.put("hostname", "example.com");

    const result = try expandTokens(allocator, "ssh://%h/path", &expanders, &ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("ssh://example.com/path", result);
}

test "expandTokens - unregistered token left as-is" {
    const allocator = std.testing.allocator;
    var expanders = [_]?*const ExpanderFn{null} ** 256;
    var ctx = ExpandContext.init(allocator);
    defer ctx.deinit();

    const result = try expandTokens(allocator, "hello %z world", &expanders, &ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello %z world", result);
}

test "expandTokens - multiple tokens" {
    const allocator = std.testing.allocator;
    var expanders = [_]?*const ExpanderFn{null} ** 256;

    const h_expander = struct {
        fn expand(ctx: *const ExpandContext) ?[]const u8 {
            return ctx.get("hostname");
        }
    }.expand;
    const u_expander = struct {
        fn expand(ctx: *const ExpandContext) ?[]const u8 {
            return ctx.get("user");
        }
    }.expand;
    expanders['h'] = h_expander;
    expanders['u'] = u_expander;

    var ctx = ExpandContext.init(allocator);
    defer ctx.deinit();
    try ctx.put("hostname", "example.com");
    try ctx.put("user", "admin");

    const result = try expandTokens(allocator, "%u@%h", &expanders, &ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("admin@example.com", result);
}

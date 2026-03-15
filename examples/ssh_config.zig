const std = @import("std");
const matchconf = @import("matchconf");

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    // Set up the parser with SSH config schema
    var parser = matchconf.Parser.init(gpa);
    defer parser.deinit();

    // Register section keywords
    try parser.section("Host", .{ .matching = .pattern });
    try parser.section("Match", .{ .matching = .conditional });

    // Register directives
    try parser.directive("HostName", .{ .value_type = .string });
    try parser.directive("Port", .{ .value_type = .integer });
    try parser.directive("User", .{ .value_type = .string });
    try parser.directive("IdentityFile", .{ .value_type = .path, .accumulate = true });
    try parser.directive("ForwardAgent", .{ .value_type = .boolean });
    try parser.directive("Compression", .{ .value_type = .boolean });
    try parser.directive("ProxyCommand", .{ .value_type = .string });
    try parser.directive("ServerAliveInterval", .{ .value_type = .integer });

    // Register token expanders
    parser.expander('h', expandHostname);
    parser.expander('u', expandUser);
    parser.expander('n', expandOriginalHost);
    parser.expander('p', expandPort);

    // Register match condition evaluators
    try parser.matcher("host", matchHost);

    // Parse the config
    const config_path = getConfigPath();
    var config = parser.parseString(config_content, config_path) catch |err| {
        std.debug.print("Error parsing config: {}\n", .{err});
        return err;
    };
    defer config.deinit();

    // Print diagnostics if any
    if (config.hasDiagnostics()) {
        const diags = config.diagnosticItems();
        for (diags) |diag| {
            const formatted = diag.format(gpa) catch continue;
            defer gpa.free(formatted);
            std.debug.print("{s}\n", .{formatted});
        }
    }

    // Query for different hosts
    const hosts = [_][]const u8{
        "web.example.com",
        "db.example.com",
        "app.staging.example.com",
        "unknown.host.org",
    };

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    for (hosts) |host| {
        try stdout.print("\n--- Lookup: {s} ---\n", .{host});

        var ctx = matchconf.ExpandContext.init(gpa);
        defer ctx.deinit();
        try ctx.put("hostname", host);
        try ctx.put("user", "currentuser");
        try ctx.put("port", "22");

        var result = try matchconf.lookupFn(gpa, &config, host, &ctx);
        defer result.deinit();

        try stdout.print("  HostName:     {s}\n", .{result.getStringOr("HostName", host)});
        try stdout.print("  Port:         {d}\n", .{result.getIntOr("Port", 22)});
        try stdout.print("  User:         {s}\n", .{result.getStringOr("User", "default")});

        const forward = result.getBoolOr("ForwardAgent", false);
        try stdout.print("  ForwardAgent: {}\n", .{forward});

        const compress = result.getBoolOr("Compression", false);
        try stdout.print("  Compression:  {}\n", .{compress});

        const id_files = result.getStringList("IdentityFile");
        if (id_files.len > 0) {
            try stdout.print("  IdentityFiles:\n", .{});
            for (id_files) |f| {
                try stdout.print("    - {s}\n", .{f});
            }
        }
    }

    try stdout.print("\n", .{});
    try stdout.flush();
}

fn getConfigPath() []const u8 {
    return "examples/fixtures/ssh_config.conf";
}

// Token expanders
fn expandHostname(ctx: *const matchconf.ExpandContext) ?[]const u8 {
    return ctx.get("hostname");
}

fn expandUser(ctx: *const matchconf.ExpandContext) ?[]const u8 {
    return ctx.get("user");
}

fn expandOriginalHost(ctx: *const matchconf.ExpandContext) ?[]const u8 {
    return ctx.get("hostname");
}

fn expandPort(ctx: *const matchconf.ExpandContext) ?[]const u8 {
    return ctx.get("port");
}

// Match condition evaluators
fn matchHost(criteria_value: []const u8, target: []const u8, _: *const matchconf.ExpandContext) bool {
    return matchconf.glob.match(criteria_value, target);
}

// Embedded config for the example (would normally be read from a file)
const config_content =
    \\# SSH Config Example
    \\
    \\Host web.example.com
    \\    HostName 10.0.1.100
    \\    Port 2222
    \\    User deploy
    \\    IdentityFile ~/.ssh/id_deploy
    \\    ForwardAgent yes
    \\
    \\Host db.example.com
    \\    HostName 10.0.1.200
    \\    Port 5432
    \\    User dbadmin
    \\    IdentityFile ~/.ssh/id_db
    \\
    \\Host *.staging.example.com
    \\    Port 22
    \\    User staging
    \\    IdentityFile ~/.ssh/id_staging
    \\
    \\Host *.example.com !db.example.com
    \\    User webteam
    \\    ForwardAgent no
    \\
    \\Host *
    \\    Port 22
    \\    User default
    \\    IdentityFile ~/.ssh/id_rsa
    \\    ForwardAgent no
    \\    Compression yes
;

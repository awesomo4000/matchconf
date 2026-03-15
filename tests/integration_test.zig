const std = @import("std");
const matchconf = @import("matchconf");

// ---------- Integration Tests ----------

test "end-to-end: SSH-style config parsing and lookup" {
    const allocator = std.testing.allocator;

    var parser = matchconf.Parser.init(allocator);
    defer parser.deinit();

    try parser.section("Host", .{ .matching = .pattern });
    try parser.directive("HostName", .{ .value_type = .string });
    try parser.directive("Port", .{ .value_type = .integer });
    try parser.directive("User", .{ .value_type = .string });
    try parser.directive("IdentityFile", .{ .value_type = .path, .accumulate = true });
    try parser.directive("ForwardAgent", .{ .value_type = .boolean });
    try parser.directive("Compression", .{ .value_type = .boolean });

    var config = try parser.parseString(
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
        \\
        \\Host *.example.com !db.example.com
        \\    User webteam
        \\    ForwardAgent no
        \\
        \\Host *
        \\    Port 22
        \\    User default
        \\    IdentityFile ~/.ssh/id_rsa
        \\    Compression yes
    , "ssh_config");
    defer config.deinit();

    try std.testing.expect(!config.hasErrors());

    var ctx = matchconf.ExpandContext.init(allocator);
    defer ctx.deinit();

    // Test: web.example.com - matches first section AND *.example.com AND *
    {
        var result = try matchconf.lookupFn(allocator, &config, "web.example.com", &ctx);
        defer result.deinit();

        try std.testing.expectEqualStrings("10.0.1.100", result.getString("HostName").?);
        try std.testing.expect(result.getInt("Port").? == 2222);
        try std.testing.expectEqualStrings("deploy", result.getString("User").?);
        try std.testing.expect(result.getBool("ForwardAgent").? == true);
        try std.testing.expect(result.getBool("Compression").? == true);

        const id_files = result.getStringList("IdentityFile");
        try std.testing.expect(id_files.len == 2);
        try std.testing.expectEqualStrings("~/.ssh/id_deploy", id_files[0]);
        try std.testing.expectEqualStrings("~/.ssh/id_rsa", id_files[1]);
    }

    // Test: db.example.com - matches db section, NOT *.example.com (negated), and *
    {
        var result = try matchconf.lookupFn(allocator, &config, "db.example.com", &ctx);
        defer result.deinit();

        try std.testing.expectEqualStrings("10.0.1.200", result.getString("HostName").?);
        try std.testing.expect(result.getInt("Port").? == 5432);
        try std.testing.expectEqualStrings("dbadmin", result.getString("User").?);
        // ForwardAgent not set in db section, not in negated section, but is not in * either
        // So it should be null
        try std.testing.expect(result.getBool("ForwardAgent") == null);
    }

    // Test: other.example.com - matches *.example.com and *
    {
        var result = try matchconf.lookupFn(allocator, &config, "other.example.com", &ctx);
        defer result.deinit();

        try std.testing.expect(result.getString("HostName") == null);
        try std.testing.expect(result.getInt("Port").? == 22); // from * section
        try std.testing.expectEqualStrings("webteam", result.getString("User").?); // from *.example.com section
    }

    // Test: random.org - matches only *
    {
        var result = try matchconf.lookupFn(allocator, &config, "random.org", &ctx);
        defer result.deinit();

        try std.testing.expect(result.getInt("Port").? == 22);
        try std.testing.expectEqualStrings("default", result.getString("User").?);
        try std.testing.expect(result.getBool("Compression").? == true);
    }
}

test "end-to-end: deploy config with string pairs" {
    const allocator = std.testing.allocator;

    var parser = matchconf.Parser.init(allocator);
    defer parser.deinit();

    try parser.section("Service", .{ .matching = .pattern });
    try parser.directive("Port", .{ .value_type = .integer });
    try parser.directive("Replicas", .{ .value_type = .integer });
    try parser.directive("Region", .{ .value_type = .string });
    try parser.directive("EnvVar", .{ .value_type = .string_pair, .accumulate = true });

    var config = try parser.parseString(
        \\Service api-gateway
        \\    Port 8080
        \\    Replicas 3
        \\    Region us-east-1
        \\    EnvVar APP_NAME api-gateway
        \\    EnvVar LOG_LEVEL info
        \\
        \\Service *
        \\    Port 8080
        \\    Replicas 1
        \\    Region us-east-1
        \\    EnvVar LOG_LEVEL warn
    , "deploy.conf");
    defer config.deinit();

    var ctx = matchconf.ExpandContext.init(allocator);
    defer ctx.deinit();

    var result = try matchconf.lookupFn(allocator, &config, "api-gateway", &ctx);
    defer result.deinit();

    try std.testing.expect(result.getInt("Port").? == 8080);
    try std.testing.expect(result.getInt("Replicas").? == 3);
    try std.testing.expectEqualStrings("us-east-1", result.getString("Region").?);

    const env_vars = result.getStringPairList("EnvVar");
    try std.testing.expect(env_vars.len == 3); // 2 from api-gateway + 1 from *
    try std.testing.expectEqualStrings("APP_NAME", env_vars[0].first);
    try std.testing.expectEqualStrings("api-gateway", env_vars[0].second);
    try std.testing.expectEqualStrings("LOG_LEVEL", env_vars[1].first);
    try std.testing.expectEqualStrings("info", env_vars[1].second);
}

test "end-to-end: diagnostics for unknown directives" {
    const allocator = std.testing.allocator;

    var parser = matchconf.Parser.init(allocator);
    defer parser.deinit();

    try parser.section("Host", .{ .matching = .pattern });
    try parser.directive("HostName", .{ .value_type = .string });
    try parser.directive("Port", .{ .value_type = .integer });

    var config = try parser.parseString(
        \\Host example.com
        \\    HosName 10.0.0.1
        \\    Poort 22
        \\    Unknown value
    , "test.conf");
    defer config.deinit();

    try std.testing.expect(config.hasDiagnostics());
    const diags = config.diagnosticItems();
    // Should have 3 warnings for unknown directives
    try std.testing.expect(diags.len == 3);

    // First should suggest HostName
    try std.testing.expect(diags[0].suggestion != null);
    try std.testing.expectEqualStrings("HostName", diags[0].suggestion.?);
}

test "end-to-end: Match (conditional) sections" {
    const allocator = std.testing.allocator;

    var parser = matchconf.Parser.init(allocator);
    defer parser.deinit();

    try parser.section("Host", .{ .matching = .pattern });
    try parser.section("Match", .{ .matching = .conditional });
    try parser.directive("User", .{ .value_type = .string });
    try parser.directive("Port", .{ .value_type = .integer });

    const host_matcher = struct {
        fn m(criteria_value: []const u8, target: []const u8, _: *const matchconf.ExpandContext) bool {
            return matchconf.glob.match(criteria_value, target);
        }
    }.m;
    try parser.matcher("host", host_matcher);

    var config = try parser.parseString(
        \\Host *
        \\    Port 22
        \\    User default
        \\
        \\Match host *.admin.example.com
        \\    User root
        \\    Port 2222
    , "test.conf");
    defer config.deinit();

    var ctx = matchconf.ExpandContext.init(allocator);
    defer ctx.deinit();

    // Regular host
    {
        var result = try matchconf.lookupFn(allocator, &config, "web.example.com", &ctx);
        defer result.deinit();
        try std.testing.expectEqualStrings("default", result.getString("User").?);
        try std.testing.expect(result.getInt("Port").? == 22);
    }

    // Admin host
    {
        var result = try matchconf.lookupFn(allocator, &config, "db.admin.example.com", &ctx);
        defer result.deinit();
        // Host * matches first for Port and User, then Match also matches
        // First-match-wins: Host * comes first, so Port=22 and User=default win
        try std.testing.expect(result.getInt("Port").? == 22);
        try std.testing.expectEqualStrings("default", result.getString("User").?);
    }
}

test "end-to-end: token expansion in values" {
    const allocator = std.testing.allocator;

    var parser = matchconf.Parser.init(allocator);
    defer parser.deinit();

    try parser.section("Host", .{ .matching = .pattern });
    try parser.directive("HostName", .{ .value_type = .string });
    try parser.directive("ProxyCommand", .{ .value_type = .string });

    const h_expander = struct {
        fn expand(ctx: *const matchconf.ExpandContext) ?[]const u8 {
            return ctx.get("hostname");
        }
    }.expand;
    const p_expander = struct {
        fn expand(ctx: *const matchconf.ExpandContext) ?[]const u8 {
            return ctx.get("port");
        }
    }.expand;
    parser.expander('h', h_expander);
    parser.expander('p', p_expander);

    var config = try parser.parseString(
        \\Host bastion
        \\    HostName bastion.example.com
        \\    ProxyCommand ssh -W %h:%p jump.example.com
    , "test.conf");
    defer config.deinit();

    var ctx = matchconf.ExpandContext.init(allocator);
    defer ctx.deinit();
    try ctx.put("hostname", "target.internal");
    try ctx.put("port", "22");

    var result = try matchconf.lookupFn(allocator, &config, "bastion", &ctx);
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "ssh -W target.internal:22 jump.example.com",
        result.getString("ProxyCommand").?,
    );
}

test "end-to-end: top-level directives before any section" {
    const allocator = std.testing.allocator;

    var parser = matchconf.Parser.init(allocator);
    defer parser.deinit();

    try parser.section("Host", .{ .matching = .pattern });
    try parser.directive("GlobalOption", .{ .value_type = .string });
    try parser.directive("Port", .{ .value_type = .integer });

    var config = try parser.parseString(
        \\GlobalOption enabled
        \\
        \\Host example.com
        \\    Port 2222
    , "test.conf");
    defer config.deinit();

    var ctx = matchconf.ExpandContext.init(allocator);
    defer ctx.deinit();

    // Top-level directives match everything (wildcard section)
    var result = try matchconf.lookupFn(allocator, &config, "example.com", &ctx);
    defer result.deinit();

    try std.testing.expectEqualStrings("enabled", result.getString("GlobalOption").?);
    try std.testing.expect(result.getInt("Port").? == 2222);
}

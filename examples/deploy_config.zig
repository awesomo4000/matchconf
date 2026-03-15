const std = @import("std");
const matchconf = @import("matchconf");

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    // Set up the parser with deploy config schema
    var parser = matchconf.Parser.init(gpa);
    defer parser.deinit();

    // Register "Service" as a section keyword
    try parser.section("Service", .{ .matching = .pattern });

    // Register deploy directives
    try parser.directive("Port", .{ .value_type = .integer });
    try parser.directive("Replicas", .{ .value_type = .integer });
    try parser.directive("Region", .{ .value_type = .string });
    try parser.directive("HealthCheck", .{ .value_type = .string });
    try parser.directive("EnvVar", .{ .value_type = .string_pair, .accumulate = true });

    // Parse the embedded config
    var config = try parser.parseString(config_content, "deploy.conf");
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

    // Query for different services
    const services = [_][]const u8{
        "api-gateway",
        "auth-service",
        "email.worker",
        "unknown-service",
    };

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    for (services) |service| {
        try stdout.print("\n--- Service: {s} ---\n", .{service});

        var ctx = matchconf.ExpandContext.init(gpa);
        defer ctx.deinit();

        var result = try matchconf.lookupFn(gpa, &config, service, &ctx);
        defer result.deinit();

        try stdout.print("  Port:        {d}\n", .{result.getIntOr("Port", 8080)});
        try stdout.print("  Replicas:    {d}\n", .{result.getIntOr("Replicas", 1)});
        try stdout.print("  Region:      {s}\n", .{result.getStringOr("Region", "us-east-1")});
        try stdout.print("  HealthCheck: {s}\n", .{result.getStringOr("HealthCheck", "/health")});

        const env_vars = result.getStringPairList("EnvVar");
        if (env_vars.len > 0) {
            try stdout.print("  Environment:\n", .{});
            for (env_vars) |pair| {
                try stdout.print("    {s}={s}\n", .{ pair.first, pair.second });
            }
        }
    }

    try stdout.print("\n", .{});
    try stdout.flush();
}

const config_content =
    \\# Deploy Configuration
    \\
    \\Service api-gateway
    \\    Port 8080
    \\    Replicas 3
    \\    Region us-east-1
    \\    HealthCheck /health
    \\    EnvVar APP_NAME api-gateway
    \\    EnvVar LOG_LEVEL info
    \\
    \\Service auth-service
    \\    Port 8081
    \\    Replicas 2
    \\    Region us-east-1
    \\    HealthCheck /auth/health
    \\    EnvVar APP_NAME auth-service
    \\    EnvVar LOG_LEVEL debug
    \\
    \\Service *.worker
    \\    Port 9090
    \\    Replicas 5
    \\    Region us-west-2
    \\    HealthCheck /worker/health
    \\    EnvVar WORKER_MODE async
    \\
    \\Service *
    \\    Port 8080
    \\    Replicas 1
    \\    Region us-east-1
    \\    HealthCheck /health
    \\    EnvVar LOG_LEVEL warn
;

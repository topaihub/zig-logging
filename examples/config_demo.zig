const std = @import("std");
const logging = @import("zig-logging");

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa_impl.allocator();

    // ── 场景 1：最简单 — 只要控制台 ──
    {
        std.debug.print("\n=== 场景 1: 控制台 pretty 格式 ===\n", .{});
        var managed = try logging.create(allocator, .{
            .level = .debug,
            .console = .{ .style = .pretty },
        });
        defer managed.deinit();

        var log = managed.logger.child("app");
        log.info("Application started", &.{
            logging.LogField.string("version", "1.0.0"),
        });
        log.debug("Debug info", &.{});
    }

    // ── 场景 2：trace 格式控制台 ──
    {
        std.debug.print("\n=== 场景 2: trace 格式控制台 ===\n", .{});
        var managed = try logging.create(allocator, .{
            .level = .debug,
            .trace_console = .{},
        });
        defer managed.deinit();

        var log = managed.logger.child("request");
        log.logKind(.info, .request, "Request started", &.{
            logging.LogField.string("Method", "CHAT"),
            logging.LogField.string("Path", "/chat"),
        });
        log.logKind(.@"error", .method, "ERROR", &.{
            logging.LogField.string("method", "AgentLoop.Run"),
            logging.LogField.string("Status", "FAIL"),
            logging.LogField.uint("Duration", 2482),
        });
    }

    // ── 场景 3：控制台 + 轮转文件同时输出 ──
    {
        std.debug.print("\n=== 场景 3: 控制台 + 轮转文件 ===\n", .{});
        var managed = try logging.create(allocator, .{
            .level = .info,
            .console = .{ .style = .compact },
            .rotating = .{
                .log_dir = "/tmp/zig-logging-demo",
                .prefix = "demo",
                .format = .text,
            },
        });
        defer managed.deinit();

        var log = managed.logger.child("demo");
        log.info("This goes to console AND file", &.{});
        log.warn("Warning also goes to both", &.{});
    }

    // ── 场景 4：零配置（默认控制台）──
    {
        std.debug.print("\n=== 场景 4: 零配置默认 ===\n", .{});
        var managed = try logging.create(allocator, .{});
        defer managed.deinit();

        managed.logger.child("default").info("Zero config works", &.{});
    }

    std.debug.print("\n=== 完成 ===\n", .{});
}

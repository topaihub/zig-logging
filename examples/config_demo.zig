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

    // ── 场景 3：控制台 + 按日滚动文件 ──
    //
    // 文件名格式：
    //   logs/myapp-2026-04-23.log       ← 当天第一个文件
    //   logs/myapp-2026-04-23.1.log     ← 超过 10MB 后自动分文件
    //   logs/myapp-2026-04-24.log       ← 第二天自动切换新文件
    {
        std.debug.print("\n=== 场景 3: 控制台 + 按日滚动文件（10MB/文件）===\n", .{});
        var managed = try logging.create(allocator, .{
            .level = .info,
            .console = .{ .style = .compact },
            .rotating = .{
                .log_dir = "/tmp/zig-logging-demo",
                .prefix = "myapp",
                .max_file_bytes = 10 * 1024 * 1024, // 10MB，默认值
                .format = .text,
            },
        });
        defer managed.deinit();

        var log = managed.logger.child("demo");
        log.info("This goes to console AND file", &.{});
        log.warn("Warning also goes to both", &.{
            logging.LogField.string("module", "config"),
        });
        log.info("File rotates daily + by size", &.{});
    }

    // ── 场景 4：trace 控制台 + trace 文件 ──
    {
        std.debug.print("\n=== 场景 4: trace 控制台 + trace 文件 ===\n", .{});
        var managed = try logging.create(allocator, .{
            .level = .debug,
            .trace_console = .{},
            .trace_file = .{
                .path = "/tmp/zig-logging-demo/trace.log",
                .max_bytes = 10 * 1024 * 1024,
            },
        });
        defer managed.deinit();

        var log = managed.logger.child("agent");
        log.logKind(.info, .request, "Request started", &.{
            logging.LogField.string("Method", "CHAT"),
        });
        log.logKind(.debug, .method, "ENTRY", &.{
            logging.LogField.string("method", "AgentLoop.Run"),
        });
    }

    // ── 场景 5：零配置（默认控制台）──
    {
        std.debug.print("\n=== 场景 5: 零配置默认 ===\n", .{});
        var managed = try logging.create(allocator, .{});
        defer managed.deinit();

        managed.logger.child("default").info("Zero config works", &.{});
    }

    std.debug.print("\n=== 完成 ===\n", .{});

    // 验证文件是否生成
    std.debug.print("\n=== 生成的日志文件 ===\n", .{});
}

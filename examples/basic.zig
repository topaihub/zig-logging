const std = @import("std");
const logging = @import("zig-logging");

pub fn main() !void {
    // 强制彩色输出，直接运行就能看到 ANSI 效果
    var console = logging.sinks.Console.initWithColorMode(.debug, .pretty, .always);

    // 创建 logger
    var logger = logging.Logger.init(console.asLogSink(), .debug);
    defer logger.deinit();

    // 创建根 subsystem logger
    const root = logger.child("app");

    // 基本日志
    root.info("Application started", &.{
        logging.LogField.string("version", "0.1.0"),
        logging.LogField.boolean("debug_mode", true),
    });

    // 使用子系统
    const auth_logger = logger.child("auth");
    auth_logger.info("User login attempt", &.{
        logging.LogField.string("username", "alice"),
        logging.LogField.uint("attempt", 1),
    });

    auth_logger.warn("Invalid password", &.{
        logging.LogField.string("username", "alice"),
        logging.LogField.uint("attempt", 2),
    });

    // 不同级别的日志
    root.debug("Debug information", &.{});
    root.warn("Warning message", &.{});
    root.@"error"("Error occurred", &.{
        logging.LogField.string("error", "connection_timeout"),
    });

    root.info("Application stopped", &.{});

    // trace 格式彩色输出
    {
        std.debug.print("\n=== trace format with colors ===\n", .{});
        var trace_console = logging.sinks.TraceConsole.initWithColorMode(.debug, .always);
        var trace_logger = logging.Logger.init(trace_console.asLogSink(), .debug);
        defer trace_logger.deinit();

        const trace_root = trace_logger.child("request");
        trace_root.logKind(.info, .request, "Request started", &.{
            logging.LogField.string("Method", "CHAT"),
            logging.LogField.string("Path", "/chat"),
        });
        trace_root.logKind(.@"error", .method, "ERROR", &.{
            logging.LogField.string("method", "AgentLoop.Run"),
            logging.LogField.string("Status", "FAIL"),
            logging.LogField.uint("Duration", 2482),
        });
    }
}

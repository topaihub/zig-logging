const std = @import("std");
const logging = @import("zig-logging");

pub fn main() !void {
    // 创建控制台 sink
    var console = logging.sinks.Console.init(.debug, .pretty);
    
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
}

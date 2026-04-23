const std = @import("std");
const logging = @import("zig-logging");

pub fn main() !void {
    var sink = logging.sinks.Console.init(.debug, .compact);
    var logger = logging.Logger.init(sink.asLogSink(), .debug);
    defer logger.deinit();

    logger.child("demo").info("basic log", &.{
        logging.LogField.string("mode", "basic"),
        logging.LogField.boolean("ok", true),
    });
}

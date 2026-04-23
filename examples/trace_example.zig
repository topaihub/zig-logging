const std = @import("std");
const logging = @import("zig-logging");

// 模拟 TraceContext 提供者
const SimpleTraceProvider = struct {
    trace_id: []const u8,
    request_id: []const u8,

    fn getCurrent(ptr: *anyopaque) logging.TraceContext {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return .{
            .trace_id = self.trace_id,
            .span_id = null,
            .request_id = self.request_id,
        };
    }

    pub fn provider(self: *@This()) logging.TraceContextProvider {
        return .{
            .ptr = @ptrCast(self),
            .current = getCurrent,
        };
    }
};

pub fn main() !void {
    // 使用 TraceConsoleSink — 输出 [HH:MM:SS LVL] TraceId:xxx|Message|Field:value 格式
    var trace_console = logging.sinks.TraceConsole.init(.debug);

    var trace_provider = SimpleTraceProvider{
        .trace_id = "05b287fe7fd7d54b",
        .request_id = "req_001",
    };

    var logger = logging.Logger.initWithOptions(trace_console.asLogSink(), .{
        .min_level = .debug,
        .trace_context_provider = trace_provider.provider(),
    });
    defer logger.deinit();

    // 1. Request started
    const request_log = logger.child("request");
    request_log.logKind(.info, .request, "Request started", &.{
        logging.LogField.string("Method", "CHAT"),
        logging.LogField.string("Path", "/chat"),
    });

    // 2. Method ENTRY
    const method_log = logger.child("agent");
    method_log.logKind(.debug, .method, "ENTRY", &.{
        logging.LogField.string("method", "AgentLoop.Run"),
        logging.LogField.string("Params", "{\"messages\":2,\"tools\":23}"),
    });

    // 3. Method ERROR
    method_log.logKind(.@"error", .method, "ERROR", &.{
        logging.LogField.string("method", "AgentLoop.Run"),
        logging.LogField.string("Status", "FAIL"),
        logging.LogField.uint("Duration", 2482),
        logging.LogField.string("Type", "SYNC"),
        logging.LogField.string("Exception", "ResponsesEmptyOutput"),
        logging.LogField.string("ErrorCode", "ResponsesEmptyOutput"),
    });

    // 4. Step completed
    const db_log = logger.child("database");
    db_log.logKind(.info, .step, "Step completed", &.{
        logging.LogField.string("Step", "query_users"),
        logging.LogField.uint("Duration", 45),
    });

    // 5. Processing message
    const msg_log = logger.child("processor");
    msg_log.info("Processing message", &.{
        logging.LogField.string("user_id", "user123"),
        logging.LogField.uint("message_length", 256),
    });
}

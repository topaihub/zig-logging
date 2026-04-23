const std = @import("std");
const logging = @import("zig-logging");

const SimpleTraceProvider = struct {
    trace_id: []const u8,

    fn getCurrent(ptr: *anyopaque) logging.TraceContext {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return .{
            .trace_id = self.trace_id,
            .span_id = null,
            .request_id = null,
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
    const allocator = std.heap.page_allocator;

    std.debug.print("\n=== TraceTextFileSink 示例 ===\n", .{});
    std.debug.print("这个 sink 会生成类似 hermes-zig 的日志格式：\n", .{});
    std.debug.print("[时间 级别] TraceId:xxx|Message|Field:value\n\n", .{});

    // 创建 TraceTextFileSink - 这会生成 TraceId:xxx|Message|Field:value 格式
    var trace_sink = try logging.sinks.TraceTextFile.init(
        allocator,
        "trace.log",
        null, // 无大小限制
        .{
            .include_observer = false,
            .include_runtime_dispatch = false,
            .include_framework_method_trace = true,
        },
    );
    defer trace_sink.deinit();

    // 创建带 TraceContextProvider 的 Logger
    var trace_provider = SimpleTraceProvider{ .trace_id = "05b287fe7fd7d54b" };
    var logger = logging.Logger.initWithOptions(trace_sink.asLogSink(), .{
        .min_level = .debug,
        .trace_context_provider = trace_provider.provider(),
    });
    defer logger.deinit();

    // 示例 1: Request trace
    std.debug.print("1. Request trace (subsystem='request'):\n", .{});
    const request_logger = logger.child("request");
    request_logger.logKind(.info, .request, "Request started", &.{
        logging.LogField.string("method", "CHAT"),
        logging.LogField.string("path", "/chat"),
    });
    std.debug.print("   -> 已调用 logKind\n", .{});

    // 示例 2: Method trace - ENTRY
    std.debug.print("2. Method trace - ENTRY:\n", .{});
    const method_logger = logger.child("method");
    method_logger.logKind(.debug, .method, "ENTRY", &.{
        logging.LogField.string("method", "AgentLoop.Run"),
        logging.LogField.string("params", "{\"messages\":2,\"tools\":23}"),
    });

    // 示例 3: Method trace - ERROR
    std.debug.print("3. Method trace - ERROR:\n", .{});
    method_logger.logKind(.@"error", .method, "ERROR", &.{
        logging.LogField.string("method", "AgentLoop.Run"),
        logging.LogField.string("status", "FAIL"),
        logging.LogField.uint("duration_ms", 2482),
        logging.LogField.string("type", "SYNC"),
        logging.LogField.string("exception_type", "ResponsesEmptyOutput"),
        logging.LogField.string("error_code", "ResponsesEmptyOutput"),
    });

    // 示例 4: Step trace
    std.debug.print("4. Step trace:\n", .{});
    const db_logger = logger.child("database");
    db_logger.logKind(.info, .step, "Step completed", &.{
        logging.LogField.string("step", "query_users"),
        logging.LogField.uint("duration_ms", 45),
    });

    // 示例 5: 普通日志（带 trace_id）
    std.debug.print("5. Generic log with trace_id:\n", .{});
    const app_logger = logger.child("app");
    app_logger.info("Processing message", &.{
        logging.LogField.string("user_id", "user123"),
        logging.LogField.uint("message_length", 256),
    });

    std.debug.print("\n✅ 日志已写入 trace.log\n", .{});
    std.debug.print("查看文件内容以验证格式：\n", .{});
    std.debug.print("  cat trace.log\n\n", .{});
}

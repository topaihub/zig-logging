const std = @import("std");
const logging = @import("zig-logging");

// 模拟一个简单的 TraceContext 提供者
const SimpleTraceProvider = struct {
    trace_id: []const u8,
    request_id: []const u8,

    const vtable = logging.TraceContextProvider{
        .ptr = undefined,
        .current = getCurrent,
    };

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
    
    // 创建控制台 sink
    var console = logging.sinks.Console.init(.debug, .pretty);
    
    // 创建 trace provider
    var trace_provider = SimpleTraceProvider{
        .trace_id = "trc_abc123xyz",
        .request_id = "req_001",
    };

    // 创建带 trace context 的 logger
    var logger = logging.Logger.initWithOptions(console.asLogSink(), .{
        .min_level = .debug,
        .trace_context_provider = trace_provider.provider(),
    });
    defer logger.deinit();

    std.debug.print("\n=== 示例 1: 普通日志（自动附加 traceId 和 requestId）===\n", .{});
    logger.child("app").info("User authentication started", &.{
        logging.LogField.string("username", "alice"),
        logging.LogField.string("ip", "192.168.1.100"),
    });

    std.debug.print("\n=== 示例 2: Request Span 格式（特殊格式化）===\n", .{});
    const request_logger = logger.child("request");
    request_logger.logKind(.info, .request, "Request completed", &.{
        logging.LogField.string("method", "GET"),
        logging.LogField.string("path", "/api/users"),
        logging.LogField.string("query", "page=1&limit=10"),
        logging.LogField.uint("status", 200),
        logging.LogField.uint("duration_ms", 45),
    });

    std.debug.print("\n=== 示例 3: Method Trace 格式（方法追踪）===\n", .{});
    const method_logger = logger.child("method");
    method_logger.logKind(.debug, .method, "ENTRY", &.{
        logging.LogField.string("method", "UserService.authenticate"),
    });
    
    // 模拟方法执行
    
    method_logger.logKind(.debug, .method, "EXIT", &.{
        logging.LogField.string("method", "UserService.authenticate"),
        logging.LogField.uint("duration_ms", 10),
    });

    std.debug.print("\n=== 示例 4: Step Span 格式（步骤追踪）===\n", .{});
    const db_logger = logger.child("database");
    db_logger.logKind(.info, .step, "Step started", &.{
        logging.LogField.string("step", "query_users"),
    });
    
    db_logger.logKind(.info, .step, "Step completed", &.{
        logging.LogField.string("step", "query_users"),
        logging.LogField.uint("rows", 42),
        logging.LogField.uint("duration_ms", 23),
    });

    std.debug.print("\n=== 示例 5: 错误日志（带 error_code）===\n", .{});
    logger.child("app").@"error"("Database connection failed", &.{
        logging.LogField.string("error_code", "DB_CONN_TIMEOUT"),
        logging.LogField.string("host", "db.example.com"),
        logging.LogField.uint("port", 5432),
    });

    std.debug.print("\n=== 完成 ===\n", .{});
}

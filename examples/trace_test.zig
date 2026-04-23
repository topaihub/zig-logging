const std = @import("std");
const logging = @import("zig-logging");

// 简单的 TraceContext 提供者
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
    std.debug.print("\n=== 测试 1: Compact 格式 ===\n", .{});
    {
        var console = logging.ConsoleSink.init(.debug, .compact);
        var trace_provider = SimpleTraceProvider{
            .trace_id = "trace-abc-123",
            .request_id = "req-xyz-789",
        };
        var logger = logging.Logger.initWithOptions(console.asLogSink(), .{
            .min_level = .debug,
            .trace_context_provider = trace_provider.provider(),
        });
        defer logger.deinit();

        const app = logger.child("app");
        app.info("User login", &.{
            logging.LogField.string("username", "alice"),
            logging.LogField.uint("user_id", 12345),
        });
    }

    std.debug.print("\n=== 测试 2: Pretty 格式 ===\n", .{});
    {
        var console = logging.ConsoleSink.init(.debug, .pretty);
        var trace_provider = SimpleTraceProvider{
            .trace_id = "trace-def-456",
            .request_id = "req-uvw-012",
        };
        var logger = logging.Logger.initWithOptions(console.asLogSink(), .{
            .min_level = .debug,
            .trace_context_provider = trace_provider.provider(),
        });
        defer logger.deinit();

        const app = logger.child("app");
        app.info("Payment processed", &.{
            logging.LogField.string("payment_id", "pay-001"),
            logging.LogField.uint("amount", 9999),
        });
    }

    std.debug.print("\n=== 测试 3: Request 类型 (Pretty 格式) ===\n", .{});
    {
        var console = logging.ConsoleSink.init(.info, .pretty);
        var trace_provider = SimpleTraceProvider{
            .trace_id = "trace-ghi-789",
            .request_id = "req-rst-345",
        };
        var logger = logging.Logger.initWithOptions(console.asLogSink(), .{
            .min_level = .info,
            .trace_context_provider = trace_provider.provider(),
        });
        defer logger.deinit();

        const request_logger = logger.child("request");
        request_logger.log(.info, .request, "Request completed", &.{
            logging.LogField.string("method", "POST"),
            logging.LogField.string("path", "/api/orders"),
            logging.LogField.string("query", ""),
        });
    }

    std.debug.print("\n=== 测试 4: Method Trace (Pretty 格式) ===\n", .{});
    {
        var console = logging.ConsoleSink.init(.debug, .pretty);
        var trace_provider = SimpleTraceProvider{
            .trace_id = "trace-jkl-012",
            .request_id = "req-mno-678",
        };
        var logger = logging.Logger.initWithOptions(console.asLogSink(), .{
            .min_level = .debug,
            .trace_context_provider = trace_provider.provider(),
        });
        defer logger.deinit();

        const method_logger = logger.child("method");
        method_logger.log(.debug, .method, "ENTRY", &.{
            logging.LogField.string("method", "OrderService.createOrder"),
        });
        
        method_logger.log(.debug, .method, "EXIT", &.{
            logging.LogField.string("method", "OrderService.createOrder"),
        });
    }

    std.debug.print("\n=== 完成 ===\n", .{});
}

const std = @import("std");
const core = struct {
    const level = @import("core/level.zig");
    const record = @import("core/record.zig");
    const sink = @import("core/sink.zig");
    const redact = @import("core/redact.zig");
};
const sink_impls = struct {
    const console = @import("sinks/console.zig");
    const jsonl_file = @import("sinks/jsonl_file.zig");
    const rotating_file = @import("sinks/rotating_file.zig");
    const trace_console = @import("sinks/trace/console.zig");
    const trace_text_file = @import("sinks/trace/text_file.zig");
    const multi = @import("sinks/multi.zig");
};
const logger_mod = @import("logger.zig");

pub const LogLevel = core.level.LogLevel;
pub const LogSink = core.sink.LogSink;
pub const Logger = logger_mod.Logger;
pub const LoggerOptions = logger_mod.LoggerOptions;
pub const TraceContextProvider = logger_mod.TraceContextProvider;
pub const RedactMode = core.redact.RedactMode;

/// 日志输出配置。所有字段都有默认值，按需开启。
pub const LogConfig = struct {
    /// 全局最低日志级别
    level: LogLevel = .info,
    /// 控制台输出
    console: ?ConsoleConfig = null,
    /// trace 格式控制台（和 console 二选一）
    trace_console: ?TraceConsoleConfig = null,
    /// JSON Lines 文件
    file: ?FileConfig = null,
    /// trace 格式文件
    trace_file: ?TraceFileConfig = null,
    /// 自动轮转文件
    rotating: ?RotatingConfig = null,
    /// 脱敏模式
    redact: RedactMode = .safe,
    /// Trace context 提供者
    trace_provider: ?TraceContextProvider = null,

    pub const ConsoleConfig = struct {
        style: sink_impls.console.ConsoleStyle = .pretty,
    };
    pub const TraceConsoleConfig = struct {};
    pub const FileConfig = struct {
        path: []const u8,
        max_bytes: ?u64 = null,
    };
    pub const TraceFileConfig = struct {
        path: []const u8,
        max_bytes: ?u64 = null,
    };
    pub const RotatingConfig = struct {
        log_dir: []const u8 = "logs",
        prefix: []const u8 = "app",
        max_file_bytes: u64 = 10 * 1024 * 1024,
        format: sink_impls.rotating_file.LogFormat = .text,
    };
};

/// 由 create() 返回，持有 Logger 和所有 sink 的生命周期。
pub const ManagedLogger = struct {
    logger: Logger,
    allocator: std.mem.Allocator,
    // 堆上分配的 sink，通过指针保证地址稳定
    console_sink: ?*sink_impls.console.ConsoleSink = null,
    trace_console_sink: ?*sink_impls.trace_console.TraceConsoleSink = null,
    file_sink: ?*sink_impls.jsonl_file.JsonlFileSink = null,
    trace_file_sink: ?*sink_impls.trace_text_file.TraceTextFileSink = null,
    rotating_sink: ?*sink_impls.rotating_file.RotatingFileSink = null,
    multi_sink: ?*sink_impls.multi.MultiSink = null,

    pub fn deinit(self: *ManagedLogger) void {
        self.logger.deinit();
        if (self.multi_sink) |s| {
            s.deinit();
            self.allocator.destroy(s);
        }
        if (self.file_sink) |s| {
            s.deinit();
            self.allocator.destroy(s);
        }
        if (self.trace_file_sink) |s| {
            s.deinit();
            self.allocator.destroy(s);
        }
        if (self.rotating_sink) |s| {
            s.deinit();
            self.allocator.destroy(s);
        }
        if (self.console_sink) |s| self.allocator.destroy(s);
        if (self.trace_console_sink) |s| self.allocator.destroy(s);
    }
};

/// 一行创建 Logger。
///
/// ```zig
/// var managed = try logging.create(allocator, .{
///     .level = .debug,
///     .console = .{ .style = .pretty },
///     .rotating = .{ .log_dir = "logs", .prefix = "myapp" },
/// });
/// defer managed.deinit();
/// var log = managed.logger.child("app");
/// log.info("started", &.{});
/// ```
pub fn create(allocator: std.mem.Allocator, config: LogConfig) !ManagedLogger {
    var managed = ManagedLogger{
        .logger = undefined,
        .allocator = allocator,
    };

    var sink_buf: [5]LogSink = undefined;
    var sink_count: usize = 0;

    // 控制台
    if (config.console) |c| {
        const s = try allocator.create(sink_impls.console.ConsoleSink);
        s.* = sink_impls.console.ConsoleSink.init(config.level, c.style);
        managed.console_sink = s;
        sink_buf[sink_count] = s.asLogSink();
        sink_count += 1;
    }

    // trace 控制台
    if (config.trace_console != null) {
        const s = try allocator.create(sink_impls.trace_console.TraceConsoleSink);
        s.* = sink_impls.trace_console.TraceConsoleSink.init(config.level);
        managed.trace_console_sink = s;
        sink_buf[sink_count] = s.asLogSink();
        sink_count += 1;
    }

    // JSON 文件
    if (config.file) |f| {
        const s = try allocator.create(sink_impls.jsonl_file.JsonlFileSink);
        const io = std.Io.Threaded.global_single_threaded.*.io();
        s.* = try sink_impls.jsonl_file.JsonlFileSink.init(allocator, f.path, f.max_bytes, io);
        managed.file_sink = s;
        sink_buf[sink_count] = s.asLogSink();
        sink_count += 1;
    }

    // trace 文件
    if (config.trace_file) |f| {
        const s = try allocator.create(sink_impls.trace_text_file.TraceTextFileSink);
        s.* = try sink_impls.trace_text_file.TraceTextFileSink.init(allocator, f.path, f.max_bytes, .{});
        managed.trace_file_sink = s;
        sink_buf[sink_count] = s.asLogSink();
        sink_count += 1;
    }

    // 轮转文件
    if (config.rotating) |r| {
        const s = try allocator.create(sink_impls.rotating_file.RotatingFileSink);
        s.* = sink_impls.rotating_file.RotatingFileSink.init(allocator, .{
            .log_dir = r.log_dir,
            .prefix = r.prefix,
            .max_file_bytes = r.max_file_bytes,
            .format = r.format,
        });
        managed.rotating_sink = s;
        sink_buf[sink_count] = s.asLogSink();
        sink_count += 1;
    }

    // 组合
    const final_sink: LogSink = if (sink_count == 0) blk: {
        // 默认控制台
        const s = try allocator.create(sink_impls.console.ConsoleSink);
        s.* = sink_impls.console.ConsoleSink.init(config.level, .pretty);
        managed.console_sink = s;
        break :blk s.asLogSink();
    } else if (sink_count == 1) sink_buf[0] else blk: {
        const s = try allocator.create(sink_impls.multi.MultiSink);
        s.* = try sink_impls.multi.MultiSink.init(allocator, sink_buf[0..sink_count]);
        managed.multi_sink = s;
        break :blk s.asLogSink();
    };

    managed.logger = Logger.initWithOptions(final_sink, .{
        .min_level = config.level,
        .redact_mode = config.redact,
        .trace_context_provider = config.trace_provider,
    });

    return managed;
}

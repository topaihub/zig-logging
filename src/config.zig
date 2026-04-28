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
        color_mode: sink_impls.console.ConsoleColorMode = .auto,
        stream_routing: sink_impls.console.ConsoleStreamRouting = .split,
    };
    pub const TraceConsoleConfig = struct {
        color_mode: sink_impls.console.ConsoleColorMode = .auto,
    };
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
///     .console = .{
///         .style = .pretty,
///         .color_mode = .auto,
///     },
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
        s.* = sink_impls.console.ConsoleSink.initWithColorMode(config.level, c.style, c.color_mode);
        s.min_level = .trace;
        s.stream_routing = c.stream_routing;
        managed.console_sink = s;
        sink_buf[sink_count] = s.asLogSink();
        sink_count += 1;
    }

    // trace 控制台
    if (config.trace_console != null) {
        const s = try allocator.create(sink_impls.trace_console.TraceConsoleSink);
        s.* = sink_impls.trace_console.TraceConsoleSink.initWithColorMode(config.level, config.trace_console.?.color_mode);
        s.min_level = .trace;
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
        s.* = sink_impls.console.ConsoleSink.initWithColorMode(config.level, .pretty, .auto);
        s.min_level = .trace;
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

test "create threads console color mode" {
    var managed = try create(std.testing.allocator, .{
        .console = .{
            .style = .compact,
            .color_mode = .always,
            .stream_routing = .stderr,
        },
        .level = .debug,
    });
    defer managed.deinit();

    try std.testing.expect(managed.console_sink != null);
    try std.testing.expectEqual(sink_impls.console.ConsoleColorMode.always, managed.console_sink.?.color_mode);
    try std.testing.expectEqual(sink_impls.console.ConsoleStyle.compact, managed.console_sink.?.style);
    try std.testing.expectEqual(sink_impls.console.ConsoleStreamRouting.stderr, managed.console_sink.?.stream_routing);
    try std.testing.expectEqual(LogLevel.debug, managed.logger.minLevel());
}

test "create defaults console color mode to auto" {
    var managed = try create(std.testing.allocator, .{});
    defer managed.deinit();

    try std.testing.expect(managed.console_sink != null);
    try std.testing.expectEqual(sink_impls.console.ConsoleColorMode.auto, managed.console_sink.?.color_mode);
    try std.testing.expectEqual(sink_impls.console.ConsoleStyle.pretty, managed.console_sink.?.style);
    try std.testing.expectEqual(sink_impls.console.ConsoleStreamRouting.split, managed.console_sink.?.stream_routing);
}

test "create keeps trace console separate" {
    var managed = try create(std.testing.allocator, .{
        .trace_console = .{ .color_mode = .always },
    });
    defer managed.deinit();

    try std.testing.expect(managed.trace_console_sink != null);
    try std.testing.expect(managed.console_sink == null);
    try std.testing.expectEqual(sink_impls.console.ConsoleColorMode.always, managed.trace_console_sink.?.color_mode);
}

test "create keeps file output unchanged across console routing" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);

    const stdout_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "stdout.jsonl" });
    defer std.testing.allocator.free(stdout_path);

    const stderr_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "stderr.jsonl" });
    defer std.testing.allocator.free(stderr_path);

    var stdout_managed = try create(std.testing.allocator, .{
        .level = .info,
        .console = .{
            .stream_routing = .stdout,
        },
        .file = .{
            .path = stdout_path,
        },
    });
    defer stdout_managed.deinit();

    var stderr_managed = try create(std.testing.allocator, .{
        .level = .info,
        .console = .{
            .stream_routing = .stderr,
        },
        .file = .{
            .path = stderr_path,
        },
    });
    defer stderr_managed.deinit();

    const record = core.record.LogRecord{
        .ts_unix_ms = 42,
        .level = .info,
        .subsystem = "config",
        .message = "updated",
        .fields = &.{core.record.LogField.string("path", "gateway.port")},
    };

    stdout_managed.file_sink.?.write(&record);
    stderr_managed.file_sink.?.write(&record);

    const stdout_bytes = try tmp_dir.dir.readFileAlloc(std.testing.io, "stdout.jsonl", std.testing.allocator, std.Io.Limit.limited(4096));
    defer std.testing.allocator.free(stdout_bytes);
    const stderr_bytes = try tmp_dir.dir.readFileAlloc(std.testing.io, "stderr.jsonl", std.testing.allocator, std.Io.Limit.limited(4096));
    defer std.testing.allocator.free(stderr_bytes);

    try std.testing.expectEqualStrings(stdout_bytes, stderr_bytes);
    try std.testing.expect(std.mem.indexOf(u8, stdout_bytes, "\"subsystem\":\"config\"") != null);
}

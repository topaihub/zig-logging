const std = @import("std");
const level_model = @import("core/level.zig");
const record_model = @import("core/record.zig");
const redact_model = @import("core/redact.zig");
const sink_model = @import("core/sink.zig");

pub const LogLevel = level_model.LogLevel;
pub const LogField = record_model.LogField;
pub const LogRecord = record_model.LogRecord;
pub const LogRecordKind = record_model.LogRecordKind;
pub const RedactMode = redact_model.RedactMode;
pub const LogSink = sink_model.LogSink;

pub const TraceContext = struct {
    trace_id: ?[]const u8 = null,
    span_id: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
};

pub const TraceContextProvider = struct {
    ptr: *anyopaque,
    current: *const fn (ptr: *anyopaque) TraceContext,

    pub fn getCurrent(self: TraceContextProvider) TraceContext {
        return self.current(self.ptr);
    }
};

pub const LoggerTruncationStats = struct {
    truncated_subsystem_count: usize,
    dropped_default_fields_count: usize,
    dropped_runtime_fields_count: usize,
};

pub const LoggerOptions = struct {
    min_level: LogLevel = .info,
    redact_mode: RedactMode = .safe,
    trace_context_provider: ?TraceContextProvider = null,
};

pub const Logger = struct {
    sink: LogSink,
    min_level: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(LogLevel.info)),
    redact_mode: RedactMode = .safe,
    trace_context_provider: ?TraceContextProvider = null,
    truncated_subsystem_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    dropped_default_fields_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    dropped_runtime_fields_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    const Self = @This();

    pub fn init(sink: LogSink, min_level: LogLevel) Self {
        return initWithOptions(sink, .{ .min_level = min_level });
    }

    pub fn initWithOptions(sink: LogSink, options: LoggerOptions) Self {
        return .{
            .sink = sink,
            .min_level = std.atomic.Value(u8).init(@intFromEnum(options.min_level)),
            .redact_mode = options.redact_mode,
            .trace_context_provider = options.trace_context_provider,
        };
    }

    pub fn deinit(self: *Self) void {
        self.flush();
    }

    pub fn flush(self: *Self) void {
        self.sink.flush();
    }

    pub fn minLevel(self: *const Self) LogLevel {
        return @enumFromInt(self.min_level.load(.monotonic));
    }

    pub fn setMinLevel(self: *Self, level: LogLevel) void {
        self.min_level.store(@intFromEnum(level), .monotonic);
    }

    pub fn child(self: *Self, subsystem_name: []const u8) SubsystemLogger {
        return SubsystemLogger.init(self, subsystem_name);
    }

    pub fn subsystem(self: *Self, subsystem_name: []const u8) SubsystemLogger {
        return self.child(subsystem_name);
    }

    pub fn truncationStats(self: *const Self) LoggerTruncationStats {
        return .{
            .truncated_subsystem_count = self.truncated_subsystem_count.load(.monotonic),
            .dropped_default_fields_count = self.dropped_default_fields_count.load(.monotonic),
            .dropped_runtime_fields_count = self.dropped_runtime_fields_count.load(.monotonic),
        };
    }

    fn log(self: *Self, level: LogLevel, kind: LogRecordKind, subsystem_name: []const u8, message: []const u8, fields: []const LogField) void {
        if (!self.minLevel().allows(level)) {
            return;
        }

        const io = std.Io.Threaded.global_single_threaded.*.io();
        const ts = std.Io.Timestamp.now(io, .real);
        var record = LogRecord{
            .ts_unix_ms = @intCast(@divFloor(ts.nanoseconds, 1_000_000)),
            .level = level,
            .kind = kind,
            .subsystem = subsystem_name,
            .message = message,
            .fields = fields,
        };

        if (self.trace_context_provider) |provider| {
            const trace_context = provider.getCurrent();
            record.trace_id = trace_context.trace_id;
            record.span_id = trace_context.span_id;
            record.request_id = trace_context.request_id;
        }

        self.sink.write(&record);
    }

    fn noteTruncatedSubsystem(self: *Self) void {
        _ = self.truncated_subsystem_count.fetchAdd(1, .monotonic);
    }

    fn noteDroppedDefaultFields(self: *Self, count: usize) void {
        if (count == 0) return;
        _ = self.dropped_default_fields_count.fetchAdd(count, .monotonic);
    }

    fn noteDroppedRuntimeFields(self: *Self, count: usize) void {
        if (count == 0) return;
        _ = self.dropped_runtime_fields_count.fetchAdd(count, .monotonic);
    }
};

pub const SubsystemLogger = struct {
    logger: *Logger,
    subsystem_storage: [max_subsystem_len]u8 = undefined,
    subsystem_len: usize = 0,
    default_fields_storage: [max_default_fields]LogField = undefined,
    default_field_count: usize = 0,

    const Self = @This();
    const max_subsystem_len = 128;
    const max_default_fields = 8;
    const max_combined_fields = 16;

    pub fn init(logger: *Logger, subsystem_name: []const u8) Self {
        var self = Self{
            .logger = logger,
        };
        self.setSubsystem(subsystem_name);
        return self;
    }

    pub fn subsystem(self: *const Self) []const u8 {
        return self.subsystem_storage[0..self.subsystem_len];
    }

    pub fn child(self: Self, name: []const u8) Self {
        var next = self;
        next.appendSubsystem(name);
        return next;
    }

    pub fn withField(self: Self, field: LogField) Self {
        var next = self;
        if (next.default_field_count < max_default_fields) {
            next.default_fields_storage[next.default_field_count] = field;
            next.default_field_count += 1;
        } else {
            next.logger.noteDroppedDefaultFields(1);
        }
        return next;
    }

    pub fn withFields(self: Self, fields: []const LogField) Self {
        var next = self;
        for (fields, 0..) |field, index| {
            if (next.default_field_count >= max_default_fields) {
                const remaining = fields.len - index;
                next.logger.noteDroppedDefaultFields(remaining);
                break;
            }
            next.default_fields_storage[next.default_field_count] = field;
            next.default_field_count += 1;
        }
        return next;
    }

    pub fn trace(self: *const Self, message: []const u8, fields: []const LogField) void {
        self.emit(.trace, message, fields);
    }

    pub fn debug(self: *const Self, message: []const u8, fields: []const LogField) void {
        self.emit(.debug, message, fields);
    }

    pub fn info(self: *const Self, message: []const u8, fields: []const LogField) void {
        self.emit(.info, message, fields);
    }

    pub fn warn(self: *const Self, message: []const u8, fields: []const LogField) void {
        self.emit(.warn, message, fields);
    }

    pub fn @"error"(self: *const Self, message: []const u8, fields: []const LogField) void {
        self.emit(.@"error", message, fields);
    }

    pub fn fatal(self: *const Self, message: []const u8, fields: []const LogField) void {
        self.emit(.fatal, message, fields);
    }

    pub fn logKind(self: *const Self, level: LogLevel, kind: LogRecordKind, message: []const u8, fields: []const LogField) void {
        self.emitKind(level, kind, message, fields);
    }

    fn emit(self: *const Self, level: LogLevel, message: []const u8, fields: []const LogField) void {
        self.emitKind(level, .generic, message, fields);
    }

    fn emitKind(self: *const Self, level: LogLevel, kind: LogRecordKind, message: []const u8, fields: []const LogField) void {
        var combined: [max_combined_fields]LogField = undefined;
        var redacted: [max_combined_fields]LogField = undefined;
        var combined_len: usize = 0;

        for (self.default_fields_storage[0..self.default_field_count]) |field| {
            if (combined_len >= max_combined_fields) {
                break;
            }
            combined[combined_len] = field;
            combined_len += 1;
        }

        for (fields) |field| {
            if (combined_len >= max_combined_fields) {
                self.logger.noteDroppedRuntimeFields(fields.len - (combined_len - self.default_field_count));
                break;
            }
            combined[combined_len] = field;
            combined_len += 1;
        }

        const emitted_fields = redact_model.redactFields(
            self.logger.redact_mode,
            combined[0..combined_len],
            redacted[0..combined_len],
        );

        self.logger.log(level, kind, self.subsystem(), message, emitted_fields);
    }

    fn setSubsystem(self: *Self, subsystem_name: []const u8) void {
        const copy_len = @min(max_subsystem_len, subsystem_name.len);
        @memcpy(self.subsystem_storage[0..copy_len], subsystem_name[0..copy_len]);
        self.subsystem_len = copy_len;
        if (copy_len < subsystem_name.len) {
            self.logger.noteTruncatedSubsystem();
        }
    }

    fn appendSubsystem(self: *Self, suffix: []const u8) void {
        if (suffix.len == 0 or self.subsystem_len >= max_subsystem_len) {
            return;
        }

        var start = self.subsystem_len;
        if (start > 0 and start < max_subsystem_len) {
            self.subsystem_storage[start] = '/';
            start += 1;
        }

        const available = max_subsystem_len - start;
        const copy_len = @min(available, suffix.len);
        @memcpy(self.subsystem_storage[start .. start + copy_len], suffix[0..copy_len]);
        self.subsystem_len = start + copy_len;
        if (copy_len < suffix.len) {
            self.logger.noteTruncatedSubsystem();
        }
    }
};

test "logger writes structured records into memory sink" {
    const memory_sink_model = @import("sinks/memory.zig");

    var memory_sink = memory_sink_model.MemorySink.init(std.testing.allocator, 8);
    defer memory_sink.deinit();

    var logger = Logger.init(memory_sink.asLogSink(), .debug);
    defer logger.deinit();

    const fields = [_]LogField{
        LogField.string("method", "config.set"),
        LogField.boolean("retryable", false),
    };
    const subsystem_logger = logger
        .child("runtime")
        .child("dispatch")
        .withField(LogField.string("source", "test"));

    subsystem_logger.info("command started", fields[0..]);

    try std.testing.expectEqual(@as(usize, 1), memory_sink.count());
    try std.testing.expectEqualStrings("runtime/dispatch", memory_sink.latest().?.subsystem);
    try std.testing.expectEqualStrings("command started", memory_sink.latest().?.message);
    try std.testing.expectEqual(@as(usize, 3), memory_sink.latest().?.fields.len);
    try std.testing.expectEqualStrings("source", memory_sink.latest().?.fields[0].key);
    try std.testing.expectEqualStrings("config.set", memory_sink.latest().?.fields[1].value.string);
}

test "logger respects minimum level filtering" {
    const memory_sink_model = @import("sinks/memory.zig");

    var memory_sink = memory_sink_model.MemorySink.init(std.testing.allocator, 4);
    defer memory_sink.deinit();

    var logger = Logger.init(memory_sink.asLogSink(), .warn);
    defer logger.deinit();

    const subsystem_logger = logger.child("config");
    subsystem_logger.info("ignored", &.{});
    subsystem_logger.@"error"("persist failed", &.{});

    try std.testing.expectEqual(@as(usize, 1), memory_sink.count());
    try std.testing.expect(memory_sink.latest().?.level == .@"error");
    try std.testing.expectEqualStrings("persist failed", memory_sink.latest().?.message);
}

test "logger applies runtime minimum level updates to subsequent emissions" {
    const memory_sink_model = @import("sinks/memory.zig");

    var memory_sink = memory_sink_model.MemorySink.init(std.testing.allocator, 8);
    defer memory_sink.deinit();

    var logger = Logger.init(memory_sink.asLogSink(), .info);
    defer logger.deinit();

    const subsystem_logger = logger.child("config");
    subsystem_logger.debug("ignored before lowering", &.{});

    logger.setMinLevel(.debug);
    subsystem_logger.debug("emitted after lowering", &.{});

    logger.setMinLevel(.warn);
    subsystem_logger.info("ignored after raising", &.{});
    subsystem_logger.@"error"("emitted after raising", &.{});

    try std.testing.expectEqual(@as(usize, 2), memory_sink.count());
    try std.testing.expectEqualStrings("emitted after lowering", memory_sink.recordAt(0).?.message);
    try std.testing.expect(memory_sink.recordAt(0).?.level == .debug);
    try std.testing.expectEqualStrings("emitted after raising", memory_sink.latest().?.message);
    try std.testing.expect(memory_sink.latest().?.level == .@"error");
}

test "logger redacts sensitive fields before sink write" {
    const memory_sink_model = @import("sinks/memory.zig");

    var memory_sink = memory_sink_model.MemorySink.init(std.testing.allocator, 4);
    defer memory_sink.deinit();

    var logger = Logger.initWithOptions(memory_sink.asLogSink(), .{
        .min_level = .info,
        .redact_mode = .safe,
    });
    defer logger.deinit();

    const subsystem_logger = logger.child("providers");
    subsystem_logger.info("request prepared", &.{
        LogField.string("api_key", "top-secret"),
        LogField.string("model", "gpt-test"),
    });

    try std.testing.expectEqualStrings(redact_model.REDACTED_VALUE, memory_sink.latest().?.fields[0].value.string);
    try std.testing.expectEqualStrings("gpt-test", memory_sink.latest().?.fields[1].value.string);
}

test "logger injects trace context automatically" {
    const memory_sink_model = @import("sinks/memory.zig");

    const TraceState = struct {
        trace_context: TraceContext,

        fn current(ptr: *anyopaque) TraceContext {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.trace_context;
        }
    };

    var trace_state = TraceState{
        .trace_context = .{
            .trace_id = "trc_01",
            .span_id = "spn_01",
            .request_id = "req_01",
        },
    };

    var memory_sink = memory_sink_model.MemorySink.init(std.testing.allocator, 4);
    defer memory_sink.deinit();

    var logger = Logger.initWithOptions(memory_sink.asLogSink(), .{
        .min_level = .info,
        .trace_context_provider = .{
            .ptr = @ptrCast(&trace_state),
            .current = TraceState.current,
        },
    });
    defer logger.deinit();

    logger.child("runtime").info("dispatch started", &.{});

    try std.testing.expectEqualStrings("trc_01", memory_sink.latest().?.trace_id.?);
    try std.testing.expectEqualStrings("spn_01", memory_sink.latest().?.span_id.?);
    try std.testing.expectEqualStrings("req_01", memory_sink.latest().?.request_id.?);
}

test "logger tracks subsystem truncation" {
    const memory_sink_model = @import("sinks/memory.zig");

    var memory_sink = memory_sink_model.MemorySink.init(std.testing.allocator, 2);
    defer memory_sink.deinit();

    var logger = Logger.init(memory_sink.asLogSink(), .info);
    defer logger.deinit();

    const long_name = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz";
    logger.child(long_name).info("truncated", &.{});

    const stats = logger.truncationStats();
    try std.testing.expect(stats.truncated_subsystem_count >= 1);
}

test "logger tracks dropped default and runtime fields" {
    const memory_sink_model = @import("sinks/memory.zig");

    var memory_sink = memory_sink_model.MemorySink.init(std.testing.allocator, 4);
    defer memory_sink.deinit();

    var logger = Logger.init(memory_sink.asLogSink(), .info);
    defer logger.deinit();

    const default_fields = [_]LogField{
        LogField.string("f1", "1"),
        LogField.string("f2", "2"),
        LogField.string("f3", "3"),
        LogField.string("f4", "4"),
        LogField.string("f5", "5"),
        LogField.string("f6", "6"),
        LogField.string("f7", "7"),
        LogField.string("f8", "8"),
        LogField.string("f9", "9"),
        LogField.string("f10", "10"),
    };
    const runtime_fields = [_]LogField{
        LogField.string("r1", "1"),
        LogField.string("r2", "2"),
        LogField.string("r3", "3"),
        LogField.string("r4", "4"),
        LogField.string("r5", "5"),
        LogField.string("r6", "6"),
        LogField.string("r7", "7"),
        LogField.string("r8", "8"),
        LogField.string("r9", "9"),
        LogField.string("r10", "10"),
    };

    const subsystem_logger = logger.child("runtime").withFields(default_fields[0..]);
    subsystem_logger.info("field pressure", runtime_fields[0..]);

    const stats = logger.truncationStats();
    try std.testing.expect(stats.dropped_default_fields_count >= 1);
    try std.testing.expect(stats.dropped_runtime_fields_count >= 1);
}

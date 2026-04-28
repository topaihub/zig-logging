const std = @import("std");
const level_model = @import("../core/level.zig");
const record_model = @import("../core/record.zig");
const sink_model = @import("../core/sink.zig");

pub const LogLevel = level_model.LogLevel;
pub const LogField = record_model.LogField;
pub const LogFieldValue = record_model.LogFieldValue;
pub const LogRecord = record_model.LogRecord;
pub const LogSink = sink_model.LogSink;

pub const ConsoleStyle = enum {
    pretty,
    compact,
    json,
};

pub const ConsoleColorMode = enum {
    auto,
    always,
    never,
};

pub const ConsoleStreamRouting = enum {
    split,
    stdout,
    stderr,
};

pub const EmitFn = *const fn (ctx: *anyopaque, to_stderr: bool, bytes: []const u8) anyerror!void;

pub const ConsoleSink = struct {
    min_level: LogLevel = .info,
    style: ConsoleStyle = .pretty,
    color_mode: ConsoleColorMode = .auto,
    stream_routing: ConsoleStreamRouting = .split,
    degraded: bool = false,
    dropped_records: usize = 0,
    emitter_ctx: ?*anyopaque = null,
    emitter_fn: ?EmitFn = null,
    mutex: std.atomic.Mutex = .unlocked,

    const Self = @This();

    const vtable = LogSink.VTable{
        .write = writeErased,
        .flush = flushErased,
        .deinit = deinitErased,
        .name = nameErased,
    };

    pub fn init(min_level: LogLevel, style: ConsoleStyle) Self {
        return .{
            .min_level = min_level,
            .style = style,
            .color_mode = .auto,
        };
    }

    pub fn initWithColorMode(min_level: LogLevel, style: ConsoleStyle, color_mode: ConsoleColorMode) Self {
        return .{
            .min_level = min_level,
            .style = style,
            .color_mode = color_mode,
        };
    }

    pub fn setEmitter(self: *Self, ctx: *anyopaque, emit_fn: EmitFn) void {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();
        self.emitter_ctx = ctx;
        self.emitter_fn = emit_fn;
    }

    pub fn asLogSink(self: *Self) LogSink {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn deinit(_: *Self) void {}

    pub fn flush(_: *Self) void {}

    pub fn write(self: *Self, record: *const LogRecord) void {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();

        if (@intFromEnum(record.level) < @intFromEnum(self.min_level)) {
            return;
        }

        const to_stderr = switch (self.stream_routing) {
            .split => @intFromEnum(record.level) >= @intFromEnum(LogLevel.warn),
            .stdout => false,
            .stderr => true,
        };

        var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var rendered: std.ArrayListUnmanaged(u8) = .empty;
        defer rendered.deinit(std.heap.page_allocator);

        self.renderRecord(record, &rendered, io, to_stderr) catch {
            self.degraded = true;
            self.dropped_records += 1;
            return;
        };

        self.emit(io, to_stderr, rendered.items) catch {
            self.degraded = true;
            self.dropped_records += 1;
        };
    }

    fn renderRecord(self: *Self, record: *const LogRecord, buffer: *std.ArrayListUnmanaged(u8), io: std.Io, to_stderr: bool) !void {
        var temp = std.array_list.Managed(u8).init(std.heap.page_allocator);
        errdefer temp.deinit();
        // 预分配足够的容量（4KB 应该足够大多数日志消息）
        try temp.ensureTotalCapacity(4096);
        var unmanaged = temp.moveToUnmanaged();
        var writer = std.Io.Writer.fromArrayList(&unmanaged);

        switch (self.style) {
            .json => {
                try record.writeJson(&writer);
            },
            .compact => {
                const use_ansi = self.shouldUseAnsi(io, to_stderr);
                try writer.writeByte('[');
                try writeCompactLevel(&writer, record.level, use_ansi);
                try writer.writeAll("] ");
                try writer.print("{s}: {s}", .{ record.subsystem, record.message });
                try appendContext(&writer, record);
                try appendFieldPairs(&writer, record.fields);
            },
            .pretty => {
                const use_ansi = self.shouldUseAnsi(io, to_stderr);
                const ts = try formatPrettyTimestamp(std.heap.page_allocator, record.ts_unix_ms);
                defer std.heap.page_allocator.free(ts);
                try writer.print("{s} ", .{ts});
                try writePrettyLevel(&writer, record.level, use_ansi);
                try writer.writeByte(' ');
                if (!try renderPrettyTyped(&writer, record) and !try renderPrettyRequestSpan(&writer, record) and !try renderPrettyMethodTrace(&writer, record) and !try renderPrettyStepSpan(&writer, record)) {
                    try writer.print("{s}: {s}", .{ record.subsystem, record.message });
                    try appendContext(&writer, record);
                    try appendFieldPairs(&writer, record.fields);
                }
            },
        }

        try writer.writeByte('\n');
        // 从 writer 中获取结果并转换为 unmanaged
        const result = writer.toArrayList();
        buffer.* = .{
            .items = result.items,
            .capacity = result.capacity,
        };
    }

    fn emit(self: *Self, io: std.Io, to_stderr: bool, bytes: []const u8) !void {
        if (self.emitter_fn) |emit_fn| {
            return emit_fn(self.emitter_ctx.?, to_stderr, bytes);
        }

        var local_buffer: [4096]u8 = undefined;
        if (to_stderr) {
            var stderr_file = std.Io.File.stderr();
            var stderr_writer = stderr_file.writer(io, &local_buffer);
            try stderr_writer.interface.writeAll(bytes);
            try stderr_writer.interface.flush();
        } else {
            var stdout_file = std.Io.File.stdout();
            var stdout_writer = stdout_file.writer(io, &local_buffer);
            try stdout_writer.interface.writeAll(bytes);
            try stdout_writer.interface.flush();
        }
    }

    fn shouldUseAnsi(self: *Self, io: std.Io, to_stderr: bool) bool {
        const is_terminal = if (to_stderr)
            std.Io.File.stderr().isTty(io) catch false
        else
            std.Io.File.stdout().isTty(io) catch false;
        return ansiEnabledForMode(self.color_mode, is_terminal);
    }

    fn writeErased(ptr: *anyopaque, record: *const LogRecord) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.write(record);
    }

    fn flushErased(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.flush();
    }

    fn deinitErased(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn nameErased(_: *anyopaque) []const u8 {
        return "console";
    }
};

fn renderPrettyTyped(writer: *std.Io.Writer, record: *const LogRecord) !bool {
    return switch (record.kind) {
        .request => try renderPrettyRequestSpan(writer, record),
        .method => try renderPrettyMethodTrace(writer, record),
        .step => try renderPrettyStepSpan(writer, record),
        .summary => false,
        .generic => false,
    };
}

fn appendContext(writer: *std.Io.Writer, record: *const LogRecord) !void {
    if (record.trace_id) |trace_id| {
        try writer.print(" trace={s}", .{trace_id});
    }
    if (record.request_id) |request_id| {
        try writer.print(" request={s}", .{request_id});
    }
    if (record.error_code) |error_code| {
        try writer.print(" error_code={s}", .{error_code});
    }
    if (record.duration_ms) |duration_ms| {
        try writer.print(" duration_ms={d}", .{duration_ms});
    }
}

fn renderPrettyRequestSpan(writer: *std.Io.Writer, record: *const LogRecord) !bool {
    if (!std.mem.eql(u8, record.subsystem, "request")) return false;

    const trace_id = record.trace_id orelse return false;
    const method = fieldString(record.fields, "method") orelse return false;
    const path = fieldString(record.fields, "path") orelse return false;
    const query = fieldString(record.fields, "query");

    try writer.print("request{{trace_id={s}", .{trace_id});
    if (record.request_id) |request_id| {
        try writer.print(" request_id={s}", .{request_id});
    }
    try writer.print(" method={s} path={s}", .{ method, path });
    if (query) |value| {
        try writer.print(" query={s}", .{value});
    }
    try writer.print("}}: {s}", .{record.message});
    if (record.error_code) |error_code| {
        try writer.print(" error_code={s}", .{error_code});
    }
    if (record.duration_ms) |duration_ms| {
        try writer.print(" duration_ms={d}", .{duration_ms});
    }
    try appendFieldPairsSkipping(writer, record.fields, &.{ "method", "path", "query" });
    return true;
}

fn renderPrettyStepSpan(writer: *std.Io.Writer, record: *const LogRecord) !bool {
    const step = fieldString(record.fields, "step") orelse return false;
    if (!std.mem.eql(u8, record.message, "Step started") and !std.mem.eql(u8, record.message, "Step completed")) return false;

    try writer.print("{s}{{step={s}}}: {s}", .{ record.subsystem, step, record.message });
    try appendContext(writer, record);
    try appendFieldPairsSkipping(writer, record.fields, &.{"step"});
    return true;
}

fn renderPrettyMethodTrace(writer: *std.Io.Writer, record: *const LogRecord) !bool {
    if (!std.mem.eql(u8, record.subsystem, "method")) return false;
    const method = fieldString(record.fields, "method") orelse return false;
    if (!(std.mem.eql(u8, record.message, "ENTRY") or std.mem.eql(u8, record.message, "EXIT") or std.mem.eql(u8, record.message, "ERROR"))) return false;

    if (record.trace_id) |trace_id| {
        try writer.print("TraceId:{s}|{s}|{s}", .{ trace_id, record.message, method });
    } else {
        try writer.print("{s}|{s}", .{ record.message, method });
    }
    try appendFieldPairsSkipping(writer, record.fields, &.{"method"});
    return true;
}

fn fieldString(fields: []const LogField, key: []const u8) ?[]const u8 {
    for (fields) |field| {
        if (!std.mem.eql(u8, field.key, key)) continue;
        return switch (field.value) {
            .string => |text| text,
            else => null,
        };
    }
    return null;
}

fn prettyLevelText(level: LogLevel) []const u8 {
    return switch (level) {
        .trace => "TRACE",
        .debug => "DEBUG",
        .info => "INFO",
        .warn => "WARN",
        .@"error" => "ERROR",
        .fatal => "FATAL",
        .silent => "SILENT",
    };
}

fn ansiEnabledForMode(mode: ConsoleColorMode, is_terminal: bool) bool {
    return switch (mode) {
        .auto => is_terminal,
        .always => true,
        .never => false,
    };
}

fn ansiLevelStart(level: LogLevel) []const u8 {
    return switch (level) {
        .trace, .silent => "\x1b[90m",
        .debug => "\x1b[34m",
        .info => "\x1b[32m",
        .warn => "\x1b[33m",
        .@"error", .fatal => "\x1b[31m",
    };
}

fn writePrettyLevel(writer: *std.Io.Writer, level: LogLevel, use_ansi: bool) !void {
    if (use_ansi) try writer.writeAll(ansiLevelStart(level));
    try writer.print("{s: >5}", .{prettyLevelText(level)});
    if (use_ansi) try writer.writeAll("\x1b[0m");
}

fn writeCompactLevel(writer: *std.Io.Writer, level: LogLevel, use_ansi: bool) !void {
    if (use_ansi) try writer.writeAll(ansiLevelStart(level));
    try writer.writeAll(level.asText());
    if (use_ansi) try writer.writeAll("\x1b[0m");
}

fn formatPrettyTimestamp(allocator: std.mem.Allocator, ts_unix_ms: i64) ![]u8 {
    const seconds = @divFloor(ts_unix_ms, 1000);
    const millis = @mod(ts_unix_ms, 1000);
    const epoch_seconds: u64 = @intCast(seconds);
    const day_seconds = 86_400;
    const days_since_epoch = @divFloor(epoch_seconds, day_seconds);
    const secs_of_day = epoch_seconds % day_seconds;

    const date = civilFromDays(@as(i64, @intCast(days_since_epoch)));
    const hour = secs_of_day / 3600;
    const minute = (secs_of_day % 3600) / 60;
    const second = secs_of_day % 60;

    var managed = std.array_list.Managed(u8).init(allocator);
    try managed.ensureTotalCapacity(64); // 预分配足够容量用于时间戳格式化
    var buf = managed.moveToUnmanaged();
    defer buf.deinit(allocator);
    var writer = std.Io.Writer.fromArrayList(&buf);

    const year: u64 = @intCast(date.year);
    const month: u8 = date.month;
    const day: u8 = date.day;
    try appendPaddedUnsigned(&writer, year, 4);
    try writer.writeByte('-');
    try appendPaddedUnsigned(&writer, month, 2);
    try writer.writeByte('-');
    try appendPaddedUnsigned(&writer, day, 2);
    try writer.writeByte('T');
    try appendPaddedUnsigned(&writer, hour, 2);
    try writer.writeAll(":");
    try appendPaddedUnsigned(&writer, minute, 2);
    try writer.writeAll(":");
    try appendPaddedUnsigned(&writer, second, 2);
    try writer.writeAll(".");
    try appendPaddedUnsigned(&writer, millis, 3);
    try writer.writeByte('Z');

    // 获取写入的数据
    const list = writer.toArrayList();
    return allocator.dupe(u8, list.items);
}

const CivilDate = struct {
    year: i64,
    month: u8,
    day: u8,
};

fn civilFromDays(z: i64) CivilDate {
    const z_adj = z + 719468;
    const era = @divFloor(if (z_adj >= 0) z_adj else z_adj - 146096, 146097);
    const doe = z_adj - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: i64 = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m: i64 = mp + (if (mp < 10) @as(i64, 3) else @as(i64, -9));
    return .{
        .year = y + (if (m <= 2) @as(i64, 1) else @as(i64, 0)),
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

fn appendPaddedUnsigned(writer: *std.Io.Writer, value: anytype, width: usize) !void {
    var buffer: [20]u8 = undefined;
    var current = @as(u64, @intCast(value));
    var index: usize = buffer.len;

    if (current == 0) {
        index -= 1;
        buffer[index] = '0';
    } else {
        while (current > 0) {
            index -= 1;
            buffer[index] = @as(u8, @intCast('0' + (current % 10)));
            current /= 10;
        }
    }

    const digits = buffer.len - index;
    var pad: usize = width;
    while (pad > digits) : (pad -= 1) {
        try writer.writeByte('0');
    }
    try writer.writeAll(buffer[index..]);
}

fn appendFieldPairs(writer: anytype, fields: []const LogField) !void {
    for (fields) |field| {
        try writer.print(" {s}=", .{field.key});
        try appendFieldValue(writer, field.value);
    }
}

fn appendFieldPairsSkipping(writer: anytype, fields: []const LogField, skipped: []const []const u8) !void {
    field_loop: for (fields) |field| {
        for (skipped) |key| {
            if (std.mem.eql(u8, field.key, key)) continue :field_loop;
        }
        try writer.print(" {s}=", .{field.key});
        try appendFieldValue(writer, field.value);
    }
}

fn appendFieldValue(writer: anytype, value: LogFieldValue) !void {
    switch (value) {
        .string => |text| try writer.print("\"{s}\"", .{text}),
        .int => |number| try writer.print("{}", .{number}),
        .uint => |number| try writer.print("{}", .{number}),
        .float => |number| try writer.print("{}", .{number}),
        .bool => |flag| try writer.writeAll(if (flag) "true" else "false"),
        .null => try writer.writeAll("null"),
    }
}

test "console sink split routing keeps stdout and stderr separated" {
    const Capture = struct {
        allocator: std.mem.Allocator,
        stdout: std.ArrayListUnmanaged(u8) = .empty,
        stderr: std.ArrayListUnmanaged(u8) = .empty,

        fn deinit(self: *@This()) void {
            self.stdout.deinit(self.allocator);
            self.stderr.deinit(self.allocator);
        }

        fn emit(ptr: *anyopaque, to_stderr: bool, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (to_stderr) {
                try self.stderr.appendSlice(self.allocator, bytes);
            } else {
                try self.stdout.appendSlice(self.allocator, bytes);
            }
        }
    };

    var capture = Capture{ .allocator = std.testing.allocator };
    defer capture.deinit();

    var sink = ConsoleSink.initWithColorMode(.trace, .json, .always);
    sink.setEmitter(&capture, Capture.emit);

    const info_record = LogRecord{
        .ts_unix_ms = 10,
        .level = .info,
        .subsystem = "runtime/dispatch",
        .message = "command started",
    };
    const error_record = LogRecord{
        .ts_unix_ms = 11,
        .level = .@"error",
        .subsystem = "runtime/dispatch",
        .message = "command failed",
        .trace_id = "trc_01",
    };
    sink.write(&info_record);
    sink.write(&error_record);

    try std.testing.expect(std.mem.indexOf(u8, capture.stdout.items, "\"level\":\"info\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr.items, "\"level\":\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout.items, "\x1b[") == null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr.items, "\x1b[") == null);
}

test "console sink routes json output to stdout when requested" {
    const Capture = struct {
        allocator: std.mem.Allocator,
        stdout: std.ArrayListUnmanaged(u8) = .empty,
        stderr: std.ArrayListUnmanaged(u8) = .empty,

        fn deinit(self: *@This()) void {
            self.stdout.deinit(self.allocator);
            self.stderr.deinit(self.allocator);
        }

        fn emit(ptr: *anyopaque, to_stderr: bool, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (to_stderr) {
                try self.stderr.appendSlice(self.allocator, bytes);
            } else {
                try self.stdout.appendSlice(self.allocator, bytes);
            }
        }
    };

    var capture = Capture{ .allocator = std.testing.allocator };
    defer capture.deinit();

    var sink = ConsoleSink.initWithColorMode(.trace, .json, .always);
    sink.stream_routing = .stdout;
    sink.setEmitter(&capture, Capture.emit);

    const record = LogRecord{
        .ts_unix_ms = 12,
        .level = .warn,
        .subsystem = "runtime/dispatch",
        .message = "command started",
    };
    sink.write(&record);

    try std.testing.expect(std.mem.indexOf(u8, capture.stdout.items, "\"level\":\"warn\"") != null);
    try std.testing.expectEqual(@as(usize, 0), capture.stderr.items.len);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout.items, "\x1b[") == null);
}

test "console sink routes pretty output to stderr when requested" {
    const Capture = struct {
        allocator: std.mem.Allocator,
        stdout: std.ArrayListUnmanaged(u8) = .empty,
        stderr: std.ArrayListUnmanaged(u8) = .empty,

        fn deinit(self: *@This()) void {
            self.stdout.deinit(self.allocator);
            self.stderr.deinit(self.allocator);
        }

        fn emit(ptr: *anyopaque, to_stderr: bool, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (to_stderr) {
                try self.stderr.appendSlice(self.allocator, bytes);
            } else {
                try self.stdout.appendSlice(self.allocator, bytes);
            }
        }
    };

    var capture = Capture{ .allocator = std.testing.allocator };
    defer capture.deinit();

    var sink = ConsoleSink.initWithColorMode(.trace, .pretty, .never);
    sink.stream_routing = .stderr;
    sink.setEmitter(&capture, Capture.emit);

    const record = LogRecord{
        .ts_unix_ms = 13,
        .level = .info,
        .subsystem = "runtime/dispatch",
        .message = "stderr only",
    };
    sink.write(&record);

    try std.testing.expectEqual(@as(usize, 0), capture.stdout.items.len);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr.items, "INFO runtime/dispatch: stderr only") != null);
}

test "console sink pretty and compact output differ" {
    const Capture = struct {
        allocator: std.mem.Allocator,
        stdout: std.ArrayListUnmanaged(u8) = .empty,

        fn deinit(self: *@This()) void {
            self.stdout.deinit(self.allocator);
        }

        fn emit(ptr: *anyopaque, _: bool, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try self.stdout.appendSlice(self.allocator, bytes);
        }
    };

    const record = LogRecord{
        .ts_unix_ms = 22,
        .level = .info,
        .subsystem = "config",
        .message = "field updated",
        .fields = &.{LogField.string("path", "gateway.port")},
    };

    var pretty_capture = Capture{ .allocator = std.testing.allocator };
    defer pretty_capture.deinit();
    var pretty_sink = ConsoleSink.initWithColorMode(.trace, .pretty, .never);
    pretty_sink.setEmitter(&pretty_capture, Capture.emit);
    pretty_sink.write(&record);

    var compact_capture = Capture{ .allocator = std.testing.allocator };
    defer compact_capture.deinit();
    var compact_sink = ConsoleSink.initWithColorMode(.trace, .compact, .never);
    compact_sink.setEmitter(&compact_capture, Capture.emit);
    compact_sink.write(&record);

    try std.testing.expect(std.mem.indexOf(u8, pretty_capture.stdout.items, "INFO config: field updated") != null);
    try std.testing.expect(std.mem.indexOf(u8, pretty_capture.stdout.items, "1970-01-01T00:00:00.022Z") != null);
    try std.testing.expect(std.mem.indexOf(u8, compact_capture.stdout.items, "[info] config: field updated") != null);
    try std.testing.expect(std.mem.indexOf(u8, pretty_capture.stdout.items, "\x1b[") == null);
    try std.testing.expect(std.mem.indexOf(u8, compact_capture.stdout.items, "\x1b[") == null);
}

test "console sink colors level tokens in always mode" {
    const Capture = struct {
        allocator: std.mem.Allocator,
        stdout: std.ArrayListUnmanaged(u8) = .empty,

        fn deinit(self: *@This()) void {
            self.stdout.deinit(self.allocator);
        }

        fn emit(ptr: *anyopaque, _: bool, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try self.stdout.appendSlice(self.allocator, bytes);
        }
    };

    const pretty_record = LogRecord{
        .ts_unix_ms = 22,
        .level = .warn,
        .subsystem = "config",
        .message = "field updated",
    };

    var pretty_capture = Capture{ .allocator = std.testing.allocator };
    defer pretty_capture.deinit();
    var pretty_sink = ConsoleSink.initWithColorMode(.trace, .pretty, .always);
    pretty_sink.setEmitter(&pretty_capture, Capture.emit);
    pretty_sink.write(&pretty_record);

    try std.testing.expect(std.mem.indexOf(u8, pretty_capture.stdout.items, "\x1b[33m WARN\x1b[0m") != null);

    const compact_record = LogRecord{
        .ts_unix_ms = 22,
        .level = .info,
        .subsystem = "config",
        .message = "field updated",
    };

    var compact_capture = Capture{ .allocator = std.testing.allocator };
    defer compact_capture.deinit();
    var compact_sink = ConsoleSink.initWithColorMode(.trace, .compact, .always);
    compact_sink.setEmitter(&compact_capture, Capture.emit);
    compact_sink.write(&compact_record);

    try std.testing.expect(std.mem.indexOf(u8, compact_capture.stdout.items, "[\x1b[32minfo\x1b[0m] config: field updated") != null);
}

test "console color mode auto follows terminal state" {
    try std.testing.expect(ansiEnabledForMode(.always, false));
    try std.testing.expect(!ansiEnabledForMode(.never, true));
    try std.testing.expect(ansiEnabledForMode(.auto, true));
    try std.testing.expect(!ansiEnabledForMode(.auto, false));
}

test "console sink pretty renders request span style" {
    const Capture = struct {
        allocator: std.mem.Allocator,
        stdout: std.ArrayListUnmanaged(u8) = .empty,

        fn deinit(self: *@This()) void {
            self.stdout.deinit(self.allocator);
        }

        fn emit(ptr: *anyopaque, _: bool, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try self.stdout.appendSlice(self.allocator, bytes);
        }
    };

    const record = LogRecord{
        .ts_unix_ms = 22,
        .level = .info,
        .kind = .request,
        .subsystem = "request",
        .message = "Request completed",
        .trace_id = "trc_01",
        .request_id = "req_01",
        .fields = &.{
            LogField.string("method", "GET"),
            LogField.string("path", "/health"),
            LogField.string("query", "None"),
            LogField.uint("status", 200),
            LogField.uint("duration_ms", 4),
        },
    };

    var capture = Capture{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var sink = ConsoleSink.initWithColorMode(.trace, .pretty, .never);
    sink.setEmitter(&capture, Capture.emit);
    sink.write(&record);

    try std.testing.expect(std.mem.indexOf(u8, capture.stdout.items, "request{trace_id=trc_01 request_id=req_01 method=GET path=/health query=None}: Request completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout.items, "status=200") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout.items, "duration_ms=4") != null);
}

test "console sink pretty renders step trace style" {
    const Capture = struct {
        allocator: std.mem.Allocator,
        stdout: std.ArrayListUnmanaged(u8) = .empty,

        fn deinit(self: *@This()) void {
            self.stdout.deinit(self.allocator);
        }

        fn emit(ptr: *anyopaque, _: bool, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try self.stdout.appendSlice(self.allocator, bytes);
        }
    };

    const record = LogRecord{
        .ts_unix_ms = 22,
        .level = .warn,
        .kind = .step,
        .subsystem = "runtime/provider",
        .message = "Step completed",
        .fields = &.{
            LogField.string("step", "request"),
            LogField.uint("duration_ms", 31),
            LogField.boolean("beyond_threshold", true),
            LogField.uint("threshold_ms", 10),
            LogField.string("error_code", "PROVIDER_TIMEOUT"),
        },
    };

    var capture = Capture{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var sink = ConsoleSink.initWithColorMode(.trace, .pretty, .never);
    sink.setEmitter(&capture, Capture.emit);
    sink.write(&record);

    try std.testing.expect(std.mem.indexOf(u8, capture.stdout.items, "runtime/provider{step=request}: Step completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout.items, "duration_ms=31") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout.items, "beyond_threshold=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout.items, "error_code=\"PROVIDER_TIMEOUT\"") != null);
}

test "console sink pretty renders method trace style" {
    const Capture = struct {
        allocator: std.mem.Allocator,
        stdout: std.ArrayListUnmanaged(u8) = .empty,

        fn deinit(self: *@This()) void {
            self.stdout.deinit(self.allocator);
        }

        fn emit(ptr: *anyopaque, _: bool, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try self.stdout.appendSlice(self.allocator, bytes);
        }
    };

    const record = LogRecord{
        .ts_unix_ms = 22,
        .level = .info,
        .kind = .method,
        .subsystem = "method",
        .message = "EXIT",
        .trace_id = "trc_01",
        .fields = &.{
            LogField.string("method", "Controller.Auth.Login"),
            LogField.string("result", "Ok(200)"),
            LogField.string("status", "SUCCESS"),
            LogField.uint("duration_ms", 542),
            LogField.string("type", "SYNC"),
        },
    };

    var capture = Capture{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var sink = ConsoleSink.initWithColorMode(.trace, .pretty, .never);
    sink.setEmitter(&capture, Capture.emit);
    sink.write(&record);

    try std.testing.expect(std.mem.indexOf(u8, capture.stdout.items, "TraceId:trc_01|EXIT|Controller.Auth.Login") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout.items, "result=\"Ok(200)\"") != null);
}

test "console sink supports concurrent writes without degrading" {
    const Capture = struct {
        allocator: std.mem.Allocator,
        mutex: std.atomic.Mutex = .unlocked,
        stdout: std.ArrayListUnmanaged(u8) = .empty,

        fn deinit(self: *@This()) void {
            self.stdout.deinit(self.allocator);
        }

        fn emit(ptr: *anyopaque, _: bool, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            while (!self.mutex.tryLock()) {}
            defer self.mutex.unlock();
            try self.stdout.appendSlice(self.allocator, bytes);
        }
    };

    const Writer = struct {
        fn run(sink: *ConsoleSink, index: usize) void {
            const record = LogRecord{
                .ts_unix_ms = @intCast(index),
                .level = .info,
                .subsystem = "console-concurrency",
                .message = "write",
            };
            var i: usize = 0;
            while (i < 50) : (i += 1) sink.write(&record);
        }
    };

    var capture = Capture{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var sink = ConsoleSink.initWithColorMode(.trace, .compact, .never);
    sink.setEmitter(&capture, Capture.emit);

    const threads = [_]std.Thread{
        try std.Thread.spawn(.{}, Writer.run, .{ &sink, 0 }),
        try std.Thread.spawn(.{}, Writer.run, .{ &sink, 1 }),
        try std.Thread.spawn(.{}, Writer.run, .{ &sink, 2 }),
    };
    for (threads) |thread| thread.join();

    try std.testing.expect(!sink.degraded);
    try std.testing.expect(std.mem.count(u8, capture.stdout.items, "\n") == 150);
}

const std = @import("std");
const record_model = @import("../../core/record.zig");
const sink_model = @import("../../core/sink.zig");
const level_model = @import("../../core/level.zig");
const trace_formatter = @import("formatter.zig");

pub const LogRecord = record_model.LogRecord;
pub const LogSink = sink_model.LogSink;
pub const LogLevel = level_model.LogLevel;

/// TraceConsoleSink outputs logs to stdout in trace format: [HH:MM:SS LVL] TraceId:xxx|Message|Field:value
pub const TraceConsoleSink = struct {
    min_level: LogLevel,
    mutex: std.atomic.Mutex = .unlocked,

    const Self = @This();

    const vtable = LogSink.VTable{
        .write = writeErased,
        .flush = flushErased,
        .deinit = deinitErased,
        .name = nameErased,
    };

    pub fn init(min_level: LogLevel) Self {
        return .{
            .min_level = min_level,
        };
    }

    pub fn deinit(_: *Self) void {}

    pub fn asLogSink(self: *Self) LogSink {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn write(self: *Self, record: *const LogRecord) void {
        if (@intFromEnum(record.level) < @intFromEnum(self.min_level)) return;

        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();

        var buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const allocator = fba.allocator();

        var allocating_writer = std.Io.Writer.Allocating.init(allocator);
        const writer = &allocating_writer.writer;

        trace_formatter.formatRecord(writer, record) catch return;

        const result = allocating_writer.toArrayList();

        // 使用 Threaded Io 输出到 stdout
        var local_buffer: [4096]u8 = undefined;
        var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var stdout_file = std.Io.File.stdout();
        var stdout_writer = stdout_file.writer(io, &local_buffer);
        stdout_writer.interface.writeAll(result.items) catch return;
        stdout_writer.interface.writeByte('\n') catch return;
        stdout_writer.interface.flush() catch return;
    }

    pub fn flush(_: *Self) void {}

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
        return "trace_console";
    }
};

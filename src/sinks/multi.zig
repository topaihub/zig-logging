const std = @import("std");
const sink_model = @import("../core/sink.zig");
const record_model = @import("../core/record.zig");

pub const LogSink = sink_model.LogSink;
pub const LogRecord = record_model.LogRecord;

pub const MultiSink = struct {
    allocator: std.mem.Allocator,
    sinks: []LogSink,

    const Self = @This();

    const vtable = LogSink.VTable{
        .write = writeErased,
        .flush = flushErased,
        .deinit = deinitErased,
        .name = nameErased,
    };

    pub fn init(allocator: std.mem.Allocator, sinks: []const LogSink) !Self {
        return .{
            .allocator = allocator,
            .sinks = try allocator.dupe(LogSink, sinks),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.sinks);
    }

    pub fn asLogSink(self: *Self) LogSink {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn write(self: *Self, record: *const LogRecord) void {
        for (self.sinks) |sink| {
            sink.write(record);
        }
    }

    pub fn flush(self: *Self) void {
        for (self.sinks) |sink| {
            sink.flush();
        }
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
        return "multi";
    }
};

test "multi sink fans out and isolates degraded sink" {
    const memory_sink_model = @import("memory.zig");
    const console_sink_model = @import("console.zig");

    const FailingEmitter = struct {
        fn emit(_: *anyopaque, _: bool, _: []const u8) anyerror!void {
            return error.EmitFailed;
        }
    };

    var memory_sink = memory_sink_model.MemorySink.init(std.testing.allocator, 4);
    defer memory_sink.deinit();

    var console_sink = console_sink_model.ConsoleSink.init(.trace, .compact);
    console_sink.setEmitter(@ptrFromInt(1), FailingEmitter.emit);

    var multi_sink = try MultiSink.init(std.testing.allocator, &.{
        console_sink.asLogSink(),
        memory_sink.asLogSink(),
    });
    defer multi_sink.deinit();

    const record = LogRecord{
        .ts_unix_ms = 1,
        .level = .info,
        .subsystem = "runtime",
        .message = "fanout",
    };

    multi_sink.write(&record);

    try std.testing.expect(console_sink.degraded);
    try std.testing.expectEqual(@as(usize, 1), memory_sink.count());
    try std.testing.expectEqualStrings("fanout", memory_sink.latest().?.message);
}

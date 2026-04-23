const std = @import("std");
const level_model = @import("../core/level.zig");
const record_model = @import("../core/record.zig");
const sink_model = @import("../core/sink.zig");

pub const LogLevel = level_model.LogLevel;
pub const LogField = record_model.LogField;
pub const LogFieldValue = record_model.LogFieldValue;
pub const LogRecord = record_model.LogRecord;
pub const LogRecordKind = record_model.LogRecordKind;
pub const LogSink = sink_model.LogSink;

pub const StoredLogRecord = struct {
    ts_unix_ms: i64,
    level: LogLevel,
    kind: LogRecordKind,
    subsystem: []const u8,
    message: []const u8,
    trace_id: ?[]const u8 = null,
    span_id: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
    error_code: ?[]const u8 = null,
    duration_ms: ?u64 = null,
    fields: []LogField = &.{},

    pub fn clone(allocator: std.mem.Allocator, record: *const LogRecord) !StoredLogRecord {
        const fields = try allocator.alloc(LogField, record.fields.len);
        errdefer allocator.free(fields);

        for (record.fields, 0..) |field, index| {
            fields[index] = .{
                .key = try allocator.dupe(u8, field.key),
                .value = try cloneFieldValue(allocator, field.value),
            };
        }

        return .{
            .ts_unix_ms = record.ts_unix_ms,
            .level = record.level,
            .kind = record.kind,
            .subsystem = try allocator.dupe(u8, record.subsystem),
            .message = try allocator.dupe(u8, record.message),
            .trace_id = try cloneOptionalString(allocator, record.trace_id),
            .span_id = try cloneOptionalString(allocator, record.span_id),
            .request_id = try cloneOptionalString(allocator, record.request_id),
            .error_code = try cloneOptionalString(allocator, record.error_code),
            .duration_ms = record.duration_ms,
            .fields = fields,
        };
    }

    pub fn deinit(self: *StoredLogRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.subsystem);
        allocator.free(self.message);
        if (self.trace_id) |trace_id| allocator.free(trace_id);
        if (self.span_id) |span_id| allocator.free(span_id);
        if (self.request_id) |request_id| allocator.free(request_id);
        if (self.error_code) |error_code| allocator.free(error_code);

        for (self.fields) |field| {
            allocator.free(field.key);
            switch (field.value) {
                .string => |value| allocator.free(value),
                else => {},
            }
        }
        allocator.free(self.fields);
    }

    pub fn cloneStored(self: *const StoredLogRecord, allocator: std.mem.Allocator) !StoredLogRecord {
        const fields = try allocator.alloc(LogField, self.fields.len);
        errdefer allocator.free(fields);

        for (self.fields, 0..) |field, index| {
            fields[index] = .{
                .key = try allocator.dupe(u8, field.key),
                .value = try cloneFieldValue(allocator, field.value),
            };
        }

        return .{
            .ts_unix_ms = self.ts_unix_ms,
            .level = self.level,
            .kind = self.kind,
            .subsystem = try allocator.dupe(u8, self.subsystem),
            .message = try allocator.dupe(u8, self.message),
            .trace_id = try cloneOptionalString(allocator, self.trace_id),
            .span_id = try cloneOptionalString(allocator, self.span_id),
            .request_id = try cloneOptionalString(allocator, self.request_id),
            .error_code = try cloneOptionalString(allocator, self.error_code),
            .duration_ms = self.duration_ms,
            .fields = fields,
        };
    }
};

pub const MemorySink = struct {
    allocator: std.mem.Allocator,
    capacity: usize,
    records: std.ArrayListUnmanaged(StoredLogRecord) = .empty,
    dropped_records: usize = 0,
    flush_count: usize = 0,
    mutex: std.atomic.Mutex = .unlocked,

    const Self = @This();

    const vtable = LogSink.VTable{
        .write = writeErased,
        .flush = flushErased,
        .deinit = deinitErased,
        .name = nameErased,
    };

    pub fn init(allocator: std.mem.Allocator, capacity: usize) Self {
        return .{
            .allocator = allocator,
            .capacity = capacity,
        };
    }

    pub fn deinit(self: *Self) void {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();
        for (self.records.items) |*record| {
            record.deinit(self.allocator);
        }
        self.records.deinit(self.allocator);
    }

    pub fn asLogSink(self: *Self) LogSink {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn write(self: *Self, record: *const LogRecord) void {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();
        self.appendOwnedRecord(record) catch {
            self.dropped_records += 1;
        };
    }

    pub fn flush(self: *Self) void {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();
        self.flush_count += 1;
    }

    pub fn count(self: *const Self) usize {
        const mutable_self: *Self = @ptrCast(@constCast(self));
        while (!mutable_self.mutex.tryLock()) {}
        defer mutable_self.mutex.unlock();
        return self.records.items.len;
    }

    /// Returns an owned snapshot of all currently buffered records.
    /// Prefer this API in concurrent or long-lived consumers.
    pub fn snapshot(self: *const Self, allocator: std.mem.Allocator) ![]StoredLogRecord {
        const mutable_self: *Self = @ptrCast(@constCast(self));
        while (!mutable_self.mutex.tryLock()) {}
        defer mutable_self.mutex.unlock();

        const cloned = try allocator.alloc(StoredLogRecord, self.records.items.len);
        errdefer allocator.free(cloned);

        for (self.records.items, 0..) |*record, index| {
            cloned[index] = try record.cloneStored(allocator);
            errdefer {
                var i: usize = 0;
                while (i <= index) : (i += 1) cloned[i].deinit(allocator);
            }
        }
        return cloned;
    }

    /// Returns a pointer into internal storage and is only safe for
    /// immediate inspection in controlled/testing scenarios.
    pub fn latest(self: *const Self) ?*const StoredLogRecord {
        const mutable_self: *Self = @ptrCast(@constCast(self));
        while (!mutable_self.mutex.tryLock()) {}
        defer mutable_self.mutex.unlock();
        if (self.records.items.len == 0) {
            return null;
        }
        return &self.records.items[self.records.items.len - 1];
    }

    /// Returns a pointer into internal storage and is only safe for
    /// immediate inspection in controlled/testing scenarios.
    pub fn recordAt(self: *const Self, index: usize) ?*const StoredLogRecord {
        const mutable_self: *Self = @ptrCast(@constCast(self));
        while (!mutable_self.mutex.tryLock()) {}
        defer mutable_self.mutex.unlock();
        if (index >= self.records.items.len) {
            return null;
        }
        return &self.records.items[index];
    }

    fn appendOwnedRecord(self: *Self, record: *const LogRecord) !void {
        if (self.capacity == 0) {
            self.dropped_records += 1;
            return;
        }

        if (self.records.items.len == self.capacity) {
            var oldest = self.records.orderedRemove(0);
            oldest.deinit(self.allocator);
        }

        try self.records.append(self.allocator, try StoredLogRecord.clone(self.allocator, record));
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
        return "memory";
    }
};

fn cloneOptionalString(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |slice| {
        return try allocator.dupe(u8, slice);
    }
    return null;
}

fn cloneFieldValue(allocator: std.mem.Allocator, value: LogFieldValue) !LogFieldValue {
    return switch (value) {
        .string => |slice| .{ .string = try allocator.dupe(u8, slice) },
        .int => |number| .{ .int = number },
        .uint => |number| .{ .uint = number },
        .float => |number| .{ .float = number },
        .bool => |flag| .{ .bool = flag },
        .null => .null,
    };
}

test "memory sink keeps only newest records within capacity" {
    var sink = MemorySink.init(std.testing.allocator, 2);
    defer sink.deinit();

    const first = LogRecord{
        .ts_unix_ms = 1,
        .level = .info,
        .subsystem = "runtime",
        .message = "first",
    };
    const second = LogRecord{
        .ts_unix_ms = 2,
        .level = .warn,
        .subsystem = "runtime",
        .message = "second",
    };
    const third = LogRecord{
        .ts_unix_ms = 3,
        .level = .@"error",
        .subsystem = "runtime",
        .message = "third",
    };

    sink.write(&first);
    sink.write(&second);
    sink.write(&third);

    try std.testing.expectEqual(@as(usize, 2), sink.count());
    try std.testing.expectEqualStrings("second", sink.recordAt(0).?.message);
    try std.testing.expectEqualStrings("third", sink.latest().?.message);
}

test "memory sink clones fields and supports erased interface" {
    var sink = MemorySink.init(std.testing.allocator, 4);
    defer sink.deinit();

    const fields = [_]LogField{
        LogField.string("path", "gateway.port"),
        LogField.boolean("retryable", true),
    };
    const record = LogRecord{
        .ts_unix_ms = 9,
        .level = .info,
        .subsystem = "config",
        .message = "updated",
        .trace_id = "trc_01",
        .fields = fields[0..],
    };

    const log_sink = sink.asLogSink();
    log_sink.write(&record);
    log_sink.flush();

    try std.testing.expectEqualStrings("memory", log_sink.name());
    try std.testing.expectEqual(@as(usize, 1), sink.count());
    try std.testing.expectEqual(@as(usize, 1), sink.flush_count);
    try std.testing.expectEqualStrings("config", sink.latest().?.subsystem);
    try std.testing.expectEqual(LogRecordKind.generic, sink.latest().?.kind);
    try std.testing.expectEqualStrings("gateway.port", sink.latest().?.fields[0].value.string);
}

test "memory sink supports concurrent writes without corrupting storage" {
    const Writer = struct {
        fn run(sink: *MemorySink, index: usize) !void {
            var i: usize = 0;
            while (i < 200) : (i += 1) {
                const record = LogRecord{
                    .ts_unix_ms = @intCast(index * 1000 + i),
                    .level = .info,
                    .subsystem = "concurrency",
                    .message = "write",
                };
                sink.write(&record);
            }
        }
    };

    var sink = MemorySink.init(std.testing.allocator, 2048);
    defer sink.deinit();

    const threads = [_]std.Thread{
        try std.Thread.spawn(.{}, Writer.run, .{ &sink, 0 }),
        try std.Thread.spawn(.{}, Writer.run, .{ &sink, 1 }),
        try std.Thread.spawn(.{}, Writer.run, .{ &sink, 2 }),
        try std.Thread.spawn(.{}, Writer.run, .{ &sink, 3 }),
    };
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(@as(usize, 800), sink.count());
    try std.testing.expect(sink.latest() != null);
}

test "memory sink snapshot returns owned stable copies" {
    var sink = MemorySink.init(std.testing.allocator, 8);
    defer sink.deinit();

    const record = LogRecord{
        .ts_unix_ms = 1,
        .level = .info,
        .subsystem = "snapshot",
        .message = "hello",
        .fields = &.{LogField.string("path", "README.md")},
    };
    sink.write(&record);

    const snapshot = try sink.snapshot(std.testing.allocator);
    defer {
        for (snapshot) |*item| item.deinit(std.testing.allocator);
        std.testing.allocator.free(snapshot);
    }

    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expectEqualStrings("snapshot", snapshot[0].subsystem);
    try std.testing.expectEqualStrings("README.md", snapshot[0].fields[0].value.string);
}

test "memory sink snapshot is safe during concurrent writes" {
    const Writer = struct {
        fn run(sink: *MemorySink, base: usize) !void {
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                const record = LogRecord{
                    .ts_unix_ms = @intCast(base + i),
                    .level = .info,
                    .subsystem = "snapshot-concurrency",
                    .message = "write",
                };
                sink.write(&record);
                const io = std.Io.Threaded.global_single_threaded.*.io();
                io.sleep(std.Io.Duration.fromNanoseconds(1 * std.time.ns_per_ms), .awake) catch {};
            }
        }
    };

    var sink = MemorySink.init(std.testing.allocator, 1024);
    defer sink.deinit();

    const threads = [_]std.Thread{
        try std.Thread.spawn(.{}, Writer.run, .{ &sink, 0 }),
        try std.Thread.spawn(.{}, Writer.run, .{ &sink, 1000 }),
    };

    var sample_count: usize = 0;
    while (sample_count < 20) : (sample_count += 1) {
        const snapshot = try sink.snapshot(std.testing.allocator);
        for (snapshot) |*item| item.deinit(std.testing.allocator);
        std.testing.allocator.free(snapshot);
        const io = std.Io.Threaded.global_single_threaded.*.io();
        io.sleep(std.Io.Duration.fromNanoseconds(2 * std.time.ns_per_ms), .awake) catch {};
    }

    for (threads) |thread| thread.join();
    try std.testing.expect(sink.count() > 0);
}

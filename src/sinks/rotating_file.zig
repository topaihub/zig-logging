const std = @import("std");
const record_model = @import("../core/record.zig");
const sink_model = @import("../core/sink.zig");

pub const LogRecord = record_model.LogRecord;
pub const LogSink = sink_model.LogSink;

pub const LogFormat = enum {
    /// Human-readable: "2026-04-02 23:00:00 INFO server: message key=value"
    text,
    /// Machine-readable: {"ts":1712016000,"level":"info","message":"..."}
    json,
};

pub const RotatingFileSinkConfig = struct {
    /// Directory for log files (created if missing).
    log_dir: []const u8 = "logs",
    /// Filename prefix (e.g. "app" → "logs/app-2026-04-02.log").
    prefix: []const u8 = "app",
    /// Max bytes per file before rotating. Default 100 MB.
    max_file_bytes: u64 = 100 * 1024 * 1024,
    /// Output format.
    format: LogFormat = .text,
};

pub const RotatingFileSink = struct {
    allocator: std.mem.Allocator,
    config: RotatingFileSinkConfig,
    mutex: std.atomic.Mutex = .unlocked,
    current_date: [10]u8 = .{0} ** 10,
    current_file: ?std.Io.File = null,
    current_size: u64 = 0,
    current_part: u32 = 0,
    total_records: u64 = 0,
    dropped_records: u64 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, cfg: RotatingFileSinkConfig) Self {
        const io = std.Io.Threaded.global_single_threaded.*.io();
        std.Io.Dir.cwd().createDirPath(io, cfg.log_dir) catch {};
        return .{ .allocator = allocator, .config = cfg };
    }

    pub fn deinit(self: *Self) void {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();
        if (self.current_file) |*f| {
            const io = std.Io.Threaded.global_single_threaded.*.io();
            f.close(io);
        }
        self.current_file = null;
    }

    pub fn asLogSink(self: *Self) LogSink {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn status(self: *Self) RotatingFileSinkStatus {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();
        return .{
            .total_records = self.total_records,
            .dropped_records = self.dropped_records,
            .current_size = self.current_size,
            .current_part = self.current_part,
            .current_date = self.current_date,
        };
    }

    const vtable = LogSink.VTable{
        .write = writeErased,
        .flush = flushErased,
        .deinit = deinitErased,
        .name = nameErased,
    };

    fn writeErased(ptr: *anyopaque, rec: *const LogRecord) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.writeRecord(rec);
    }

    fn flushErased(_: *anyopaque) void {}

    fn deinitErased(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn nameErased(_: *anyopaque) []const u8 {
        return "rotating_file";
    }

    fn writeRecord(self: *Self, rec: *const LogRecord) void {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();

        // Render log line
        var managed = std.array_list.Managed(u8).init(self.allocator);
        var buf = managed.moveToUnmanaged();
        defer buf.deinit(self.allocator);
        var w = std.Io.Writer.fromArrayList(&buf);

        switch (self.config.format) {
            .json => {
                rec.writeJson(&w) catch {
                    self.dropped_records += 1;
                    return;
                };
            },
            .text => {
                // Format: YYYY-MM-DD HH:MM:SS LEVEL subsystem: message key=value
                // Timestamp
                const ts_secs: u64 = @intCast(if (rec.ts_unix_ms > 0) @divTrunc(rec.ts_unix_ms, 1000) else 0);
                const ts_rem: u64 = @intCast(if (rec.ts_unix_ms > 0) @rem(rec.ts_unix_ms, 1000) else 0);
                var d_buf: [10]u8 = undefined;
                epochToDate(ts_secs, &d_buf);
                const sod = @rem(ts_secs, 86400);
                const hh = sod / 3600;
                const mm = @rem(sod, 3600) / 60;
                const ss = @rem(sod, 60);
                w.print("{s} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} {s}", .{ d_buf, hh, mm, ss, ts_rem, rec.level.asText() }) catch {
                    self.dropped_records += 1;
                    return;
                };
                // Subsystem
                if (rec.subsystem.len > 0) {
                    w.print(" {s}:", .{rec.subsystem}) catch {};
                }
                // Message
                w.print(" {s}", .{rec.message}) catch {};
                // Trace context
                if (rec.trace_id) |tid| {
                    w.print(" trace_id={s}", .{tid}) catch {};
                }
                if (rec.request_id) |rid| {
                    w.print(" request_id={s}", .{rid}) catch {};
                }
                if (rec.span_id) |sid| {
                    w.print(" span_id={s}", .{sid}) catch {};
                }
                // Fields
                for (rec.fields) |field| {
                    w.print(" {s}=", .{field.key}) catch {};
                    switch (field.value) {
                        .string => |s| w.print("{s}", .{s}) catch {},
                        .int => |i| w.print("{d}", .{i}) catch {},
                        .uint => |u| w.print("{d}", .{u}) catch {},
                        .float => |f| w.print("{d:.2}", .{f}) catch {},
                        .bool => |b| w.print("{}", .{b}) catch {},
                        .null => {},
                    }
                }
            },
        }
        buf.append(self.allocator, '\n') catch {
            self.dropped_records += 1;
            return;
        };

        // Get today's date
        const io = std.Io.Threaded.global_single_threaded.*.io();
        const ts = std.Io.Timestamp.now(io, .real);
        const epoch_secs: u64 = @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_s));
        var date_buf: [10]u8 = undefined;
        epochToDate(epoch_secs, &date_buf);

        // Check if we need a new file
        const date_changed = !std.mem.eql(u8, &self.current_date, &date_buf);
        const size_exceeded = self.current_size + buf.items.len > self.config.max_file_bytes;

        if (self.current_file == null or date_changed or size_exceeded) {
            if (self.current_file) |*f| {
                const io_close = std.Io.Threaded.global_single_threaded.*.io();
                f.close(io_close);
            }

            if (date_changed) {
                @memcpy(&self.current_date, &date_buf);
                self.current_part = 0;
            } else if (size_exceeded) {
                self.current_part += 1;
            }
            self.current_size = 0;

            // Build path
            var path_buf: [256]u8 = undefined;
            const path = if (self.current_part == 0)
                std.fmt.bufPrint(&path_buf, "{s}/{s}-{s}.log", .{
                    self.config.log_dir, self.config.prefix, self.current_date,
                }) catch return
            else
                std.fmt.bufPrint(&path_buf, "{s}/{s}-{s}.{d}.log", .{
                    self.config.log_dir, self.config.prefix, self.current_date, self.current_part,
                }) catch return;

            const io_local = std.Io.Threaded.global_single_threaded.*.io();
            std.Io.Dir.cwd().createDirPath(io_local, self.config.log_dir) catch {};
            const file = std.Io.Dir.cwd().createFile(io_local, path, .{ .truncate = false }) catch {
                self.dropped_records += 1;
                return;
            };
            // Seek to end for append
            const io_stat = std.Io.Threaded.global_single_threaded.*.io();
            const stat = file.stat(io_stat) catch {
                const io_close2 = std.Io.Threaded.global_single_threaded.*.io();
                file.close(io_close2);
                self.dropped_records += 1;
                return;
            };
            self.current_size = stat.size;
            self.current_file = file;
        }

        // Write
        if (self.current_file) |f| {
            const io_write = std.Io.Threaded.global_single_threaded.*.io();
            f.writeStreamingAll(io_write, buf.items) catch {
                self.dropped_records += 1;
                return;
            };
            self.current_size += buf.items.len;
            self.total_records += 1;
        }
    }
};

pub const RotatingFileSinkStatus = struct {
    total_records: u64,
    dropped_records: u64,
    current_size: u64,
    current_part: u32,
    current_date: [10]u8,
};

/// Convert Unix epoch seconds to YYYY-MM-DD.
pub fn epochToDate(epoch_secs: u64, buf: *[10]u8) void {
    var d = epoch_secs / 86400;
    var y: u32 = 1970;
    while (true) {
        const diy: u64 = if (isLeap(y)) 366 else 365;
        if (d < diy) break;
        d -= diy;
        y += 1;
    }
    const mdays = if (isLeap(y))
        [_]u8{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    else
        [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var m: u8 = 0;
    while (m < 12) : (m += 1) {
        if (d < mdays[m]) break;
        d -= mdays[m];
    }
    _ = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ y, m + 1, @as(u32, @intCast(d)) + 1 }) catch {};
}

fn isLeap(y: u32) bool {
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
}

test "epochToDate epoch zero is 1970-01-01" {
    var buf: [10]u8 = undefined;
    epochToDate(0, &buf);
    try std.testing.expectEqualStrings("1970-01-01", &buf);
}

test "epochToDate known date" {
    var buf: [10]u8 = undefined;
    // 2024-01-01 00:00:00 UTC = 1704067200
    epochToDate(1704067200, &buf);
    try std.testing.expectEqualStrings("2024-01-01", &buf);
}

test "rotating file sink init and status" {
    var s = RotatingFileSink.init(std.testing.allocator, .{
        .log_dir = "_test_rotating_logs",
        .prefix = "test",
        .max_file_bytes = 1024,
    });
    defer s.deinit();
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, "_test_rotating_logs") catch {};

    const st = s.status();
    try std.testing.expectEqual(@as(u64, 0), st.total_records);
    try std.testing.expectEqual(@as(u64, 0), st.dropped_records);
}

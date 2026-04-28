const std = @import("std");
const record_model = @import("../core/record.zig");
const sink_model = @import("../core/sink.zig");

pub const LogRecord = record_model.LogRecord;
pub const LogSink = sink_model.LogSink;

pub const JsonlFileSinkStatus = struct {
    path: []u8,
    current_bytes: u64,
    max_bytes: ?u64,
    degraded: bool,
    dropped_records: usize,

    pub fn deinit(self: *JsonlFileSinkStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const JsonlFileSink = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    max_bytes: ?u64 = null,
    current_bytes: u64 = 0,
    degraded: bool = false,
    dropped_records: usize = 0,
    mutex: std.atomic.Mutex = .unlocked,

    const Self = @This();

    const vtable = LogSink.VTable{
        .write = writeErased,
        .flush = flushErased,
        .deinit = deinitErased,
        .name = nameErased,
    };

    pub fn init(allocator: std.mem.Allocator, path: []const u8, max_bytes: ?u64, io: std.Io) !Self {
        var self = Self{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .max_bytes = max_bytes,
        };

        self.current_bytes = currentSize(self.path, io);
        return self;
    }

    pub fn deinit(self: *Self) void {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();
        self.allocator.free(self.path);
    }

    pub fn asLogSink(self: *Self) LogSink {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn statusSnapshot(self: *Self, allocator: std.mem.Allocator) !JsonlFileSinkStatus {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();
        return .{
            .path = try allocator.dupe(u8, self.path),
            .current_bytes = self.current_bytes,
            .max_bytes = self.max_bytes,
            .degraded = self.degraded,
            .dropped_records = self.dropped_records,
        };
    }

    pub fn write(self: *Self, record: *const LogRecord) void {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();
        self.writeInternal(record) catch {
            self.degraded = true;
            self.dropped_records += 1;
        };
    }

    pub fn flush(_: *Self) void {}

    fn writeInternal(self: *Self, record: *const LogRecord) !void {
        var allocating_writer = std.Io.Writer.Allocating.init(self.allocator);
        defer allocating_writer.deinit();
        const writer = &allocating_writer.writer;
        try record.writeJson(writer);
        try writer.writeByte('\n');
        var output = allocating_writer.toArrayList();
        defer output.deinit(self.allocator);

        if (self.max_bytes) |max_bytes| {
            if (self.current_bytes + output.items.len > max_bytes) {
                self.dropped_records += 1;
                return;
            }
        }

        try ensureParentDirectory(self.path);
        // Future extension point:
        // before opening the append file, a rotation/retention policy can inspect
        // current_bytes, max_bytes, and on-disk file state to decide whether to
        // rotate the current file or prune old generations.
        var file = try openAppendFile(self.path);
        const io_write = std.Io.Threaded.global_single_threaded.*.io();
        defer file.close(io_write);

        const file_size = try file.length(io_write);
        try file.writePositionalAll(io_write, output.items, file_size);
        self.current_bytes += output.items.len;
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
        return "jsonl_file";
    }
};

fn currentSize(path: []const u8, io: std.Io) u64 {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return 0;
    return stat.size;
}

fn ensureParentDirectory(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir_name| {
        const io = std.Io.Threaded.global_single_threaded.*.io();
        try std.Io.Dir.cwd().createDirPath(io, dir_name);
    }
}

fn openAppendFile(path: []const u8) !std.Io.File {
    const io = std.Io.Threaded.global_single_threaded.*.io();
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false }),
        else => return err,
    };

    return file;
}

test "jsonl file sink creates parent directory and appends records" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);

    const log_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "logs", "app.jsonl" });
    defer std.testing.allocator.free(log_path);

    var sink = try JsonlFileSink.init(std.testing.allocator, log_path, 4096, std.testing.io);
    defer sink.deinit();

    const record = LogRecord{
        .ts_unix_ms = 1,
        .level = .info,
        .subsystem = "config",
        .message = "updated",
    };
    sink.write(&record);
    sink.write(&record);

    const contents = try tmp_dir.dir.readFileAlloc(std.testing.io, "logs/app.jsonl", std.testing.allocator, std.Io.Limit.limited(4096));
    defer std.testing.allocator.free(contents);

    try std.testing.expect(std.mem.count(u8, contents, "\n") == 2);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"subsystem\":\"config\"") != null);
}

test "jsonl file sink respects max bytes limit" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);

    const log_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "limited.jsonl" });
    defer std.testing.allocator.free(log_path);

    var sink = try JsonlFileSink.init(std.testing.allocator, log_path, 80, std.testing.io);
    defer sink.deinit();

    const record = LogRecord{
        .ts_unix_ms = 1,
        .level = .info,
        .subsystem = "runtime/dispatch",
        .message = "command finished with a long message",
    };

    sink.write(&record);
    sink.write(&record);

    try std.testing.expect(sink.dropped_records >= 1);
}

test "jsonl file sink supports concurrent writes" {
    const Writer = struct {
        fn run(sink: *JsonlFileSink, index: usize) void {
            const record = LogRecord{
                .ts_unix_ms = @intCast(index),
                .level = .info,
                .subsystem = "jsonl-concurrency",
                .message = "write",
            };
            var i: usize = 0;
            while (i < 50) : (i += 1) sink.write(&record);
        }
    };

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    const log_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "concurrent.jsonl" });
    defer std.testing.allocator.free(log_path);

    var sink = try JsonlFileSink.init(std.testing.allocator, log_path, 4096 * 64, std.testing.io);
    defer sink.deinit();

    const threads = [_]std.Thread{
        try std.Thread.spawn(.{}, Writer.run, .{ &sink, 0 }),
        try std.Thread.spawn(.{}, Writer.run, .{ &sink, 1 }),
        try std.Thread.spawn(.{}, Writer.run, .{ &sink, 2 }),
    };
    for (threads) |thread| thread.join();

    const contents = try tmp_dir.dir.readFileAlloc(std.testing.io, "concurrent.jsonl", std.testing.allocator, std.Io.Limit.limited(4096 * 64));
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.count(u8, contents, "\n") == 150);
    try std.testing.expect(!sink.degraded);
}

test "jsonl file sink exposes status snapshot" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    const log_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "snapshot.jsonl" });
    defer std.testing.allocator.free(log_path);

    var sink = try JsonlFileSink.init(std.testing.allocator, log_path, 4096, std.testing.io);
    defer sink.deinit();

    const record = LogRecord{
        .ts_unix_ms = 1,
        .level = .info,
        .subsystem = "status",
        .message = "snapshot",
    };
    sink.write(&record);

    var status = try sink.statusSnapshot(std.testing.allocator);
    defer status.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(log_path, status.path);
    try std.testing.expect(status.current_bytes > 0);
    try std.testing.expectEqual(@as(?u64, 4096), status.max_bytes);
    try std.testing.expect(!status.degraded);
}

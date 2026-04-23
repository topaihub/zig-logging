const std = @import("std");
const record_model = @import("../../core/record.zig");
const sink_model = @import("../../core/sink.zig");
const level_model = @import("../../core/level.zig");
const trace_formatter = @import("formatter.zig");

pub const LogRecord = record_model.LogRecord;
pub const LogField = record_model.LogField;
pub const LogFieldValue = record_model.LogFieldValue;
pub const LogSink = sink_model.LogSink;
pub const LogLevel = level_model.LogLevel;

pub const TraceTextFileSinkStatus = struct {
    path: []u8,
    current_bytes: u64,
    max_bytes: ?u64,
    degraded: bool,
    dropped_records: usize,

    pub fn deinit(self: *TraceTextFileSinkStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const TraceTextFileSinkOptions = struct {
    include_observer: bool = false,
    include_runtime_dispatch: bool = false,
    include_framework_method_trace: bool = false,
};

pub const TraceTextFileSink = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    max_bytes: ?u64 = null,
    current_bytes: u64 = 0,
    degraded: bool = false,
    dropped_records: usize = 0,
    options: TraceTextFileSinkOptions = .{},
    mutex: std.atomic.Mutex = .unlocked,

    const Self = @This();

    const vtable = LogSink.VTable{
        .write = writeErased,
        .flush = flushErased,
        .deinit = deinitErased,
        .name = nameErased,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        path: []const u8,
        max_bytes: ?u64,
        options: TraceTextFileSinkOptions,
    ) !Self {
        var self = Self{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .max_bytes = max_bytes,
            .options = options,
        };
        self.current_bytes = currentSize(self.path);
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

    pub fn statusSnapshot(self: *Self, allocator: std.mem.Allocator) !TraceTextFileSinkStatus {
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
        self.writeInternal(record) catch |err| {
            std.debug.print("TraceTextFileSink write error: {}\n", .{err});
        };
    }

    pub fn flush(_: *Self) void {}

    fn writeInternal(self: *Self, record: *const LogRecord) !void {
        if (shouldSkipRecord(record, self.options)) return;

        var temp = std.array_list.Managed(u8).init(self.allocator);
        try temp.ensureTotalCapacity(4096);
        var rendered = temp.moveToUnmanaged();
        defer rendered.deinit(self.allocator);

        var writer = std.Io.Writer.fromArrayList(&rendered);
        try trace_formatter.formatRecord(&writer, record);
        rendered = writer.toArrayList();
        try rendered.append(self.allocator, '\n');

        try ensureParentDirectory(self.path);
        var file = try openAppendFile(self.path);
        const io_write = std.Io.Threaded.global_single_threaded.*.io();
        defer file.close(io_write);

        // 获取当前文件大小，在末尾追加
        const file_size = try file.length(io_write);
        try file.writePositionalAll(io_write, rendered.items, file_size);
        self.current_bytes += rendered.items.len;
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
        return "trace_text_file";
    }
};

fn shouldSkipRecord(record: *const LogRecord, options: TraceTextFileSinkOptions) bool {
    if (!options.include_observer and std.mem.eql(u8, record.subsystem, "observer")) {
        return true;
    }
    if (!options.include_runtime_dispatch and std.mem.startsWith(u8, record.subsystem, "runtime/dispatch")) {
        return true;
    }
    if (!options.include_framework_method_trace and std.mem.eql(u8, record.subsystem, "method")) {
        if (fieldString(record.fields, "method")) |method_name| {
            if (std.mem.startsWith(u8, method_name, "Command.") or std.mem.startsWith(u8, method_name, "AsyncCommand.")) {
                return true;
            }
        }
    }
    return false;
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

fn currentSize(path: []const u8) u64 {
    const io = std.Io.Threaded.global_single_threaded.*.io();
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
    // 不需要 seek，使用 writePositional 在调用处指定偏移量
    return file;
}

test "trace text file sink writes human-readable method trace lines" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);

    const log_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "logs", "trace.log" });
    defer std.testing.allocator.free(log_path);

    var sink = try TraceTextFileSink.init(std.testing.allocator, log_path, 4096, .{});
    defer sink.deinit();

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
    sink.write(&record);

    const contents = try tmp_dir.dir.readFileAlloc(std.testing.io, "logs/trace.log", std.testing.allocator, std.Io.Limit.limited(4096));
    defer std.testing.allocator.free(contents);

    try std.testing.expect(std.mem.indexOf(u8, contents, "[00:00:00 INF] TraceId:trc_01|EXIT|Controller.Auth.Login|Result:Ok(200)|Status:SUCCESS|Duration:542ms|Type:SYNC") != null);
}

test "trace text file sink can skip observer and framework command traces" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);

    const log_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "trace.log" });
    defer std.testing.allocator.free(log_path);

    var sink = try TraceTextFileSink.init(std.testing.allocator, log_path, 4096, .{});
    defer sink.deinit();

    sink.write(&LogRecord{
        .ts_unix_ms = 1,
        .level = .info,
        .subsystem = "observer",
        .message = "observer event",
    });
    sink.write(&LogRecord{
        .ts_unix_ms = 1,
        .level = .debug,
        .kind = .method,
        .subsystem = "method",
        .message = "ENTRY",
        .fields = &.{
            LogField.string("method", "Command.workflow.status"),
            LogField.string("params", "{}"),
        },
    });
    sink.write(&LogRecord{
        .ts_unix_ms = 1,
        .level = .info,
        .kind = .method,
        .subsystem = "method",
        .message = "EXIT",
        .trace_id = "trc_01",
        .fields = &.{
            LogField.string("method", "OpenSpecZig.Status"),
            LogField.string("result", "Ok(status)"),
            LogField.string("status", "SUCCESS"),
            LogField.uint("duration_ms", 1),
            LogField.string("type", "SYNC"),
        },
    });

    const contents = try tmp_dir.dir.readFileAlloc(std.testing.io, "trace.log", std.testing.allocator, std.Io.Limit.limited(4096));
    defer std.testing.allocator.free(contents);

    try std.testing.expect(std.mem.indexOf(u8, contents, "observer event") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "Command.workflow.status") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "OpenSpecZig.Status") != null);
}

test "trace text file sink renders summary trace in ME/RT/BT/ET format" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);

    const log_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "trace.log" });
    defer std.testing.allocator.free(log_path);

    var sink = try TraceTextFileSink.init(std.testing.allocator, log_path, 4096, .{});
    defer sink.deinit();

    sink.write(&LogRecord{
        .ts_unix_ms = 22,
        .level = .warn,
        .kind = .summary,
        .subsystem = "summary",
        .message = "TRACE_SUMMARY",
        .trace_id = "trc_01",
        .fields = &.{
            LogField.string("method", "Auth.Login"),
            LogField.uint("rt", 449),
            LogField.boolean("bt", false),
            LogField.string("et", "N"),
        },
    });

    const contents = try tmp_dir.dir.readFileAlloc(std.testing.io, "trace.log", std.testing.allocator, std.Io.Limit.limited(4096));
    defer std.testing.allocator.free(contents);

    try std.testing.expect(std.mem.indexOf(u8, contents, "[00:00:00 WRN] TraceId:trc_01|ME:Auth.Login|RT:449|BT:N|ET:N") != null);
}

test "trace text file sink supports concurrent writes" {
    const Writer = struct {
        fn run(sink: *TraceTextFileSink, index: usize) void {
            const record = LogRecord{
                .ts_unix_ms = @intCast(index),
                .level = .info,
                .subsystem = "summary",
                .message = "TRACE_SUMMARY",
                .trace_id = "trc_concurrent",
                .fields = &.{
                    LogField.string("method", "Concurrent.Method"),
                    LogField.uint("rt", 1),
                    LogField.boolean("bt", false),
                    LogField.string("et", "N"),
                },
            };
            var i: usize = 0;
            while (i < 40) : (i += 1) sink.write(&record);
        }
    };

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    const log_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "trace.log" });
    defer std.testing.allocator.free(log_path);

    var sink = try TraceTextFileSink.init(std.testing.allocator, log_path, 4096 * 64, .{});
    defer sink.deinit();

    const threads = [_]std.Thread{
        try std.Thread.spawn(.{}, Writer.run, .{ &sink, 0 }),
        try std.Thread.spawn(.{}, Writer.run, .{ &sink, 1 }),
        try std.Thread.spawn(.{}, Writer.run, .{ &sink, 2 }),
    };
    for (threads) |thread| thread.join();

    const contents = try tmp_dir.dir.readFileAlloc(std.testing.io, "trace.log", std.testing.allocator, std.Io.Limit.limited(4096 * 64));
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.count(u8, contents, "\n") >= 90);
    try std.testing.expect(!sink.degraded);
}

test "trace text file sink exposes status snapshot" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    const log_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "trace.log" });
    defer std.testing.allocator.free(log_path);

    var sink = try TraceTextFileSink.init(std.testing.allocator, log_path, 8192, .{});
    defer sink.deinit();

    sink.write(&LogRecord{
        .ts_unix_ms = 1,
        .level = .info,
        .kind = .summary,
        .subsystem = "summary",
        .message = "TRACE_SUMMARY",
        .fields = &.{
            LogField.string("method", "Status.Check"),
            LogField.uint("rt", 1),
            LogField.boolean("bt", false),
            LogField.string("et", "N"),
        },
    });

    var status = try sink.statusSnapshot(std.testing.allocator);
    defer status.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(log_path, status.path);
    try std.testing.expect(status.current_bytes > 0);
    try std.testing.expectEqual(@as(?u64, 8192), status.max_bytes);
    try std.testing.expect(!status.degraded);
}

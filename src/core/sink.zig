const record_model = @import("record.zig");

pub const LogRecord = record_model.LogRecord;

pub const LogSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (ptr: *anyopaque, record: *const LogRecord) void,
        flush: *const fn (ptr: *anyopaque) void,
        deinit: *const fn (ptr: *anyopaque) void,
        name: *const fn (ptr: *anyopaque) []const u8,
    };

    pub fn write(self: LogSink, record: *const LogRecord) void {
        self.vtable.write(self.ptr, record);
    }

    pub fn flush(self: LogSink) void {
        self.vtable.flush(self.ptr);
    }

    pub fn deinit(self: LogSink) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn name(self: LogSink) []const u8 {
        return self.vtable.name(self.ptr);
    }
};

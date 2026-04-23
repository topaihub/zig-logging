# 新增 Sink 开发模板

## LogSink 接口（core/sink.zig）

```zig
pub const LogSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (ptr: *anyopaque, record: *const LogRecord) void,
        flush: *const fn (ptr: *anyopaque) void,
        deinit: *const fn (ptr: *anyopaque) void,
        name: *const fn (ptr: *anyopaque) []const u8,
    };
};
```

每个 sink 必须实现这 4 个方法：write、flush、deinit、name。

## 新增 sink 步骤

### 1. 在 sinks/ 下创建文件

```zig
// sinks/udp.zig
const std = @import("std");
const record_model = @import("../core/record.zig");
const sink_model = @import("../core/sink.zig");

pub const LogRecord = record_model.LogRecord;
pub const LogSink = sink_model.LogSink;

pub const UdpSink = struct {
    // 字段
    allocator: std.mem.Allocator,
    address: []const u8,
    port: u16,
    mutex: std.atomic.Mutex = .unlocked,

    const Self = @This();

    // vtable（编译期常量）
    const vtable = LogSink.VTable{
        .write = writeErased,
        .flush = flushErased,
        .deinit = deinitErased,
        .name = nameErased,
    };

    // 构造
    pub fn init(allocator: std.mem.Allocator, address: []const u8, port: u16) !Self {
        return .{
            .allocator = allocator,
            .address = try allocator.dupe(u8, address),
            .port = port,
        };
    }

    // 析构
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.address);
    }

    // 转为接口（关键方法）
    pub fn asLogSink(self: *Self) LogSink {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    // 具体实现
    pub fn write(self: *Self, record: *const LogRecord) void {
        while (!self.mutex.tryLock()) {}
        defer self.mutex.unlock();
        // ... 序列化 record 并发送 UDP
        _ = record;
    }

    pub fn flush(_: *Self) void {}

    // 类型擦除桥接函数（固定模式，直接复制）
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
        return "udp";
    }
};
```

### 2. 在 root.zig 注册导出

```zig
pub const sinks = struct {
    // ... 已有的
    pub const Udp = @import("sinks/udp.zig").UdpSink;
};
```

### 3. 写测试

```zig
test "udp sink implements LogSink interface" {
    var sink = try UdpSink.init(std.testing.allocator, "127.0.0.1", 9000);
    defer sink.deinit();

    const log_sink = sink.asLogSink();
    try std.testing.expectEqualStrings("udp", log_sink.name());
}
```

## 检查清单

新增 sink 前逐项确认：

- [ ] 文件放在 sinks/ 下（trace 相关放 sinks/trace/）
- [ ] 只引用 core/ 下的类型，不引用 logger.zig 或其他 sink
- [ ] 实现了 vtable 的 4 个方法（write/flush/deinit/name）
- [ ] 有 `asLogSink()` 方法返回 `LogSink` 接口
- [ ] 有 mutex 保护并发写入
- [ ] 有 `deinit` 释放所有分配的资源
- [ ] root.zig 中注册了导出
- [ ] 至少一个测试验证接口实现

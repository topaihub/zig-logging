# 类型系统模式

## Tagged Union（互斥状态）

```zig
const RequestState = union(enum) {
    idle,
    loading,
    success: []const u8,
    failure: anyerror,
};
```

## Distinct Type（防止 ID 混用）

```zig
const UserId = enum(u64) { _ };
const OrderId = enum(u64) { _ };
// 编译器阻止 UserId 和 OrderId 互相赋值
```

## Comptime 验证

```zig
fn Buffer(comptime size: usize) type {
    if (size == 0) @compileError("buffer size must be > 0");
    return struct { data: [size]u8 = undefined, len: usize = 0 };
}
```

## 约定

- 泛型优先 `comptime T: type`，只在真正多态时用 `anytype`
- `switch` 必须穷举所有分支，用 `else => unreachable` 标记不可能的情况
- 日志用 `std.log.scoped(.module_name)`
- 公共 API 必须有 doc comment（`///`）
- 文件内测试紧跟实现代码
- I/O 通过 `io: std.Io` 参数传递

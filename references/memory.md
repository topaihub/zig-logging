# 内存管理规范

## 分配器显式传递

```zig
// ✅ 每个分配函数接受 allocator 参数
fn processData(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();
    // ...
    return list.toOwnedSlice();
}
```

## defer 紧跟资源获取

```zig
const res = try allocator.create(Resource);
defer allocator.destroy(res);  // 紧跟，不要隔行
```

## errdefer 用于错误路径

```zig
fn init(allocator: std.mem.Allocator) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{ .data = try allocator.alloc(u8, 1024) };
    errdefer allocator.free(self.data);
    return self;
}
```

## Arena 用于批量临时分配

```zig
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();  // 一次性释放所有分配
const ally = arena.allocator();
```

## 测试中检测泄漏

```zig
test "no leaks" {
    const allocator = std.testing.allocator;  // 自动报告泄漏+堆栈
    const ptr = try allocator.create(Thing);
    defer allocator.destroy(ptr);
}
```

## 规则

- `defer` 紧跟资源获取
- `errdefer` 用于错误路径清理
- Arena 用于生命周期一致的批量分配
- 测试必须用 `std.testing.allocator`
- 优先 slice 而非裸指针
- 优先 `const` 而非 `var`

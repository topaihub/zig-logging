# 错误处理规范

## 显式 error set

```zig
// ✅ 声明具体的错误类型
const ParseError = error{ InvalidSyntax, UnexpectedToken, EndOfInput };
fn parse(input: []const u8) ParseError!Ast { ... }

// ❌ 隐藏错误类型
fn parse(input: []const u8) anyerror!Ast { ... }
```

## errdefer 清理错误路径

```zig
fn createResource(allocator: std.mem.Allocator) !*Resource {
    const res = try allocator.create(Resource);
    errdefer allocator.destroy(res);  // 仅在错误时执行
    res.* = try initResource();
    return res;
}
```

## 规则

- 每个可能失败的函数声明显式 error set
- `errdefer` 紧跟资源获取，清理错误路径
- `try` 传播错误，`catch` 处理错误
- `catch unreachable` 仅在错误真正不可能时使用
- 错误集可组合：`ErrorSet1 || ErrorSet2`
- 禁止 `_ = mayFail()`（编译器也会报错）

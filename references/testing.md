# 测试规范

## 测试模板

```zig
test "函数名 — 正常路径" {
    const allocator = std.testing.allocator;
    const result = try targetFunction(allocator, valid_input);
    defer allocator.free(result);
    try std.testing.expectEqual(expected, result);
}

test "函数名 — 错误路径" {
    const allocator = std.testing.allocator;
    const result = targetFunction(allocator, invalid_input);
    try std.testing.expectError(error.InvalidInput, result);
}

test "字符串比较" {
    try std.testing.expectEqualStrings("expected", actual);
}
```

## 规则

- 测试必须用 `std.testing.allocator`（自动检测内存泄漏并报告堆栈）
- 测试名描述意图，不用 `test_1`
- 用 `expectEqual`、`expectEqualStrings`、`expectError` 做断言
- 每个公共函数至少一个正常路径 + 一个错误路径测试
- 测试和实现在同一文件（Zig 惯例）
- `zig build test` 必须覆盖所有 `test` 块（build.zig 中用 `addTest` 配置）

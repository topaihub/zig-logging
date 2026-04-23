# zig-logging 项目规范

## 环境

- Zig 0.16.x
- 构建：`zig build`
- 测试：`zig build test`
- 格式化：`zig fmt src/`
- 增量编译：`zig build --watch -fincremental`

## 红线

1. 不使用全局可变状态（禁止模块级 `var`）
2. 不隐藏分配（分配内存的函数必须接受 `std.mem.Allocator` 参数）
3. 不忽略错误（禁止 `_ = mayFail()`）
4. 不用 `@panic` 做常规错误处理
5. 不用 `anyerror` 做返回类型（必须显式 error set）
6. 不修改 build.zig 除非明确要求
7. 不引入新依赖除非明确要求
8. 不推送 main 分支
9. sink 实现不直接引用其他 sink（通过 LogSink 接口通信）
10. sinks/ 下的文件不引用 logger.zig（依赖方向：logger → core ← sinks）

## 验证

```bash
zig fmt --check src/ && zig build && zig build test
```

全部通过才算完成。

## 架构

```
src/
├── core/           ← 接口 + 基础类型（稳定层，很少改）
│   ├── sink.zig    ← LogSink vtable 接口
│   ├── level.zig   ← LogLevel 枚举
│   ├── record.zig  ← LogRecord, LogField
│   └── redact.zig  ← 脱敏工具
├── sinks/          ← sink 实现（可替换层）
│   ├── console.zig
│   ├── jsonl_file.zig
│   ├── rotating_file.zig
│   ├── memory.zig  ← 测试用
│   ├── multi.zig   ← 组合器
│   └── trace/      ← trace 格式子模块
│       ├── console.zig
│       ├── text_file.zig
│       └── formatter.zig  ← 内部，不导出到顶层
├── logger.zig      ← Logger + SubsystemLogger
└── root.zig        ← 精简导出
```

## 依赖方向

```
用户代码 → root.zig → logger.zig → core/sink.zig（接口）
                                       ↑
                        sinks/*（实现）→ core/*（基础类型）
```

- 箭头只能指向 core/，不能反过来
- sinks 之间不互相依赖（MultiSink 持有 LogSink 接口数组，不引用具体 sink）
- 新增 sink 只需在 sinks/ 下加文件 + root.zig 加一行导出

## 参考文档（写代码前必须读对应文件）

- 新增 sink 实现 → 读 `references/sink-pattern.md`
- 用 std.Io / ArrayList 等 0.16 API → 读 `references/zig016.md`
- 写 error union / try / catch → 读 `references/error-handling.md`
- 涉及 allocator / defer / Arena → 读 `references/memory.md`
- 定义 tagged union / comptime 泛型 → 读 `references/type-patterns.md`
- 写测试 → 读 `references/testing.md`

## Commit 格式

```
feat(sinks): 添加 UDP sink
fix(rotating): 修复日期切换时文件未关闭
test(memory): 补充并发写入测试
refactor(core): 精简 LogRecord 字段
```

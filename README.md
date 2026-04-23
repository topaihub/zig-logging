# zig-logging

结构化日志库。基于 vtable 接口的 sink 插件体系。Zig 0.16。

## 架构

```
src/
├── core/           接口 + 基础类型（LogSink vtable、LogLevel、LogRecord）
├── sinks/          可插拔的 sink 实现（console、file、rotating、trace、multi）
│   └── trace/      trace 格式子模块
├── logger.zig      Logger 核心，只依赖 LogSink 接口
└── root.zig        精简导出
```

依赖方向：`logger → core/sink（接口） ← sinks/*（实现） → core/*（基础类型）`

## 快速使用

```zig
const logging = @import("zig-logging");

var console = logging.sinks.Console.init(.info, .pretty);
var logger = logging.Logger.init(console.asLogSink(), .info);
defer logger.deinit();

var log = logger.child("app");
log.info("started", &.{});
```

## 可用 Sink

- `sinks.Console` — 控制台输出（pretty / compact / json）
- `sinks.JsonlFile` — JSONL 文件
- `sinks.RotatingFile` — 按日期+大小自动轮转
- `sinks.Memory` — 内存缓冲（测试用）
- `sinks.Multi` — 组合多个 sink
- `sinks.TraceConsole` — trace 格式控制台
- `sinks.TraceTextFile` — trace 格式文件

## 构建

```bash
zig build              # 构建
zig build test         # 测试（37 个）
zig build run-example  # 运行示例
```

## 新增 Sink

参考 `references/sink-pattern.md`，实现 LogSink 的 4 个 vtable 方法（write / flush / deinit / name），加 `asLogSink()` 转换方法即可。

## AI 开发指引

本项目配置了 `CLAUDE.md` / `AGENTS.md` + `references/` 文档体系，指导 AI Agent 按规范开发：

- `CLAUDE.md` / `AGENTS.md` — 入口，指向 RULES.md
- `references/RULES.md` — 红线、验证命令、架构图、文档索引
- `references/sink-pattern.md` — 新增 sink 的完整模板和检查清单
- `references/zig016.md` — Zig 0.16 关键变更
- `references/error-handling.md` — 错误处理规范
- `references/memory.md` — 内存管理规范
- `references/type-patterns.md` — 类型系统模式
- `references/testing.md` — 测试规范

## License

MIT

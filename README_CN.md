中文 | [English](README.md)

# zig-logging

结构化日志库。基于 vtable 接口的 sink 插件体系。Zig 0.16。

## 快速开始

```zig
const logging = @import("zig-logging");

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa_impl.allocator();

    var managed = try logging.create(allocator, .{
        .level = .info,
        .console = .{ .style = .pretty },
    });
    defer managed.deinit();

    var log = managed.logger.child("app");
    log.info("started", &.{ logging.LogField.string("version", "1.0.0") });
}
```

输出：

```
2026-04-23T03:43:58.690Z  INFO app: started version="1.0.0"
```

## 运行时级别

```zig
var managed = try logging.create(allocator, .{
    .level = .info, // 初始运行时最低级别
    .console = .{
        .style = .pretty,
        .stream_routing = .stderr,
    },
});
defer managed.deinit();

managed.logger.setMinLevel(.debug);
```

把 CLI 参数或 `DEBUG=1` 先转换成 `LogLevel`，再传给 `create()`。日志库本身不解析环境变量。

## 配置方式

`logging.create()` 一行搞定。所有选项都有默认值，按需开启。

### 只要控制台

```zig
var managed = try logging.create(allocator, .{
    .level = .debug,
    .console = .{
        .style = .pretty,        // pretty / compact / json
        .color_mode = .auto,     // auto / always / never
    },
});
defer managed.deinit();
```

`auto` 只在终端上启用 ANSI 颜色。需要强制上色用 `always`，保持纯文本用 `never`。
`stream_routing` 默认是 `.split`；如果 stdout 要给管道数据用，可以改成 `.stderr`。

### trace 格式控制台

输出 `[HH:MM:SS LVL] TraceId:xxx|Message|Field:value` 格式：

```zig
var managed = try logging.create(allocator, .{
    .level = .debug,
    .trace_console = .{ .color_mode = .always },
});
defer managed.deinit();
```

输出：

```
[03:33:24 INF] TraceId:05b287fe|Request started|Method:CHAT|Path:/chat
[03:33:24 ERR] TraceId:05b287fe|ERROR|method:AgentLoop.Run|Status:FAIL|Duration:2482
```

trace 控制台默认只给级别 token 上色，其它部分保持纯文本。

### 按日滚动文件

每天一个新文件，超过指定大小自动分文件：

```zig
var managed = try logging.create(allocator, .{
    .level = .info,
    .rotating = .{
        .log_dir = "logs",
        .prefix = "myapp",
        .max_file_bytes = 10 * 1024 * 1024,  // 10MB，默认值
        .format = .text,                       // text / json
    },
});
defer managed.deinit();
```

生成的文件：

```
logs/
├── myapp-2026-04-23.log       ← 当天第一个文件
├── myapp-2026-04-23.1.log     ← 超过 10MB 后自动分文件
├── myapp-2026-04-23.2.log
└── myapp-2026-04-24.log       ← 第二天自动切换新文件
```

### 控制台 + 文件同时输出

```zig
var managed = try logging.create(allocator, .{
    .level = .info,
    .console = .{ .style = .compact },
    .rotating = .{
        .log_dir = "logs",
        .prefix = "myapp",
    },
});
defer managed.deinit();
```

日志同时输出到控制台和文件，自动组合，不需要手动创建 MultiSink。

### trace 控制台 + trace 文件

```zig
var managed = try logging.create(allocator, .{
    .level = .debug,
    .trace_console = .{},
    .trace_file = .{
        .path = "logs/trace.log",
        .max_bytes = 10 * 1024 * 1024,
    },
});
defer managed.deinit();
```

### JSON Lines 文件

```zig
var managed = try logging.create(allocator, .{
    .level = .info,
    .file = .{
        .path = "logs/app.jsonl",
        .max_bytes = 50 * 1024 * 1024,  // 50MB
    },
});
defer managed.deinit();
```

### 零配置

不传任何选项，默认控制台 pretty 格式，`color_mode = .auto`。

```zig
var managed = try logging.create(allocator, .{});
defer managed.deinit();
```

## 配置参数一览

```zig
logging.create(allocator, .{
    .level = .info,              // 初始运行时最低级别：trace/debug/info/warn/error/fatal
    .console = .{                // 控制台输出（可选）
        .style = .pretty,        //   pretty / compact / json
        .color_mode = .auto,     //   auto / always / never
        .stream_routing = .split, //   split / stdout / stderr
    },
    .trace_console = .{          // trace 格式控制台（可选，和 console 二选一）
        .color_mode = .auto,     //   auto / always / never
    },
    .file = .{                   // JSON Lines 文件（可选）
        .path = "app.jsonl",
        .max_bytes = null,        //   null = 不限大小
    },
    .trace_file = .{             // trace 格式文件（可选）
        .path = "trace.log",
        .max_bytes = null,
    },
    .rotating = .{               // 按日滚动文件（可选）
        .log_dir = "logs",        //   日志目录（自动创建）
        .prefix = "app",          //   文件名前缀
        .max_file_bytes = 10MB,   //   单文件最大大小，超过自动分文件
        .format = .text,          //   text / json
    },
    .redact = .safe,             // 脱敏模式：safe / none
    .trace_provider = provider,  // TraceContext 提供者（可选）
});
```

## 日志 API

```zig
// 创建子系统 logger
var log = managed.logger.child("module_name");

// 基本日志
log.trace("message", &.{});
log.debug("message", &.{});
log.info("message", &.{ logging.LogField.string("key", "value") });
log.warn("message", &.{});
log.@"error"("message", &.{});
log.fatal("message", &.{});

// 带类型的日志（trace 格式用）
log.logKind(.info, .request, "Request started", &.{
    logging.LogField.string("Method", "GET"),
    logging.LogField.string("Path", "/api/users"),
});

// 嵌套子系统
var child = log.child("sub_module");  // → "module_name/sub_module"

// 附加默认字段（每条日志自动携带）
var enriched = log.withField(logging.LogField.string("env", "prod"));
```

## 字段类型

```zig
logging.LogField.string("key", "value")
logging.LogField.int("count", -42)
logging.LogField.uint("port", 8080)
logging.LogField.boolean("active", true)
logging.LogField.float("ratio", 0.95)
logging.LogField.sensitiveString("token", "secret")  // 自动脱敏
```

## 架构

```
src/
├── core/           接口 + 基础类型（稳定层）
│   ├── sink.zig    LogSink vtable 接口
│   ├── level.zig   LogLevel 枚举
│   ├── record.zig  LogRecord, LogField
│   └── redact.zig  脱敏工具
├── sinks/          可插拔 sink 实现
│   ├── console.zig
│   ├── jsonl_file.zig
│   ├── rotating_file.zig   ← 按日滚动 + 按大小分文件
│   ├── memory.zig          ← 测试用
│   ├── multi.zig           ← 组合多个 sink
│   └── trace/
│       ├── console.zig     ← trace 格式控制台
│       ├── text_file.zig   ← trace 格式文件
│       └── formatter.zig
├── config.zig      ← logging.create() 一行配置入口
├── logger.zig      Logger + SubsystemLogger
└── root.zig        导出
```

## 构建

```bash
zig build              # 构建
zig build test         # 测试
zig build run-example  # 运行 basic 示例
```

## 新增 Sink

参考 `references/sink-pattern.md`，实现 LogSink 的 4 个 vtable 方法即可。

## AI 开发指引

- `CLAUDE.md` / `AGENTS.md` — 入口，指向 references/RULES.md
- `references/RULES.md` — 红线、验证命令、架构图、文档索引
- `references/sink-pattern.md` — 新增 sink 的完整模板
- `references/zig016.md` — Zig 0.16 关键变更
- `references/error-handling.md` / `memory.md` / `type-patterns.md` / `testing.md`

## 许可证

MIT

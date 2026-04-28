[中文](README_CN.md) | English

# zig-logging

Structured logging library. Plugin-based sink system built on vtable interfaces. Zig 0.16.

## Quick Start

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

Output:

```
2026-04-23T03:43:58.690Z  INFO app: started version="1.0.0"
```

## Runtime Level

```zig
var managed = try logging.create(allocator, .{
    .level = .info, // initial runtime minimum level
    .console = .{
        .style = .pretty,
        .stream_routing = .stderr,
    },
});
defer managed.deinit();

managed.logger.setMinLevel(.debug);
```

Map CLI flags or `DEBUG=1` to a `LogLevel` in the caller and pass that value into `create()`. The library does not parse env vars itself.

## Configuration

`logging.create()` does it all in one line. All options have defaults — enable only what you need.

### Console Only

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

`auto` only enables ANSI colors on terminals. Use `always` to force color or `never` to keep plain text.
`stream_routing` defaults to `.split`; use `.stderr` when stdout must stay clean for piped data.

### Trace Format Console

Outputs `[HH:MM:SS LVL] TraceId:xxx|Message|Field:value` format:

```zig
var managed = try logging.create(allocator, .{
    .level = .debug,
    .trace_console = .{ .color_mode = .always },
});
defer managed.deinit();
```

Output:

```
[03:33:24 INF] TraceId:05b287fe|Request started|Method:CHAT|Path:/chat
[03:33:24 ERR] TraceId:05b287fe|ERROR|method:AgentLoop.Run|Status:FAIL|Duration:2482
```

The trace console colors the level token by default policy and keeps the rest of the trace text plain.

### Daily Rotating File

One new file per day, automatically split when exceeding the specified size:

```zig
var managed = try logging.create(allocator, .{
    .level = .info,
    .rotating = .{
        .log_dir = "logs",
        .prefix = "myapp",
        .max_file_bytes = 10 * 1024 * 1024,  // 10MB, default
        .format = .text,                       // text / json
    },
});
defer managed.deinit();
```

Generated files:

```
logs/
├── myapp-2026-04-23.log       ← first file of the day
├── myapp-2026-04-23.1.log     ← auto-split after exceeding 10MB
├── myapp-2026-04-23.2.log
└── myapp-2026-04-24.log       ← automatically switches to a new file the next day
```

### Console + File Simultaneous Output

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

Logs are output to both console and file simultaneously, combined automatically — no need to manually create a MultiSink.

### Trace Console + Trace File

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

### JSON Lines File

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

### Zero Configuration

No options needed. Defaults to console pretty format with `color_mode = .auto`.

```zig
var managed = try logging.create(allocator, .{});
defer managed.deinit();
```

## Configuration Reference

```zig
logging.create(allocator, .{
    .level = .info,              // Initial runtime minimum level: trace/debug/info/warn/error/fatal
    .console = .{                // Console output (optional)
        .style = .pretty,        //   pretty / compact / json
        .color_mode = .auto,     //   auto / always / never
        .stream_routing = .split, //   split / stdout / stderr
    },
    .trace_console = .{          // Trace format console (optional, mutually exclusive with console)
        .color_mode = .auto,     //   auto / always / never
    },
    .file = .{                   // JSON Lines file (optional)
        .path = "app.jsonl",
        .max_bytes = null,        //   null = unlimited size
    },
    .trace_file = .{             // Trace format file (optional)
        .path = "trace.log",
        .max_bytes = null,
    },
    .rotating = .{               // Daily rotating file (optional)
        .log_dir = "logs",        //   Log directory (auto-created)
        .prefix = "app",          //   Filename prefix
        .max_file_bytes = 10MB,   //   Max size per file, auto-split when exceeded
        .format = .text,          //   text / json
    },
    .redact = .safe,             // Redaction mode: safe / none
    .trace_provider = provider,  // TraceContext provider (optional)
});
```

## Logging API

```zig
// Create a subsystem logger
var log = managed.logger.child("module_name");

// Basic logging
log.trace("message", &.{});
log.debug("message", &.{});
log.info("message", &.{ logging.LogField.string("key", "value") });
log.warn("message", &.{});
log.@"error"("message", &.{});
log.fatal("message", &.{});

// Typed logging (used with trace format)
log.logKind(.info, .request, "Request started", &.{
    logging.LogField.string("Method", "GET"),
    logging.LogField.string("Path", "/api/users"),
});

// Nested subsystems
var child = log.child("sub_module");  // → "module_name/sub_module"

// Attach default fields (automatically included in every log entry)
var enriched = log.withField(logging.LogField.string("env", "prod"));
```

## Field Types

```zig
logging.LogField.string("key", "value")
logging.LogField.int("count", -42)
logging.LogField.uint("port", 8080)
logging.LogField.boolean("active", true)
logging.LogField.float("ratio", 0.95)
logging.LogField.sensitiveString("token", "secret")  // auto-redacted
```

## Architecture

```
src/
├── core/           Interfaces + base types (stable layer)
│   ├── sink.zig    LogSink vtable interface
│   ├── level.zig   LogLevel enum
│   ├── record.zig  LogRecord, LogField
│   └── redact.zig  Redaction utilities
├── sinks/          Pluggable sink implementations
│   ├── console.zig
│   ├── jsonl_file.zig
│   ├── rotating_file.zig   ← daily rotation + size-based splitting
│   ├── memory.zig          ← for testing
│   ├── multi.zig           ← combines multiple sinks
│   └── trace/
│       ├── console.zig     ← trace format console
│       ├── text_file.zig   ← trace format file
│       └── formatter.zig
├── config.zig      ← logging.create() one-line config entry point
├── logger.zig      Logger + SubsystemLogger
└── root.zig        Exports
```

## Build

```bash
zig build              # build
zig build test         # test
zig build run-example  # run basic example
```

## Adding a New Sink

Refer to `references/sink-pattern.md` — just implement the 4 vtable methods of LogSink.

## AI Development Guide

- `CLAUDE.md` / `AGENTS.md` — entry point, links to references/RULES.md
- `references/RULES.md` — red lines, verification commands, architecture diagram, doc index
- `references/sink-pattern.md` — complete template for adding a new sink
- `references/zig016.md` — key changes in Zig 0.16
- `references/error-handling.md` / `memory.md` / `type-patterns.md` / `testing.md`

## License

MIT

const std = @import("std");

// ── Core: 接口 + 基础类型 ──
pub const LogLevel = @import("core/level.zig").LogLevel;
pub const LogRecord = @import("core/record.zig").LogRecord;
pub const LogRecordKind = @import("core/record.zig").LogRecordKind;
pub const LogField = @import("core/record.zig").LogField;
pub const LogFieldValue = @import("core/record.zig").LogFieldValue;
pub const LogSink = @import("core/sink.zig").LogSink;
pub const RedactMode = @import("core/redact.zig").RedactMode;

// ── Logger ──
pub const Logger = @import("logger.zig").Logger;
pub const SubsystemLogger = @import("logger.zig").SubsystemLogger;
pub const LoggerOptions = @import("logger.zig").LoggerOptions;
pub const TraceContext = @import("logger.zig").TraceContext;
pub const TraceContextProvider = @import("logger.zig").TraceContextProvider;

// ── Sink 实现（按需使用）──
pub const sinks = struct {
    pub const Console = @import("sinks/console.zig").ConsoleSink;
    pub const JsonlFile = @import("sinks/jsonl_file.zig").JsonlFileSink;
    pub const RotatingFile = @import("sinks/rotating_file.zig").RotatingFileSink;
    pub const Memory = @import("sinks/memory.zig").MemorySink;
    pub const Multi = @import("sinks/multi.zig").MultiSink;
    pub const TraceConsole = @import("sinks/trace/console.zig").TraceConsoleSink;
    pub const TraceTextFile = @import("sinks/trace/text_file.zig").TraceTextFileSink;
};

// ── Sink 配置类型 ──
pub const ConsoleStyle = @import("sinks/console.zig").ConsoleStyle;
pub const ConsoleColorMode = @import("sinks/console.zig").ConsoleColorMode;
pub const ConsoleStreamRouting = @import("sinks/console.zig").ConsoleStreamRouting;
pub const RotatingFileSinkConfig = @import("sinks/rotating_file.zig").RotatingFileSinkConfig;
pub const LogFormat = @import("sinks/rotating_file.zig").LogFormat;
pub const TraceTextFileSinkOptions = @import("sinks/trace/text_file.zig").TraceTextFileSinkOptions;

// ── 快速创建（推荐入口）──
const config_mod = @import("config.zig");
pub const LogConfig = config_mod.LogConfig;
pub const ManagedLogger = config_mod.ManagedLogger;
pub const create = config_mod.create;

test {
    std.testing.refAllDecls(@This());
}

test "logging module exports are available" {
    try std.testing.expectEqualStrings("info", LogLevel.info.asText());
    try std.testing.expect(ConsoleStyle.pretty == .pretty);
    try std.testing.expect(ConsoleColorMode.auto == .auto);
    try std.testing.expect(RedactMode.safe == .safe);
}

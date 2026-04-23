const std = @import("std");

pub const LogLevel = enum(u8) {
    trace,
    debug,
    info,
    warn,
    @"error",
    fatal,
    silent,

    pub fn asText(self: LogLevel) []const u8 {
        return switch (self) {
            .trace => "trace",
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .@"error" => "error",
            .fatal => "fatal",
            .silent => "silent",
        };
    }

    pub fn allows(self: LogLevel, message_level: LogLevel) bool {
        if (self == .silent or message_level == .silent) {
            return false;
        }

        return @intFromEnum(message_level) >= @intFromEnum(self);
    }
};

test "log level text values stay stable" {
    try std.testing.expectEqualStrings("trace", LogLevel.trace.asText());
    try std.testing.expectEqualStrings("fatal", LogLevel.fatal.asText());
    try std.testing.expectEqualStrings("silent", LogLevel.silent.asText());
}

test "log level filtering follows severity order" {
    try std.testing.expect(LogLevel.info.allows(.warn));
    try std.testing.expect(LogLevel.info.allows(.info));
    try std.testing.expect(!LogLevel.warn.allows(.debug));
    try std.testing.expect(!LogLevel.silent.allows(.fatal));
}

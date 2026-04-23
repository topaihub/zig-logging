const std = @import("std");
const level_model = @import("level.zig");

pub const LogLevel = level_model.LogLevel;

pub const LogRecordKind = enum {
    generic,
    request,
    step,
    method,
    summary,

    pub fn asText(self: LogRecordKind) []const u8 {
        return switch (self) {
            .generic => "generic",
            .request => "request",
            .step => "step",
            .method => "method",
            .summary => "summary",
        };
    }
};

pub const LogFieldValue = union(enum) {
    string: []const u8,
    int: i64,
    uint: u64,
    float: f64,
    bool: bool,
    null: void,

    pub fn writeJson(self: LogFieldValue, writer: *std.Io.Writer) !void {
        switch (self) {
            .string => |value| try writeJsonString(writer, value),
            .int => |value| try writer.print("{}", .{value}),
            .uint => |value| try writer.print("{}", .{value}),
            .float => |value| try writer.print("{}", .{value}),
            .bool => |value| try writer.writeAll(if (value) "true" else "false"),
            .null => try writer.writeAll("null"),
        }
    }
};

pub const LogField = struct {
    key: []const u8,
    value: LogFieldValue,
    sensitive: bool = false,

    pub fn string(key: []const u8, value: []const u8) LogField {
        return .{ .key = key, .value = .{ .string = value } };
    }

    pub fn int(key: []const u8, value: i64) LogField {
        return .{ .key = key, .value = .{ .int = value } };
    }

    pub fn uint(key: []const u8, value: u64) LogField {
        return .{ .key = key, .value = .{ .uint = value } };
    }

    pub fn float(key: []const u8, value: f64) LogField {
        return .{ .key = key, .value = .{ .float = value } };
    }

    pub fn boolean(key: []const u8, value: bool) LogField {
        return .{ .key = key, .value = .{ .bool = value } };
    }

    pub fn nullValue(key: []const u8) LogField {
        return .{ .key = key, .value = .null };
    }

    pub fn sensitiveString(key: []const u8, value: []const u8) LogField {
        return .{
            .key = key,
            .value = .{ .string = value },
            .sensitive = true,
        };
    }

    pub fn markSensitive(self: LogField) LogField {
        var next = self;
        next.sensitive = true;
        return next;
    }

    pub fn writeJson(self: LogField, writer: *std.Io.Writer) !void {
        try writer.writeByte('{');
        try writeJsonString(writer, "key");
        try writer.writeByte(':');
        try writeJsonString(writer, self.key);
        try writer.writeByte(',');
        try writeJsonString(writer, "value");
        try writer.writeByte(':');
        try self.value.writeJson(writer);
        try writer.writeByte(',');
        try writeJsonString(writer, "sensitive");
        try writer.writeByte(':');
        try writer.writeAll(if (self.sensitive) "true" else "false");
        try writer.writeByte('}');
    }
};

pub const LogRecord = struct {
    ts_unix_ms: i64,
    level: LogLevel,
    kind: LogRecordKind = .generic,
    subsystem: []const u8,
    message: []const u8,
    trace_id: ?[]const u8 = null,
    span_id: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
    error_code: ?[]const u8 = null,
    duration_ms: ?u64 = null,
    fields: []const LogField = &.{},

    pub fn writeJson(self: *const LogRecord, writer: *std.Io.Writer) !void {
        try writer.writeByte('{');

        var first = true;
        try writeNumberField(writer, &first, "tsUnixMs", self.ts_unix_ms);
        try writeStringField(writer, &first, "level", self.level.asText());
        try writeStringField(writer, &first, "kind", self.kind.asText());
        try writeStringField(writer, &first, "subsystem", self.subsystem);
        try writeStringField(writer, &first, "message", self.message);

        if (self.trace_id) |trace_id| {
            try writeStringField(writer, &first, "traceId", trace_id);
        }
        if (self.span_id) |span_id| {
            try writeStringField(writer, &first, "spanId", span_id);
        }
        if (self.request_id) |request_id| {
            try writeStringField(writer, &first, "requestId", request_id);
        }
        if (self.error_code) |error_code| {
            try writeStringField(writer, &first, "errorCode", error_code);
        }
        if (self.duration_ms) |duration_ms| {
            try writeNumberField(writer, &first, "durationMs", duration_ms);
        }
        if (self.fields.len > 0) {
            try beginObjectField(writer, &first, "fields");
            try writer.writeByte('[');
            for (self.fields, 0..) |field, index| {
                if (index > 0) {
                    try writer.writeByte(',');
                }
                try field.writeJson(writer);
            }
            try writer.writeByte(']');
        }

        try writer.writeByte('}');
    }
};

fn beginObjectField(writer: anytype, first: *bool, key: []const u8) !void {
    if (!first.*) {
        try writer.writeByte(',');
    }
    first.* = false;

    try writeJsonString(writer, key);
    try writer.writeByte(':');
}

fn writeStringField(writer: anytype, first: *bool, key: []const u8, value: []const u8) !void {
    try beginObjectField(writer, first, key);
    try writeJsonString(writer, value);
}

fn writeNumberField(writer: anytype, first: *bool, key: []const u8, value: anytype) !void {
    try beginObjectField(writer, first, key);
    try writer.print("{}", .{value});
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 32) {
                    try writer.print("\\u00{x:0>2}", .{ch});
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
    try writer.writeByte('"');
}

test "log field values serialize to json scalars" {
    var allocating_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    const writer = &allocating_writer.writer;

    try LogField.string("path", "gateway.port").writeJson(writer);
    try writer.writeByte('\n');
    try LogField.boolean("retryable", true).writeJson(writer);
    try writer.writeByte('\n');
    try LogField.int("attempt", 3).writeJson(writer);
    try writer.writeByte('\n');
    try LogField.sensitiveString("token", "secret").writeJson(writer);

    var buf = allocating_writer.toArrayList();
    defer buf.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"key\":\"path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"value\":\"gateway.port\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"sensitive\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"value\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"value\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"key\":\"token\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"sensitive\":true") != null);
}

test "log record json contains core structured fields" {
    const fields = [_]LogField{
        LogField.string("path", "gateway.port"),
        LogField.boolean("requires_restart", true),
    };
    const record = LogRecord{
        .ts_unix_ms = 1_741_687_365_123,
        .level = .info,
        .kind = .request,
        .subsystem = "config",
        .message = "config field updated",
        .trace_id = "trc_01",
        .request_id = "req_01",
        .error_code = "CONFIG_WRITE_FAILED",
        .duration_ms = 42,
        .fields = fields[0..],
    };

    var allocating_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    const writer = &allocating_writer.writer;

    try record.writeJson(writer);

    var buf = allocating_writer.toArrayList();
    defer buf.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"level\":\"info\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"kind\":\"request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"subsystem\":\"config\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"traceId\":\"trc_01\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"errorCode\":\"CONFIG_WRITE_FAILED\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"fields\":[") != null);
}

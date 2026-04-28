const std = @import("std");
const record_model = @import("../../core/record.zig");
const level_model = @import("../../core/level.zig");

pub const LogRecord = record_model.LogRecord;
pub const LogField = record_model.LogField;
pub const LogFieldValue = record_model.LogFieldValue;
pub const LogLevel = level_model.LogLevel;

/// Format a log record in trace format: [HH:MM:SS LVL] TraceId:xxx|Message|Field:value
pub const TraceFormatOptions = struct {
    use_color: bool = false,
};

pub fn formatRecord(writer: anytype, record: *const LogRecord) !void {
    try formatRecordWithOptions(writer, record, .{});
}

pub fn formatRecordWithOptions(writer: anytype, record: *const LogRecord, options: TraceFormatOptions) !void {
    const time_text = try formatTimeOfDay(record.ts_unix_ms);
    try writer.writeByte('[');
    try writer.writeAll(time_text[0..]);
    try writer.writeByte(' ');
    try writeShortLevel(writer, record.level, options.use_color);
    try writer.writeAll("] ");

    if (try renderTyped(writer, record)) return;
    if (try renderSummaryTrace(writer, record)) return;
    if (try renderMethodTrace(writer, record)) return;
    if (try renderRequestTrace(writer, record)) return;
    if (try renderStepTrace(writer, record)) return;
    try renderGeneric(writer, record);
}

fn renderTyped(writer: anytype, record: *const LogRecord) !bool {
    return switch (record.kind) {
        .summary => try renderSummaryTrace(writer, record),
        .method => try renderMethodTrace(writer, record),
        .request => try renderRequestTrace(writer, record),
        .step => try renderStepTrace(writer, record),
        .generic => false,
    };
}

fn renderSummaryTrace(writer: anytype, record: *const LogRecord) !bool {
    if (!std.mem.eql(u8, record.subsystem, "summary")) return false;
    if (!std.mem.eql(u8, record.message, "TRACE_SUMMARY")) return false;

    const method_name = fieldString(record.fields, "method") orelse return false;
    const rt = fieldUint(record.fields, "rt") orelse return false;
    const bt = fieldBool(record.fields, "bt") orelse return false;
    const et = fieldString(record.fields, "et") orelse return false;

    try appendTracePrefix(writer, record);
    try writer.print("ME:{s}|RT:{d}|BT:{s}|ET:{s}", .{
        method_name,
        rt,
        if (bt) "Y" else "N",
        et,
    });
    return true;
}

fn renderMethodTrace(writer: anytype, record: *const LogRecord) !bool {
    if (!std.mem.eql(u8, record.subsystem, "method")) return false;
    const method_name = fieldString(record.fields, "method") orelse return false;
    if (!(std.mem.eql(u8, record.message, "ENTRY") or std.mem.eql(u8, record.message, "EXIT") or std.mem.eql(u8, record.message, "ERROR"))) return false;

    try appendTracePrefix(writer, record);
    try writer.print("{s}|{s}", .{ record.message, method_name });

    if (std.mem.eql(u8, record.message, "ENTRY")) {
        if (fieldString(record.fields, "params")) |params| {
            try writer.print("|Params:{s}", .{params});
        }
        return true;
    }

    if (fieldString(record.fields, "result")) |result| {
        try writer.print("|Result:{s}", .{result});
    }
    if (fieldString(record.fields, "status")) |status| {
        try writer.print("|Status:{s}", .{status});
    }
    if (fieldUint(record.fields, "duration_ms")) |duration_ms| {
        try writer.print("|Duration:{d}ms", .{duration_ms});
    }
    if (fieldString(record.fields, "type")) |kind| {
        try writer.print("|Type:{s}", .{kind});
    }
    if (fieldString(record.fields, "exception_type")) |exception_type| {
        try writer.print("|Exception:{s}", .{exception_type});
    }
    if (fieldString(record.fields, "error_code")) |error_code| {
        try writer.print("|ErrorCode:{s}", .{error_code});
    }
    return true;
}

fn renderRequestTrace(writer: anytype, record: *const LogRecord) !bool {
    if (!std.mem.eql(u8, record.subsystem, "request")) return false;

    try appendTracePrefix(writer, record);
    try writer.writeAll(record.message);

    if (fieldString(record.fields, "method")) |method_name| {
        try writer.print("|Method:{s}", .{method_name});
    }
    if (fieldString(record.fields, "path")) |path| {
        try writer.print("|Path:{s}", .{path});
    }
    if (fieldString(record.fields, "query")) |query| {
        try writer.print("|Query:{s}", .{query});
    }
    if (fieldUint(record.fields, "status")) |status| {
        try writer.print("|Status:{d}", .{status});
    }
    if (fieldUint(record.fields, "duration_ms")) |duration_ms| {
        try writer.print("|Duration:{d}ms", .{duration_ms});
    }
    if (fieldString(record.fields, "error_code")) |error_code| {
        try writer.print("|ErrorCode:{s}", .{error_code});
    }
    return true;
}

fn renderStepTrace(writer: anytype, record: *const LogRecord) !bool {
    const step = fieldString(record.fields, "step") orelse return false;
    if (!std.mem.eql(u8, record.message, "Step started") and !std.mem.eql(u8, record.message, "Step completed")) return false;

    try appendTracePrefix(writer, record);
    try writer.print("{s}|Subsystem:{s}|Step:{s}", .{ record.message, record.subsystem, step });

    if (fieldUint(record.fields, "duration_ms")) |duration_ms| {
        try writer.print("|Duration:{d}ms", .{duration_ms});
    }
    if (fieldBool(record.fields, "beyond_threshold")) |beyond_threshold| {
        try writer.print("|BT:{s}", .{if (beyond_threshold) "Y" else "N"});
    }
    if (fieldUint(record.fields, "threshold_ms")) |threshold_ms| {
        try writer.print("|Threshold:{d}ms", .{threshold_ms});
    }
    if (fieldString(record.fields, "error_code")) |error_code| {
        try writer.print("|ErrorCode:{s}", .{error_code});
    }
    return true;
}

fn renderGeneric(writer: anytype, record: *const LogRecord) !void {
    if (record.trace_id != null) {
        try appendTracePrefix(writer, record);
    }
    try writer.writeAll(record.message);
    for (record.fields) |field| {
        try appendLabeledField(writer, field.key, field.value);
    }
}

fn appendTracePrefix(writer: anytype, record: *const LogRecord) !void {
    if (record.trace_id) |trace_id| {
        try writer.print("TraceId:{s}|", .{trace_id});
    }
}

fn appendLabeledField(writer: anytype, key: []const u8, value: LogFieldValue) !void {
    const label = prettyLabel(key);
    switch (value) {
        .string => |text| {
            try writer.print("|{s}:{s}", .{ label, text });
        },
        .int => |number| {
            if (std.mem.eql(u8, key, "duration_ms") or std.mem.eql(u8, key, "threshold_ms")) {
                try writer.print("|{s}:{d}ms", .{ label, number });
            } else {
                try writer.print("|{s}:{d}", .{ label, number });
            }
        },
        .uint => |number| {
            if (std.mem.eql(u8, key, "duration_ms") or std.mem.eql(u8, key, "threshold_ms")) {
                try writer.print("|{s}:{d}ms", .{ label, number });
            } else {
                try writer.print("|{s}:{d}", .{ label, number });
            }
        },
        .float => |number| {
            try writer.print("|{s}:{d}", .{ label, number });
        },
        .bool => |flag| {
            try writer.print("|{s}:{s}", .{ label, if (flag) "Y" else "N" });
        },
        .null => {
            try writer.print("|{s}:null", .{label});
        },
    }
}

fn prettyLabel(key: []const u8) []const u8 {
    if (std.mem.eql(u8, key, "params")) return "Params";
    if (std.mem.eql(u8, key, "result")) return "Result";
    if (std.mem.eql(u8, key, "status")) return "Status";
    if (std.mem.eql(u8, key, "duration_ms")) return "Duration";
    if (std.mem.eql(u8, key, "type")) return "Type";
    if (std.mem.eql(u8, key, "exception_type")) return "Exception";
    if (std.mem.eql(u8, key, "error_code")) return "ErrorCode";
    if (std.mem.eql(u8, key, "threshold_ms")) return "Threshold";
    if (std.mem.eql(u8, key, "beyond_threshold")) return "BT";
    if (std.mem.eql(u8, key, "change_dir")) return "ChangeDir";
    if (std.mem.eql(u8, key, "metadata_path")) return "MetadataPath";
    if (std.mem.eql(u8, key, "change")) return "Change";
    if (std.mem.eql(u8, key, "schema")) return "Schema";
    if (std.mem.eql(u8, key, "project_root")) return "ProjectRoot";
    if (std.mem.eql(u8, key, "config_path")) return "ConfigPath";
    if (std.mem.eql(u8, key, "has_created")) return "HasCreated";
    if (std.mem.eql(u8, key, "is_complete")) return "IsComplete";
    if (std.mem.eql(u8, key, "completed_count")) return "CompletedCount";
    if (std.mem.eql(u8, key, "artifact_count")) return "ArtifactCount";
    if (std.mem.eql(u8, key, "artifact")) return "Artifact";
    if (std.mem.eql(u8, key, "dependency_count")) return "DependencyCount";
    if (std.mem.eql(u8, key, "unlock_count")) return "UnlockCount";
    if (std.mem.eql(u8, key, "has_rules")) return "HasRules";
    if (std.mem.eql(u8, key, "has_context")) return "HasContext";
    if (std.mem.eql(u8, key, "specs_rule_count")) return "SpecsRuleCount";
    if (std.mem.eql(u8, key, "design_rule_count")) return "DesignRuleCount";
    if (std.mem.eql(u8, key, "tasks_rule_count")) return "TasksRuleCount";
    if (std.mem.eql(u8, key, "path")) return "Path";
    if (std.mem.eql(u8, key, "query")) return "Query";
    if (std.mem.eql(u8, key, "step")) return "Step";
    return key;
}

fn fieldString(fields: []const LogField, key: []const u8) ?[]const u8 {
    for (fields) |field| {
        if (!std.mem.eql(u8, field.key, key)) continue;
        return switch (field.value) {
            .string => |text| text,
            else => null,
        };
    }
    return null;
}

fn fieldUint(fields: []const LogField, key: []const u8) ?u64 {
    for (fields) |field| {
        if (!std.mem.eql(u8, field.key, key)) continue;
        return switch (field.value) {
            .uint => |value| value,
            .int => |value| if (value >= 0) @intCast(value) else null,
            else => null,
        };
    }
    return null;
}

fn fieldBool(fields: []const LogField, key: []const u8) ?bool {
    for (fields) |field| {
        if (!std.mem.eql(u8, field.key, key)) continue;
        return switch (field.value) {
            .bool => |value| value,
            else => null,
        };
    }
    return null;
}

fn shortLevelText(level: LogLevel) []const u8 {
    return switch (level) {
        .trace => "TRC",
        .debug => "DBG",
        .info => "INF",
        .warn => "WRN",
        .@"error" => "ERR",
        .fatal => "FTL",
        .silent => "OFF",
    };
}

fn writeShortLevel(writer: anytype, level: LogLevel, use_color: bool) !void {
    if (use_color) try writer.writeAll(ansiLevelStart(level));
    try writer.writeAll(shortLevelText(level));
    if (use_color) try writer.writeAll("\x1b[0m");
}

fn ansiLevelStart(level: LogLevel) []const u8 {
    return switch (level) {
        .trace, .silent => "\x1b[90m",
        .debug => "\x1b[34m",
        .info => "\x1b[32m",
        .warn => "\x1b[33m",
        .@"error", .fatal => "\x1b[31m",
    };
}

fn formatTimeOfDay(ts_unix_ms: i64) ![8]u8 {
    const seconds = @divFloor(ts_unix_ms, 1000);
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const day_seconds = epoch_seconds.getDaySeconds();

    const hour = day_seconds.getHoursIntoDay();
    const minute = day_seconds.getMinutesIntoHour();
    const second = day_seconds.getSecondsIntoMinute();

    var out: [8]u8 = undefined;
    _ = try std.fmt.bufPrint(&out, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hour, minute, second });
    return out;
}

test "trace formatter colors level tokens in always mode" {
    const record_debug = LogRecord{
        .ts_unix_ms = 22,
        .level = .debug,
        .subsystem = "runtime",
        .message = "debug",
    };
    const record_info = LogRecord{
        .ts_unix_ms = 22,
        .level = .info,
        .subsystem = "runtime",
        .message = "info",
    };
    const record_error = LogRecord{
        .ts_unix_ms = 22,
        .level = .@"error",
        .subsystem = "runtime",
        .message = "error",
    };

    var allocating_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer allocating_writer.deinit();
    const writer = &allocating_writer.writer;

    try formatRecordWithOptions(writer, &record_debug, .{ .use_color = true });
    try writer.writeByte('\n');
    try formatRecordWithOptions(writer, &record_info, .{ .use_color = true });
    try writer.writeByte('\n');
    try formatRecordWithOptions(writer, &record_error, .{ .use_color = true });

    var result = allocating_writer.toArrayList();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.items, "\x1b[34mDBG\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.items, "\x1b[32mINF\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.items, "\x1b[31mERR\x1b[0m") != null);
}

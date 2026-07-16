const std = @import("std");
const model = @import("../config/model.zig");
const runtime = @import("../runtime/context.zig");
const xdg = @import("../runtime/xdg.zig");

pub fn writeListPlain(
    context: *runtime.RuntimeContext,
    config: *const model.Config,
) !void {
    var width: usize = 0;
    for (config.values.keys()) |key| width = @max(width, key.len);
    const use_color = supportsAnsi(context);
    for (config.values.keys()) |key| {
        if (use_color) try context.stdout.writeAll("\x1b[38;2;0;255;255m");
        try context.stdout.print("{s}", .{key});
        try context.stdout.splatByteAll(' ', width - key.len);
        if (use_color) try context.stdout.writeAll("\x1b[0m");
        const value = try config.getDisplay(context.allocator, key);
        try context.stdout.print("  {s}\n", .{value orelse "(null)"});
    }
}

pub fn writeDictionaryJson(
    allocator: std.mem.Allocator,
    config: *const model.Config,
    writer: *std.Io.Writer,
) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    for (config.values.keys()) |key| {
        try json.objectField(key);
        const value = try config.getDisplay(allocator, key);
        try json.write(value);
    }
    try json.endObject();
}

pub fn writeSingleValueFrame(
    context: *runtime.RuntimeContext,
    key: []const u8,
    value: []const u8,
) !void {
    var payload = std.Io.Writer.Allocating.init(context.allocator);
    defer payload.deinit();
    var json: std.json.Stringify = .{ .writer = &payload.writer };
    try json.beginObject();
    try json.objectField(key);
    try json.write(value);
    try json.endObject();
    try writeFrame(context, payload.writer.buffered());
}

pub fn writeConfigFrame(context: *runtime.RuntimeContext, config: *const model.Config) !void {
    var payload = std.Io.Writer.Allocating.init(context.allocator);
    defer payload.deinit();
    try writeDictionaryJson(context.allocator, config, &payload.writer);
    try writeFrame(context, payload.writer.buffered());
}

pub fn writeInfoFrame(context: *runtime.RuntimeContext, message: []const u8) !void {
    try writeAlpmInfoFrame(context, "InformationalOutput", message);
}

pub fn writeAlpmInfoFrame(
    context: *runtime.RuntimeContext,
    event_type: []const u8,
    message: []const u8,
) !void {
    var payload = std.Io.Writer.Allocating.init(context.allocator);
    defer payload.deinit();
    var json: std.json.Stringify = .{ .writer = &payload.writer };
    try json.beginObject();
    try json.objectField("$kind");
    try json.write("alpm.info");
    try json.objectField("EventType");
    try json.write(event_type);
    try json.objectField("Message");
    try json.write(message);
    try json.objectField("PackageName");
    try json.write(null);
    try json.objectField("CurrentIndex");
    try json.write(null);
    try json.objectField("TotalCount");
    try json.write(null);
    try json.objectField("Source");
    try json.write("Alpm");
    try json.objectField("Level");
    try json.write("Information");
    try json.objectField("TimeStamp");
    try json.write(try timestamp(context));
    try json.endObject();
    try writeFrame(context, payload.writer.buffered());
}

pub fn writeErrorFrame(context: *runtime.RuntimeContext, message: []const u8) !void {
    var payload = std.Io.Writer.Allocating.init(context.allocator);
    defer payload.deinit();
    var json: std.json.Stringify = .{ .writer = &payload.writer };
    try json.beginObject();
    try json.objectField("$kind");
    try json.write("alpm.error");
    try json.objectField("ErrorMessage");
    try json.write(message);
    try json.objectField("Source");
    try json.write("Alpm");
    try json.objectField("Level");
    try json.write("Error");
    try json.objectField("TimeStamp");
    try json.write(try timestamp(context));
    try json.endObject();
    try writeFrame(context, payload.writer.buffered());
}

pub fn writeSuccess(context: *runtime.RuntimeContext, message: []const u8) !void {
    if (supportsAnsi(context)) {
        try context.stdout.print("\x1b[38;2;0;128;0m{s}\x1b[0m\n", .{message});
    } else {
        try context.stdout.print("{s}\n", .{message});
    }
}

pub fn writeFailure(context: *runtime.RuntimeContext, message: []const u8) !void {
    if (supportsAnsi(context)) {
        try context.stdout.print("\x1b[38;2;255;0;0m{s}\x1b[0m\n", .{message});
    } else {
        try context.stdout.print("{s}\n", .{message});
    }
}

fn writeFrame(context: *runtime.RuntimeContext, payload: []const u8) !void {
    const size = std.base64.standard.Encoder.calcSize(payload.len);
    const encoded = try context.allocator.alloc(u8, size);
    const result = std.base64.standard.Encoder.encode(encoded, payload);
    try context.stdout.print("[JSON]{s}[/JSON]\n", .{result});
}

pub fn supportsAnsi(context: *const runtime.RuntimeContext) bool {
    if (!context.stdin_is_tty or !context.stdout_is_tty) return false;
    if (xdg.getEnv(context, "NO_COLOR") != null) return false;
    if (xdg.getEnv(context, "TERM")) |term| {
        if (std.mem.eql(u8, term, "dumb")) return false;
    }
    return true;
}

fn timestamp(context: *runtime.RuntimeContext) ![]const u8 {
    const seconds = std.Io.Clock.real.now(context.io).toSeconds();
    if (seconds < 0) return error.InvalidTimestamp;
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    return std.fmt.allocPrint(
        context.allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}+00:00",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

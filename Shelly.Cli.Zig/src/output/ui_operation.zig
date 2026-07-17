const std = @import("std");
const Zigalpm = @import("Zigalpm");
const output = @import("config.zig");
const runtime = @import("../runtime/context.zig");

pub const Reporter = struct {
    context: *runtime.RuntimeContext,
    mutex: std.Io.Mutex = .init,
    write_failed: std.atomic.Value(bool) = .init(false),

    pub fn handle(data: ?*anyopaque, event: Zigalpm.OperationEvent) void {
        const self: *Reporter = @ptrCast(@alignCast(data.?));
        self.mutex.lockUncancelable(self.context.io);
        defer self.mutex.unlock(self.context.io);
        self.write(event) catch self.write_failed.store(true, .release);
    }

    pub fn failed(self: *const Reporter) bool {
        return self.write_failed.load(.acquire);
    }

    fn write(self: *Reporter, event: Zigalpm.OperationEvent) !void {
        switch (event) {
            .status => |status| try output.writeAlpmInfoFrame(
                self.context,
                "InformationalOutput",
                status.message,
            ),
            .progress => |progress| try output.writeOperationProgressFrame(self.context, progress),
            .failure => |failure| try output.writeErrorFrame(self.context, failure.message),
            .started, .completed => {},
        }
        try flush(self.context);
    }
};

pub fn acceptQuestionDefaults(
    _: ?*anyopaque,
    question: Zigalpm.OperationQuestion,
) Zigalpm.OperationQuestionResponse {
    return switch (question.kind) {
        .confirmation, .review_changes => .accepted,
        .select_one, .select_provider => .{ .choice = 0 },
        .select_many, .select_optional_dependencies => .{ .choices = &.{} },
    };
}

pub fn flush(context: *runtime.RuntimeContext) !void {
    try context.stdout.flush();
    try context.stderr.flush();
}

test "UI operation reporter preserves percentages for every progress frame shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
    };
    var operation_context = Zigalpm.OperationContext.init(arena.allocator(), std.testing.io);
    defer operation_context.deinit();
    var reporter: Reporter = .{ .context = &context };
    const subscription = try operation_context.subscribe(.{
        .function = Reporter.handle,
        .data = &reporter,
    });
    defer _ = operation_context.unsubscribe(subscription);

    var alpm = operation_context.begin(.{ .backend = .alpm, .kind = .install, .subject = "demo" });
    alpm.progress(.{ .completed = 37, .total = 100, .percentage = 37, .native_code = 100 });
    alpm.finish(.success);
    var flatpak = operation_context.begin(.{ .backend = .flatpak, .kind = .install, .subject = "org.demo.App" });
    flatpak.progress(.{ .stage = "Downloading", .percentage = 64 });
    flatpak.finish(.success);
    var appimage = operation_context.begin(.{ .backend = .appimage, .kind = .download, .subject = "demo.AppImage" });
    appimage.progress(.{ .bytes_completed = 25, .bytes_total = 100 });
    appimage.finish(.success);

    var frame_iterator = std.mem.splitSequence(u8, stdout.writer.buffered(), "[/JSON]\n");
    const expected = [_][]const []const u8{
        &.{
            "\"$kind\":\"alpm.progress\"",
            "\"CurrentDownload\":37",
            "\"TotalDownload\":100",
            "\"ProgressType\":\"PackageDownload\"",
            "\"Percent\":37",
        },
        &.{
            "\"$kind\":\"flatpak.progress\"",
            "\"Status\":\"Downloading\"",
            "\"Percentage\":64",
        },
        &.{
            "\"$kind\":\"appimage.progress\"",
            "\"Status\":\"demo.AppImage\"",
            "\"Percentage\":25",
        },
    };
    for (expected) |needles| {
        const frame = frame_iterator.next() orelse return error.MissingProgressFrame;
        const prefix = "[JSON]";
        try std.testing.expect(std.mem.startsWith(u8, frame, prefix));
        const encoded = frame[prefix.len..];
        const decoded_length = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
        const decoded = try arena.allocator().alloc(u8, decoded_length);
        try std.base64.standard.Decoder.decode(decoded, encoded);
        for (needles) |needle|
            try std.testing.expect(std.mem.indexOf(u8, decoded, needle) != null);
    }
    try std.testing.expectEqual(@as(usize, 0), (frame_iterator.next() orelse return error.MissingFrameTerminator).len);
    try std.testing.expect(frame_iterator.next() == null);
    try std.testing.expect(!reporter.failed());
}

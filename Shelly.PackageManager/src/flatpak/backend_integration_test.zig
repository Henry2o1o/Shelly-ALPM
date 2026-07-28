const std = @import("std");
const client_api = @import("client.zig");
const events = @import("events.zig");
const errors = @import("errors.zig");
const loader = @import("backend_loader.zig");

const SuccessResult = struct {
    ok: bool,
    value: []const u8,
};

const StatsResult = struct {
    released: u64,
};

const EventCapture = struct {
    statuses: std.atomic.Value(u64) = .init(0),
    progress: std.atomic.Value(u64) = .init(0),
    percentage: std.atomic.Value(u8) = .init(0),

    fn status(data: ?*anyopaque, _: events.StatusArgs) void {
        const self: *EventCapture = @ptrCast(@alignCast(data orelse return));
        _ = self.statuses.fetchAdd(1, .acq_rel);
    }

    fn update(data: ?*anyopaque, args: events.ProgressArgs) void {
        const self: *EventCapture = @ptrCast(@alignCast(data orelse return));
        _ = self.progress.fetchAdd(1, .acq_rel);
        self.percentage.store(args.percentage, .release);
    }

    fn cancelled(_: ?*anyopaque) bool {
        return true;
    }
};

const ConcurrentCall = struct {
    completed: std.atomic.Value(bool) = .init(false),

    fn run(self: *ConcurrentCall) void {
        const client: client_api.Client = .{
            .allocator = std.heap.c_allocator,
        };
        var result = client.call(
            SuccessResult,
            "fake.success",
            .{},
            .{},
        ) catch return;
        defer result.deinit();
        self.completed.store(result.value.ok, .release);
    }
};

test "PackageManager loads and validates the Flatpak-free fake backend" {
    const status = loader.backendStatus();
    switch (status) {
        .available => |info| {
            try std.testing.expectEqual(@as(u32, 1), info.abi_version);
            try std.testing.expect(std.fs.path.isAbsolute(info.path));
        },
        else => return error.ExpectedAvailableFakeBackend,
    }
}

test "PackageManager client owns responses and bridges errors events and cancellation" {
    const client: client_api.Client = .{ .allocator = std.heap.c_allocator };
    var dispatcher = events.Dispatcher.init(std.heap.c_allocator);
    defer dispatcher.deinit();
    var capture: EventCapture = .{};
    _ = try dispatcher.addStatusHandler(.{
        .function = EventCapture.status,
        .data = &capture,
    });
    _ = try dispatcher.addProgressHandler(.{
        .function = EventCapture.update,
        .data = &capture,
    });

    var success = try client.call(
        SuccessResult,
        "fake.success",
        .{},
        .{ .dispatcher = &dispatcher },
    );
    defer success.deinit();
    try std.testing.expect(success.value.ok);
    try std.testing.expectEqualStrings("fake", success.value.value);
    try std.testing.expect(capture.statuses.load(.acquire) > 0);
    try std.testing.expect(capture.progress.load(.acquire) > 0);
    try std.testing.expectEqual(@as(u8, 50), capture.percentage.load(.acquire));

    try std.testing.expectError(
        errors.Error.FlatpakOperationFailed,
        client.call(SuccessResult, "fake.error", .{}, .{}),
    );
    try std.testing.expectError(
        errors.Error.FlatpakProtocolInvalid,
        client.call(SuccessResult, "fake.malformed", .{}, .{}),
    );
    try std.testing.expectError(
        errors.Error.Cancelled,
        client.call(
            SuccessResult,
            "fake.wait",
            .{},
            .{ .cancellation = .{ .function = EventCapture.cancelled } },
        ),
    );

    var stats = try client.call(StatsResult, "fake.stats", .{}, .{});
    defer stats.deinit();
    try std.testing.expect(stats.value.released >= 4);
}

test "process-wide loader supports concurrent clients and remains loaded" {
    var first: ConcurrentCall = .{};
    var second: ConcurrentCall = .{};
    const first_thread = try std.Thread.spawn(
        .{},
        ConcurrentCall.run,
        .{&first},
    );
    const second_thread = try std.Thread.spawn(
        .{},
        ConcurrentCall.run,
        .{&second},
    );
    first_thread.join();
    second_thread.join();
    try std.testing.expect(first.completed.load(.acquire));
    try std.testing.expect(second.completed.load(.acquire));
    try std.testing.expect(loader.backendStatus() == .available);
}

const std = @import("std");

/// Values intentionally match the C# FlatpakEventEnum ordering.
pub const EventType = enum(u8) {
    information,
    warning,
    err,
    success,
};

/// Message slices are borrowed and remain valid only for the callback.
pub const StatusArgs = struct {
    event_type: EventType,
    message: []const u8,
};

/// Progress slices are borrowed and remain valid only for the callback.
pub const ProgressArgs = struct {
    name: []const u8,
    status: []const u8,
    percentage: u8,
};

pub const StatusHandler = struct {
    pub const Fn = *const fn (data: ?*anyopaque, args: StatusArgs) void;

    function: Fn,
    data: ?*anyopaque = null,

    fn call(self: StatusHandler, args: StatusArgs) void {
        self.function(self.data, args);
    }
};

pub const ProgressHandler = struct {
    pub const Fn = *const fn (data: ?*anyopaque, args: ProgressArgs) void;

    function: Fn,
    data: ?*anyopaque = null,

    fn call(self: ProgressHandler, args: ProgressArgs) void {
        self.function(self.data, args);
    }
};

/// A cancellation callback may be shared with transaction and HTTP work.
pub const Cancellation = struct {
    pub const Fn = *const fn (data: ?*anyopaque) bool;

    function: Fn,
    data: ?*anyopaque = null,

    pub fn isCancelled(self: Cancellation) bool {
        return self.function(self.data);
    }
};

pub const Dispatcher = struct {
    allocator: std.mem.Allocator,
    statuses: std.ArrayList(StatusHandler) = .empty,
    progress: std.ArrayList(ProgressHandler) = .empty,

    pub fn init(allocator: std.mem.Allocator) Dispatcher {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Dispatcher) void {
        self.statuses.deinit(self.allocator);
        self.progress.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addStatusHandler(self: *Dispatcher, handler: StatusHandler) !usize {
        try self.statuses.append(self.allocator, handler);
        return self.statuses.items.len - 1;
    }

    pub fn removeStatusHandler(self: *Dispatcher, token: usize) void {
        removeHandler(StatusHandler, &self.statuses, token);
    }

    pub fn addProgressHandler(self: *Dispatcher, handler: ProgressHandler) !usize {
        try self.progress.append(self.allocator, handler);
        return self.progress.items.len - 1;
    }

    pub fn removeProgressHandler(self: *Dispatcher, token: usize) void {
        removeHandler(ProgressHandler, &self.progress, token);
    }

    pub fn raiseStatus(self: *Dispatcher, args: StatusArgs) void {
        dispatch(self, StatusArgs, StatusHandler, self.statuses.items, args);
    }

    pub fn raiseProgress(self: *Dispatcher, args: ProgressArgs) void {
        dispatch(self, ProgressArgs, ProgressHandler, self.progress.items, args);
    }

    fn dispatch(
        self: *Dispatcher,
        comptime Args: type,
        comptime HandlerType: type,
        live: []const HandlerType,
        args: Args,
    ) void {
        if (live.len == 0) return;
        const snapshot = self.allocator.dupe(HandlerType, live) catch {
            for (live) |handler| handler.call(args);
            return;
        };
        defer self.allocator.free(snapshot);
        for (snapshot) |handler| handler.call(args);
    }

    fn removeHandler(comptime HandlerType: type, handlers: *std.ArrayList(HandlerType), token: usize) void {
        if (token >= handlers.items.len) return;
        _ = handlers.swapRemove(token);
    }
};

test "Flatpak dispatcher forwards typed status and progress" {
    const Capture = struct {
        event_type: ?EventType = null,
        percentage: ?u8 = null,

        fn status(data: ?*anyopaque, args: StatusArgs) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.event_type = args.event_type;
        }

        fn update(data: ?*anyopaque, args: ProgressArgs) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.percentage = args.percentage;
        }
    };

    var dispatcher = Dispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var capture: Capture = .{};
    _ = try dispatcher.addStatusHandler(.{ .function = Capture.status, .data = &capture });
    _ = try dispatcher.addProgressHandler(.{ .function = Capture.update, .data = &capture });

    dispatcher.raiseStatus(.{ .event_type = .success, .message = "installed" });
    dispatcher.raiseProgress(.{ .name = "org.example.App", .status = "Downloading", .percentage = 42 });

    try std.testing.expectEqual(EventType.success, capture.event_type.?);
    try std.testing.expectEqual(@as(u8, 42), capture.percentage.?);
}

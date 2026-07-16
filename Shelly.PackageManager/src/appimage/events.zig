const std = @import("std");

/// Values intentionally match the C# AppImageEvents ordering.
pub const StatusKind = enum(u8) {
    information,
    warning,
    err,
    success,
};

/// Message slices are borrowed and remain valid only for the callback.
pub const StatusArgs = struct {
    kind: StatusKind,
    message: []const u8,
};

/// The application name is borrowed and remains valid only for the callback.
pub const DownloadProgressArgs = struct {
    app_name: []const u8,
    total_bytes: ?u64,
    downloaded_bytes: u64,
    percentage: ?f64,
};

pub const StatusHandler = struct {
    pub const Fn = *const fn (data: ?*anyopaque, args: StatusArgs) void;

    function: Fn,
    data: ?*anyopaque = null,

    fn call(self: StatusHandler, args: StatusArgs) void {
        self.function(self.data, args);
    }
};

pub const DownloadProgressHandler = struct {
    pub const Fn = *const fn (data: ?*anyopaque, args: DownloadProgressArgs) void;

    function: Fn,
    data: ?*anyopaque = null,

    fn call(self: DownloadProgressHandler, args: DownloadProgressArgs) void {
        self.function(self.data, args);
    }
};

pub const Dispatcher = struct {
    allocator: std.mem.Allocator,
    statuses: std.ArrayList(StatusHandler) = .empty,
    download_progress: std.ArrayList(DownloadProgressHandler) = .empty,

    pub fn init(allocator: std.mem.Allocator) Dispatcher {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Dispatcher) void {
        self.statuses.deinit(self.allocator);
        self.download_progress.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addStatusHandler(self: *Dispatcher, handler: StatusHandler) !usize {
        try self.statuses.append(self.allocator, handler);
        return self.statuses.items.len - 1;
    }

    pub fn removeStatusHandler(self: *Dispatcher, token: usize) void {
        removeHandler(StatusHandler, &self.statuses, token);
    }

    pub fn addDownloadProgressHandler(self: *Dispatcher, handler: DownloadProgressHandler) !usize {
        try self.download_progress.append(self.allocator, handler);
        return self.download_progress.items.len - 1;
    }

    pub fn removeDownloadProgressHandler(self: *Dispatcher, token: usize) void {
        removeHandler(DownloadProgressHandler, &self.download_progress, token);
    }

    pub fn raiseStatus(self: *Dispatcher, args: StatusArgs) void {
        dispatch(self, StatusArgs, StatusHandler, self.statuses.items, args);
    }

    pub fn raiseDownloadProgress(self: *Dispatcher, args: DownloadProgressArgs) void {
        dispatch(self, DownloadProgressArgs, DownloadProgressHandler, self.download_progress.items, args);
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

test "AppImage dispatcher forwards typed status and download progress" {
    const Capture = struct {
        status: ?StatusKind = null,
        downloaded: ?u64 = null,
        percentage: ?f64 = null,

        fn captureStatus(data: ?*anyopaque, args: StatusArgs) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.status = args.kind;
        }

        fn captureProgress(data: ?*anyopaque, args: DownloadProgressArgs) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.downloaded = args.downloaded_bytes;
            self.percentage = args.percentage;
        }
    };

    var dispatcher = Dispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var capture: Capture = .{};
    _ = try dispatcher.addStatusHandler(.{ .function = Capture.captureStatus, .data = &capture });
    _ = try dispatcher.addDownloadProgressHandler(.{ .function = Capture.captureProgress, .data = &capture });

    dispatcher.raiseStatus(.{ .kind = .success, .message = "updated" });
    dispatcher.raiseDownloadProgress(.{
        .app_name = "Example",
        .total_bytes = 200,
        .downloaded_bytes = 50,
        .percentage = 25.0,
    });

    try std.testing.expectEqual(StatusKind.success, capture.status.?);
    try std.testing.expectEqual(@as(u64, 50), capture.downloaded.?);
    try std.testing.expectEqual(@as(f64, 25.0), capture.percentage.?);
}

const std = @import("std");

pub const Level = enum {
    information,
    warning,
    err,
    success,
};

/// The message slice is borrowed and is valid only for the duration of the
/// callback.
pub const Message = struct {
    level: Level,
    text: []const u8,
};

pub const Handler = struct {
    pub const Fn = *const fn (data: ?*anyopaque, message: Message) void;

    function: Fn,
    data: ?*anyopaque = null,

    pub fn call(self: Handler, message: Message) void {
        self.function(self.data, message);
    }
};

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
    handlers: std.ArrayList(Handler) = .empty,

    pub fn init(allocator: std.mem.Allocator) Dispatcher {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Dispatcher) void {
        self.handlers.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *Dispatcher, handler: Handler) !usize {
        try self.handlers.append(self.allocator, handler);
        return self.handlers.items.len - 1;
    }

    pub fn remove(self: *Dispatcher, index: usize) void {
        if (index >= self.handlers.items.len) return;
        _ = self.handlers.swapRemove(index);
    }

    pub fn raise(self: *Dispatcher, message: Message) void {
        const snapshot = self.allocator.dupe(Handler, self.handlers.items) catch {
            for (self.handlers.items) |handler| handler.call(message);
            return;
        };
        defer self.allocator.free(snapshot);
        for (snapshot) |handler| handler.call(message);
    }
};

test "dispatcher forwards typed local package messages" {
    const Capture = struct {
        level: ?Level = null,
        text: [64]u8 = undefined,
        len: usize = 0,

        fn handler(data: ?*anyopaque, message: Message) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.level = message.level;
            self.len = @min(message.text.len, self.text.len);
            @memcpy(self.text[0..self.len], message.text[0..self.len]);
        }
    };

    var dispatcher = Dispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();
    var capture: Capture = .{};
    _ = try dispatcher.add(.{ .function = Capture.handler, .data = &capture });
    dispatcher.raise(.{ .level = .success, .text = "installed" });

    try std.testing.expectEqual(Level.success, capture.level.?);
    try std.testing.expectEqualStrings("installed", capture.text[0..capture.len]);
}

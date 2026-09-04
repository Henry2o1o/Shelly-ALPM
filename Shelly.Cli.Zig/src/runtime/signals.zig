const std = @import("std");
const builtin = @import("builtin");
const Zigalpm = @import("Zigalpm");

var received_signal = std.atomic.Value(u8).init(0);
var graceful_cancellation = std.atomic.Value(bool).init(false);

pub fn installInterruptHandler(graceful: bool) void {
    if (builtin.os.tag != .linux) return;
    received_signal.store(0, .release);
    graceful_cancellation.store(graceful, .release);
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleInterrupt },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
}

fn handleInterrupt(signal: std.posix.SIG) callconv(.c) void {
    received_signal.store(@intCast(@intFromEnum(signal)), .release);
    if (!graceful_cancellation.load(.acquire)) {
        const message = "\nOperation cancelled.\n";
        _ = std.os.linux.write(std.posix.STDERR_FILENO, message.ptr, message.len);
        std.os.linux.exit_group(130);
    }
}

pub fn wasInterrupted() bool {
    return received_signal.load(.acquire) != 0;
}

/// Bridges the async-signal-safe flag into the ordinary cancellation API.
/// The watcher runs in normal execution context, where OperationContext is
/// allowed to allocate, lock, and invoke cancellation subscribers.
pub const CancellationWatcher = struct {
    io: std.Io = undefined,
    operation_context: *Zigalpm.OperationContext = undefined,
    stopped: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(void) = null,

    pub fn start(
        self: *CancellationWatcher,
        io: std.Io,
        operation_context: *Zigalpm.OperationContext,
    ) !void {
        self.io = io;
        self.operation_context = operation_context;
        self.stopped.store(false, .release);
        if (wasInterrupted()) operation_context.cancel();
        self.future = try io.concurrent(watch, .{self});
    }

    pub fn deinit(self: *CancellationWatcher) void {
        self.stopped.store(true, .release);
        if (self.future) |*future| future.await(self.io);
        self.future = null;
    }

    fn watch(self: *CancellationWatcher) void {
        while (!self.stopped.load(.acquire)) {
            if (wasInterrupted()) {
                self.operation_context.cancel();
                return;
            }
            self.io.sleep(.fromMilliseconds(25), .awake) catch return;
        }
    }
};

test "signal handler records cancellation without exiting or writing" {
    received_signal.store(0, .release);
    defer received_signal.store(0, .release);
    graceful_cancellation.store(true, .release);
    defer graceful_cancellation.store(false, .release);
    handleInterrupt(.TERM);
    try std.testing.expect(wasInterrupted());
}

test "cancellation watcher translates a signal into OperationContext cancellation" {
    received_signal.store(0, .release);
    defer received_signal.store(0, .release);
    graceful_cancellation.store(true, .release);
    defer graceful_cancellation.store(false, .release);

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var operation_context = Zigalpm.OperationContext.init(std.testing.allocator, io);
    defer operation_context.deinit();
    var watcher: CancellationWatcher = .{};
    try watcher.start(io, &operation_context);
    defer watcher.deinit();

    handleInterrupt(.INT);
    var attempts: usize = 0;
    while (!operation_context.isCancelled() and attempts < 50) : (attempts += 1)
        io.sleep(.fromMilliseconds(5), .awake) catch break;
    try std.testing.expect(operation_context.isCancelled());
}

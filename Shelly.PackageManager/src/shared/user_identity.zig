const std = @import("std");

pub const IdentityError = error{ BufferTooSmall, LookupFailed, UserNotFound, InvalidRecord, BufferTooLarge, OutOfMemory };

pub const UserIdentiy = struct {
    uid: u32,
    gid: u32,
    username: []const u8,
    home_directory: []const u8,
    shell: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *UserIdentiy) void {
        self.allocator.free(self.username);
        self.allocator.free(self.home_directory);
        self.allocator.free(self.shell);
        self.* = undefined;
    }

    pub fn init(allocator: std.mem.Allocator, uid: u32, buffer_size: u32) IdentityError!UserIdentiy {
        var pwd: std.c.passwd = undefined;
        var result: ?*std.c.passwd = null;
        const buffer = try allocator.alloc(u8, buffer_size * 1024);
        var owns_buffer = true;
        errdefer if (owns_buffer) allocator.free(buffer);

        const rc = std.c.getpwuid_r(uid, &pwd, buffer[0..].ptr, buffer.len, &result);

        if (rc == @intFromEnum(std.c.E.RANGE)) {
            if (buffer.len >= 1024 * 1024) return IdentityError.BufferTooLarge;
            allocator.free(buffer);
            owns_buffer = false;
            return init(allocator, uid, 2 * buffer_size);
        }

        if (rc != 0)
            return IdentityError.LookupFailed;

        const user = result orelse return IdentityError.UserNotFound;

        const username: []const u8 = try allocator.dupe(u8, std.mem.span(user.name orelse return IdentityError.InvalidRecord));
        errdefer allocator.free(username);
        const home: []const u8 = try allocator.dupe(u8, std.mem.span(user.dir orelse return IdentityError.InvalidRecord));
        errdefer allocator.free(home);
        const shell: []const u8 = try allocator.dupe(u8, std.mem.span(user.shell orelse return IdentityError.InvalidRecord));
        errdefer allocator.free(shell);
        const gid: u32 = user.gid;
        allocator.free(buffer);
        return UserIdentiy{
            .allocator = allocator,
            .uid = uid,
            .username = username,
            .home_directory = home,
            .shell = shell,
            .gid = gid,
        };
    }
};

test "init resolves and owns the current NSS identity" {
    const testing = std.testing;
    const uid = std.c.getuid();
    const expected = std.c.getpwuid(uid) orelse return error.TestUnexpectedResult;

    var identity = try UserIdentiy.init(testing.allocator, uid, 16);
    defer identity.deinit();

    try testing.expectEqual(uid, identity.uid);
    try testing.expectEqual(expected.gid, identity.gid);
    try testing.expectEqualStrings(
        std.mem.span(expected.name orelse return error.TestUnexpectedResult),
        identity.username,
    );
    try testing.expectEqualStrings(
        std.mem.span(expected.dir orelse return error.TestUnexpectedResult),
        identity.home_directory,
    );
    try testing.expectEqualStrings(
        std.mem.span(expected.shell orelse return error.TestUnexpectedResult),
        identity.shell,
    );
}

test "init reports a missing NSS identity" {
    try std.testing.expectError(
        IdentityError.UserNotFound,
        UserIdentiy.init(std.testing.allocator, std.math.maxInt(u32), 16),
    );
}

fn resolveCurrentIdentity(allocator: std.mem.Allocator) !void {
    var identity = try UserIdentiy.init(allocator, std.c.getuid(), 16);
    defer identity.deinit();
}

test "init releases all allocations after allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        resolveCurrentIdentity,
        .{},
    );
}

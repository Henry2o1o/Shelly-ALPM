//! Virtual package ownership captured from unprivileged package steps.
//!
//! The shell wrappers journal ownership changes against inode identities at
//! the time of the request. Package assembly resolves surviving identities
//! back to final archive paths, so ownership follows renames and hard links
//! but does not transfer to replacement files. Host filesystem ownership is
//! never changed.

const std = @import("std");
const archive = @import("archive");

const max_journal_bytes = 16 * 1024 * 1024;
const max_records = 100_000;

pub const Tracker = struct {
    allocator: std.mem.Allocator,
    by_inode: std.AutoHashMap(u64, archive.VirtualOwnership),

    pub fn init(allocator: std.mem.Allocator) Tracker {
        return .{ .allocator = allocator, .by_inode = .init(allocator) };
    }

    pub fn deinit(self: *Tracker) void {
        self.by_inode.deinit();
        self.* = undefined;
    }

    pub fn hasNonDefaultOwnership(self: *const Tracker) bool {
        var values = self.by_inode.valueIterator();
        while (values.next()) |ownership| {
            if (ownership.uid != 0 or ownership.gid != 0) return true;
        }
        return false;
    }

    pub fn readJournal(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        package_root: []const u8,
    ) !Tracker {
        const contents = try std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            allocator,
            .limited(max_journal_bytes),
        );
        defer allocator.free(contents);
        const canonical_package_root = try std.Io.Dir.cwd().realPathFileAlloc(io, package_root, allocator);
        defer allocator.free(canonical_package_root);

        var tracker = Tracker.init(allocator);
        errdefer tracker.deinit();
        const passwd = try std.Io.Dir.cwd().readFileAlloc(io, "/etc/passwd", allocator, .limited(4 * 1024 * 1024));
        defer allocator.free(passwd);
        const group = try std.Io.Dir.cwd().readFileAlloc(io, "/etc/group", allocator, .limited(4 * 1024 * 1024));
        defer allocator.free(group);

        var offset: usize = 0;
        var record_count: usize = 0;
        var terminated = false;
        while (offset < contents.len) {
            const operation = try nextField(contents, &offset);
            if (std.mem.eql(u8, operation, "E")) {
                if (offset != contents.len) return error.InvalidVirtualOwnershipJournal;
                terminated = true;
                break;
            }
            if (record_count >= max_records) return error.VirtualOwnershipJournalTooLarge;
            record_count += 1;
            const inode_text = try nextField(contents, &offset);
            const specification = try nextField(contents, &offset);
            const target_path = try nextField(contents, &offset);
            try validateTargetPath(canonical_package_root, target_path);
            const inode = std.fmt.parseUnsigned(u64, inode_text, 10) catch
                return error.InvalidVirtualOwnershipJournal;
            const current = tracker.by_inode.get(inode) orelse archive.VirtualOwnership{};
            const updated = if (std.mem.eql(u8, operation, "C"))
                try applyChownSpecification(current, specification, passwd, group)
            else if (std.mem.eql(u8, operation, "G"))
                archive.VirtualOwnership{
                    .uid = current.uid,
                    .gid = try resolveGroupId(specification, group),
                }
            else
                return error.InvalidVirtualOwnershipJournal;
            try tracker.by_inode.put(inode, updated);
        }
        if (!terminated) return error.InvalidVirtualOwnershipJournal;
        return tracker;
    }

    pub fn buildMetadata(
        self: *const Tracker,
        io: std.Io,
        package_root: []const u8,
    ) !OwnedMetadata {
        var paths: std.ArrayList([]u8) = .empty;
        errdefer {
            for (paths.items) |path| self.allocator.free(path);
            paths.deinit(self.allocator);
        }
        var overrides: std.ArrayList(archive.OwnershipOverride) = .empty;
        errdefer overrides.deinit(self.allocator);

        var directory = try std.Io.Dir.cwd().openDir(io, package_root, .{ .iterate = true });
        defer directory.close(io);
        var walker = try directory.walk(self.allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            const stat = try entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false });
            const ownership = self.by_inode.get(stat.inode) orelse continue;
            if (ownership.uid == 0 and ownership.gid == 0) continue;
            const owned_path = try self.allocator.dupe(u8, entry.path);
            errdefer self.allocator.free(owned_path);
            try paths.append(self.allocator, owned_path);
            try overrides.append(self.allocator, .{ .path = owned_path, .ownership = ownership });
        }
        std.mem.sort(archive.OwnershipOverride, overrides.items, {}, struct {
            fn before(_: void, left: archive.OwnershipOverride, right: archive.OwnershipOverride) bool {
                return std.mem.order(u8, left.path, right.path) == .lt;
            }
        }.before);
        return .{
            .allocator = self.allocator,
            .paths = try paths.toOwnedSlice(self.allocator),
            .overrides = try overrides.toOwnedSlice(self.allocator),
        };
    }
};

pub const OwnedMetadata = struct {
    allocator: std.mem.Allocator,
    paths: [][]u8,
    overrides: []archive.OwnershipOverride,

    pub fn deinit(self: *OwnedMetadata) void {
        for (self.paths) |path| self.allocator.free(path);
        self.allocator.free(self.paths);
        self.allocator.free(self.overrides);
        self.* = undefined;
    }

    pub fn view(self: *const OwnedMetadata) archive.VirtualMetadata {
        return .{
            .ownership_overrides = self.overrides,
            .ownership_overrides_sorted = true,
        };
    }
};

fn nextField(contents: []const u8, offset: *usize) ![]const u8 {
    if (offset.* >= contents.len) return error.InvalidVirtualOwnershipJournal;
    const end = std.mem.indexOfScalarPos(u8, contents, offset.*, 0) orelse
        return error.InvalidVirtualOwnershipJournal;
    const field = contents[offset.*..end];
    offset.* = end + 1;
    return field;
}

fn validateTargetPath(package_root: []const u8, path: []const u8) !void {
    if (std.mem.eql(u8, path, package_root)) return;
    if (path.len <= package_root.len or !std.mem.startsWith(u8, path, package_root) or
        path[package_root.len] != std.fs.path.sep)
        return error.VirtualOwnershipOutsidePackage;
}

fn applyChownSpecification(
    current: archive.VirtualOwnership,
    specification: []const u8,
    passwd: []const u8,
    group: []const u8,
) !archive.VirtualOwnership {
    if (specification.len == 0 or std.mem.eql(u8, specification, ":"))
        return error.InvalidVirtualOwnership;
    const separator = std.mem.indexOfScalar(u8, specification, ':');
    if (separator == null) return .{
        .uid = try resolveUserId(specification, passwd),
        .gid = current.gid,
    };
    if (std.mem.indexOfScalarPos(u8, specification, separator.? + 1, ':') != null)
        return error.InvalidVirtualOwnership;
    const owner = specification[0..separator.?];
    const requested_group = specification[separator.? + 1 ..];
    var result = current;
    if (owner.len > 0) result.uid = try resolveUserId(owner, passwd);
    if (requested_group.len > 0) {
        result.gid = try resolveGroupId(requested_group, group);
    } else if (owner.len > 0) {
        result.gid = try primaryGroupForUser(owner, passwd);
    }
    return result;
}

fn resolveUserId(value: []const u8, passwd: []const u8) !i64 {
    if (parseNumericId(value)) |id| return id;
    var lines = std.mem.splitScalar(u8, passwd, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const name = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const id = fields.next() orelse continue;
        if (std.mem.eql(u8, name, value))
            return parseNumericId(id) orelse return error.InvalidVirtualOwnership;
    }
    return error.UnknownVirtualOwner;
}

fn primaryGroupForUser(value: []const u8, passwd: []const u8) !i64 {
    if (parseNumericId(value)) |_| return error.UnknownVirtualOwnerGroup;
    var lines = std.mem.splitScalar(u8, passwd, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const name = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const gid = fields.next() orelse continue;
        if (std.mem.eql(u8, name, value))
            return parseNumericId(gid) orelse return error.InvalidVirtualOwnership;
    }
    return error.UnknownVirtualOwnerGroup;
}

fn resolveGroupId(value: []const u8, group: []const u8) !i64 {
    if (parseNumericId(value)) |id| return id;
    var lines = std.mem.splitScalar(u8, group, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const name = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const id = fields.next() orelse continue;
        if (std.mem.eql(u8, name, value))
            return parseNumericId(id) orelse return error.InvalidVirtualOwnership;
    }
    return error.UnknownVirtualGroup;
}

fn parseNumericId(value: []const u8) ?i64 {
    const digits = if (std.mem.startsWith(u8, value, "+")) value[1..] else value;
    if (digits.len == 0) return null;
    for (digits) |byte| if (!std.ascii.isDigit(byte)) return null;
    const parsed = std.fmt.parseUnsigned(u32, digits, 10) catch return null;
    return @intCast(parsed);
}

test "virtual ownership specifications preserve unspecified fields" {
    const passwd = "root:x:0:0:root:/root:/bin/bash\nservice:x:42:84::/:/bin/false\n";
    const group = "root:x:0:\nservice:x:84:\n";
    try std.testing.expectEqual(
        archive.VirtualOwnership{ .uid = 42, .gid = 9 },
        try applyChownSpecification(.{ .uid = 7, .gid = 9 }, "42", passwd, group),
    );
    try std.testing.expectEqual(
        archive.VirtualOwnership{ .uid = 42, .gid = 84 },
        try applyChownSpecification(.{}, "service:", passwd, group),
    );
    try std.testing.expectEqual(
        archive.VirtualOwnership{ .uid = 0, .gid = 84 },
        try applyChownSpecification(.{}, ":service", passwd, group),
    );
}

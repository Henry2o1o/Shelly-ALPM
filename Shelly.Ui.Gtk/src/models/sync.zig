const std = @import("std");

pub const Sync = struct {
    meta: SyncMetaData,
    packages: []SyncPackage,
    aur: []SyncAur,
    flatpak: []SyncFlatpak,

    pub fn count(self: *const Sync) i64 {
        return @intCast(self.packages.len + self.aur.len + self.flatpak.len);
    }
};

pub const SyncPackage = struct {
    name: []const u8 = "",
    version: []const u8 = "",
    old_version: []const u8 = "",
    download_size: []const u8 = "",
};

pub const SyncAur = struct {
    name: []const u8 = "",
    version: []const u8 = "",
    old_version: []const u8 = "",
};

pub const SyncFlatpak = struct {
    name: []const u8 = "",
    version: []const u8 = "",
    id: []const u8 = "",
};

pub const SyncMetaData = struct {
    version: []const u8 = "v1",
    date: []const u8 = "",
    time: i64,
};

pub const CheckUpdates = struct {
    MetaData: CheckUpdatesMetaData,
    Packages: []CheckUpdatesPackage,
    Aur: []CheckUpdatesAur,
    Flatpak: []CheckUpdatesFlatpak,

    pub fn count(self: *const CheckUpdates) usize {
        return self.Packages.len + self.Aur.len + self.Flatpak.len;
    }
};

pub const CheckUpdatesPackage = struct {
    Name: []const u8 = "",
    Version: []const u8 = "",
    OldVersion: []const u8 = "",
    DownloadSize: []const u8 = "",
};

pub const CheckUpdatesAur = struct {
    Name: []const u8 = "",
    Version: []const u8 = "",
    OldVersion: []const u8 = "",
    DownloadSize: []const u8 = "",
};

pub const CheckUpdatesFlatpak = struct {
    Id: []const u8 = "",
    Name: []const u8 = "",
    Version: []const u8 = "",
};

pub const CheckUpdatesMetaData = struct {
    Version: []const u8 = "v1",
    Date: []const u8 = "",
    Time: i64 = 0,
};

test "parse check-updates JSON response" {
    const json =
        \\{"MetaData":{"Version":"v1","Date":"07/17/2026","Time":1784295469},"Packages":[{"Name":"mesa","Version":"3:26.1.5-1","OldVersion":"3:26.1.4-1","DownloadSize":"13.34 MiB"}],"Aur":[{"Name":"shelly-git","Version":"2.4.1","OldVersion":"2.4.0","DownloadSize":"0.00 MiB"}],"Flatpak":[{"Id":"org.gnome.Platform","Name":"GNOME Platform","Version":"50"}]}
    ;
    const parsed = try std.json.parseFromSlice(CheckUpdates, std.testing.allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 3), parsed.value.count());
    try std.testing.expectEqualStrings("13.34 MiB", parsed.value.Packages[0].DownloadSize);
    try std.testing.expectEqualStrings("org.gnome.Platform", parsed.value.Flatpak[0].Id);
}

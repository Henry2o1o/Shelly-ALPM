pub const Sync = struct {
    meta: SyncMetaData,
    packages: []SyncPackage,
    aur: []SyncAur,
    flatpak: []SyncFlatpak,

    pub fn count(self: *Sync) i64 {
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

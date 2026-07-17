pub const InstallLevel = enum(u8) {
    system = 0,
    user = 1,
};

pub const Remote = struct {
    Name: []const u8 = "",
    Url: []const u8 = "",
    Scope: InstallLevel = .system,
};

pub const FlatpakKind = enum(u8) {
    app = 0,
    runtime = 1,
};

pub const Flatpak = struct {
    Id: []const u8 = "",
    Name: []const u8 = "",
    Version: []const u8 = "",
    Remote: []const u8 = "",
    Kind: FlatpakKind = .app,
    InstalledSize: i64 = 0,
    InstallLevel: InstallLevel = .system,
};

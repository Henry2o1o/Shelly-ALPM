/// A unified package struct
pub const UnifiedPackage = struct {
    Id: [:0]const u8,
    Name: [:0]const u8,
    Version: [:0]const u8,
    Description: ?[:0]const u8 = null,
    Url: ?[:0]const u8 = null,

    Depends: ?[]const [:0]const u8 = null,

    OptDepends: ?[]const [:0]const u8 = null,
    CheckDepends: ?[]const [:0]const u8 = null,
    Conflicts: ?[]const [:0]const u8 = null,
    Provides: ?[]const [:0]const u8 = null,
    Replaces: ?[]const [:0]const u8 = null,
    Groups: ?[]const [:0]const u8 = null,
    License: ?[]const [:0]const u8 = null,
};

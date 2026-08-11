pub const Source = enum(u8) {
    standard,
    aur,
    flatpak,
};

pub const SearchResult = struct {
    source: Source = .standard,
    name: [:0]const u8 = "",
    install_target: [:0]const u8 = "",
    version: [:0]const u8 = "",
    description: [:0]const u8 = "",
    repository: [:0]const u8 = "",
    installed: bool = false,
    out_of_date: bool = false,
    verified: bool = false,
};

test "SearchResult defaults to a standard package" {
    const result: SearchResult = .{};
    try @import("std").testing.expectEqual(Source.standard, result.source);
    try @import("std").testing.expectEqualStrings("", result.name);
    try @import("std").testing.expect(!result.installed);
    try @import("std").testing.expect(!result.out_of_date);
    try @import("std").testing.expect(!result.verified);
}

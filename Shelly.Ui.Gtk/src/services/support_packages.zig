const std = @import("std");
const options = @import("options");

pub const Feature = enum {
    flatpak,
    appimage,
};

const flatpak_packages = [_][]const u8{ "flatpak", options.flatpak_backend_package };
const appimage_packages = [_][]const u8{"fuse2"};

pub fn forFeature(feature: Feature) []const []const u8 {
    return switch (feature) {
        .flatpak => &flatpak_packages,
        .appimage => &appimage_packages,
    };
}

pub fn selected(
    buffer: *[3][]const u8,
    flatpak: bool,
    appimage: bool,
) []const []const u8 {
    var len: usize = 0;
    if (flatpak) {
        for (flatpak_packages) |package| {
            buffer[len] = package;
            len += 1;
        }
    }
    if (appimage) {
        for (appimage_packages) |package| {
            buffer[len] = package;
            len += 1;
        }
    }
    return buffer[0..len];
}

test "selected support packages combine Flatpak and AppImage dependencies" {
    var buffer: [3][]const u8 = undefined;
    const packages = selected(&buffer, true, true);
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "flatpak", options.flatpak_backend_package, "fuse2" },
        packages,
    );
}

test "selected support packages include only requested features" {
    var buffer: [3][]const u8 = undefined;

    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "flatpak", options.flatpak_backend_package },
        selected(&buffer, true, false),
    );
    try std.testing.expectEqualSlices(
        []const u8,
        &.{"fuse2"},
        selected(&buffer, false, true),
    );
    try std.testing.expectEqual(@as(usize, 0), selected(&buffer, false, false).len);
}

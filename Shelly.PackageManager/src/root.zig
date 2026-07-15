//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

pub const alpm = struct {
    pub const manager = @import("alpm/manager.zig");
    pub const bindings = @import("alpm/bindings.zig");
    pub const events = @import("alpm/events.zig");
    pub const configuration = @import("alpm/configuration.zig");

    pub const Manager = manager.Manager;
    pub const TransFlag = bindings.libalpm.TransFlag;
    pub const SigLevel = bindings.libalpm.SigLevel;
    pub const OwnedPackage = bindings.libalpm.OwnedPackage;
    pub const OwnedPackageWithUpdate = bindings.libalpm.OwnedPackageWithUpdate;
};

pub const aur = @import("aur/manager.zig");

pub const flatpak = struct {
    pub const manager = @import("flatpak/manager.zig");
    pub const remote_manager = @import("flatpak/remote_manager.zig");
    pub const appstream_manager = @import("flatpak/appstream_manager.zig");
    pub const appstream_parser = @import("flatpak/appstream_parser.zig");
    pub const bindings = @import("flatpak/bindings.zig");

    pub const Manager = manager.Manager;
    pub const RemoteManager = remote_manager.RemoteManager;
    pub const AppstreamManager = appstream_manager.AppstreamManager;
};

pub const appimage = struct {
    pub const manager = @import("appimage/manager.zig");
    pub const update_manager = @import("appimage/update_manager.zig");
    pub const bindings = @import("appimage/bindings.zig");

    pub const Manager = manager.AppImageManager;
    pub const UpdateManager = update_manager.UpdateManager;
};

pub const pkgbuild = struct {
    pub const parser = @import("pkgbuild/pkgbuild_parser.zig");
    pub const validation = @import("pkgbuild/shared_validtor.zig");
    pub const homograph_validator = @import("pkgbuild/homograph_validator.zig");
    pub const post_install_validator = @import("pkgbuild/post_install_validator.zig");

    pub const Parser = parser.PkgbuildParser;
    pub const HomographValidator = homograph_validator.HomographValidator;
    pub const PostInstallValidator = post_install_validator.PostInstallValidator;
};

pub const shared = struct {
    pub const downloader = @import("shared/downloader.zig");
    pub const list_dictionary = @import("shared/list_dictionary.zig");
    pub const xdg_paths = @import("shared/xdg_paths.zig");

    pub const Downloader = downloader.CoreDownloader;
};

pub const AlpmManager = alpm.Manager;
pub const AurManager = aur.Manager;
pub const FlatpakManager = flatpak.Manager;
pub const AppImageManager = appimage.Manager;

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}

test "public AUR module exposes the package manager" {
    _ = aur.Manager;
    _ = aur.models.Package;
}

test "public library surface exposes package manager APIs" {
    _ = AlpmManager;
    _ = AurManager;
    _ = FlatpakManager;
    _ = AppImageManager;
    _ = alpm.TransFlag;
    _ = alpm.SigLevel;
    _ = alpm.events.Dispatcher;
    _ = alpm.configuration.Configuration;
    _ = flatpak.RemoteManager;
    _ = flatpak.AppstreamManager;
    _ = appimage.UpdateManager;
    _ = pkgbuild.Parser;
    _ = pkgbuild.HomographValidator;
    _ = pkgbuild.PostInstallValidator;
    _ = shared.Downloader;
}

test {
    _ = @import("alpm/bindings.zig");
    _ = @import("alpm/manager.zig");
    _ = @import("alpm/manager_test.zig");
    _ = @import("alpm/events.zig");
    _ = @import("alpm/configuration.zig");
    _ = @import("alpm/distribution-hooks/CachyOS/update_notice.zig");
    _ = @import("alpm/distribution-hooks/os_utilities.zig");
    _ = @import("flatpak/bindings.zig");
    _ = @import("flatpak/remote_manager.zig");
    _ = @import("flatpak/manager.zig");
    _ = @import("flatpak/appstream_manager.zig");
    _ = @import("flatpak/appstream_parser.zig");
    _ = @import("appimage/manager.zig");
    _ = @import("shared/downloader.zig");
    _ = @import("appimage/update_manager.zig");
    _ = @import("pkgbuild/pkgbuild_parser.zig");
    _ = @import("pkgbuild/post_install_validator.zig");
    _ = @import("pkgbuild/homograph_validator.zig");
    _ = @import("aur/manager.zig");
}

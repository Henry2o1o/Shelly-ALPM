//! Tests for the AUR PackageBuilder (builder.zig).
//!
//! These tests describe the intended behavior of `PackageBuilder`. They are
//! wired into the module test block in src/root.zig and the aur-test filter
//! list in build.zig.
//!
//! Two implementation details of the fixture are worth knowing:
//!
//! * `PackageBuilder.init` receives the `OperationContext` **by value**, so
//!   the builder operates on its own copy. Operations emit events through
//!   that copy. Subscriptions must therefore be registered *before* the
//!   context is copied into the builder (done in `create`), otherwise the
//!   builder's copy dispatches into an empty subscription list and the test
//!   captures never fire.
//! * `PackageBuilder` currently exposes no teardown, so the fixture releases
//!   the builder's state directly. If a `deinit` is added to PackageBuilder,
//!   route the fixture teardown through it instead.

const std = @import("std");
const testing = std.testing;

const builder_mod = @import("builder.zig");
const PackageBuilder = builder_mod.PackageBuilder;
const pkgbuild_mod = @import("../../pkgbuild/pkgbuild_parser.zig");
const events = @import("../events.zig");
const op_context = @import("operation_context");
const MakePkgConfiguration = @import("../makepackage.zig").MakePackageConfiguration;
const archive = @import("archive");
const raw_alpm = @import("../../alpm/bindings.zig").libalpm.alpm;

const ErrorCapture = struct {
    count: usize = 0,

    fn handle(data: ?*anyopaque, _: events.ErrorArgs) void {
        const self: *@This() = @ptrCast(@alignCast(data.?));
        self.count += 1;
    }
};

const CompletionCapture = struct {
    completion: ?op_context.CompletionStatus = null,

    fn handle(data: ?*anyopaque, event: op_context.Event) void {
        const self: *@This() = @ptrCast(@alignCast(data.?));
        switch (event) {
            .completed => |completed| self.completion = completed.status,
            else => {},
        }
    }
};

const Fixture = struct {
    builder: *PackageBuilder,
    operation_context: op_context.OperationContext,
    config: *MakePkgConfiguration,
    // Sentinel-terminated: realPathFileAlloc allocates len+1 for the 0 byte,
    // and free() only releases the full allocation when the slice type still
    // carries the sentinel.
    build_dir: [:0]const u8,
    allocator: std.mem.Allocator,
    temporary: std.testing.TmpDir,

    /// Parses `pkgbuild_content`, creates a per-test build directory, and
    /// constructs a PackageBuilder around them. Ownership of the parsed
    /// PKGBUILD and the dispatcher moves into the builder; the config and
    /// operation context remain owned here.
    ///
    /// The build directory doubles as the parser's base directory so the
    /// makepkg built-ins ($startdir/$srcdir/$pkgdir) expand into it.
    /// `event_handler`, when provided, is subscribed to the operation context
    /// *before* the context is copied into the builder so the builder's copy
    /// (which dispatches during BuildPackage) sees the subscription.
    /// `selected_package_name` selects the split-package member whose
    /// package_<name>() step is extracted; pass null for single packages.
    fn create(
        allocator: std.mem.Allocator,
        pkgbuild_content: []const u8,
        event_handler: ?op_context.EventHandler,
        selected_package_name: ?[]const u8,
    ) !Fixture {
        const io = testing.io;

        var temporary = std.testing.tmpDir(.{});
        errdefer temporary.cleanup();
        const build_dir = try temporary.dir.realPathFileAlloc(io, ".", allocator);
        errdefer allocator.free(build_dir);

        var parser = pkgbuild_mod.PkgbuildParser{
            .allocator = allocator,
            .io = io,
            .selected_package_name = selected_package_name,
        };
        var info = try parser.parser_content(pkgbuild_content, build_dir);
        errdefer info.deinit(allocator);

        var operation_context = op_context.OperationContext.init(allocator, io);
        errdefer operation_context.deinit();

        if (event_handler) |handler| {
            _ = try operation_context.subscribe(handler);
        }

        var dispatcher = events.Dispatcher.init(allocator);
        errdefer dispatcher.deinit();

        const config_content = try std.fmt.allocPrint(
            allocator,
            "builddir={s}\npkgdest={s}\n",
            .{ build_dir, build_dir },
        );
        defer allocator.free(config_content);
        const config = try MakePkgConfiguration.initFromBuffer(io, allocator, config_content);
        errdefer config.deinit();

        const builder = try PackageBuilder.init(allocator, info, dispatcher, operation_context, config.*, io);

        return .{
            .builder = builder,
            .operation_context = operation_context,
            .config = config,
            .build_dir = build_dir,
            .allocator = allocator,
            .temporary = temporary,
        };
    }

    fn destroy(self: *Fixture) void {
        // PackageBuilder exposes no teardown, so release the state it holds
        // (received by value in init) and then the builder allocation
        // itself — contents first, container second. The operation context is
        // deinitialized through the fixture's copy, which shares the
        // subscription storage the builder's copy was created from. The
        // testing allocator fails the test if anything is missed.
        self.builder.package_build.deinit(self.allocator);
        self.builder.dispatcher.deinit();
        self.allocator.destroy(self.builder);
        self.config.deinit();
        self.operation_context.deinit();
        self.allocator.free(self.build_dir);
        self.temporary.cleanup();
    }
};

fn printPackageTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    package_directory: []const u8,
) !void {
    var directory = try std.Io.Dir.cwd().openDir(io, package_directory, .{ .iterate = true });
    defer directory.close(io);

    var walker = try directory.walk(allocator);
    defer walker.deinit();

    std.debug.print("[builder-test] staged package tree: {s}\n", .{package_directory});
    while (try walker.next(io)) |entry| {
        const stat = try entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false });
        const mode = stat.permissions.toMode() & 0o7777;
        std.debug.print(
            "[builder-test]   {s: <13} {o:0>4} {s}\n",
            .{ @tagName(entry.kind), mode, entry.path },
        );
    }
}

test "PackageBuilder init keeps the provided collaborators" {
    const allocator = testing.allocator;

    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\
        \\build() {
        \\  true
        \\}
    , null, null);
    defer fixture.destroy();

    try testing.expectEqual(fixture.allocator, fixture.builder.allocator);
    try testing.expectEqualStrings("demo", fixture.builder.package_build.pkg_name.?);
}

test "PackageBuilder runs execution steps in the configured build directory" {
    const allocator = testing.allocator;
    const io = testing.io;

    var capture: CompletionCapture = .{};
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1.0
        \\arch=('any')
        \\
        \\build() {
        \\  echo built > build-marker
        \\}
        \\package() {
        \\  mkdir -p "$pkgdir"
        \\  echo packaged > "$pkgdir/package-marker"
        \\}
    , .{ .function = CompletionCapture.handle, .data = &capture }, null);
    defer fixture.destroy();

    var artifact = try fixture.builder.BuildPackage();
    defer artifact.deinit(allocator);

    // Both steps ran, in makepkg order, inside the configured build
    // directory (the markers only exist when cwd is the build directory).
    try fixture.temporary.dir.access(io, "build-marker", .{});
    try fixture.temporary.dir.access(io, "pkg/demo/package-marker", .{});

    // The artifact identifies the built package and owns its storage
    // (deinit above must not free borrowed memory).
    try testing.expectEqualStrings("demo", artifact.package_name);
    try testing.expect(artifact.path.len > 0);
    try testing.expect(std.mem.endsWith(u8, artifact.path, "demo-1.0-any.pkg.tar.zst"));
    try std.Io.Dir.cwd().access(io, artifact.path, .{});

    // The operation completed successfully.
    try testing.expectEqual(op_context.CompletionStatus.success, capture.completion.?);
}

test "PackageBuilder reports failure when a step exits non-zero" {
    const allocator = testing.allocator;

    var capture: CompletionCapture = .{};
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\
        \\build() {
        \\  exit 3
        \\}
    , .{ .function = CompletionCapture.handle, .data = &capture }, null);
    defer fixture.destroy();

    var errors: ErrorCapture = .{};
    _ = try fixture.builder.dispatcher.addErrorHandler(.{
        .function = ErrorCapture.handle,
        .data = &errors,
    });

    // A failing step must surface as an error result, not a silent success.
    if (fixture.builder.BuildPackage()) |artifact| {
        var copy = artifact;
        copy.deinit(allocator);
        return error.ExpectedStepFailure;
    } else |_| {}

    // The failure is reported to error listeners and to the operation.
    try testing.expectEqual(@as(usize, 1), errors.count);
    try testing.expectEqual(op_context.CompletionStatus.failed, capture.completion.?);
}

test "PackageBuilder reports failure instead of crashing without execution steps" {
    const allocator = testing.allocator;

    // A PKGBUILD that defines none of the well-known functions produces no
    // execution steps; BuildPackage must report this gracefully instead of
    // unwrapping a null optional.
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1.0
    , null, null);
    defer fixture.destroy();

    if (fixture.builder.BuildPackage()) |artifact| {
        var copy = artifact;
        copy.deinit(allocator);
        return error.ExpectedMissingSteps;
    } else |_| {}
}
/// The repository PKGBUILD-bin, vendored verbatim: a real split package
/// whose package_shelly-bin() step installs prebuilt binaries plus
/// heredoc-generated desktop entries, a polkit policy, icons and shell
/// completions. Everything the step needs is placed in $srcdir by the
/// test, mirroring what makepkg extracts, so the build runs offline.
const shelly_bin_pkgbuild =
    \\# Maintainer: Zoey Bauer <zoey.erin.bauer@gmail.com>
    \\# Maintainer: Caroline Snyder <hirpeng@gmail.com>
    \\pkgbase=shelly-bin
    \\pkgname=('shelly-bin' 'shelly-flatpak-backend-bin')
    \\pkgver=3.0.3
    \\pkgrel=1
    \\arch=('x86_64')
    \\url="https://github.com/Seafoam-Labs/Shelly-ALPM"
    \\license=('GPL-3.0-only')
    \\source=(
    \\    "Shelly-ALPM-linux-x64-${pkgver}.tar.gz::https://github.com/Seafoam-Labs/Shelly-ALPM/releases/download/v${pkgver}/Shelly-ALPM-linux-x64.tar.gz"
    \\    "Shelly-Flatpak-Backend-linux-x64-${pkgver}.tar.gz::https://github.com/Seafoam-Labs/Shelly-ALPM/releases/download/v${pkgver}/Shelly-Flatpak-Backend-linux-x64.tar.gz"
    \\)
    \\
    \\sha256sums=('1c696140104d7f51eaa5fe6488b32f4a0d441944c1f127ad9507399b156f8ce6'
    \\            '46907ce81348430aefbb27cd865cc2470aba9087d352a5f1c3cfb9d576f34f16')
    \\
    \\package_shelly-bin() {
    \\  pkgdesc="Shelly: A Modern Arch Package Manager (prebuilt binary)"
    \\  provides=('shelly')
    \\  conflicts=('shelly' 'shelly-git')
    \\  depends=(
    \\      'pacman'
    \\      'gtk4'
    \\      'glib2'
    \\      'sudo'
    \\      'tar'
    \\      'bash'
    \\      'git'
    \\      'hicolor-icon-theme'
    \\      'dbus'
    \\      'glibc'
    \\      'libarchive'
    \\      'dconf'
    \\      'gnupg'
    \\      'zstd'
    \\      'json-glib'
    \\  )
    \\  optdepends=(
    \\      'fish: Fish shell completions'
    \\      'zsh: Zsh shell completions'
    \\      'libstarfish: dependency viewer for arch packages'
    \\      'shelly-flatpak-backend-bin: Flatpak package management support'
    \\      'fuse2: run AppImages that require FUSE 2'
    \\  )
    \\
    \\  # Install Shelly.Gtk binary
    \\  install -Dm755 "$srcdir/shelly-ui" "$pkgdir/usr/bin/shelly-ui"
    \\
    \\  # Install Shelly-Notifications binary
    \\  install -Dm755 "$srcdir/shelly-notifications" "$pkgdir/usr/bin/shelly-notifications"
    \\
    \\  # Install Shelly.Cli binary
    \\  install -Dm755 "$srcdir/shelly" "$pkgdir/usr/bin/shelly"
    \\
    \\  # Install Shelly.Key binary
    \\  install -Dm755 "$srcdir/shelly-key" "$pkgdir/usr/bin/shelly-key"
    \\
    \\  # Install desktop entry
    \\  cat <<'EOF' | install -Dm644 /dev/stdin "$pkgdir/usr/share/applications/com.shellyorg.shelly.desktop"
    \\[Desktop Entry]
    \\Name=Shelly
    \\Comment=A Modern Arch Package Manager
    \\Exec=/usr/bin/shelly-ui %u
    \\Icon=shelly
    \\Type=Application
    \\Categories=System;Utility;
    \\Keywords=program;software;store;repository;package;add;install;uninstall;remove;update;apps;applications;flatpak;pacman;aur;appimage;
    \\MimeType=x-scheme-handler/appstream;x-scheme-handler/flatpak+https;
    \\Terminal=false
    \\X-GNOME-UsesNotifications=true
    \\Actions=FlatpakInstall;FlatpakUpdate;FlatpakRemove;
    \\
    \\[Desktop Action FlatpakInstall]
    \\Name=Flatpak Install
    \\Icon=flatpak-symbolic
    \\Exec=/usr/bin/shelly-ui --page flatpak-install
    \\
    \\[Desktop Action FlatpakUpdate]
    \\Name=Flatpak Update
    \\Icon=flatpak-symbolic
    \\Exec=/usr/bin/shelly-ui --page flatpak-update
    \\
    \\[Desktop Action FlatpakRemove]
    \\Name=Flatpak Remove
    \\Icon=flatpak-symbolic
    \\Exec=/usr/bin/shelly-ui --page flatpak-remove
    \\EOF
    \\
    \\  # Install desktop entry for notification service
    \\  cat <<'EOF' | install -Dm644 /dev/stdin "$pkgdir/usr/share/applications/com.shellyorg.shelly-notifications.desktop"
    \\[Desktop Entry]
    \\Name=Shelly Notifications
    \\Comment=Notification service for Shelly package manager
    \\Exec=/usr/bin/shelly-notifications
    \\Icon=shelly-tray
    \\Type=Application
    \\Categories=System;Utility;
    \\Keywords=program;software;store;repository;package;add;install;uninstall;remove;update;apps;applications;flatpak;pacman;aur;appimage;
    \\Terminal=false
    \\NoDisplay=true
    \\EOF
    \\
    \\  # Ensure the polkit directory exists
    \\  install -m0755 -d "${pkgdir}"/usr/share/polkit-1/actions
    \\
    \\  # Install Polkit policy for privileged Shelly CLI execution via pkexec
    \\  cat <<'EOF' | install -Dm644 /dev/stdin "$pkgdir/usr/share/polkit-1/actions/com.shellyorg.shelly.policy"
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE policyconfig PUBLIC "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
    \\ "http://www.freedesktop.org/standards/PolicyKit/1.0/policyconfig.dtd">
    \\<policyconfig>
    \\  <vendor>Shelly</vendor>
    \\  <vendor_url>https://github.com/Seafoam-Labs/Shelly-ALPM</vendor_url>
    \\  <action id="com.shellyorg.shelly.pkexec.cli">
    \\    <description>Run Shelly CLI as administrator</description>
    \\    <message>Run Shelly CLI with administrator privileges.</message>
    \\    <icon_name>shelly</icon_name>
    \\    <defaults>
    \\      <allow_any>auth_admin</allow_any>
    \\      <allow_inactive>auth_admin</allow_inactive>
    \\      <allow_active>auth_admin_keep</allow_active>
    \\    </defaults>
    \\    <annotate key="org.freedesktop.policykit.exec.path">/usr/bin/shelly</annotate>
    \\  </action>
    \\</policyconfig>
    \\EOF
    \\
    \\  # Install icon
    \\  install -Dm644 "$srcdir/shellylogo.png" "$pkgdir/usr/share/icons/hicolor/256x256/apps/shelly.png"
    \\
    \\  install -Dm644 "$srcdir/shellylogo-tray.png" "$pkgdir/usr/share/icons/hicolor/256x256/apps/shelly-tray.png"
    \\  install -Dm644 "$srcdir/shellylogo-update.png" "$pkgdir/usr/share/icons/hicolor/256x256/apps/shelly-update.png"
    \\
    \\  # Install fish shell completions
    \\  install -Dm644 "$srcdir/shelly.fish" "$pkgdir/usr/share/fish/vendor_completions.d/shelly.fish"
    \\
    \\  # Install zsh shell completions
    \\  install -Dm644 "$srcdir/_shelly" "$pkgdir/usr/share/zsh/site-functions/_shelly"
    \\
    \\  # Install translations
    \\if [ -d "$srcdir/locale" ] && [ -n "$(ls -A "$srcdir/locale" 2>/dev/null)" ]; then
    \\    install -d "$pkgdir/usr/share/locale"
    \\    cp -r "$srcdir/locale/."/* "$pkgdir/usr/share/locale/" 2>/dev/null || true
    \\fi
    \\
    \\  # Install Flatpak integration script
    \\  cat <<'SCRIPT' | install -Dm755 /dev/stdin "$pkgdir/usr/bin/shelly-flatpak-integrate"
    \\#!/bin/bash
    \\# Adds "Manage in Shelly" right-click action to all Flatpak .desktop files
    \\FLATPAK_DIRS=(
    \\    "/var/lib/flatpak/exports/share/applications"
    \\    "$HOME/.local/share/flatpak/exports/share/applications"
    \\)
    \\LOCAL_APPS_DIR="$HOME/.local/share/applications"
    \\mkdir -p "$LOCAL_APPS_DIR"
    \\
    \\for dir in "${FLATPAK_DIRS[@]}"; do
    \\    [ -d "$dir" ] || continue
    \\    for desktop_file in "$dir"/*.desktop; do
    \\        [ -f "$desktop_file" ] || continue
    \\        filename=$(basename "$desktop_file")
    \\        app_id="${filename%.desktop}"
    \\        dest="$LOCAL_APPS_DIR/$filename"
    \\
    \\        # Copy if override doesn't exist yet
    \\        [ -f "$dest" ] || cp "$desktop_file" "$dest"
    \\
    \\        # Skip if already patched
    \\        grep -q "ShellyManage" "$dest" && continue
    \\
    \\        # Add action to existing Actions= line or insert one
    \\        if grep -q "^Actions=" "$dest"; then
    \\            sed -i 's/^Actions=\(.*\)/Actions=\1ShellyManage;/' "$dest"
    \\        else
    \\            sed -i '/^\[Desktop Entry\]/a Actions=ShellyManage;' "$dest"
    \\        fi
    \\
    \\        cat >> "$dest" << EOF
    \\
    \\[Desktop Action ShellyManage]
    \\Name=Manage in Shelly
    \\Icon=shelly
    \\Exec=/usr/bin/shelly-ui --page flatpak-install
    \\EOF
    \\    done
    \\done
    \\
    \\update-desktop-database "$LOCAL_APPS_DIR" 2>/dev/null || true
    \\echo "Flatpak desktop entries patched with Shelly integration."
    \\SCRIPT
    \\}
    \\
    \\package_shelly-flatpak-backend-bin() {
    \\  pkgdesc="Optional native Flatpak backend for Shelly (prebuilt binary)"
    \\  depends=("shelly-bin=${pkgver}-${pkgrel}" 'flatpak')
    \\  provides=("shelly-flatpak-backend=${pkgver}")
    \\  conflicts=('shelly-flatpak-backend' 'shelly-flatpak-backend-git')
    \\
    \\  install -Dm755 \
    \\    "$srcdir/libshelly-flatpak-backend.so.1.0.0" \
    \\    "$pkgdir/usr/lib/shelly/libshelly-flatpak-backend.so.1.0.0"
    \\  ln -s libshelly-flatpak-backend.so.1.0.0 \
    \\    "$pkgdir/usr/lib/shelly/libshelly-flatpak-backend.so.1"
    \\}
;

test "PackageBuilder builds a real package from the repository PKGBUILD-bin" {
    const allocator = testing.allocator;
    const io = testing.io;

    var capture: CompletionCapture = .{};
    var fixture = try Fixture.create(allocator, shelly_bin_pkgbuild, .{
        .function = CompletionCapture.handle,
        .data = &capture,
    }, "shelly-bin");
    defer fixture.destroy();

    std.debug.print("[builder-test] building vendored PKGBUILD-bin ({d} bytes) as package 'shelly-bin'\n", .{shelly_bin_pkgbuild.len});
    std.debug.print("[builder-test] build directory: {s}\n", .{fixture.build_dir});

    // Populate $srcdir the way makepkg would after extracting the release
    // tarballs referenced by the PKGBUILD's source array.
    try fixture.temporary.dir.createDir(io, "src", .default_dir);
    for ([_][]const u8{ "shelly-ui", "shelly-notifications", "shelly", "shelly-key" }) |binary| {
        const sub_path = try std.fmt.allocPrint(allocator, "src/{s}", .{binary});
        defer allocator.free(sub_path);
        try fixture.temporary.dir.writeFile(io, .{ .sub_path = sub_path, .data = "#!/bin/sh\nexit 0\n" });
    }
    for ([_][]const u8{ "src/shellylogo.png", "src/shellylogo-tray.png", "src/shellylogo-update.png" }) |icon| {
        try fixture.temporary.dir.writeFile(io, .{ .sub_path = icon, .data = "placeholder icon bytes" });
    }
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "src/shelly.fish", .data = "# fish completions\n" });
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "src/_shelly", .data = "# zsh completions\n" });

    var artifact = try fixture.builder.BuildPackage();
    defer artifact.deinit(allocator);

    try testing.expectEqualStrings("shelly-bin", artifact.package_name);
    try testing.expect(artifact.path.len > 0);
    try testing.expect(std.mem.endsWith(u8, artifact.path, "shelly-bin-3.0.3-1-x86_64.pkg.tar.zst"));
    try std.Io.Dir.cwd().access(io, artifact.path, .{});
    std.debug.print("[builder-test] BuildPackage succeeded: artifact '{s}' at {s}\n", .{ artifact.package_name, artifact.path });

    // package_shelly-bin installed the full tree into $pkgdir.
    const pkgdir = try std.fs.path.join(allocator, &.{ fixture.build_dir, "pkg", "shelly-bin" });
    defer allocator.free(pkgdir);
    try printPackageTree(allocator, io, pkgdir);

    // Binaries and generated scripts are installed executable.
    for ([_][]const u8{
        "usr/bin/shelly-ui",
        "usr/bin/shelly-notifications",
        "usr/bin/shelly",
        "usr/bin/shelly-key",
        "usr/bin/shelly-flatpak-integrate",
    }) |file| {
        const path = try std.fs.path.join(allocator, &.{ pkgdir, file });
        defer allocator.free(path);
        const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
        try testing.expect(stat.permissions.toMode() & 0o111 != 0);
        std.debug.print("[builder-test]   executable installed: {s}\n", .{file});
    }

    // Remaining payload files are installed as data.
    for ([_][]const u8{
        "usr/share/applications/com.shellyorg.shelly.desktop",
        "usr/share/applications/com.shellyorg.shelly-notifications.desktop",
        "usr/share/polkit-1/actions/com.shellyorg.shelly.policy",
        "usr/share/icons/hicolor/256x256/apps/shelly.png",
        "usr/share/icons/hicolor/256x256/apps/shelly-tray.png",
        "usr/share/icons/hicolor/256x256/apps/shelly-update.png",
        "usr/share/fish/vendor_completions.d/shelly.fish",
        "usr/share/zsh/site-functions/_shelly",
    }) |file| {
        const path = try std.fs.path.join(allocator, &.{ pkgdir, file });
        defer allocator.free(path);
        try std.Io.Dir.cwd().access(io, path, .{});
        std.debug.print("[builder-test]   file installed:       {s}\n", .{file});
    }

    // Quoted-heredoc bodies must reach the installed files verbatim: $HOME
    // and ${filename%.desktop} inside the flatpak integration script are
    // runtime shell, not PKGBUILD-time expansion.
    const integrate_path = try std.fs.path.join(allocator, &.{ pkgdir, "usr/bin/shelly-flatpak-integrate" });
    defer allocator.free(integrate_path);
    const integrate = try std.Io.Dir.cwd().readFileAlloc(io, integrate_path, allocator, .unlimited);
    defer allocator.free(integrate);
    try testing.expect(std.mem.indexOf(u8, integrate, "$HOME/.local/share/applications") != null);
    try testing.expect(std.mem.indexOf(u8, integrate, "${filename%.desktop}") != null);
    std.debug.print("[builder-test] quoted heredoc preserved: $HOME and ${{filename%.desktop}} intact in installed script\n", .{});

    // The desktop entry content came through the heredoc unchanged.
    const desktop_path = try std.fs.path.join(allocator, &.{ pkgdir, "usr/share/applications/com.shellyorg.shelly.desktop" });
    defer allocator.free(desktop_path);
    const desktop = try std.Io.Dir.cwd().readFileAlloc(io, desktop_path, allocator, .unlimited);
    defer allocator.free(desktop);
    try testing.expect(std.mem.indexOf(u8, desktop, "Name=Shelly\n") != null);

    // Read the assembled package back through libarchive. Metadata must be
    // present, staged modes must survive, and ownership must be normalized to
    // root independently of the user running the test.
    var package_reader = try archive.Reader.init(allocator, artifact.path);
    defer package_reader.deinit();
    var saw_pkginfo = false;
    var saw_buildinfo = false;
    var saw_mtree = false;
    var saw_executable = false;
    var saw_data_file = false;
    while (try package_reader.next()) |entry| {
        try testing.expectEqual(@as(i64, 0), entry.uid);
        try testing.expectEqual(@as(i64, 0), entry.gid);
        if (std.mem.eql(u8, entry.path, ".PKGINFO")) {
            saw_pkginfo = true;
            var contents: [16 * 1024]u8 = undefined;
            const amount = try package_reader.readPrefix(&contents);
            try testing.expect(std.mem.indexOf(u8, contents[0..amount], "pkgname = shelly-bin\n") != null);
        } else if (std.mem.eql(u8, entry.path, ".BUILDINFO")) {
            saw_buildinfo = true;
        } else if (std.mem.eql(u8, entry.path, ".MTREE")) {
            saw_mtree = true;
        } else if (std.mem.eql(u8, entry.path, "usr/bin/shelly")) {
            saw_executable = true;
            try testing.expectEqual(@as(u32, 0o755), entry.permissions);
        } else if (std.mem.eql(u8, entry.path, "usr/share/applications/com.shellyorg.shelly.desktop")) {
            saw_data_file = true;
            try testing.expectEqual(@as(u32, 0o644), entry.permissions);
        }
    }
    try testing.expect(saw_pkginfo);
    try testing.expect(saw_buildinfo);
    try testing.expect(saw_mtree);
    try testing.expect(saw_executable);
    try testing.expect(saw_data_file);

    // libalpm is the final consumer of the artifact. Loading it here catches
    // package-format or metadata defects that a libarchive readback alone
    // would accept.
    try fixture.temporary.dir.createDir(io, "alpm-root", .default_dir);
    try fixture.temporary.dir.createDir(io, "alpm-db", .default_dir);
    const alpm_root = try std.fs.path.joinZ(allocator, &.{ fixture.build_dir, "alpm-root" });
    defer allocator.free(alpm_root);
    const alpm_db = try std.fs.path.joinZ(allocator, &.{ fixture.build_dir, "alpm-db" });
    defer allocator.free(alpm_db);

    var alpm_error: raw_alpm.alpm_errno_t = 0;
    const alpm_handle = raw_alpm.alpm_initialize(alpm_root.ptr, alpm_db.ptr, &alpm_error) orelse
        return error.AlpmInitializeFailed;
    defer _ = raw_alpm.alpm_release(alpm_handle);

    var loaded_package: ?*raw_alpm.alpm_pkg_t = null;
    try testing.expectEqual(
        @as(c_int, 0),
        raw_alpm.alpm_pkg_load(alpm_handle, artifact.path.ptr, 1, 0, &loaded_package),
    );
    try testing.expect(loaded_package != null);
    defer _ = raw_alpm.alpm_pkg_free(loaded_package.?);
    try testing.expectEqualStrings("shelly-bin", std.mem.span(raw_alpm.alpm_pkg_get_name(loaded_package.?)));

    // The operation completed successfully.
    try testing.expectEqual(op_context.CompletionStatus.success, capture.completion.?);
    std.debug.print("[builder-test] operation completed: {s}\n", .{@tagName(capture.completion.?)});
}

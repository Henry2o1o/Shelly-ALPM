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
//! * `PackageBuilder.deinit` releases only the builder container. Its parsed
//!   PKGBUILDs, requested names, dispatcher, and operation context are borrowed
//!   from the caller and remain fixture-owned.

const std = @import("std");
const testing = std.testing;

const builder_mod = @import("builder.zig");
const PackageBuilder = builder_mod.PackageBuilder;
const process_runner = @import("../builder.zig");
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
    package_builds: []pkgbuild_mod.Pkgbuild,
    requested_names: [][]const u8,
    operation_context: op_context.OperationContext,
    config: *MakePkgConfiguration,
    // Sentinel-terminated: realPathFileAlloc allocates len+1 for the 0 byte,
    // and free() only releases the full allocation when the slice type still
    // carries the sentinel.
    build_dir: [:0]const u8,
    allocator: std.mem.Allocator,
    temporary: std.testing.TmpDir,

    /// Parses `pkgbuild_content`, creates a per-test build directory, and
    /// constructs a PackageBuilder around them. The builder borrows parsed
    /// PKGBUILD data and requested names; the fixture owns and releases them.
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

        const package_builds = try allocator.alloc(pkgbuild_mod.Pkgbuild, 1);
        errdefer allocator.free(package_builds);
        package_builds[0] = info;
        const requested_names = try allocator.alloc([]const u8, 1);
        errdefer allocator.free(requested_names);
        requested_names[0] = info.pkg_name orelse "";
        const builder = try PackageBuilder.init(
            allocator,
            package_builds,
            dispatcher,
            operation_context,
            config.*,
            requested_names,
            .{
                .run_check = true,
                .overwrite = true,
                .clean_after_success = false,
                .skip_source_pgp_verification = true,
                .build_directory = build_dir,
                .sources_prepared = true,
            },
            testing.environ,
            io,
        );

        return .{
            .builder = builder,
            .package_builds = package_builds,
            .requested_names = requested_names,
            .operation_context = operation_context,
            .config = config,
            .build_dir = build_dir,
            .allocator = allocator,
            .temporary = temporary,
        };
    }

    fn createMany(
        allocator: std.mem.Allocator,
        pkgbuild_content: []const u8,
        requested: []const []const u8,
        event_handler: ?op_context.EventHandler,
    ) !Fixture {
        const io = testing.io;
        var temporary = std.testing.tmpDir(.{});
        errdefer temporary.cleanup();
        const build_dir = try temporary.dir.realPathFileAlloc(io, ".", allocator);
        errdefer allocator.free(build_dir);

        const package_builds = try allocator.alloc(pkgbuild_mod.Pkgbuild, requested.len);
        var parsed_count: usize = 0;
        errdefer {
            for (package_builds[0..parsed_count]) |*package_build| package_build.deinit(allocator);
            allocator.free(package_builds);
        }
        for (requested, package_builds) |requested_name, *package_build| {
            package_build.* = try (pkgbuild_mod.PkgbuildParser{
                .allocator = allocator,
                .io = io,
                .selected_package_name = requested_name,
            }).parser_content(pkgbuild_content, build_dir);
            parsed_count += 1;
        }

        var operation_context = op_context.OperationContext.init(allocator, io);
        errdefer operation_context.deinit();
        if (event_handler) |handler| _ = try operation_context.subscribe(handler);
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
        const requested_names = try allocator.dupe([]const u8, requested);
        errdefer allocator.free(requested_names);
        const builder = try PackageBuilder.init(
            allocator,
            package_builds,
            dispatcher,
            operation_context,
            config.*,
            requested_names,
            .{
                .run_check = true,
                .overwrite = true,
                .clean_after_success = false,
                .skip_source_pgp_verification = true,
                .build_directory = build_dir,
                .sources_prepared = true,
            },
            testing.environ,
            io,
        );

        return .{
            .builder = builder,
            .package_builds = package_builds,
            .requested_names = requested_names,
            .operation_context = operation_context,
            .config = config,
            .build_dir = build_dir,
            .allocator = allocator,
            .temporary = temporary,
        };
    }

    fn destroy(self: *Fixture) void {
        // Release borrowed inputs and the copied dispatcher before destroying
        // the builder container. The testing allocator catches omissions.
        for (self.package_builds) |*package_build| package_build.deinit(self.allocator);
        self.allocator.free(self.package_builds);
        self.allocator.free(self.requested_names);
        self.builder.dispatcher.deinit();
        self.builder.deinit();
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

fn readPkgInfo(allocator: std.mem.Allocator, package_path: []const u8) ![]u8 {
    var reader = try archive.Reader.init(allocator, package_path);
    defer reader.deinit();
    while (try reader.next()) |entry| {
        if (!std.mem.eql(u8, entry.path, ".PKGINFO")) continue;
        var buffer: [32 * 1024]u8 = undefined;
        const amount = try reader.readPrefix(&buffer);
        return allocator.dupe(u8, buffer[0..amount]);
    }
    return error.MissingPkgInfo;
}

fn runTestCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    working_directory: ?[]const u8,
) !void {
    var result = try process_runner.run(allocator, io, argv, working_directory, null);
    defer result.deinit(allocator);
    if (result.exit_code != 0) {
        std.debug.print("builder fixture command failed ({d}): {s}\n", .{ result.exit_code, result.stderr });
        return error.FixtureCommandFailed;
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
    try testing.expectEqualStrings("demo", fixture.builder.package_builds[0].pkg_name.?);
}

test "non-root worker guard rejects root effective uid" {
    try testing.expectError(
        error.BuilderMustNotRunAsRoot,
        builder_mod.requireNonRootEffectiveUid(0),
    );
    try builder_mod.requireNonRootEffectiveUid(1000);
}

test "root effective uid selects the de-escalated worker boundary" {
    try testing.expect(builder_mod.requiresDeescalatedWorker(0));
    try testing.expect(!builder_mod.requiresDeescalatedWorker(1000));
}

test "PackageBuilder rejects a legacy unwritable package tree" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\package() {
        \\  mkdir -p "$pkgdir/usr"
        \\}
    , null, null);
    defer fixture.destroy();

    try fixture.temporary.dir.createDirPath(io, "pkg/demo");
    try fixture.temporary.dir.setFilePermissions(io, "pkg", .fromMode(0o555), .{});
    defer fixture.temporary.dir.setFilePermissions(io, "pkg", .fromMode(0o755), .{}) catch {};

    try testing.expectError(error.BuildDirectoryNotWritable, fixture.builder.BuildPackage());
}

test "PackageBuilder rejects privileged package filesystem operations" {
    const allocator = testing.allocator;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/demo"
        \\  mknod "$pkgdir/usr/share/demo/device" c 1 3
        \\}
    , null, null);
    defer fixture.destroy();

    try testing.expectError(
        error.PrivilegedPackageOperationUnsupported,
        fixture.builder.BuildPackage(),
    );
}

test "PackageBuilder simulates root ownership without host chown" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\arch=('any')
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/demo"
        \\  printf payload > "$pkgdir/usr/share/demo/data"
        \\  chown root:root "$pkgdir/usr/share/demo/data"
        \\  install -o root -g root -m 0644 /dev/null "$pkgdir/usr/share/demo/installed"
        \\}
    , null, null);
    defer fixture.destroy();

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);

    const staged_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "pkg/demo/usr/share/demo/data" });
    defer allocator.free(staged_path);
    var stat_result = try process_runner.run(allocator, io, &.{ "stat", "-c", "%u", staged_path }, null, null);
    defer stat_result.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), stat_result.exit_code);
    var expected_uid_buffer: [32]u8 = undefined;
    const expected_uid = try std.fmt.bufPrint(&expected_uid_buffer, "{d}", .{std.os.linux.geteuid()});
    try testing.expectEqualStrings(expected_uid, std.mem.trim(u8, stat_result.stdout, " \t\r\n"));

    var reader = try archive.Reader.init(allocator, artifacts[0].path);
    defer reader.deinit();
    var saw_data = false;
    var saw_installed = false;
    while (try reader.next()) |entry| {
        if (std.mem.eql(u8, entry.path, "usr/share/demo/data")) saw_data = true;
        if (std.mem.eql(u8, entry.path, "usr/share/demo/installed")) saw_installed = true;
        try testing.expectEqual(@as(i64, 0), entry.uid);
        try testing.expectEqual(@as(i64, 0), entry.gid);
    }
    try testing.expect(saw_data);
    try testing.expect(saw_installed);
}

test "PackageBuilder rejects unsupported virtual ownership" {
    const allocator = testing.allocator;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/demo"
        \\  touch "$pkgdir/usr/share/demo/data"
        \\  chown 42:84 "$pkgdir/usr/share/demo/data"
        \\}
    , null, null);
    defer fixture.destroy();

    try testing.expectError(
        error.PrivilegedPackageOperationUnsupported,
        fixture.builder.BuildPackage(),
    );
}

test "PackageBuilder applies explicit virtual ownership to the archive" {
    const allocator = testing.allocator;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\arch=('any')
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/demo"
        \\  printf payload > "$pkgdir/usr/share/demo/data"
        \\}
    , null, null);
    defer fixture.destroy();

    const overrides = [_]archive.OwnershipOverride{.{
        .path = "usr/share/demo/data",
        .ownership = .{ .uid = 42, .gid = 84 },
    }};
    fixture.builder.options.virtual_ownership_overrides = &overrides;

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    var reader = try archive.Reader.init(allocator, artifacts[0].path);
    defer reader.deinit();
    var saw_data = false;
    while (try reader.next()) |entry| {
        if (!std.mem.eql(u8, entry.path, "usr/share/demo/data")) continue;
        saw_data = true;
        try testing.expectEqual(@as(i64, 42), entry.uid);
        try testing.expectEqual(@as(i64, 84), entry.gid);
    }
    try testing.expect(saw_data);
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

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);
    const artifact = artifacts[0];

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

test "PackageBuilder runs local declarations and reviewed helper functions inside package steps" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=qwen-code-bin
        \\pkgver=1
        \\pkgrel=1
        \\arch=('x86_64')
        \\_target_name() {
        \\  local suffix=cli
        \\  printf '%s-%s' "$pkgname" "$suffix"
        \\}
        \\package() {
        \\  local appdir="$pkgdir/usr/lib/$pkgname"
        \\  mkdir -p "$appdir"
        \\  _target_name > "$appdir/target"
        \\}
    , null, null);
    defer fixture.destroy();

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    const target = try fixture.temporary.dir.readFileAlloc(
        io,
        "pkg/qwen-code-bin/usr/lib/qwen-code-bin/target",
        allocator,
        .unlimited,
    );
    defer allocator.free(target);
    try testing.expectEqualStrings("qwen-code-bin-cli", target);
}

test "PackageBuilder accepts b2 checksums and honors noextract" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=cline-cli
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('payload.tar.gz')
        \\noextract=('payload.tar.gz')
        \\b2sums=('3571ea965605821dbb49046a8de67321531bcefe1bb1d68282eed4ebdaff4f7feb63f710cede300638d3e44f825e3f3e436059d290f4d2749784bf01020f684e')
        \\package() {
        \\  install -Dm644 "$srcdir/payload.tar.gz" "$pkgdir/usr/share/cline-cli/payload.tar.gz"
        \\}
    , null, null);
    defer fixture.destroy();
    fixture.builder.options.sources_prepared = false;
    try fixture.temporary.dir.writeFile(io, .{
        .sub_path = "payload.tar.gz",
        .data = "opaque archive payload",
    });

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try fixture.temporary.dir.access(io, "src/payload.tar.gz", .{});
    try fixture.temporary.dir.access(io, "pkg/cline-cli/usr/share/cline-cli/payload.tar.gz", .{});
}

test "PackageBuilder stages and verifies local sources before build steps" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('helper.sh')
        \\sha256sums=('a9f2d25d1f71f8065e2119e538bde8846570fcdad320388236e99d9e225c290d')
        \\build() {
        \\  test "$(cat "$srcdir/helper.sh")" = reviewed
        \\}
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/demo"
        \\  cp "$srcdir/helper.sh" "$pkgdir/usr/share/demo/helper.sh"
        \\}
    , null, null);
    defer fixture.destroy();
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "helper.sh", .data = "reviewed\n" });
    fixture.builder.options.sources_prepared = false;

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);
    try fixture.temporary.dir.access(io, "src/helper.sh", .{});
    try fixture.temporary.dir.access(io, "pkg/demo/usr/share/demo/helper.sh", .{});
}

test "PackageBuilder rejects a source checksum mismatch without committing srcdir" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('helper.sh')
        \\sha256sums=('0000000000000000000000000000000000000000000000000000000000000000')
        \\package() {
        \\  mkdir -p "$pkgdir"
        \\}
    , null, null);
    defer fixture.destroy();
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "helper.sh", .data = "reviewed\n" });
    fixture.builder.options.sources_prepared = false;

    try testing.expectError(error.BuildFailed, fixture.builder.BuildPackage());
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "src", .{}));
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, ".src.shelly-staging", .{}));
}

test "PackageBuilder extracts source archives into srcdir" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('payload.tar.gz')
        \\sha256sums=('SKIP')
        \\build() {
        \\  test "$(cat "$srcdir/demo/source.txt")" = extracted
        \\}
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/demo"
        \\  cp "$srcdir/demo/source.txt" "$pkgdir/usr/share/demo/source.txt"
        \\}
    , null, null);
    defer fixture.destroy();
    const archive_path = try std.fs.path.join(allocator, &.{ fixture.build_dir, "payload.tar.gz" });
    defer allocator.free(archive_path);
    try archive.writeFixture(allocator, archive_path, .gzip, &.{
        .{ .path = "demo/source.txt", .contents = "extracted\n" },
    });
    fixture.builder.options.sources_prepared = false;

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);
    try fixture.temporary.dir.access(io, "src/payload.tar.gz", .{});
    try fixture.temporary.dir.access(io, "src/demo/source.txt", .{});
    try fixture.temporary.dir.access(io, "pkg/demo/usr/share/demo/source.txt", .{});
}

test "PackageBuilder downloads renamed file sources before build steps" {
    const allocator = testing.allocator;
    const io = testing.io;
    var remote = std.testing.tmpDir(.{});
    defer remote.cleanup();
    try remote.dir.writeFile(io, .{ .sub_path = "source.txt", .data = "reviewed\n" });
    const remote_path = try remote.dir.realPathFileAlloc(io, "source.txt", allocator);
    defer allocator.free(remote_path);
    const pkgbuild = try std.fmt.allocPrint(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('downloaded.txt::file://{s}')
        \\sha256sums=('a9f2d25d1f71f8065e2119e538bde8846570fcdad320388236e99d9e225c290d')
        \\package() {{
        \\  mkdir -p "$pkgdir/usr/share/demo"
        \\  cp "$srcdir/downloaded.txt" "$pkgdir/usr/share/demo/downloaded.txt"
        \\}}
    , .{remote_path});
    defer allocator.free(pkgbuild);
    var fixture = try Fixture.create(allocator, pkgbuild, null, null);
    defer fixture.destroy();
    fixture.builder.options.sources_prepared = false;

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);
    try fixture.temporary.dir.access(io, "src/downloaded.txt", .{});
    try fixture.temporary.dir.access(io, "pkg/demo/usr/share/demo/downloaded.txt", .{});
}

test "PackageBuilder rejects unsupported source protocols" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('hg+https://example.invalid/demo')
        \\sha256sums=('SKIP')
        \\package() {
        \\  mkdir -p "$pkgdir"
        \\}
    , null, null);
    defer fixture.destroy();
    fixture.builder.options.sources_prepared = false;

    try testing.expectError(error.BuildFailed, fixture.builder.BuildPackage());
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "src", .{}));
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, ".src.shelly-staging", .{}));
}

test "PackageBuilder cancels source preparation without committing srcdir" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('helper.sh')
        \\sha256sums=('SKIP')
        \\package() {
        \\  mkdir -p "$pkgdir"
        \\}
    , null, null);
    defer fixture.destroy();
    fixture.builder.options.sources_prepared = false;
    fixture.builder.operation_context.cancel();

    try testing.expectError(error.Cancelled, fixture.builder.BuildPackage());
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "src", .{}));
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, ".src.shelly-staging", .{}));
}

test "PackageBuilder clones renamed git sources into srcdir before pkgver" {
    const allocator = testing.allocator;
    const io = testing.io;
    var remote = std.testing.tmpDir(.{});
    defer remote.cleanup();
    const remote_path = try remote.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(remote_path);
    try remote.dir.writeFile(io, .{ .sub_path = "source-marker", .data = "checked out\n" });
    try runTestCommand(allocator, io, &.{ "git", "init", "-b", "development" }, remote_path);
    try runTestCommand(allocator, io, &.{ "git", "config", "user.email", "shelly-tests@example.invalid" }, remote_path);
    try runTestCommand(allocator, io, &.{ "git", "config", "user.name", "Shelly Tests" }, remote_path);
    try runTestCommand(allocator, io, &.{ "git", "add", "source-marker" }, remote_path);
    try runTestCommand(allocator, io, &.{ "git", "commit", "-m", "fixture" }, remote_path);

    const pkgbuild = try std.fmt.allocPrint(allocator,
        \\pkgname=shelly-git
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\source=('shelly-git::git+file://{s}#branch=development')
        \\sha256sums=('SKIP')
        \\pkgver() {{
        \\  cd "$srcdir/$pkgname"
        \\  test -f source-marker
        \\}}
        \\package() {{
        \\  mkdir -p "$pkgdir/usr/share/shelly"
        \\  cp "$srcdir/$pkgname/source-marker" "$pkgdir/usr/share/shelly/source-marker"
        \\}}
    , .{remote_path});
    defer allocator.free(pkgbuild);
    var fixture = try Fixture.create(allocator, pkgbuild, null, null);
    defer fixture.destroy();
    fixture.builder.options.sources_prepared = false;

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);
    try fixture.temporary.dir.access(io, "src/shelly-git/.git", .{});
    try fixture.temporary.dir.access(io, "src/shelly-git/source-marker", .{});
    try fixture.temporary.dir.access(io, "pkg/shelly-git/usr/share/shelly/source-marker", .{});
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
    if (fixture.builder.BuildPackage()) |artifacts| {
        builder_mod.deinitArtifacts(allocator, artifacts);
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

    if (fixture.builder.BuildPackage()) |artifacts| {
        builder_mod.deinitArtifacts(allocator, artifacts);
        return error.ExpectedMissingSteps;
    } else |_| {}
}

test "PackageBuilder builds all requested split members after shared steps run once" {
    const allocator = testing.allocator;
    const io = testing.io;
    const content =
        \\pkgbase=demo
        \\pkgname=('demo' 'demo-docs')
        \\pkgver=1.0
        \\pkgrel=1
        \\arch=('any')
        \\prepare() {
        \\  echo prepare >> shared-steps
        \\}
        \\build() {
        \\  echo build >> shared-steps
        \\}
        \\check() {
        \\  echo check >> shared-steps
        \\}
        \\package_demo() {
        \\  mkdir -p "$pkgdir/usr/bin"
        \\  echo executable > "$pkgdir/usr/bin/demo"
        \\  chmod 755 "$pkgdir/usr/bin/demo"
        \\}
        \\package_demo-docs() {
        \\  mkdir -p "$pkgdir/usr/share/doc/demo"
        \\  echo documentation > "$pkgdir/usr/share/doc/demo/readme"
        \\}
    ;
    const requested = [_][]const u8{ "demo", "demo-docs" };
    var fixture = try Fixture.createMany(allocator, content, &requested, null);
    defer fixture.destroy();

    try fixture.temporary.dir.createDirPath(io, "pkg/demo");
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "pkg/demo/stale", .data = "old" });

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 2), artifacts.len);
    try testing.expectEqualStrings("demo", artifacts[0].package_name);
    try testing.expectEqualStrings("demo-docs", artifacts[1].package_name);
    try testing.expect(std.mem.endsWith(u8, artifacts[0].path, "demo-1.0-1-any.pkg.tar.zst"));
    try testing.expect(std.mem.endsWith(u8, artifacts[1].path, "demo-docs-1.0-1-any.pkg.tar.zst"));

    const shared = try fixture.temporary.dir.readFileAlloc(io, "shared-steps", allocator, .unlimited);
    defer allocator.free(shared);
    try testing.expectEqualStrings("prepare\nbuild\ncheck\n", shared);

    var saw_main = false;
    var saw_stale = false;
    var main_reader = try archive.Reader.init(allocator, artifacts[0].path);
    defer main_reader.deinit();
    while (try main_reader.next()) |entry| {
        if (std.mem.eql(u8, entry.path, "usr/bin/demo")) saw_main = true;
        if (std.mem.eql(u8, entry.path, "stale")) saw_stale = true;
    }
    try testing.expect(saw_main);
    try testing.expect(!saw_stale);

    var saw_docs = false;
    var docs_reader = try archive.Reader.init(allocator, artifacts[1].path);
    defer docs_reader.deinit();
    while (try docs_reader.next()) |entry| {
        if (std.mem.eql(u8, entry.path, "usr/share/doc/demo/readme")) saw_docs = true;
    }
    try testing.expect(saw_docs);
}

test "PackageBuilder keeps shared split builds under the global pkgname" {
    const allocator = testing.allocator;
    const io = testing.io;
    const content =
        \\pkgbase=shelly-git
        \\pkgname=('shelly-git' 'shelly-flatpak-backend-git')
        \\pkgver=1
        \\pkgrel=1
        \\arch=('x86_64')
        \\build() {
        \\  mkdir -p "$srcdir/$pkgname/out/bin"
        \\  printf ui > "$srcdir/$pkgname/out/bin/Shelly_Ui_Gtk"
        \\  mkdir -p "$srcdir/$pkgbase/out-flatpak-backend"
        \\  printf backend > "$srcdir/$pkgbase/out-flatpak-backend/backend"
        \\}
        \\package_shelly-git() {
        \\  install -Dm755 "$srcdir/$pkgbase/out/bin/Shelly_Ui_Gtk" "$pkgdir/usr/bin/shelly-ui"
        \\}
        \\package_shelly-flatpak-backend-git() {
        \\  install -Dm755 "$srcdir/$pkgbase/out-flatpak-backend/backend" "$pkgdir/usr/bin/backend"
        \\}
    ;
    const requested = [_][]const u8{ "shelly-flatpak-backend-git", "shelly-git" };
    var fixture = try Fixture.createMany(allocator, content, &requested, null);
    defer fixture.destroy();

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try fixture.temporary.dir.access(io, "src/shelly-git/out/bin/Shelly_Ui_Gtk", .{});
    try fixture.temporary.dir.access(io, "pkg/shelly-git/usr/bin/shelly-ui", .{});
    try fixture.temporary.dir.access(io, "pkg/shelly-flatpak-backend-git/usr/bin/backend", .{});
}

test "PackageBuilder preserves selected split metadata in PKGINFO" {
    const allocator = testing.allocator;
    const io = testing.io;
    const content =
        \\pkgbase=shelly-git
        \\pkgname=('shelly-git' 'shelly-flatpak-backend-git')
        \\pkgver=1
        \\pkgrel=2
        \\pkgdesc='Shared description'
        \\arch=('x86_64')
        \\license=('GPL-3.0-only')
        \\makedepends=('zig')
        \\package_shelly-git() {
        \\  pkgdesc='Shelly git package'
        \\  provides=('shelly')
        \\  conflicts=('shelly' 'shelly-bin')
        \\  replaces=('old-shelly')
        \\  depends=('pacman' 'gtk4')
        \\  optdepends=('libstarfish: dependency viewer')
        \\  mkdir -p "$pkgdir/usr/bin"
        \\  printf main > "$pkgdir/usr/bin/shelly"
        \\}
        \\package_shelly-flatpak-backend-git() {
        \\  pkgdesc='Shelly Flatpak backend'
        \\  depends=("shelly-git=${pkgver}-${pkgrel}" 'flatpak')
        \\  mkdir -p "$pkgdir/usr/lib"
        \\  printf backend > "$pkgdir/usr/lib/backend"
        \\}
    ;
    const requested = [_][]const u8{ "shelly-git", "shelly-flatpak-backend-git" };
    var fixture = try Fixture.createMany(allocator, content, &requested, null);
    defer fixture.destroy();

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    const main_info = try readPkgInfo(allocator, artifacts[0].path);
    defer allocator.free(main_info);
    try testing.expect(std.mem.indexOf(u8, main_info, "pkgdesc = Shelly git package\n") != null);
    try testing.expect(std.mem.indexOf(u8, main_info, "provides = shelly\n") != null);
    try testing.expect(std.mem.indexOf(u8, main_info, "conflict = shelly\n") != null);
    try testing.expect(std.mem.indexOf(u8, main_info, "conflict = shelly-bin\n") != null);
    try testing.expect(std.mem.indexOf(u8, main_info, "replaces = old-shelly\n") != null);
    try testing.expect(std.mem.indexOf(u8, main_info, "depend = pacman\n") != null);
    try testing.expect(std.mem.indexOf(u8, main_info, "depend = gtk4\n") != null);
    try testing.expect(std.mem.indexOf(u8, main_info, "optdepend = libstarfish: dependency viewer\n") != null);

    const backend_info = try readPkgInfo(allocator, artifacts[1].path);
    defer allocator.free(backend_info);
    try testing.expect(std.mem.indexOf(u8, backend_info, "pkgdesc = Shelly Flatpak backend\n") != null);
    try testing.expect(std.mem.indexOf(u8, backend_info, "depend = shelly-git=1-2\n") != null);
    try testing.expect(std.mem.indexOf(u8, backend_info, "depend = flatpak\n") != null);
    try testing.expect(std.mem.indexOf(u8, backend_info, "provides = shelly\n") == null);

    try fixture.temporary.dir.createDir(io, "metadata-alpm-root", .default_dir);
    try fixture.temporary.dir.createDir(io, "metadata-alpm-db", .default_dir);
    const alpm_root = try std.fs.path.joinZ(allocator, &.{ fixture.build_dir, "metadata-alpm-root" });
    defer allocator.free(alpm_root);
    const alpm_db = try std.fs.path.joinZ(allocator, &.{ fixture.build_dir, "metadata-alpm-db" });
    defer allocator.free(alpm_db);
    var alpm_error: raw_alpm.alpm_errno_t = 0;
    const handle = raw_alpm.alpm_initialize(alpm_root.ptr, alpm_db.ptr, &alpm_error) orelse
        return error.AlpmInitializeFailed;
    defer _ = raw_alpm.alpm_release(handle);
    var loaded: ?*raw_alpm.alpm_pkg_t = null;
    try testing.expectEqual(@as(c_int, 0), raw_alpm.alpm_pkg_load(handle, artifacts[0].path.ptr, 1, 0, &loaded));
    defer _ = raw_alpm.alpm_pkg_free(loaded.?);
    const candidates = raw_alpm.alpm_list_add(null, @ptrCast(loaded.?)) orelse return error.OutOfMemory;
    defer raw_alpm.alpm_list_free(candidates);
    const virtual_dependency = try allocator.dupeZ(u8, "shelly");
    defer allocator.free(virtual_dependency);
    try testing.expectEqual(loaded.?, raw_alpm.alpm_find_satisfier(candidates, virtual_dependency.ptr).?);
}

test "PackageBuilder honors check and overwrite policies" {
    const allocator = testing.allocator;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\check() {
        \\  exit 9
        \\}
        \\package() {
        \\  mkdir -p "$pkgdir"
        \\  echo payload > "$pkgdir/file"
        \\}
    , null, null);
    defer fixture.destroy();
    fixture.builder.options.run_check = false;

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);

    fixture.builder.options.overwrite = false;
    try testing.expectError(error.AlreadyBuilt, fixture.builder.BuildPackage());
    try std.Io.Dir.cwd().access(testing.io, artifacts[0].path, .{});
}

test "PackageBuilder cleans work directories only after successful configured builds" {
    const allocator = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\package() {
        \\  mkdir -p "$pkgdir"
        \\  echo payload > "$pkgdir/file"
        \\}
    , null, null);
    defer fixture.destroy();
    try fixture.temporary.dir.createDirPath(io, "src");
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "src/source", .data = "source" });
    fixture.builder.options.clean_after_success = true;

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);
    try std.Io.Dir.cwd().access(io, artifacts[0].path, .{});
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "src", .{}));
    try testing.expectError(error.FileNotFound, fixture.temporary.dir.access(io, "pkg", .{}));
}

test "PackageBuilder rolls back completed split artifacts when a later member fails" {
    const allocator = testing.allocator;
    const io = testing.io;
    const content =
        \\pkgbase=demo
        \\pkgname=('demo' 'demo-docs')
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\package_demo() {
        \\  mkdir -p "$pkgdir"
        \\  echo executable > "$pkgdir/demo"
        \\}
        \\package_demo-docs() {
        \\  mkdir -p "$pkgdir"
        \\  echo documentation > "$pkgdir/docs"
        \\  exit 7
        \\}
    ;
    const requested = [_][]const u8{ "demo", "demo-docs" };
    var fixture = try Fixture.createMany(allocator, content, &requested, null);
    defer fixture.destroy();
    fixture.builder.options.clean_after_success = true;

    try testing.expectError(error.BuildFailed, fixture.builder.BuildPackage());
    try testing.expectError(
        error.FileNotFound,
        fixture.temporary.dir.access(io, "demo-1-1-any.pkg.tar.zst", .{}),
    );
    try fixture.temporary.dir.access(io, "pkg/demo/demo", .{});
    try fixture.temporary.dir.access(io, "pkg/demo-docs/docs", .{});
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
    \\  install -Dm755 "$srcdir/shelly-builder" "$pkgdir/usr/bin/shelly-builder"
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
    for ([_][]const u8{ "shelly-ui", "shelly-notifications", "shelly", "shelly-builder", "shelly-key" }) |binary| {
        const sub_path = try std.fmt.allocPrint(allocator, "src/{s}", .{binary});
        defer allocator.free(sub_path);
        try fixture.temporary.dir.writeFile(io, .{ .sub_path = sub_path, .data = "#!/bin/sh\nexit 0\n" });
    }
    for ([_][]const u8{ "src/shellylogo.png", "src/shellylogo-tray.png", "src/shellylogo-update.png" }) |icon| {
        try fixture.temporary.dir.writeFile(io, .{ .sub_path = icon, .data = "placeholder icon bytes" });
    }
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "src/shelly.fish", .data = "# fish completions\n" });
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "src/_shelly", .data = "# zsh completions\n" });

    const artifacts = try fixture.builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);
    try testing.expectEqual(@as(usize, 1), artifacts.len);
    const artifact = artifacts[0];

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
        "usr/bin/shelly-builder",
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

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
    build_dir: []const u8,
    allocator: std.mem.Allocator,
    temporary: std.testing.TmpDir,

    /// Parses `pkgbuild_content`, creates a per-test build directory, and
    /// constructs a PackageBuilder around them. Ownership of the parsed
    /// PKGBUILD and the dispatcher moves into the builder; the config and
    /// operation context remain owned here.
    ///
    /// `event_handler`, when provided, is subscribed to the operation context
    /// *before* the context is copied into the builder so the builder's copy
    /// (which dispatches during BuildPackage) sees the subscription.
    fn create(
        allocator: std.mem.Allocator,
        pkgbuild_content: []const u8,
        event_handler: ?op_context.EventHandler,
    ) !Fixture {
        const io = testing.io;

        var temporary = std.testing.tmpDir(.{});
        errdefer temporary.cleanup();
        const build_dir = try temporary.dir.realPathFileAlloc(io, ".", allocator);
        errdefer allocator.free(build_dir);

        var parser = pkgbuild_mod.PkgbuildParser{ .allocator = allocator, .io = io };
        var info = try parser.parser_content(pkgbuild_content, null);
        errdefer info.deinit(allocator);

        var operation_context = op_context.OperationContext.init(allocator, io);
        errdefer operation_context.deinit();

        if (event_handler) |handler| {
            _ = try operation_context.subscribe(handler);
        }

        var dispatcher = events.Dispatcher.init(allocator);
        errdefer dispatcher.deinit();

        const config_content = try std.fmt.allocPrint(allocator, "builddir={s}\n", .{build_dir});
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

test "PackageBuilder init keeps the provided collaborators" {
    const allocator = testing.allocator;

    var fixture = try Fixture.create(allocator,
        \\pkgname=demo
        \\
        \\build() {
        \\  true
        \\}
    , null);
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
        \\
        \\build() {
        \\  echo built > build-marker
        \\}
        \\package() {
        \\  echo packaged > package-marker
        \\}
    , .{ .function = CompletionCapture.handle, .data = &capture });
    defer fixture.destroy();

    var artifact = try fixture.builder.BuildPackage();
    defer artifact.deinit(allocator);

    // Both steps ran, in makepkg order, inside the configured build
    // directory (the markers only exist when cwd is the build directory).
    try fixture.temporary.dir.access(io, "build-marker", .{});
    try fixture.temporary.dir.access(io, "package-marker", .{});

    // The artifact identifies the built package and owns its storage
    // (deinit above must not free borrowed memory).
    try testing.expectEqualStrings("demo", artifact.package_name);
    try testing.expect(artifact.path.len > 0);

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
    , .{ .function = CompletionCapture.handle, .data = &capture });
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
    , null);
    defer fixture.destroy();

    if (fixture.builder.BuildPackage()) |artifact| {
        var copy = artifact;
        copy.deinit(allocator);
        return error.ExpectedMissingSteps;
    } else |_| {}
}

const std = @import("std");
const builder_mod = @import("builder.zig");
const protocol = @import("worker_protocol.zig");
const pkgbuild_parser = @import("../../pkgbuild/pkgbuild_parser.zig");
const MakePackageConfiguration = @import("../makepackage.zig").MakePackageConfiguration;
const events = @import("../events.zig");
const operation_api = @import("operation_context");
const review_integrity = @import("../review_integrity.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    run(allocator, init.io, init.minimal.environ, args) catch |err| {
        try writeResponse(allocator, .{ .error_name = @errorName(err) });
    };
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    args: []const []const u8,
) !void {
    if (@import("builtin").os.tag == .linux)
        try builder_mod.requireNonRootEffectiveUid(@intCast(std.os.linux.geteuid()));
    if (args.len != 2) return error.InvalidBuilderWorkerRequest;

    var parsed_request = try std.json.parseFromSlice(protocol.Request, allocator, args[1], .{
        .ignore_unknown_fields = true,
    });
    defer parsed_request.deinit();
    const request = parsed_request.value;
    if (request.version != protocol.protocol_version or request.requested_names.len == 0)
        return error.InvalidBuilderWorkerRequest;

    const pkgbuild_path = try std.fs.path.join(allocator, &.{ request.build_directory, "PKGBUILD" });
    defer allocator.free(pkgbuild_path);
    const content = try std.Io.Dir.cwd().readFileAlloc(io, pkgbuild_path, allocator, .limited(32 * 1024 * 1024));
    defer allocator.free(content);
    const package_builds = try allocator.alloc(pkgbuild_parser.Pkgbuild, request.requested_names.len);
    var parsed_count: usize = 0;
    defer {
        for (package_builds[0..parsed_count]) |*package_build| package_build.deinit(allocator);
        allocator.free(package_builds);
    }
    for (request.requested_names, package_builds) |name, *package_build| {
        package_build.* = try (pkgbuild_parser.PkgbuildParser{
            .allocator = allocator,
            .io = io,
            .selected_package_name = name,
        }).parser_content(content, request.build_directory);
        parsed_count += 1;
    }
    const digest = try review_integrity.reviewDigest(
        allocator,
        io,
        request.build_directory,
        content,
        &package_builds[0],
    );
    if (!std.mem.eql(u8, &digest, &request.reviewed_pkgbuild_digest))
        return error.ReviewedPkgbuildChanged;

    const makepkg = try MakePackageConfiguration.initFromBuffer(io, allocator, "");
    defer makepkg.deinit();
    makepkg.package_extension = request.makepkg.package_extension;
    makepkg.package_carch = request.makepkg.package_carch;
    makepkg.packager = request.makepkg.packager;
    makepkg.build_environment = request.makepkg.build_environment;
    makepkg.options = request.makepkg.options;

    var dispatcher = events.Dispatcher.init(allocator);
    defer dispatcher.deinit();
    _ = try dispatcher.addInformationalHandler(.{ .function = forwardInformational });
    _ = try dispatcher.addErrorHandler(.{ .function = forwardError });
    var operation_context = operation_api.OperationContext.init(allocator, io);
    defer operation_context.deinit();
    var builder = try builder_mod.PackageBuilder.init(
        allocator,
        package_builds,
        dispatcher,
        operation_context,
        makepkg.*,
        request.requested_names,
        .{
            .run_check = request.options.run_check,
            .overwrite = request.options.overwrite,
            .clean_after_success = request.options.clean_after_success,
            .skip_source_pgp_verification = request.options.skip_source_pgp_verification,
            .sources_prepared = request.options.sources_prepared,
            .build_directory = request.build_directory,
            .reviewed_pkgbuild_digest = request.reviewed_pkgbuild_digest,
            .virtual_ownership_overrides = request.virtual_ownership_overrides,
        },
        environ,
        io,
    );
    defer builder.deinit();
    const artifacts = try builder.BuildPackage();
    defer builder_mod.deinitArtifacts(allocator, artifacts);

    const response_artifacts = try allocator.alloc(protocol.ResponseArtifact, artifacts.len);
    defer allocator.free(response_artifacts);
    for (artifacts, response_artifacts) |artifact, *response_artifact| response_artifact.* = .{
        .path = artifact.path,
        .package_name = artifact.package_name,
    };
    try writeResponse(allocator, .{ .artifacts = response_artifacts });
}

fn writeResponse(allocator: std.mem.Allocator, response: protocol.Response) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, response, .{});
    defer allocator.free(json);
    std.debug.print("{s}{s}\n", .{ protocol.result_prefix, json });
}

fn forwardInformational(_: ?*anyopaque, args: events.InformationalArgs) void {
    std.debug.print("{s}\n", .{args.message});
}

fn forwardError(_: ?*anyopaque, args: events.ErrorArgs) void {
    std.debug.print("{s}\n", .{args.message});
}

test "non-root worker executes a reviewed build request" {
    if (@import("builtin").os.tag == .linux and std.os.linux.geteuid() == 0)
        return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const build_directory = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(build_directory);
    const pkgbuild =
        \\pkgname=worker-demo
        \\pkgver=1
        \\pkgrel=1
        \\arch=('any')
        \\package() {
        \\  mkdir -p "$pkgdir/usr/share/worker-demo"
        \\  printf payload > "$pkgdir/usr/share/worker-demo/data"
        \\}
    ;
    try temporary.dir.writeFile(io, .{ .sub_path = "PKGBUILD", .data = pkgbuild });

    var parsed = try (pkgbuild_parser.PkgbuildParser{
        .allocator = allocator,
        .io = io,
        .selected_package_name = "worker-demo",
    }).parser_content(pkgbuild, build_directory);
    defer parsed.deinit(allocator);
    const digest = try review_integrity.reviewDigest(allocator, io, build_directory, pkgbuild, &parsed);
    const request: protocol.Request = .{
        .build_directory = build_directory,
        .requested_names = &.{"worker-demo"},
        .options = .{
            .run_check = false,
            .overwrite = true,
            .clean_after_success = false,
            .skip_source_pgp_verification = true,
            .sources_prepared = true,
        },
        .makepkg = .{
            .package_extension = ".pkg.tar.zst",
            .package_carch = "x86_64",
            .packager = "Shelly Test",
            .build_environment = "(!distcc !ccache !check !sign)",
            .options = "(!strip !debug !lto)",
        },
        .reviewed_pkgbuild_digest = digest,
    };
    const request_json = try std.json.Stringify.valueAlloc(allocator, request, .{});
    defer allocator.free(request_json);
    try run(allocator, io, std.testing.environ, &.{ "shelly-builder", request_json });

    const artifact_path = try std.fs.path.join(
        allocator,
        &.{ build_directory, "worker-demo-1-1-any.pkg.tar.zst" },
    );
    defer allocator.free(artifact_path);
    try std.Io.Dir.cwd().access(io, artifact_path, .{});
}

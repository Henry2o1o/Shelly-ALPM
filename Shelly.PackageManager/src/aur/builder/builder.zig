const std = @import("std");
const MakePkgConfiguration = @import("../makepackage.zig").MakePackageConfiguration;
const pkgbuild_parser = @import("../../pkgbuild/pkgbuild_parser.zig");
const PackageBuild = pkgbuild_parser.Pkgbuild;
const ExecutionStep = pkgbuild_parser.execution_step;
const events = @import("../events.zig");
const op_context = @import("operation_context");
const archive = @import("archive");
const process_runner = @import("../builder.zig");

pub const BuildArtifact = struct {
    path: [:0]u8,
    package_name: []const u8,

    pub fn deinit(self: BuildArtifact, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.package_name);
    }
};

pub fn deinitArtifacts(allocator: std.mem.Allocator, artifacts: []BuildArtifact) void {
    for (artifacts) |artifact| artifact.deinit(allocator);
    allocator.free(artifacts);
}

pub const BuildOptions = struct {
    run_check: bool,
    overwrite: bool,
    clean_after_success: bool,
    skip_source_pgp_verification: bool,
    build_directory: []const u8,
};

pub const BuilderErrors = error{ BuildFailed, OutOfMemory, Cancelled, AlreadyBuilt };

/// Builder expects to be passed all items and should not construct
/// these items as it's context only exists to serve inside manager
pub const PackageBuilder = struct {
    allocator: std.mem.Allocator,
    package_builds: []const PackageBuild,
    dispatcher: events.Dispatcher,
    operation_context: op_context.OperationContext,
    makepkg_config: MakePkgConfiguration,
    requested_names: []const []const u8,
    options: BuildOptions,
    environ: std.process.Environ,
    io: std.Io,

    pub fn init(
        allocator: std.mem.Allocator,
        package_builds: []const PackageBuild,
        dispatcher: events.Dispatcher,
        operation_context: op_context.OperationContext,
        makepackage_configuration: MakePkgConfiguration,
        requested_names: []const []const u8,
        options: BuildOptions,
        environ: std.process.Environ,
        io: std.Io,
    ) !*PackageBuilder {
        if (package_builds.len == 0 or package_builds.len != requested_names.len)
            return error.InvalidBuildInput;
        const self = allocator.create(PackageBuilder) catch |err| {
            return err;
        };

        self.* = PackageBuilder{
            .allocator = allocator,
            .package_builds = package_builds,
            .dispatcher = dispatcher,
            .operation_context = operation_context,
            .makepkg_config = makepackage_configuration,
            .requested_names = requested_names,
            .options = options,
            .environ = environ,
            .io = io,
        };

        return self;
    }

    pub fn deinit(self: *PackageBuilder) void {
        self.allocator.destroy(self);
    }

    pub fn BuildPackage(self: *PackageBuilder) BuilderErrors![]BuildArtifact {
        var operation = self.operation_context.begin(op_context.OperationDescriptor{ .backend = .aur, .kind = .build, .subject = "Package Build" });
        defer operation.finish(.cancelled);
        const artifacts = self.buildPackage(&operation) catch |err| {
            const message = std.fmt.allocPrint(
                self.allocator,
                "Failed to build package: {s}",
                .{@errorName(err)},
            ) catch return BuilderErrors.OutOfMemory;
            defer self.allocator.free(message);
            self.dispatcher.raiseError(.{ .message = message });
            if (err == error.Cancelled) {
                operation.finish(.cancelled);
                return BuilderErrors.Cancelled;
            }
            operation.finish(.failed);
            return switch (err) {
                error.OutOfMemory => BuilderErrors.OutOfMemory,
                error.AlreadyBuilt => BuilderErrors.AlreadyBuilt,
                else => BuilderErrors.BuildFailed,
            };
        };
        operation.finish(.success);
        return artifacts;
    }

    fn buildPackage(self: *PackageBuilder, operation: *op_context.Operation) ![]BuildArtifact {
        _ = self.options.skip_source_pgp_verification;
        const shared_steps = self.package_builds[0].execution_steps orelse
            return error.MissingExecutionSteps;
        for (shared_steps) |step| {
            if (isPackageStep(step.name)) continue;
            if (std.mem.eql(u8, step.name, "check") and !self.options.run_check) continue;
            try self.runStep(operation, self.requested_names[0], step.name, step.expanded_body);
        }

        var artifacts: std.ArrayList(BuildArtifact) = .empty;
        errdefer {
            for (artifacts.items) |artifact| {
                std.Io.Dir.cwd().deleteFile(self.io, artifact.path) catch {};
                artifact.deinit(self.allocator);
            }
            artifacts.deinit(self.allocator);
        }

        for (self.package_builds, self.requested_names) |*package_build, requested_name| {
            try self.preparePackageDirectory(package_build);
            const package_step = findPackageStep(package_build.execution_steps orelse
                return error.MissingExecutionSteps) orelse return error.MissingPackageStep;
            try self.runStep(operation, requested_name, package_step.name, package_step.expanded_body);
            const artifact = try self.assemblePackage(package_build);
            artifacts.append(self.allocator, artifact) catch |err| {
                std.Io.Dir.cwd().deleteFile(self.io, artifact.path) catch {};
                artifact.deinit(self.allocator);
                return err;
            };
        }

        if (self.options.clean_after_success) {
            for ([_][]const u8{ "src", "pkg" }) |name| {
                const path = try std.fs.path.join(self.allocator, &.{ self.options.build_directory, name });
                defer self.allocator.free(path);
                std.Io.Dir.cwd().deleteTree(self.io, path) catch {};
            }
        }

        return artifacts.toOwnedSlice(self.allocator);
    }

    fn runStep(
        self: *PackageBuilder,
        operation: *op_context.Operation,
        package_name: []const u8,
        step_name: []const u8,
        body: []const u8,
    ) !void {
        const active_operation = self.dispatcher.operation orelse operation;
        try active_operation.checkCancelled();
        var command = try process_runner.invokingUserCommand(
            self.allocator,
            self.io,
            self.environ,
            "/bin/bash",
            &.{ "-e", "-c", body },
        );
        defer command.deinit(self.allocator);

        var stream_context: StepStreamContext = .{ .builder = self, .package_name = package_name };
        const exit_code = try process_runner.runStreamingWithEnvironmentOperation(
            self.allocator,
            self.io,
            self.environ,
            command.asConst(),
            self.options.build_directory,
            null,
            .{ .function = forwardStepLine, .data = &stream_context },
            active_operation,
        );
        if (exit_code != 0) return error.StepFailed;
        self.dispatcher.raiseInformational(.{
            .event_type = .aur_build_output,
            .message = step_name,
            .package_name = package_name,
        });
    }

    fn preparePackageDirectory(self: *PackageBuilder, package_build: *const PackageBuild) !void {
        const package_name = package_build.pkg_name orelse return error.MissingPackageName;
        const pkgdir = try std.fs.path.join(
            self.allocator,
            &.{ self.options.build_directory, "pkg", package_name },
        );
        defer self.allocator.free(pkgdir);
        std.Io.Dir.cwd().deleteTree(self.io, pkgdir) catch {};
        try std.Io.Dir.cwd().createDirPath(self.io, pkgdir);
    }

    fn assemblePackage(self: *PackageBuilder, package_build: *const PackageBuild) !BuildArtifact {
        const package_name = package_build.pkg_name orelse return error.MissingPackageName;
        const full_version = try package_build.get_full_version(self.allocator);
        defer self.allocator.free(full_version);
        if (full_version.len == 0) return error.MissingPackageVersion;

        const package_arch = self.packageArchitecture(package_build);
        const pkgdir = try std.fs.path.join(
            self.allocator,
            &.{ self.options.build_directory, "pkg", package_name },
        );
        defer self.allocator.free(pkgdir);

        var pkgdir_handle = try std.Io.Dir.cwd().openDir(self.io, pkgdir, .{ .iterate = true });
        defer pkgdir_handle.close(self.io);

        const payload_size = try directorySize(self.allocator, self.io, pkgdir_handle);
        const build_date = std.Io.Clock.real.now(self.io).toSeconds();
        try self.writePackageInfo(package_build, pkgdir_handle, full_version, package_arch, payload_size, build_date);
        try self.writeBuildInfo(package_build, pkgdir_handle, full_version, package_arch, build_date);
        if (package_build.install_file != null) {
            const install_contents = package_build.post_install orelse return error.MissingInstallFile;
            try writeMetadataFile(pkgdir_handle, self.io, ".INSTALL", install_contents);
        } else {
            try deleteFileIgnoreMissing(pkgdir_handle, self.io, ".INSTALL");
        }

        const mtree_path = try std.fs.path.join(self.allocator, &.{ pkgdir, ".MTREE" });
        defer self.allocator.free(mtree_path);
        try archive.writeMtree(self.allocator, self.io, pkgdir, mtree_path);
        var mtree_file = try pkgdir_handle.openFile(self.io, ".MTREE", .{});
        defer mtree_file.close(self.io);
        try mtree_file.setPermissions(self.io, .fromMode(0o644));

        try std.Io.Dir.cwd().createDirPath(self.io, self.options.build_directory);
        const file_name = try std.fmt.allocPrint(
            self.allocator,
            "{s}-{s}-{s}{s}",
            .{ package_name, full_version, package_arch, self.makepkg_config.package_extension },
        );
        defer self.allocator.free(file_name);
        const output_path = try std.fs.path.joinZ(
            self.allocator,
            &.{ self.options.build_directory, file_name },
        );
        errdefer self.allocator.free(output_path);
        if (!self.options.overwrite) {
            if (std.Io.Dir.cwd().access(self.io, output_path, .{})) |_| {
                return error.AlreadyBuilt;
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
        }
        errdefer std.Io.Dir.cwd().deleteFile(self.io, output_path) catch {};

        var writer = try archive.Writer.init(self.allocator, self.io, output_path);
        defer writer.deinit();
        try writer.addDirectory(pkgdir);
        try writer.finish();

        const owned_name = try self.allocator.dupe(u8, package_name);
        errdefer self.allocator.free(owned_name);
        return .{ .path = output_path, .package_name = owned_name };
    }

    fn packageArchitecture(self: *const PackageBuilder, package_build: *const PackageBuild) []const u8 {
        if (package_build.arch) |architectures| {
            for (architectures) |architecture| {
                if (std.mem.eql(u8, architecture, "any")) return "any";
            }
        }
        return self.makepkg_config.package_carch;
    }

    fn writePackageInfo(
        self: *PackageBuilder,
        package_build: *const PackageBuild,
        pkgdir: std.Io.Dir,
        full_version: []const u8,
        package_arch: []const u8,
        payload_size: u64,
        build_date: i64,
    ) !void {
        const package_name = package_build.pkg_name orelse return error.MissingPackageName;
        const package_base = package_build.variables.get("pkgbase") orelse package_name;

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        const writer = &output.writer;
        try writeKeyValue(writer, "pkgname", package_name);
        try writeKeyValue(writer, "pkgbase", package_base);
        try writeKeyValue(writer, "xdata", "pkgtype=pkg");
        try writeKeyValue(writer, "pkgver", full_version);
        if (package_build.pkg_desc) |value| try writeKeyValue(writer, "pkgdesc", value);
        if (package_build.url) |value| try writeKeyValue(writer, "url", value);
        try writer.print("builddate = {d}\n", .{build_date});
        try writeKeyValue(writer, "packager", self.makepkg_config.packager);
        try writer.print("size = {d}\n", .{payload_size});
        try writeKeyValue(writer, "arch", package_arch);
        try writeKeyValues(writer, "license", package_build.license);
        try writeKeyValues(writer, "replaces", package_build.replaces);
        try writeKeyValues(writer, "conflict", package_build.conflicts);
        try writeKeyValues(writer, "provides", package_build.provides);
        try writeKeyValues(writer, "depend", package_build.depends);
        try writeKeyValues(writer, "optdepend", package_build.opt_depends);
        try writeKeyValues(writer, "makedepend", package_build.make_depends);
        try writeKeyValues(writer, "checkdepend", package_build.check_depends);
        try writeMetadataFile(pkgdir, self.io, ".PKGINFO", output.written());
    }

    fn writeBuildInfo(
        self: *PackageBuilder,
        package_build: *const PackageBuild,
        pkgdir: std.Io.Dir,
        full_version: []const u8,
        package_arch: []const u8,
        build_date: i64,
    ) !void {
        const package_name = package_build.pkg_name orelse return error.MissingPackageName;
        const package_base = package_build.variables.get("pkgbase") orelse package_name;

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        const writer = &output.writer;
        try writeKeyValue(writer, "format", "2");
        try writeKeyValue(writer, "pkgname", package_name);
        try writeKeyValue(writer, "pkgbase", package_base);
        try writeKeyValue(writer, "pkgver", full_version);
        try writeKeyValue(writer, "pkgarch", package_arch);
        try writeKeyValue(writer, "packager", self.makepkg_config.packager);
        try writer.print("builddate = {d}\n", .{build_date});
        try writeKeyValue(writer, "builddir", self.options.build_directory);
        try writeKeyValue(writer, "buildtool", "shelly");
        try writeKeyValue(writer, "buildtoolver", "1");
        try writeKeyValue(writer, "buildenv", self.makepkg_config.build_environment);
        try writeKeyValue(writer, "options", self.makepkg_config.options);
        try writeMetadataFile(pkgdir, self.io, ".BUILDINFO", output.written());
    }
};

const StepStreamContext = struct {
    builder: *PackageBuilder,
    package_name: []const u8,
};

fn forwardStepLine(data: ?*anyopaque, stream: process_runner.StreamKind, line: []const u8) void {
    const context: *StepStreamContext = @ptrCast(@alignCast(data.?));
    context.builder.dispatcher.raiseInformational(.{
        .event_type = if (stream == .stderr) .aur_build_error else .aur_build_output,
        .message = line,
        .package_name = context.package_name,
    });
    if (stream == .stdout) if (process_runner.parseBuildProgress(line)) |progress| {
        context.builder.dispatcher.raiseProgress(.{
            .progress_type = .makepkg_build,
            .package_name = context.package_name,
            .percent = progress.percent,
            .message = progress.message,
        });
    };
}

fn isPackageStep(name: []const u8) bool {
    return std.mem.eql(u8, name, "package") or std.mem.startsWith(u8, name, "package_");
}

fn findPackageStep(steps: []const ExecutionStep) ?*const ExecutionStep {
    for (steps) |*step| if (isPackageStep(step.name)) return step;
    return null;
}

fn directorySize(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
) !u64 {
    var walker = try directory.walk(allocator);
    defer walker.deinit();

    var size: u64 = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.path, ".PKGINFO") or
            std.mem.eql(u8, entry.path, ".BUILDINFO") or
            std.mem.eql(u8, entry.path, ".MTREE") or
            std.mem.eql(u8, entry.path, ".INSTALL")) continue;
        const stat = try entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false });
        size = std.math.add(u64, size, stat.size) catch return error.PackageTooLarge;
    }
    return size;
}

fn writeMetadataFile(
    directory: std.Io.Dir,
    io: std.Io,
    name: []const u8,
    contents: []const u8,
) !void {
    try deleteFileIgnoreMissing(directory, io, name);
    try directory.writeFile(io, .{
        .sub_path = name,
        .data = contents,
        .flags = .{ .permissions = .fromMode(0o644) },
    });
}

fn deleteFileIgnoreMissing(directory: std.Io.Dir, io: std.Io, name: []const u8) !void {
    directory.deleteFile(io, name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn writeKeyValue(writer: *std.Io.Writer, key: []const u8, value: []const u8) !void {
    if (value.len == 0) return;
    if (std.mem.indexOfScalar(u8, value, '\n') != null) return error.InvalidPackageMetadata;
    try writer.print("{s} = {s}\n", .{ key, value });
}

fn writeKeyValues(
    writer: *std.Io.Writer,
    key: []const u8,
    values: ?[][]const u8,
) !void {
    for (values orelse return) |value| try writeKeyValue(writer, key, value);
}

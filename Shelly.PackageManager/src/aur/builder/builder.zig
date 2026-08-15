const std = @import("std");
const builtin = @import("builtin");
const MakePkgConfiguration = @import("../makepackage.zig").MakePackageConfiguration;
const pkgbuild_parser = @import("../../pkgbuild/pkgbuild_parser.zig");
const PackageBuild = pkgbuild_parser.Pkgbuild;
const ExecutionStep = pkgbuild_parser.execution_step;
const events = @import("../events.zig");
const op_context = @import("operation_context");
const archive = @import("archive");
const process_runner = @import("../builder.zig");
const downloader = @import("../../shared/downloader.zig");
const worker_protocol = @import("worker_protocol.zig");

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
    /// Allows callers with an already-verified source tree to use the custom
    /// packaging machinery without reacquiring sources. Normal AUR builds must
    /// leave this false so PackageBuilder creates $srcdir itself.
    sources_prepared: bool = false,
    /// Package ownership is virtual: the staging tree remains owned by the
    /// build user and these overrides are applied only to .MTREE and the
    /// completed package archive.
    virtual_ownership_overrides: []const archive.OwnershipOverride = &.{},
    /// Digest of the PKGBUILD and its reviewed local/install files. A root
    /// caller must provide it so the worker can reject review/build races.
    reviewed_pkgbuild_digest: ?[std.crypto.hash.sha2.Sha256.digest_length]u8 = null,
};

pub const BuilderErrors = error{
    BuildFailed,
    OutOfMemory,
    Cancelled,
    AlreadyBuilt,
    BuilderMustNotRunAsRoot,
    BuilderDeescalationFailed,
    BuilderWorkerUnavailable,
    UnreviewedBuilderRequest,
    ReviewedPkgbuildChanged,
    BuildDirectoryNotWritable,
    PrivilegedPackageOperationUnsupported,
};

pub fn requireNonRootEffectiveUid(effective_uid: u32) error{BuilderMustNotRunAsRoot}!void {
    if (effective_uid == 0) return error.BuilderMustNotRunAsRoot;
}

pub fn requiresDeescalatedWorker(effective_uid: u32) bool {
    return effective_uid == 0;
}

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
        const artifacts = self.dispatchBuild(&operation) catch |err| {
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
                error.BuilderMustNotRunAsRoot => BuilderErrors.BuilderMustNotRunAsRoot,
                error.BuilderDeescalationFailed, error.InvokingUserUnavailable => BuilderErrors.BuilderDeescalationFailed,
                error.BuilderWorkerUnavailable => BuilderErrors.BuilderWorkerUnavailable,
                error.UnreviewedBuilderRequest => BuilderErrors.UnreviewedBuilderRequest,
                error.ReviewedPkgbuildChanged => BuilderErrors.ReviewedPkgbuildChanged,
                error.BuildDirectoryNotWritable => BuilderErrors.BuildDirectoryNotWritable,
                error.PrivilegedPackageOperationUnsupported => BuilderErrors.PrivilegedPackageOperationUnsupported,
                else => BuilderErrors.BuildFailed,
            };
        };
        operation.finish(.success);
        return artifacts;
    }

    fn dispatchBuild(self: *PackageBuilder, operation: *op_context.Operation) ![]BuildArtifact {
        if (builtin.os.tag == .linux and requiresDeescalatedWorker(@intCast(std.os.linux.geteuid())))
            return self.buildAsInvokingUser(operation);
        return self.buildPackage(operation);
    }

    fn buildPackage(self: *PackageBuilder, operation: *op_context.Operation) ![]BuildArtifact {
        if (builtin.os.tag == .linux)
            try requireNonRootEffectiveUid(@intCast(std.os.linux.geteuid()));
        try self.validateBuildDirectories();
        if (!self.options.sources_prepared) try self.prepareSources(operation);
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

    fn buildAsInvokingUser(self: *PackageBuilder, operation: *op_context.Operation) ![]BuildArtifact {
        const digest = self.options.reviewed_pkgbuild_digest orelse return error.UnreviewedBuilderRequest;
        const worker_path = try self.resolveWorkerPath();
        defer self.allocator.free(worker_path);

        const request: worker_protocol.Request = .{
            .build_directory = self.options.build_directory,
            .requested_names = self.requested_names,
            .options = .{
                .run_check = self.options.run_check,
                .overwrite = self.options.overwrite,
                .clean_after_success = self.options.clean_after_success,
                .skip_source_pgp_verification = self.options.skip_source_pgp_verification,
                .sources_prepared = self.options.sources_prepared,
            },
            .makepkg = .{
                .package_extension = self.makepkg_config.package_extension,
                .package_carch = self.makepkg_config.package_carch,
                .packager = self.makepkg_config.packager,
                .build_environment = self.makepkg_config.build_environment,
                .options = self.makepkg_config.options,
            },
            .reviewed_pkgbuild_digest = digest,
            .virtual_ownership_overrides = self.options.virtual_ownership_overrides,
        };
        const request_json = try std.json.Stringify.valueAlloc(self.allocator, request, .{});
        defer self.allocator.free(request_json);

        var command = process_runner.deescalatedInvokingUserCommand(
            self.allocator,
            self.io,
            self.environ,
            worker_path,
            &.{request_json},
        ) catch |err| switch (err) {
            error.InvokingUserUnavailable => return err,
            else => return error.BuilderDeescalationFailed,
        };
        defer command.deinit(self.allocator);

        var stream_context: WorkerStreamContext = .{ .builder = self };
        defer if (stream_context.response_json) |json| self.allocator.free(json);
        const exit_code = process_runner.runStreamingWithEnvironmentOperation(
            self.allocator,
            self.io,
            self.environ,
            command.asConst(),
            null,
            null,
            .{ .function = forwardWorkerLine, .data = &stream_context },
            operation,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.BuilderWorkerUnavailable,
            else => return err,
        };
        const response_json = stream_context.response_json orelse {
            if (exit_code == 127) return error.BuilderWorkerUnavailable;
            return error.BuilderDeescalationFailed;
        };
        var parsed = try std.json.parseFromSlice(worker_protocol.Response, self.allocator, response_json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        if (parsed.value.version != worker_protocol.protocol_version) return error.BuilderDeescalationFailed;
        if (parsed.value.error_name) |name| return workerError(name);
        if (exit_code != 0) return error.BuilderDeescalationFailed;

        const artifacts = try self.allocator.alloc(BuildArtifact, parsed.value.artifacts.len);
        var initialized: usize = 0;
        errdefer {
            for (artifacts[0..initialized]) |artifact| artifact.deinit(self.allocator);
            self.allocator.free(artifacts);
        }
        for (parsed.value.artifacts, artifacts) |source, *destination| {
            destination.* = .{
                .path = try self.allocator.dupeZ(u8, source.path),
                .package_name = self.allocator.dupe(u8, source.package_name) catch |err| {
                    self.allocator.free(destination.path);
                    return err;
                },
            };
            initialized += 1;
        }
        return artifacts;
    }

    fn resolveWorkerPath(self: *PackageBuilder) ![]u8 {
        if (self.environ.getPosix("SHELLY_BUILDER_WORKER")) |path| {
            if (path.len == 0) return error.BuilderWorkerUnavailable;
            return self.allocator.dupe(u8, path);
        }
        const executable_directory = std.process.executableDirPathAlloc(self.io, self.allocator) catch
            return self.allocator.dupe(u8, "/usr/bin/shelly-builder");
        defer self.allocator.free(executable_directory);
        const sibling = try std.fs.path.join(self.allocator, &.{ executable_directory, "shelly-builder" });
        std.Io.Dir.cwd().access(self.io, sibling, .{ .execute = true }) catch {
            self.allocator.free(sibling);
            return self.allocator.dupe(u8, "/usr/bin/shelly-builder");
        };
        return sibling;
    }

    fn prepareSources(self: *PackageBuilder, operation: *op_context.Operation) !void {
        try operation.checkCancelled();
        const package_build = &self.package_builds[0];
        const sources = package_build.source orelse &.{};

        try validateChecksumCount(sources.len, package_build.sha_512_sums);
        try validateChecksumCount(sources.len, package_build.sha_256_sums);
        try validateChecksumCount(sources.len, package_build.md_5_sums);
        if (sources.len > 0 and !hasSourceChecksums(package_build))
            return error.MissingSourceChecksums;

        const srcdir = try std.fs.path.join(self.allocator, &.{ self.options.build_directory, "src" });
        defer self.allocator.free(srcdir);
        const staging = try std.fs.path.join(self.allocator, &.{ self.options.build_directory, ".src.shelly-staging" });
        defer self.allocator.free(staging);
        const backup = try std.fs.path.join(self.allocator, &.{ self.options.build_directory, ".src.shelly-backup" });
        defer self.allocator.free(backup);

        std.Io.Dir.cwd().deleteTree(self.io, staging) catch {};
        try std.Io.Dir.cwd().createDirPath(self.io, staging);
        errdefer std.Io.Dir.cwd().deleteTree(self.io, staging) catch {};

        self.raiseSourceMessage(package_build, "Preparing package sources");
        for (sources, 0..) |raw_source, index| {
            try operation.checkCancelled();
            var source = try ParsedSource.parse(self.allocator, raw_source);
            defer source.deinit(self.allocator);
            const destination = try std.fs.path.join(self.allocator, &.{ staging, source.name });
            defer self.allocator.free(destination);

            self.raiseSourceMessage(package_build, source.name);
            switch (source.kind) {
                .local => try self.copyLocalSource(source.location, destination),
                .http => try self.downloadSource(operation, source.location, destination),
                .git => try self.cloneGitSource(operation, source, destination),
            }

            if (source.kind != .git) {
                try self.verifySourceChecksums(package_build, index, destination);
                if (isExtractableArchive(source.name))
                    try self.extractSourceArchive(operation, destination, staging);
            } else try requireSkippedVcsChecksums(package_build, index);
        }

        if (!self.options.skip_source_pgp_verification and containsSignatureSource(sources))
            return error.SourcePgpVerificationUnsupported;
        // Commit the complete source tree while preserving the previous tree
        // until the replacement rename succeeds.
        std.Io.Dir.cwd().deleteTree(self.io, backup) catch {};
        const had_existing = blk: {
            std.Io.Dir.rename(.cwd(), srcdir, .cwd(), backup, self.io) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            };
            break :blk true;
        };
        std.Io.Dir.rename(.cwd(), staging, .cwd(), srcdir, self.io) catch |err| {
            if (had_existing) std.Io.Dir.rename(.cwd(), backup, .cwd(), srcdir, self.io) catch {};
            return err;
        };
        if (had_existing) std.Io.Dir.cwd().deleteTree(self.io, backup) catch {};
    }

    fn copyLocalSource(self: *PackageBuilder, source_name: []const u8, destination: []const u8) !void {
        const normalized = try archive.normalizeEntryPath(self.allocator, source_name);
        defer self.allocator.free(normalized);
        const source_path = try std.fs.path.join(self.allocator, &.{ self.options.build_directory, normalized });
        defer self.allocator.free(source_path);
        const stat = try std.Io.Dir.cwd().statFile(self.io, source_path, .{ .follow_symlinks = false });
        if (stat.kind != .file) return error.InvalidLocalSource;
        try std.Io.Dir.copyFile(.cwd(), source_path, .cwd(), destination, self.io, .{});
    }

    fn downloadSource(
        self: *PackageBuilder,
        operation: *op_context.Operation,
        url: []const u8,
        destination: []const u8,
    ) !void {
        var core = downloader.CoreDownloader.init(self.allocator, self.io, .default());
        defer core.deinit();
        core.setParentOperation(operation);
        switch (core.downloadToFile(url, destination, true)) {
            .succes, .skipped => {},
            .failure => |err| return if (err == downloader.DownloadError.Cancelled)
                error.Cancelled
            else
                error.SourceDownloadFailed,
        }
    }

    fn cloneGitSource(
        self: *PackageBuilder,
        operation: *op_context.Operation,
        source: ParsedSource,
        destination: []const u8,
    ) !void {
        var clone_args: std.ArrayList([]const u8) = .empty;
        defer clone_args.deinit(self.allocator);
        try clone_args.appendSlice(self.allocator, &.{ "clone", "--", source.location, destination });
        if (source.reference) |reference| switch (reference.kind) {
            .branch, .tag => {
                clone_args.clearRetainingCapacity();
                try clone_args.appendSlice(self.allocator, &.{
                    "clone", "--branch", reference.value, "--single-branch", "--", source.location, destination,
                });
            },
            .commit => {},
        };
        try self.runSourceCommand(operation, clone_args.items);
        if (source.reference) |reference| if (reference.kind == .commit)
            try self.runSourceCommand(operation, &.{ "-C", destination, "checkout", "--detach", reference.value });
    }

    fn runSourceCommand(
        self: *PackageBuilder,
        operation: *op_context.Operation,
        args: []const []const u8,
    ) !void {
        try operation.checkCancelled();
        var command: std.ArrayList([]const u8) = .empty;
        defer command.deinit(self.allocator);
        try command.append(self.allocator, "git");
        try command.appendSlice(self.allocator, args);
        var stream_context: StepStreamContext = .{
            .builder = self,
            .package_name = self.requested_names[0],
        };
        const exit_code = try process_runner.runStreamingWithEnvironmentOperation(
            self.allocator,
            self.io,
            self.environ,
            command.items,
            self.options.build_directory,
            null,
            .{ .function = forwardStepLine, .data = &stream_context },
            operation,
        );
        if (exit_code != 0) return error.SourceVcsFailed;
    }

    fn verifySourceChecksums(
        self: *PackageBuilder,
        package_build: *const PackageBuild,
        index: usize,
        path: []const u8,
    ) !void {
        if (package_build.sha_512_sums) |sums| if (sums.len > 0)
            try verifyFileHash(std.crypto.hash.sha2.Sha512, self.io, path, sums[index]);
        if (package_build.sha_256_sums) |sums| if (sums.len > 0)
            try verifyFileHash(std.crypto.hash.sha2.Sha256, self.io, path, sums[index]);
        if (package_build.md_5_sums) |sums| if (sums.len > 0)
            try verifyFileHash(std.crypto.hash.Md5, self.io, path, sums[index]);
    }

    fn extractSourceArchive(
        self: *PackageBuilder,
        operation: *op_context.Operation,
        archive_path: []const u8,
        destination_root: []const u8,
    ) !void {
        var reader = try archive.Reader.initAll(self.allocator, archive_path);
        defer reader.deinit();
        var buffer: [64 * 1024]u8 = undefined;
        var entry_count: usize = 0;
        var total_size: u64 = 0;
        while (try reader.next()) |entry| {
            try operation.checkCancelled();
            entry_count += 1;
            if (entry_count > 1_000_000 or entry.size > 4 * 1024 * 1024 * 1024)
                return error.SourceArchiveTooLarge;
            const relative = try archive.normalizeEntryPath(self.allocator, entry.path);
            defer self.allocator.free(relative);
            const destination = try std.fs.path.join(self.allocator, &.{ destination_root, relative });
            defer self.allocator.free(destination);
            switch (entry.kind) {
                .directory => try self.ensureSafeArchivePath(destination_root, relative, true),
                .regular_file => {
                    try self.ensureSafeArchivePath(destination_root, relative, false);
                    try rejectSymlinkDestination(self.io, destination);
                    var output = try std.Io.Dir.cwd().createFile(self.io, destination, .{
                        .truncate = true,
                        .permissions = std.Io.File.Permissions.fromMode(entry.permissions & 0o777),
                    });
                    defer output.close(self.io);
                    var writer = output.writer(self.io, &.{});
                    var entry_size: u64 = 0;
                    while (true) {
                        const amount = try reader.read(&buffer);
                        if (amount == 0) break;
                        entry_size += amount;
                        total_size += amount;
                        if (entry_size > 4 * 1024 * 1024 * 1024 or total_size > 16 * 1024 * 1024 * 1024)
                            return error.SourceArchiveTooLarge;
                        try writer.interface.writeAll(buffer[0..amount]);
                    }
                },
                .symbolic_link => {
                    const target = entry.link_target orelse return error.UnsafeSourceArchiveLink;
                    try validateArchiveLink(target);
                    try self.ensureSafeArchivePath(destination_root, relative, false);
                    try rejectExistingDestination(self.io, destination);
                    try std.Io.Dir.cwd().symLink(self.io, target, destination, .{});
                },
                .other => return error.UnsupportedSourceArchiveEntry,
            }
        }
    }

    fn ensureSafeArchivePath(
        self: *PackageBuilder,
        destination_root: []const u8,
        relative: []const u8,
        include_last: bool,
    ) !void {
        var current = try self.allocator.dupe(u8, destination_root);
        defer self.allocator.free(current);
        var components = std.mem.splitScalar(u8, relative, '/');
        while (components.next()) |component| {
            if (!include_last and components.peek() == null) break;
            const next = try std.fs.path.join(self.allocator, &.{ current, component });
            self.allocator.free(current);
            current = next;
            const stat = std.Io.Dir.cwd().statFile(self.io, current, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => {
                    try std.Io.Dir.cwd().createDir(self.io, current, .default_dir);
                    continue;
                },
                else => return err,
            };
            if (stat.kind != .directory) return error.UnsafeSourceArchivePath;
        }
    }

    fn raiseSourceMessage(self: *PackageBuilder, package_build: *const PackageBuild, message: []const u8) void {
        self.dispatcher.raiseInformational(.{
            .event_type = .aur_build_output,
            .message = message,
            .package_name = package_build.pkg_name,
        });
    }

    fn validateBuildDirectories(self: *PackageBuilder) !void {
        const cwd = std.Io.Dir.cwd();
        const root_stat = cwd.statFile(self.io, self.options.build_directory, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                cwd.createDirPath(self.io, self.options.build_directory) catch {
                    self.reportUnwritableBuildDirectory(self.options.build_directory);
                    return error.BuildDirectoryNotWritable;
                };
                return;
            },
            else => return err,
        };
        if (root_stat.kind != .directory) {
            self.reportUnwritableBuildDirectory(self.options.build_directory);
            return error.BuildDirectoryNotWritable;
        }
        try self.validateWritableDirectoryTree(self.options.build_directory, false);

        for ([_][]const u8{ "src", "pkg", ".src.shelly-staging", ".src.shelly-backup" }) |name| {
            const path = try std.fs.path.join(self.allocator, &.{ self.options.build_directory, name });
            defer self.allocator.free(path);
            try self.validateWritableDirectoryTree(path, true);
        }
    }

    fn validateWritableDirectoryTree(
        self: *PackageBuilder,
        root_path: []const u8,
        recurse: bool,
    ) !void {
        const cwd = std.Io.Dir.cwd();
        const stat = cwd.statFile(self.io, root_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        if (stat.kind != .directory) {
            self.reportUnwritableBuildDirectory(root_path);
            return error.BuildDirectoryNotWritable;
        }
        cwd.access(self.io, root_path, .{ .write = true, .execute = true }) catch {
            self.reportUnwritableBuildDirectory(root_path);
            return error.BuildDirectoryNotWritable;
        };
        if (!recurse) return;

        var directory = cwd.openDir(self.io, root_path, .{ .iterate = true }) catch {
            self.reportUnwritableBuildDirectory(root_path);
            return error.BuildDirectoryNotWritable;
        };
        defer directory.close(self.io);
        var walker = directory.walk(self.allocator) catch {
            self.reportUnwritableBuildDirectory(root_path);
            return error.BuildDirectoryNotWritable;
        };
        defer walker.deinit();
        while (walker.next(self.io) catch {
            self.reportUnwritableBuildDirectory(root_path);
            return error.BuildDirectoryNotWritable;
        }) |entry| {
            if (entry.kind != .directory) continue;
            const path = try std.fs.path.join(self.allocator, &.{ root_path, entry.path });
            defer self.allocator.free(path);
            cwd.access(self.io, path, .{ .write = true, .execute = true }) catch {
                self.reportUnwritableBuildDirectory(path);
                return error.BuildDirectoryNotWritable;
            };
        }
    }

    fn reportUnwritableBuildDirectory(self: *PackageBuilder, path: []const u8) void {
        const message = std.fmt.allocPrint(
            self.allocator,
            "Build directory is not writable by the non-root builder: {s}. Remove it or restore ownership to the invoking user.",
            .{path},
        ) catch return;
        defer self.allocator.free(message);
        self.dispatcher.raiseError(.{ .message = message });
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
        const package_step = isPackageStep(step_name);
        if (package_step) try rejectPrivilegedPackageOperations(body);
        const executable_body = if (package_step)
            try std.fmt.allocPrint(self.allocator, "{s}\n{s}", .{ virtualMetadataShellPrelude, body })
        else
            body;
        defer if (package_step) self.allocator.free(executable_body);

        var stream_context: StepStreamContext = .{ .builder = self, .package_name = package_name };
        const exit_code = try process_runner.runStreamingWithEnvironmentOperation(
            self.allocator,
            self.io,
            self.environ,
            &.{ "/bin/bash", "-e", "-c", executable_body },
            self.options.build_directory,
            null,
            .{ .function = forwardStepLine, .data = &stream_context },
            active_operation,
        );
        if (package_step and exit_code == virtual_metadata_rejected_exit_code)
            return error.PrivilegedPackageOperationUnsupported;
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
        const virtual_metadata: archive.VirtualMetadata = .{
            .ownership_overrides = self.options.virtual_ownership_overrides,
        };
        try archive.writeMtreeWithMetadata(self.allocator, self.io, pkgdir, mtree_path, virtual_metadata);
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

        var writer = try archive.Writer.initWithMetadata(self.allocator, self.io, output_path, virtual_metadata);
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

fn rejectPrivilegedPackageOperations(body: []const u8) error{PrivilegedPackageOperationUnsupported}!void {
    const commands = [_][]const u8{
        "sudo",    "sudoedit", "doas",  "pkexec", "run0",
        "runuser", "su",       "mknod", "setcap", "mount",
        "umount",
    };
    var heredoc_delimiter: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (heredoc_delimiter) |delimiter| {
            if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), delimiter))
                heredoc_delimiter = null;
            continue;
        }

        const command_line = stripShellComment(line);
        for (commands) |command| {
            if (containsShellCommand(command_line, command))
                return error.PrivilegedPackageOperationUnsupported;
        }
        heredoc_delimiter = shellHeredocDelimiter(command_line);
    }
}

const virtual_metadata_rejected_exit_code: u8 = 97;

/// Bash functions used only for package() and package_<name>(). They simulate
/// the common fakeroot ownership operations without changing host ownership.
/// The archive writer independently records root ownership for every entry.
const virtualMetadataShellPrelude =
    \\__shelly_metadata_reject() {
    \\  printf '%s\n' 'shelly: unsupported privileged package metadata operation' >&2
    \\  return 97
    \\}
    \\__shelly_root_identity() {
    \\  case "$1" in
    \\    root|0|root:root|root:0|0:root|0:0) return 0 ;;
    \\    *) return 1 ;;
    \\  esac
    \\}
    \\chown() {
    \\  while [ "$#" -gt 0 ]; do
    \\    case "$1" in
    \\      -R|-h|-H|-L|-P|--recursive|--no-dereference|--dereference|--preserve-root) shift ;;
    \\      --) shift; break ;;
    \\      -*) __shelly_metadata_reject; return $? ;;
    \\      *) break ;;
    \\    esac
    \\  done
    \\  [ "$#" -ge 2 ] || { __shelly_metadata_reject; return $?; }
    \\  __shelly_root_identity "$1" || { __shelly_metadata_reject; return $?; }
    \\  return 0
    \\}
    \\chgrp() {
    \\  while [ "$#" -gt 0 ]; do
    \\    case "$1" in
    \\      -R|-h|-H|-L|-P|--recursive|--no-dereference|--dereference|--preserve-root) shift ;;
    \\      --) shift; break ;;
    \\      -*) __shelly_metadata_reject; return $? ;;
    \\      *) break ;;
    \\    esac
    \\  done
    \\  [ "$#" -ge 2 ] || { __shelly_metadata_reject; return $?; }
    \\  case "$1" in root|0) return 0 ;; *) __shelly_metadata_reject; return $? ;; esac
    \\}
    \\install() {
    \\  local -a shelly_install_args=()
    \\  while [ "$#" -gt 0 ]; do
    \\    case "$1" in
    \\      -o|--owner|-g|--group)
    \\        [ "$#" -ge 2 ] || { __shelly_metadata_reject; return $?; }
    \\        case "$2" in root|0) shift 2 ;; *) __shelly_metadata_reject; return $? ;; esac ;;
    \\      --owner=*|--group=*)
    \\        case "${1#*=}" in root|0) shift ;; *) __shelly_metadata_reject; return $? ;; esac ;;
    \\      *) shelly_install_args+=("$1"); shift ;;
    \\    esac
    \\  done
    \\  /usr/bin/install "${shelly_install_args[@]}"
    \\}
;

fn stripShellComment(line: []const u8) []const u8 {
    var single_quoted = false;
    var double_quoted = false;
    var escaped = false;
    for (line, 0..) |byte, index| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (byte == '\\' and !single_quoted) {
            escaped = true;
            continue;
        }
        if (byte == '\'' and !double_quoted) {
            single_quoted = !single_quoted;
            continue;
        }
        if (byte == '"' and !single_quoted) {
            double_quoted = !double_quoted;
            continue;
        }
        if (byte == '#' and !single_quoted and !double_quoted and
            (index == 0 or std.ascii.isWhitespace(line[index - 1])))
            return line[0..index];
    }
    return line;
}

fn shellHeredocDelimiter(line: []const u8) ?[]const u8 {
    const marker = std.mem.indexOf(u8, line, "<<") orelse return null;
    var index = marker + 2;
    if (index < line.len and line[index] == '-') index += 1;
    while (index < line.len and std.ascii.isWhitespace(line[index])) : (index += 1) {}
    if (index == line.len) return null;

    const quote: ?u8 = if (line[index] == '\'' or line[index] == '"') line[index] else null;
    if (quote != null) index += 1;
    const start = index;
    while (index < line.len) : (index += 1) {
        if (quote) |quoted| {
            if (line[index] == quoted) break;
        } else if (std.ascii.isWhitespace(line[index]) or line[index] == ';') break;
    }
    if (index == start) return null;
    return line[start..index];
}

fn containsShellCommand(body: []const u8, command: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, body, start, command)) |index| {
        const before_ok = index == 0 or isShellBoundary(body[index - 1]) or body[index - 1] == '/';
        const after = index + command.len;
        const after_ok = after == body.len or isShellBoundary(body[after]);
        if (before_ok and after_ok) return true;
        start = index + 1;
    }
    return false;
}

fn isShellBoundary(byte: u8) bool {
    return std.ascii.isWhitespace(byte) or switch (byte) {
        ';', '&', '|', '(', ')', '{', '}', '`' => true,
        else => false,
    };
}

const SourceKind = enum { local, http, git };
const GitReferenceKind = enum { branch, tag, commit };
const GitReference = struct {
    kind: GitReferenceKind,
    value: []u8,

    fn deinit(self: GitReference, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
    }
};

const ParsedSource = struct {
    name: []u8,
    location: []u8,
    kind: SourceKind,
    reference: ?GitReference = null,

    fn parse(allocator: std.mem.Allocator, raw: []const u8) !ParsedSource {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidSource;
        const rename_separator = std.mem.indexOf(u8, trimmed, "::");
        const explicit_name = if (rename_separator) |separator| trimmed[0..separator] else null;
        const raw_location = if (rename_separator) |separator| trimmed[separator + 2 ..] else trimmed;
        if (raw_location.len == 0) return error.InvalidSource;

        const fragment_start = std.mem.indexOfScalar(u8, raw_location, '#');
        const location_without_fragment = if (fragment_start) |index| raw_location[0..index] else raw_location;
        const is_git = std.ascii.startsWithIgnoreCase(location_without_fragment, "git+");
        const kind: SourceKind = if (is_git)
            .git
        else if (std.ascii.startsWithIgnoreCase(location_without_fragment, "https://") or
            std.ascii.startsWithIgnoreCase(location_without_fragment, "http://") or
            std.ascii.startsWithIgnoreCase(location_without_fragment, "file://"))
            .http
        else if (std.mem.indexOf(u8, location_without_fragment, "://") != null)
            return error.UnsupportedSourceProtocol
        else
            .local;

        const effective_location = if (is_git)
            location_without_fragment["git+".len..]
        else if (kind == .http)
            location_without_fragment
        else
            raw_location;
        if (effective_location.len == 0) return error.InvalidSource;

        const inferred_name = if (explicit_name) |name|
            name
        else
            sourceBasename(effective_location, is_git);
        try validateSourceName(inferred_name);

        var reference: ?GitReference = null;
        errdefer if (reference) |value| value.deinit(allocator);
        if (fragment_start) |index| {
            if (!is_git) return error.UnsupportedSourceFragment;
            const fragment = raw_location[index + 1 ..];
            const equals = std.mem.indexOfScalar(u8, fragment, '=') orelse return error.UnsupportedSourceFragment;
            const key = fragment[0..equals];
            const value = fragment[equals + 1 ..];
            if (value.len == 0) return error.InvalidSourceReference;
            const reference_kind: GitReferenceKind = if (std.ascii.eqlIgnoreCase(key, "branch"))
                .branch
            else if (std.ascii.eqlIgnoreCase(key, "tag"))
                .tag
            else if (std.ascii.eqlIgnoreCase(key, "commit"))
                .commit
            else
                return error.UnsupportedSourceFragment;
            reference = .{ .kind = reference_kind, .value = try allocator.dupe(u8, value) };
        }

        const name = try allocator.dupe(u8, inferred_name);
        errdefer allocator.free(name);
        const location = try allocator.dupe(u8, effective_location);
        errdefer allocator.free(location);
        return .{
            .name = name,
            .location = location,
            .kind = kind,
            .reference = reference,
        };
    }

    fn deinit(self: *ParsedSource, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.location);
        if (self.reference) |reference| reference.deinit(allocator);
        self.* = undefined;
    }
};

fn sourceBasename(location: []const u8, strip_git_suffix: bool) []const u8 {
    const query_start = std.mem.indexOfScalar(u8, location, '?') orelse location.len;
    const without_query = std.mem.trimEnd(u8, location[0..query_start], "/");
    const basename = std.fs.path.basename(without_query);
    if (strip_git_suffix and std.mem.endsWith(u8, basename, ".git")) return basename[0 .. basename.len - ".git".len];
    return basename;
}

fn validateSourceName(name: []const u8) !void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
        std.fs.path.isAbsolute(name) or std.mem.indexOfAny(u8, name, "/\\\r\n\x00") != null)
        return error.InvalidSourceName;
}

fn validateChecksumCount(source_count: usize, sums: ?[][]const u8) !void {
    if (sums) |values| if (values.len != 0 and values.len != source_count) return error.SourceChecksumCountMismatch;
}

fn hasSourceChecksums(package_build: *const PackageBuild) bool {
    if (package_build.sha_512_sums) |sums| if (sums.len > 0) return true;
    if (package_build.sha_256_sums) |sums| if (sums.len > 0) return true;
    if (package_build.md_5_sums) |sums| if (sums.len > 0) return true;
    return false;
}

fn requireSkippedVcsChecksums(package_build: *const PackageBuild, index: usize) !void {
    if (package_build.sha_512_sums) |sums| if (sums.len > 0 and !std.ascii.eqlIgnoreCase(sums[index], "SKIP")) return error.UnsupportedVcsChecksum;
    if (package_build.sha_256_sums) |sums| if (sums.len > 0 and !std.ascii.eqlIgnoreCase(sums[index], "SKIP")) return error.UnsupportedVcsChecksum;
    if (package_build.md_5_sums) |sums| if (sums.len > 0 and !std.ascii.eqlIgnoreCase(sums[index], "SKIP")) return error.UnsupportedVcsChecksum;
}

fn verifyFileHash(comptime Hash: type, io: std.Io, path: []const u8, expected: []const u8) !void {
    if (std.ascii.eqlIgnoreCase(expected, "SKIP")) return;
    if (expected.len != Hash.digest_length * 2) return error.InvalidSourceChecksum;
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    var hasher = Hash.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < stat.size) {
        const remaining: usize = @intCast(@min(stat.size - offset, buffer.len));
        const amount = try file.readPositionalAll(io, buffer[0..remaining], offset);
        if (amount == 0) return error.SourceReadFailed;
        hasher.update(buffer[0..amount]);
        offset += amount;
    }
    var digest: [Hash.digest_length]u8 = undefined;
    hasher.final(&digest);
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.ascii.eqlIgnoreCase(&actual, expected)) return error.SourceChecksumMismatch;
}

fn isExtractableArchive(name: []const u8) bool {
    const suffixes = [_][]const u8{
        ".tar", ".tar.gz", ".tgz", ".tar.zst", ".tar.xz", ".txz", ".tar.bz2", ".tbz", ".tbz2", ".zip",
    };
    for (suffixes) |suffix| if (std.ascii.endsWithIgnoreCase(name, suffix)) return true;
    return false;
}

fn containsSignatureSource(sources: []const []const u8) bool {
    for (sources) |source| {
        const location = if (std.mem.indexOf(u8, source, "::")) |separator| source[0..separator] else source;
        if (std.ascii.endsWithIgnoreCase(location, ".sig") or std.ascii.endsWithIgnoreCase(location, ".asc")) return true;
    }
    return false;
}

fn validateArchiveLink(target: []const u8) !void {
    if (target.len == 0 or std.fs.path.isAbsolute(target) or std.mem.indexOfScalar(u8, target, '\\') != null)
        return error.UnsafeSourceArchiveLink;
    var components = std.mem.splitScalar(u8, target, '/');
    while (components.next()) |component|
        if (std.mem.eql(u8, component, "..")) return error.UnsafeSourceArchiveLink;
}

fn rejectSymlinkDestination(io: std.Io, path: []const u8) !void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind == .sym_link or stat.kind == .directory) return error.UnsafeSourceArchivePath;
}

fn rejectExistingDestination(io: std.Io, path: []const u8) !void {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.UnsafeSourceArchivePath;
}

const StepStreamContext = struct {
    builder: *PackageBuilder,
    package_name: []const u8,
};

const WorkerStreamContext = struct {
    builder: *PackageBuilder,
    response_json: ?[]u8 = null,
};

fn forwardWorkerLine(data: ?*anyopaque, stream: process_runner.StreamKind, line: []const u8) void {
    const context: *WorkerStreamContext = @ptrCast(@alignCast(data.?));
    if (std.mem.startsWith(u8, line, worker_protocol.result_prefix)) {
        if (context.response_json) |old| context.builder.allocator.free(old);
        context.response_json = context.builder.allocator.dupe(
            u8,
            line[worker_protocol.result_prefix.len..],
        ) catch null;
        return;
    }
    context.builder.dispatcher.raiseInformational(.{
        .event_type = if (stream == .stderr) .aur_build_error else .aur_build_output,
        .message = line,
        .package_name = if (context.builder.requested_names.len > 0)
            context.builder.requested_names[0]
        else
            null,
    });
}

fn workerError(name: []const u8) anyerror {
    if (std.mem.eql(u8, name, "OutOfMemory")) return error.OutOfMemory;
    if (std.mem.eql(u8, name, "Cancelled")) return error.Cancelled;
    if (std.mem.eql(u8, name, "AlreadyBuilt")) return error.AlreadyBuilt;
    if (std.mem.eql(u8, name, "BuildDirectoryNotWritable")) return error.BuildDirectoryNotWritable;
    if (std.mem.eql(u8, name, "PrivilegedPackageOperationUnsupported")) return error.PrivilegedPackageOperationUnsupported;
    if (std.mem.eql(u8, name, "BuilderMustNotRunAsRoot")) return error.BuilderMustNotRunAsRoot;
    if (std.mem.eql(u8, name, "ReviewedPkgbuildChanged")) return error.ReviewedPkgbuildChanged;
    return error.BuildFailed;
}

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

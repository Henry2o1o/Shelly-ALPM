const std = @import("std");
const builtin = @import("builtin");
pub const MakePackageConfiguration = @import("../makepackage.zig").MakePackageConfiguration;
const MakePkgConfiguration = MakePackageConfiguration;
const pkgbuild_parser = @import("../../pkgbuild/pkgbuild_parser.zig");
const PackageBuild = pkgbuild_parser.Pkgbuild;
const ExecutionStep = pkgbuild_parser.execution_step;
const events = @import("../events.zig");
const op_context = @import("operation_context");
const archive = @import("archive");
const process_runner = @import("../builder.zig");
const downloader = @import("../../shared/downloader.zig");
const package_options = @import("package_options");
const install_script = @import("../../pkgbuild/install_script.zig");
const source_pgp_verifier = @import("../../shared/source_pgp_verifier.zig");
const alpm_bindings = @import("../../alpm/bindings.zig").libalpm;
const raw_alpm = alpm_bindings.alpm;

pub const pkgbuild_validation = @import("pkgbuild_validation.zig");
pub const PkgbuildValidation = pkgbuild_validation.PkgbuildValidation;
pub const pkgbuild_review = @import("pkgbuild_review.zig");
pub const PreparedPkgbuildReview = pkgbuild_review.PreparedPkgbuildReview;
pub const preparePkgbuildReview = pkgbuild_review.preparePkgbuildReview;

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
    skip_source_pgp_verification: bool = false,
    /// Optional keyring override for isolated builds and tests. Production
    /// callers normally leave this null so GnuPG uses the invoking user's
    /// keyring through the builder's sanitized environment.
    source_pgp_gnupg_home: ?[]const u8 = null,
    build_directory: []const u8,
    /// Exact PKGBUILD path used for the final in-process integrity check.
    /// It may be omitted only by unit-test fixtures.
    pkgbuild_path: ?[]const u8 = null,
    /// Allows callers with an already-verified source tree to use the custom
    /// packaging machinery without reacquiring sources. Normal AUR builds must
    /// leave this false so PackageBuilder creates $srcdir itself.
    sources_prepared: bool = false,
    /// Digest of the PKGBUILD and its reviewed local/install files. Every
    /// caller must prepare and verify this snapshot before execution.
    reviewed_pkgbuild_digest: ?[std.crypto.hash.sha2.Sha256.digest_length]u8 = null,
    /// SHA-256 of only the PKGBUILD, for BUILDINFO v2.
    pkgbuild_sha256sum: ?[std.crypto.hash.sha2.Sha256.digest_length]u8 = null,
    /// Optional deterministic build-environment snapshot. Production callers
    /// leave this null and the builder reads libalpm's local database.
    installed_packages: ?[]const []const u8 = null,
    /// Byte-exact install scripts retained by the approved package review.
    install_scripts: []const install_script.Script = &.{},
};

pub const BuilderErrors = error{
    BuildFailed,
    OutOfMemory,
    Cancelled,
    AlreadyBuilt,
    BuilderMustNotRunAsRoot,
    UnreviewedBuilderRequest,
    ReviewedPkgbuildChanged,
    BuildDirectoryNotWritable,
    PrivilegedPackageOperationUnsupported,
};

pub const FailureLocation = struct {
    package_name: ?[]const u8 = null,
    step_name: ?[]const u8 = null,
};

pub fn requireNonRootEffectiveUid(effective_uid: u32) error{BuilderMustNotRunAsRoot}!void {
    if (effective_uid == 0) return error.BuilderMustNotRunAsRoot;
}

/// Locks the current Linux process to the non-root privilege level. The flag
/// is inherited by every build child and cannot be unset.
pub fn secureBuilderProcess() !void {
    if (builtin.os.tag != .linux) return;
    // CI commonly runs Zig test binaries as root. The effective-UID policy is
    // covered directly by requireNonRootEffectiveUid's unit test; enforcing it
    // here as well would prevent the builder fixtures from reaching the code
    // they are intended to exercise. Production binaries must always reject
    // root before executing PKGBUILD steps.
    if (!builtin.is_test)
        try requireNonRootEffectiveUid(@intCast(std.os.linux.geteuid()));
    _ = try std.posix.prctl(.SET_NO_NEW_PRIVS, .{
        @as(usize, 1),
        @as(usize, 0),
        @as(usize, 0),
        @as(usize, 0),
    });
}

fn narrowBuilderError(err: anyerror) BuilderErrors {
    return switch (err) {
        error.OutOfMemory => BuilderErrors.OutOfMemory,
        error.Cancelled => BuilderErrors.Cancelled,
        error.AlreadyBuilt => BuilderErrors.AlreadyBuilt,
        error.BuilderMustNotRunAsRoot => BuilderErrors.BuilderMustNotRunAsRoot,
        error.UnreviewedBuilderRequest => BuilderErrors.UnreviewedBuilderRequest,
        error.ReviewedPkgbuildChanged => BuilderErrors.ReviewedPkgbuildChanged,
        error.BuildDirectoryNotWritable => BuilderErrors.BuildDirectoryNotWritable,
        error.PrivilegedPackageOperationUnsupported => BuilderErrors.PrivilegedPackageOperationUnsupported,
        else => BuilderErrors.BuildFailed,
    };
}

/// Non-root standalone package build engine.
pub const PackageBuilder = struct {
    allocator: std.mem.Allocator,
    package_builds: []PackageBuild,
    operation_context: *op_context.OperationContext,
    makepkg_config: MakePkgConfiguration,
    requested_names: []const []const u8,
    options: BuildOptions,
    environ: std.process.Environ,
    io: std.Io,
    failure_location: FailureLocation = .{},
    active_operation: ?*op_context.Operation = null,

    pub fn init(
        allocator: std.mem.Allocator,
        package_builds: []PackageBuild,
        operation_context: *op_context.OperationContext,
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
        const artifacts = self.run() catch |err|
            return narrowBuilderError(err);
        return artifacts;
    }

    /// Compatibility entry point that owns its operation lifecycle. Commands
    /// with an existing operation should call `runWithOperation` instead.
    pub fn run(self: *PackageBuilder) ![]BuildArtifact {
        var operation = self.operation_context.begin(op_context.OperationDescriptor{ .backend = .aur, .kind = .build, .subject = "Package Build" });
        var completion: op_context.CompletionStatus = .failed;
        defer operation.finish(completion);
        const artifacts = self.runWithOperation(&operation) catch |err| {
            if (err == error.Cancelled) {
                completion = .cancelled;
                return err;
            }
            operation.reportError(err, "Failed to build package", "build", null, false);
            return err;
        };
        completion = .success;
        return artifacts;
    }

    /// Runs the standalone build core inside a caller-owned operation.
    pub fn runWithOperation(
        self: *PackageBuilder,
        operation: *op_context.Operation,
    ) ![]BuildArtifact {
        const reviewed_digest = self.options.reviewed_pkgbuild_digest orelse
            return error.UnreviewedBuilderRequest;
        if (self.options.pkgbuild_path) |pkgbuild_path| {
            const current_pkgbuild = try std.Io.Dir.cwd().readFileAlloc(
                self.io,
                pkgbuild_path,
                self.allocator,
                .limited(32 * 1024 * 1024),
            );
            defer self.allocator.free(current_pkgbuild);
            var current_review = try preparePkgbuildReview(
                self.allocator,
                self.io,
                self.options.build_directory,
                current_pkgbuild,
                self.package_builds,
            );
            defer current_review.deinit();
            if (!std.mem.eql(u8, &reviewed_digest, &current_review.digest))
                return error.ReviewedPkgbuildChanged;
            if (!self.installScriptsMatch(current_review.install_scripts))
                return error.ReviewedPkgbuildChanged;
            self.options.pkgbuild_sha256sum = current_review.pkgbuild_digest;
        } else if (!builtin.is_test) return error.UnreviewedBuilderRequest;
        if (self.active_operation != null) return error.BuildAlreadyRunning;
        self.active_operation = operation;
        defer self.active_operation = null;
        return self.buildPackage(operation);
    }

    fn buildPackage(self: *PackageBuilder, operation: *op_context.Operation) ![]BuildArtifact {
        try secureBuilderProcess();
        try self.validateBuildDirectories();
        if (!self.options.sources_prepared) try self.prepareSources(operation);
        const shared_execution = self.package_builds[0].execution orelse
            return error.MissingExecutionSteps;
        for (shared_execution.steps) |step| {
            if (isPackageStep(step.name)) continue;
            if (std.mem.eql(u8, step.name, "check") and !self.options.run_check) continue;
            try self.runStep(
                operation,
                self.requested_names[0],
                step.name,
                shared_execution.shared_prelude,
                shared_execution.shared_helpers,
                step.body,
            );
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
            const package_execution = package_build.execution orelse
                return error.MissingExecutionSteps;
            const package_step = findPackageStep(package_execution.steps) orelse
                return error.MissingPackageStep;
            try self.runStep(
                operation,
                requested_name,
                package_step.name,
                package_execution.package_prelude,
                package_execution.package_helpers,
                package_step.body,
            );
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

    fn prepareSources(self: *PackageBuilder, operation: *op_context.Operation) !void {
        try operation.checkCancelled();
        const package_build = &self.package_builds[0];
        self.failure_location = .{
            .package_name = package_build.pkg_name,
            .step_name = "sources",
        };
        const sources = package_build.source orelse &.{};
        const valid_pgp_keys = package_build.valid_pgp_keys orelse &.{};
        try source_pgp_verifier.validatePinnedKeys(valid_pgp_keys);

        for (checksumSets(package_build)) |set|
            try validateChecksumCount(sources.len, set.sums);
        if (sources.len > 0 and !hasSourceChecksums(package_build))
            return error.MissingSourceChecksums;

        const srcdir = try std.fs.path.join(self.allocator, &.{ self.options.build_directory, "src" });
        defer self.allocator.free(srcdir);
        const staging = try std.fs.path.join(self.allocator, &.{ self.options.build_directory, ".src.shelly-staging" });
        defer self.allocator.free(staging);

        std.Io.Dir.cwd().deleteTree(self.io, staging) catch {
            self.reportUnwritableBuildDirectory(staging);
            return error.BuildDirectoryNotWritable;
        };
        std.Io.Dir.cwd().createDirPath(self.io, staging) catch {
            self.reportUnwritableBuildDirectory(staging);
            return error.BuildDirectoryNotWritable;
        };
        errdefer std.Io.Dir.cwd().deleteTree(self.io, staging) catch {};

        self.raiseSourceMessage(package_build, "Preparing package sources");
        const prepared = try self.allocator.alloc(PreparedSource, sources.len);
        var prepared_count: usize = 0;
        defer {
            for (prepared[0..prepared_count]) |*source| source.deinit(self.allocator);
            self.allocator.free(prepared);
        }
        for (sources, 0..) |raw_source, index| {
            try operation.checkCancelled();
            var source = try ParsedSource.parse(self.allocator, raw_source);
            const destination = std.fs.path.join(self.allocator, &.{ staging, source.name }) catch |err| {
                source.deinit(self.allocator);
                return err;
            };
            prepared[prepared_count] = .{
                .source = source,
                .destination = destination,
                .index = index,
            };
            prepared_count += 1;

            self.raiseSourceMessage(package_build, source.name);
            switch (source.kind) {
                .local => try self.copyLocalSource(source.location, destination),
                .http => try self.downloadSource(operation, source.location, destination),
                .git => try self.cloneGitSource(operation, source, destination),
            }
        }

        // Match makepkg's integrity ordering: acquire every source, then check
        // hashes and signatures, and only then extract anything.
        for (prepared) |*source| {
            try operation.checkCancelled();
            if (source.source.kind == .git) {
                try requireSkippedVcsChecksums(package_build, source.index);
            } else {
                try self.verifySourceChecksums(package_build, source.index, source.destination);
            }
        }

        if (!self.options.skip_source_pgp_verification)
            try self.verifyPreparedSourceSignatures(operation, package_build, prepared, staging);

        for (prepared) |*source| {
            try operation.checkCancelled();
            if (source.source.kind != .git) {
                if (isExtractableArchive(source.source.name) and
                    !containsString(package_build.no_extract orelse &.{}, source.source.name))
                    try self.extractSourceArchive(operation, source.destination, staging);
            }
        }
        // Only a fully prepared staging tree is committed. Sources are
        // reproducible, so retaining a second backup tree adds state without
        // improving recovery.
        std.Io.Dir.cwd().deleteTree(self.io, srcdir) catch {
            self.reportUnwritableBuildDirectory(srcdir);
            return error.BuildDirectoryNotWritable;
        };
        std.Io.Dir.rename(.cwd(), staging, .cwd(), srcdir, self.io) catch {
            self.reportUnwritableBuildDirectory(srcdir);
            return error.BuildDirectoryNotWritable;
        };
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
            .operation = operation,
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
        for (checksumSets(package_build)) |set| {
            const sums = set.sums orelse continue;
            if (sums.len == 0) continue;
            switch (set.algorithm) {
                .sha512 => try verifyFileHash(std.crypto.hash.sha2.Sha512, self.io, path, sums[index]),
                .sha384 => try verifyFileHash(std.crypto.hash.sha2.Sha384, self.io, path, sums[index]),
                .sha256 => try verifyFileHash(std.crypto.hash.sha2.Sha256, self.io, path, sums[index]),
                .sha224 => try verifyFileHash(std.crypto.hash.sha2.Sha224, self.io, path, sums[index]),
                .sha1 => try verifyFileHash(std.crypto.hash.Sha1, self.io, path, sums[index]),
                .md5 => try verifyFileHash(std.crypto.hash.Md5, self.io, path, sums[index]),
                .b2 => try verifyFileHash(std.crypto.hash.blake2.Blake2b512, self.io, path, sums[index]),
            }
        }
    }

    fn verifyPreparedSourceSignatures(
        self: *PackageBuilder,
        operation: *op_context.Operation,
        package_build: *const PackageBuild,
        prepared: []const PreparedSource,
        staging: []const u8,
    ) !void {
        const valid_pgp_keys = package_build.valid_pgp_keys orelse &.{};
        const verifier = source_pgp_verifier.Verifier{
            .allocator = self.allocator,
            .io = self.io,
            .environ = self.environ,
            .gnupg_home = self.options.source_pgp_gnupg_home,
        };

        for (prepared) |*signature| {
            try operation.checkCancelled();
            if (!isDetachedSignatureName(signature.source.name)) continue;
            const pairing = try findDetachedPayload(prepared, signature);
            var temporary_payload: ?[]u8 = null;
            defer if (temporary_payload) |path| {
                std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
                self.allocator.free(path);
            };
            const payload_path = if (pairing.compression) |compression| blk: {
                const path = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}/.shelly-pgp-payload-{d}",
                    .{ staging, signature.index },
                );
                errdefer self.allocator.free(path);
                try self.decompressSignedPayload(operation, pairing.source.destination, compression, path);
                temporary_payload = path;
                break :blk path;
            } else pairing.source.destination;

            const message = try std.fmt.allocPrint(
                self.allocator,
                "Verifying source signature: {s}",
                .{pairing.source.source.name},
            );
            defer self.allocator.free(message);
            self.raiseSourceMessage(package_build, message);
            var verification = try verifier.verifyDetached(
                signature.destination,
                payload_path,
                valid_pgp_keys,
            );
            defer verification.deinit(self.allocator);
            if (verification.warning != .none) self.raisePgpWarning(
                package_build,
                pairing.source.source.name,
                verification.warning,
            );
        }

        for (prepared) |*source| {
            try operation.checkCancelled();
            if (source.source.kind != .git or !source.source.signed) continue;
            const object: source_pgp_verifier.GitObject = if (source.source.reference) |reference|
                if (reference.kind == .tag) .tag else .commit
            else
                .commit;
            const reference = if (source.source.reference) |value| value.value else "HEAD";
            const message = try std.fmt.allocPrint(
                self.allocator,
                "Verifying Git signature: {s}",
                .{source.source.name},
            );
            defer self.allocator.free(message);
            self.raiseSourceMessage(package_build, message);
            var verification = try verifier.verifyGit(
                source.destination,
                object,
                reference,
                valid_pgp_keys,
            );
            defer verification.deinit(self.allocator);
            if (verification.warning != .none) self.raisePgpWarning(
                package_build,
                source.source.name,
                verification.warning,
            );
        }
    }

    fn raisePgpWarning(
        self: *PackageBuilder,
        package_build: *const PackageBuild,
        source_name: []const u8,
        warning: source_pgp_verifier.Warning,
    ) void {
        var buffer: [512]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buffer,
            "PGP warning for {s}: {s}",
            .{ source_name, @tagName(warning) },
        ) catch return;
        self.raiseSourceMessage(package_build, message);
    }

    fn decompressSignedPayload(
        self: *PackageBuilder,
        operation: *op_context.Operation,
        source_path: []const u8,
        compression: SignatureCompression,
        destination: []const u8,
    ) !void {
        const argv: []const []const u8 = switch (compression) {
            .gz, .compress => &.{ "/usr/bin/gzip", "-cdf", "--", source_path },
            .bz2 => &.{ "/usr/bin/bzip2", "-cdf", "--", source_path },
            .xz => &.{ "/usr/bin/xz", "-cdf", "--", source_path },
            .zst => &.{ "/usr/bin/zstd", "-d", "-q", "-c", "--", source_path },
            .lzo => &.{ "/usr/bin/lzop", "-d", "-q", "-c", "--", source_path },
            .lrz => &.{ "/usr/bin/lrzip", "-q", "-d", "-o", "-", source_path },
        };
        var child = try std.process.spawn(self.io, .{
            .argv = argv,
            .environ_map = null,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        defer child.kill(self.io);
        var output = try std.Io.Dir.cwd().createFile(self.io, destination, .{
            .truncate = true,
            .permissions = .fromMode(0o600),
        });
        defer output.close(self.io);
        var reader_buffer: [64 * 1024]u8 = undefined;
        var chunk: [64 * 1024]u8 = undefined;
        var output_buffer: [64 * 1024]u8 = undefined;
        var reader = child.stdout.?.reader(self.io, &reader_buffer);
        var writer = output.writer(self.io, &output_buffer);
        var total: u64 = 0;
        while (true) {
            try operation.checkCancelled();
            const amount = try reader.interface.readSliceShort(&chunk);
            if (amount == 0) break;
            total += amount;
            if (total > 4 * 1024 * 1024 * 1024) return error.SourcePayloadTooLarge;
            try writer.interface.writeAll(chunk[0..amount]);
        }
        try writer.interface.flush();
        try output.sync(self.io);
        const term = try child.wait(self.io);
        if (term != .exited or term.exited != 0) return error.SourceDecompressionFailed;
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
        const operation = self.active_operation orelse return;
        operation.status(.information, message, "aur_build_output", @intFromEnum(events.EventType.aur_build_output));
        operation.progress(.{
            .stage = "sources",
            .message = package_build.pkg_name orelse message,
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
        try self.validateWritableDirectory(self.options.build_directory);

        for ([_][]const u8{ "src", "pkg", ".src.shelly-staging" }) |name| {
            const path = try std.fs.path.join(self.allocator, &.{ self.options.build_directory, name });
            defer self.allocator.free(path);
            try self.validateWritableDirectory(path);
        }
    }

    fn validateWritableDirectory(self: *PackageBuilder, root_path: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        const stat = cwd.statFile(self.io, root_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        if (stat.kind != .directory) {
            self.reportUnwritableBuildDirectory(root_path);
            return error.BuildDirectoryNotWritable;
        }
        const mode = stat.permissions.toMode();
        if (mode & 0o222 == 0 or mode & 0o111 == 0) {
            self.reportUnwritableBuildDirectory(root_path);
            return error.BuildDirectoryNotWritable;
        }
        cwd.access(self.io, root_path, .{ .write = true, .execute = true }) catch {
            self.reportUnwritableBuildDirectory(root_path);
            return error.BuildDirectoryNotWritable;
        };
    }

    fn reportUnwritableBuildDirectory(self: *PackageBuilder, path: []const u8) void {
        const message = std.fmt.allocPrint(
            self.allocator,
            "Build directory is not writable by the non-root builder: {s}. Remove it or restore ownership to the invoking user.",
            .{path},
        ) catch return;
        defer self.allocator.free(message);
        if (self.active_operation) |operation|
            operation.reportError(error.BuildDirectoryNotWritable, message, "build", null, false);
    }

    fn runStep(
        self: *PackageBuilder,
        operation: *op_context.Operation,
        package_name: []const u8,
        step_name: []const u8,
        execution_prelude: []const u8,
        helper_definitions: []const u8,
        body: []const u8,
    ) !void {
        self.failure_location = .{
            .package_name = package_name,
            .step_name = step_name,
        };
        try operation.checkCancelled();
        const package_step = isPackageStep(step_name);
        const capture_pkgver = std.mem.eql(u8, step_name, "pkgver");
        const capture_metadata = package_step;
        const executable_body = try std.fmt.allocPrint(
            self.allocator,
            "{s}\n{s}\n{s}\n{s}\ndeclare -- pkgver=\"$1\"\n__shelly_step() {{\n{s}\n}}\n{s}",
            .{
                if (package_step) virtualMetadataShellPrelude else "",
                if (package_step) packageMetadataCaptureShellPrelude else "",
                execution_prelude,
                helper_definitions,
                body,
                if (capture_pkgver) "__shelly_step > \"$2\"" else "__shelly_step",
            },
        );
        defer self.allocator.free(executable_body);

        const command_body = if (capture_metadata)
            try std.fmt.allocPrint(self.allocator, "{s}\n__shelly_capture_metadata > \"$3\"", .{executable_body})
        else
            try self.allocator.dupe(u8, executable_body);
        defer self.allocator.free(command_body);

        const srcdir = try std.fs.path.join(
            self.allocator,
            &.{ self.options.build_directory, "src" },
        );
        defer self.allocator.free(srcdir);

        const pkgver_result_path = try std.fs.path.join(
            self.allocator,
            &.{ self.options.build_directory, ".shelly-pkgver" },
        );
        defer self.allocator.free(pkgver_result_path);
        const metadata_result_path = try std.fs.path.join(
            self.allocator,
            &.{ self.options.build_directory, ".shelly-package-metadata" },
        );
        defer self.allocator.free(metadata_result_path);
        if (capture_pkgver) {
            std.Io.Dir.cwd().deleteFile(self.io, pkgver_result_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
        defer if (capture_pkgver)
            std.Io.Dir.cwd().deleteFile(self.io, pkgver_result_path) catch {};
        if (capture_metadata) {
            std.Io.Dir.cwd().deleteFile(self.io, metadata_result_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
        defer if (capture_metadata)
            std.Io.Dir.cwd().deleteFile(self.io, metadata_result_path) catch {};

        const current_pkgver = self.package_builds[0].pkg_version orelse "";

        var stream_context: StepStreamContext = .{ .operation = operation, .package_name = package_name };
        const exit_code = try process_runner.runStreamingWithEnvironmentOperation(
            self.allocator,
            self.io,
            self.environ,
            &.{ "/bin/bash", "-e", "-c", command_body, "shelly-step", current_pkgver, pkgver_result_path, metadata_result_path },
            srcdir,
            null,
            .{ .function = forwardStepLine, .data = &stream_context },
            operation,
        );
        if (package_step and exit_code == virtual_metadata_rejected_exit_code)
            return error.PrivilegedPackageOperationUnsupported;
        if (exit_code != 0) return error.StepFailed;
        if (capture_pkgver) {
            const output = try std.Io.Dir.cwd().readFileAlloc(
                self.io,
                pkgver_result_path,
                self.allocator,
                .limited(64 * 1024),
            );
            defer self.allocator.free(output);
            try self.applyDynamicPkgver(output);
        }
        if (capture_metadata) {
            const output = try std.Io.Dir.cwd().readFileAlloc(
                self.io,
                metadata_result_path,
                self.allocator,
                .limited(1024 * 1024),
            );
            defer self.allocator.free(output);
            try self.applyPackageMetadata(package_name, output);
        }
        operation.status(.information, step_name, "aur_build_output", @intFromEnum(events.EventType.aur_build_output));
    }

    fn applyDynamicPkgver(self: *PackageBuilder, output: []const u8) !void {
        const version = std.mem.trimEnd(u8, output, "\r\n");
        try validatePkgver(version);

        for (self.package_builds) |*package_build| {
            const owned_version = try self.allocator.dupe(u8, version);
            if (package_build.pkg_version) |old| self.allocator.free(old);
            package_build.pkg_version = owned_version;

            const map_value = try self.allocator.dupe(u8, version);
            if (package_build.variables.fetchRemove("pkgver")) |old| {
                self.allocator.free(old.value);
                package_build.variables.put(old.key, map_value) catch |err| {
                    self.allocator.free(old.key);
                    self.allocator.free(map_value);
                    return err;
                };
            } else {
                const map_key = try self.allocator.dupe(u8, "pkgver");
                package_build.variables.put(map_key, map_value) catch |err| {
                    self.allocator.free(map_key);
                    self.allocator.free(map_value);
                    return err;
                };
            }
        }
    }

    fn applyPackageMetadata(
        self: *PackageBuilder,
        package_name: []const u8,
        encoded: []const u8,
    ) !void {
        const package_build = for (self.package_builds) |*candidate| {
            const name = candidate.pkg_name orelse continue;
            if (std.mem.eql(u8, name, package_name)) break candidate;
        } else return error.MissingPackageName;

        var cursor: usize = 0;
        while (cursor < encoded.len) {
            const kind = try nextMetadataField(encoded, &cursor);
            const name = try nextMetadataField(encoded, &cursor);
            if (std.mem.eql(u8, kind, "S")) {
                const value = try nextMetadataField(encoded, &cursor);
                if (std.mem.eql(u8, name, "pkgdesc"))
                    try replaceOptionalString(self.allocator, &package_build.pkg_desc, value)
                else if (std.mem.eql(u8, name, "url"))
                    try replaceOptionalString(self.allocator, &package_build.url, value)
                else
                    return error.InvalidPackageMetadata;
                continue;
            }
            if (!std.mem.eql(u8, kind, "A")) return error.InvalidPackageMetadata;
            const count_text = try nextMetadataField(encoded, &cursor);
            const count = std.fmt.parseInt(usize, count_text, 10) catch
                return error.InvalidPackageMetadata;
            const values = try self.allocator.alloc([]const u8, count);
            var populated: usize = 0;
            errdefer {
                for (values[0..populated]) |value| self.allocator.free(value);
                self.allocator.free(values);
            }
            while (populated < count) : (populated += 1)
                values[populated] = try self.allocator.dupe(u8, try nextMetadataField(encoded, &cursor));

            if (std.mem.eql(u8, name, "license"))
                replaceOptionalStrings(self.allocator, &package_build.license, values)
            else if (std.mem.eql(u8, name, "arch"))
                replaceOptionalStrings(self.allocator, &package_build.arch, values)
            else if (std.mem.eql(u8, name, "depends")) {
                replaceOptionalStrings(self.allocator, &package_build.depends, values);
                if (package_build.parsed_depends) |dependencies| {
                    for (dependencies) |dependency| dependency.deinit(self.allocator);
                    self.allocator.free(dependencies);
                }
                package_build.parsed_depends = null;
            } else if (std.mem.eql(u8, name, "optdepends"))
                replaceOptionalStrings(self.allocator, &package_build.opt_depends, values)
            else if (std.mem.eql(u8, name, "provides"))
                replaceOptionalStrings(self.allocator, &package_build.provides, values)
            else if (std.mem.eql(u8, name, "conflicts"))
                replaceOptionalStrings(self.allocator, &package_build.conflicts, values)
            else if (std.mem.eql(u8, name, "replaces"))
                replaceOptionalStrings(self.allocator, &package_build.replaces, values)
            else if (std.mem.eql(u8, name, "options"))
                replaceOptionalStrings(self.allocator, &package_build.options, values)
            else
                return error.InvalidPackageMetadata;
        }
    }

    fn preparePackageDirectory(self: *PackageBuilder, package_build: *const PackageBuild) !void {
        const package_name = package_build.pkg_name orelse return error.MissingPackageName;
        const pkgdir = try std.fs.path.join(
            self.allocator,
            &.{ self.options.build_directory, "pkg", package_name },
        );
        defer self.allocator.free(pkgdir);
        std.Io.Dir.cwd().deleteTree(self.io, pkgdir) catch {
            self.reportUnwritableBuildDirectory(pkgdir);
            return error.BuildDirectoryNotWritable;
        };
        std.Io.Dir.cwd().createDirPath(self.io, pkgdir) catch {
            self.reportUnwritableBuildDirectory(pkgdir);
            return error.BuildDirectoryNotWritable;
        };
    }

    /// Applies the small, content-affecting subset of makepkg's tidy phase
    /// currently modeled by Shelly. PKGBUILD options override makepkg.conf
    /// options using the same `option`/`!option` convention as makepkg.
    fn tidyPackage(self: *PackageBuilder, package_build: *const PackageBuild, pkgdir: []const u8) !void {
        const effective = try effectivePackageOptions(
            self.allocator,
            self.makepkg_config.options,
            package_build.options orelse &.{},
        );
        defer freeOwnedStrings(self.allocator, effective);
        if (!optionEnabled(effective, "strip")) return;

        var directory = try std.Io.Dir.cwd().openDir(self.io, pkgdir, .{ .iterate = true });
        defer directory.close(self.io);
        var walker = try directory.walk(self.allocator);
        defer walker.deinit();
        while (try walker.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (self.active_operation) |operation| try operation.checkCancelled();
            const stat = try entry.dir.statFile(self.io, entry.basename, .{ .follow_symlinks = false });
            if (stat.permissions.toMode() & 0o200 == 0) continue;

            const path = try std.fs.path.join(self.allocator, &.{ pkgdir, entry.path });
            defer self.allocator.free(path);
            const kind = try stripKind(self.io, path);
            const raw_flags = switch (kind orelse continue) {
                .binary => self.makepkg_config.strip_binaries,
                .shared => self.makepkg_config.strip_shared,
                .static => self.makepkg_config.strip_static,
            };
            const flags = try parseConfigurationWords(self.allocator, raw_flags);
            defer freeOwnedStrings(self.allocator, flags);
            var command: std.ArrayList([]const u8) = .empty;
            defer command.deinit(self.allocator);
            try command.append(self.allocator, "strip");
            for (flags) |flag| try command.append(self.allocator, flag);
            try command.append(self.allocator, path);
            var result = try process_runner.runWithEnvironment(
                self.allocator,
                self.io,
                self.environ,
                command.items,
                null,
                60,
            );
            defer result.deinit(self.allocator);
            if (result.exit_code != 0) return error.StripFailed;
        }
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

        try self.tidyPackage(package_build, pkgdir);

        var pkgdir_handle = try std.Io.Dir.cwd().openDir(self.io, pkgdir, .{ .iterate = true });
        defer pkgdir_handle.close(self.io);

        const payload_size = try directorySize(self.allocator, self.io, pkgdir_handle);
        const build_date = std.Io.Clock.real.now(self.io).toSeconds();
        try self.writePackageInfo(package_build, pkgdir_handle, full_version, package_arch, payload_size, build_date);
        try self.writeBuildInfo(package_build, pkgdir_handle, full_version, package_arch, build_date);
        if (package_build.install_file) |install_file| {
            const reviewed_script = self.findInstallScript(install_file) orelse return error.MissingInstallFile;
            try writeMetadataFile(pkgdir_handle, self.io, ".INSTALL", reviewed_script.contents);
        } else {
            try deleteFileIgnoreMissing(pkgdir_handle, self.io, ".INSTALL");
        }

        const mtree_path = try std.fs.path.join(self.allocator, &.{ pkgdir, ".MTREE" });
        defer self.allocator.free(mtree_path);
        const virtual_metadata: archive.VirtualMetadata = .{};
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

    fn findInstallScript(self: *const PackageBuilder, file_name: []const u8) ?*const install_script.Script {
        for (self.options.install_scripts) |*script| {
            if (std.mem.eql(u8, script.file_name, file_name)) return script;
        }
        return null;
    }

    fn installScriptsMatch(
        self: *const PackageBuilder,
        current_scripts: []const install_script.Script,
    ) bool {
        if (self.options.install_scripts.len != current_scripts.len) return false;
        for (current_scripts) |current| {
            const reviewed = self.findInstallScript(current.file_name) orelse return false;
            if (!std.mem.eql(u8, reviewed.contents, current.contents)) return false;
        }
        return true;
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
        const pkgbuild_digest = self.options.pkgbuild_sha256sum orelse
            return error.MissingPkgbuildDigest;
        const pkgbuild_digest_hex = std.fmt.bytesToHex(pkgbuild_digest, .lower);
        try writeKeyValue(writer, "pkgbuild_sha256sum", &pkgbuild_digest_hex);
        try writeKeyValue(writer, "packager", self.makepkg_config.packager);
        try writer.print("builddate = {d}\n", .{build_date});
        try writeKeyValue(writer, "builddir", self.options.build_directory);
        try writeKeyValue(
            writer,
            "startdir",
            if (self.options.pkgbuild_path) |path|
                std.fs.path.dirname(path) orelse self.options.build_directory
            else
                self.options.build_directory,
        );
        try writeKeyValue(writer, "buildtool", "shelly");
        try writeKeyValue(writer, "buildtoolver", package_options.version);

        const build_environment = try parseConfigurationWords(
            self.allocator,
            self.makepkg_config.build_environment,
        );
        defer freeOwnedStrings(self.allocator, build_environment);
        for (build_environment) |value| try writeKeyValue(writer, "buildenv", value);

        const effective_options = try effectivePackageOptions(
            self.allocator,
            self.makepkg_config.options,
            package_build.options orelse &.{},
        );
        defer freeOwnedStrings(self.allocator, effective_options);
        for (effective_options) |value| try writeKeyValue(writer, "options", value);

        if (self.options.installed_packages) |installed| {
            for (installed) |value| try writeKeyValue(writer, "installed", value);
        } else {
            const installed = try collectInstalledPackages(self.allocator);
            defer freeOwnedStrings(self.allocator, installed);
            for (installed) |value| try writeKeyValue(writer, "installed", value);
        }
        try writeMetadataFile(pkgdir, self.io, ".BUILDINFO", output.written());
    }
};

const virtual_metadata_rejected_exit_code: u8 = 97;

/// Mirrors makepkg's pkgver restrictions: the value must be non-empty ASCII
/// and cannot contain colons, slashes, hyphens, or whitespace.
fn validatePkgver(version: []const u8) !void {
    if (version.len == 0) return error.InvalidPackageVersion;
    for (version) |byte| {
        if (byte == 0 or !std.ascii.isAscii(byte) or std.ascii.isWhitespace(byte) or
            byte == ':' or byte == '/' or byte == '-')
        {
            return error.InvalidPackageVersion;
        }
    }
}

fn nextMetadataField(encoded: []const u8, cursor: *usize) ![]const u8 {
    if (cursor.* >= encoded.len) return error.InvalidPackageMetadata;
    const end = std.mem.indexOfScalarPos(u8, encoded, cursor.*, 0) orelse
        return error.InvalidPackageMetadata;
    const field = encoded[cursor.*..end];
    cursor.* = end + 1;
    return field;
}

fn replaceOptionalString(
    allocator: std.mem.Allocator,
    destination: *?[]const u8,
    value: []const u8,
) !void {
    const owned = try allocator.dupe(u8, value);
    if (destination.*) |old| allocator.free(old);
    destination.* = owned;
}

fn replaceOptionalStrings(
    allocator: std.mem.Allocator,
    destination: *?[][]const u8,
    values: [][]const u8,
) void {
    if (destination.*) |old| {
        for (old) |value| allocator.free(value);
        allocator.free(old);
    }
    destination.* = values;
}

const StripKind = enum { binary, shared, static };

fn stripKind(io: std.Io, path: []const u8) !?StripKind {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var header: [20]u8 = undefined;
    const amount = try file.readPositionalAll(io, &header, 0);
    if (amount >= 8 and std.mem.eql(u8, header[0..8], "!<arch>\n")) return .static;
    if (amount < header.len or !std.mem.eql(u8, header[0..4], "\x7fELF")) return null;
    const elf_type: u16 = switch (header[5]) {
        1 => std.mem.readInt(u16, header[16..18], .little),
        2 => std.mem.readInt(u16, header[16..18], .big),
        else => return null,
    };
    return switch (elf_type) {
        1 => if (std.mem.endsWith(u8, path, ".o")) .static else if (std.mem.endsWith(u8, path, ".ko")) .shared else null,
        2 => .binary,
        3 => .shared,
        else => null,
    };
}

fn freeOwnedStrings(allocator: std.mem.Allocator, values: [][]u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

/// Parses the shell-like array syntax used for makepkg.conf option and flag
/// values. It deliberately supports data syntax only; no substitutions or
/// commands are evaluated.
fn parseConfigurationWords(allocator: std.mem.Allocator, raw: []const u8) ![][]u8 {
    var text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len >= 2 and text[0] == '(' and text[text.len - 1] == ')')
        text = text[1 .. text.len - 1];

    var words: std.ArrayList([]u8) = .empty;
    errdefer {
        for (words.items) |word| allocator.free(word);
        words.deinit(allocator);
    }
    var index: usize = 0;
    while (index < text.len) {
        while (index < text.len and std.ascii.isWhitespace(text[index])) index += 1;
        if (index >= text.len or text[index] == '#') break;
        var word: std.ArrayList(u8) = .empty;
        defer word.deinit(allocator);
        var quote: ?u8 = null;
        var started = false;
        while (index < text.len) {
            const byte = text[index];
            if (quote == null and (std.ascii.isWhitespace(byte) or byte == '#')) break;
            started = true;
            if (byte == '\\' and quote != '\'') {
                index += 1;
                if (index >= text.len) return error.InvalidConfigurationArray;
                try word.append(allocator, text[index]);
                index += 1;
                continue;
            }
            if (byte == '\'' or byte == '"') {
                if (quote == null) {
                    quote = byte;
                    index += 1;
                    continue;
                }
                if (quote.? == byte) {
                    quote = null;
                    index += 1;
                    continue;
                }
            }
            try word.append(allocator, byte);
            index += 1;
        }
        if (quote != null) return error.InvalidConfigurationArray;
        if (started) try words.append(allocator, try allocator.dupe(u8, word.items));
        if (index < text.len and text[index] == '#') break;
    }
    return words.toOwnedSlice(allocator);
}

fn optionName(value: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, value, "!")) value[1..] else value;
}

fn optionEnabled(options: []const []u8, name: []const u8) bool {
    for (options) |option| {
        if (!std.mem.eql(u8, optionName(option), name)) continue;
        return !std.mem.startsWith(u8, option, "!");
    }
    return false;
}

fn effectivePackageOptions(
    allocator: std.mem.Allocator,
    configured: []const u8,
    overrides: []const []const u8,
) ![][]u8 {
    var options = try parseConfigurationWords(allocator, configured);
    errdefer freeOwnedStrings(allocator, options);
    for (overrides) |override| {
        if (override.len == 0 or std.mem.eql(u8, override, "!")) continue;
        var replaced = false;
        for (options) |*current| {
            if (!std.mem.eql(u8, optionName(current.*), optionName(override))) continue;
            const owned = try allocator.dupe(u8, override);
            allocator.free(current.*);
            current.* = owned;
            replaced = true;
            break;
        }
        if (!replaced) {
            const owned = try allocator.dupe(u8, override);
            errdefer allocator.free(owned);
            const resized = try allocator.realloc(options, options.len + 1);
            options = resized;
            options[options.len - 1] = owned;
        }
    }
    return options;
}

fn collectInstalledPackages(allocator: std.mem.Allocator) ![][]u8 {
    var alpm_error: raw_alpm.alpm_errno_t = 0;
    const handle = raw_alpm.alpm_initialize("/", "/var/lib/pacman", &alpm_error) orelse
        return error.LocalDatabaseOpenFailed;
    defer _ = raw_alpm.alpm_release(handle);
    const database = raw_alpm.alpm_get_localdb(handle) orelse
        return error.LocalDatabaseOpenFailed;
    var packages = raw_alpm.alpm_db_get_pkgcache(database);
    var installed: std.ArrayList([]u8) = .empty;
    errdefer {
        for (installed.items) |value| allocator.free(value);
        installed.deinit(allocator);
    }
    while (packages != null) : (packages = packages.?.*.next) {
        const package = packages.?.*.data orelse continue;
        const name = alpm_bindings.str(raw_alpm.alpm_pkg_get_name(@ptrCast(package))) orelse continue;
        const version = alpm_bindings.str(raw_alpm.alpm_pkg_get_version(@ptrCast(package))) orelse continue;
        const architecture = alpm_bindings.str(raw_alpm.alpm_pkg_get_arch(@ptrCast(package))) orelse continue;
        try installed.append(
            allocator,
            try std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ name, version, architecture }),
        );
    }
    std.mem.sort([]u8, installed.items, {}, struct {
        fn before(_: void, left: []u8, right: []u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.before);
    return installed.toOwnedSlice(allocator);
}

/// Writes supported package-scoped metadata through a NUL-delimited channel.
/// The package function may print arbitrary output without corrupting it.
const packageMetadataCaptureShellPrelude =
    \\__shelly_capture_scalar() {
    \\  local name="$1"
    \\  declare -p "$name" >/dev/null 2>&1 || return 0
    \\  local -n value="$name"
    \\  printf 'S\0%s\0%s\0' "$name" "$value"
    \\}
    \\__shelly_capture_array() {
    \\  local name="$1"
    \\  declare -p "$name" >/dev/null 2>&1 || return 0
    \\  local -n values="$name"
    \\  printf 'A\0%s\0%s\0' "$name" "${#values[@]}"
    \\  if ((${#values[@]})); then printf '%s\0' "${values[@]}"; fi
    \\}
    \\__shelly_capture_metadata() {
    \\  local name
    \\  for name in pkgdesc url; do __shelly_capture_scalar "$name"; done
    \\  for name in license arch depends optdepends provides conflicts replaces options; do
    \\    __shelly_capture_array "$name"
    \\  done
    \\}
;

/// Bash functions used only for package() and package_<name>(). They simulate
/// the common fakeroot ownership operations without changing host ownership.
/// The archive writer independently records root ownership for every entry.
const virtualMetadataShellPrelude =
    \\__shelly_metadata_reject() {
    \\  printf '%s\n' 'shelly: unsupported privileged package metadata operation' >&2
    \\  return 97
    \\}
    \\mknod() {
    \\  printf '%s\n' 'shelly: package steps cannot create device nodes' >&2
    \\  return 1
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
    signed: bool = false,

    fn parse(allocator: std.mem.Allocator, raw: []const u8) !ParsedSource {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidSource;
        const rename_separator = std.mem.indexOf(u8, trimmed, "::");
        const explicit_name = if (rename_separator) |separator| trimmed[0..separator] else null;
        const raw_location = if (rename_separator) |separator| trimmed[separator + 2 ..] else trimmed;
        if (raw_location.len == 0) return error.InvalidSource;

        const fragment_start = std.mem.indexOfScalar(u8, raw_location, '#');
        const query_start = std.mem.indexOfScalar(u8, raw_location, '?');
        const first_suffix = @min(fragment_start orelse raw_location.len, query_start orelse raw_location.len);
        const git_location = raw_location[0..first_suffix];
        const location_without_fragment = if (fragment_start) |index| raw_location[0..index] else raw_location;
        const is_git = std.ascii.startsWithIgnoreCase(git_location, "git+");
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
            git_location["git+".len..]
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
            const fragment_end = if (query_start) |query| if (query > index) query else raw_location.len else raw_location.len;
            const fragment = raw_location[index + 1 .. fragment_end];
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

        var signed = false;
        if (query_start) |index| {
            if (!is_git) {
                if (fragment_start != null and index > fragment_start.?) return error.UnsupportedSourceFragment;
            } else {
                const query_end = if (fragment_start) |fragment| if (fragment > index) fragment else raw_location.len else raw_location.len;
                const query = raw_location[index + 1 .. query_end];
                if (!std.mem.eql(u8, query, "signed")) return error.UnsupportedSourceQuery;
                signed = true;
            }
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
            .signed = signed,
        };
    }

    fn deinit(self: *ParsedSource, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.location);
        if (self.reference) |reference| reference.deinit(allocator);
        self.* = undefined;
    }
};

const PreparedSource = struct {
    source: ParsedSource,
    destination: []u8,
    index: usize,

    fn deinit(self: *PreparedSource, allocator: std.mem.Allocator) void {
        self.source.deinit(allocator);
        allocator.free(self.destination);
        self.* = undefined;
    }
};

const SignatureCompression = enum {
    gz,
    bz2,
    xz,
    lrz,
    lzo,
    compress,
    zst,

    fn suffix(self: SignatureCompression) []const u8 {
        return switch (self) {
            .gz => ".gz",
            .bz2 => ".bz2",
            .xz => ".xz",
            .lrz => ".lrz",
            .lzo => ".lzo",
            .compress => ".Z",
            .zst => ".zst",
        };
    }
};

const DetachedPayload = struct {
    source: *const PreparedSource,
    compression: ?SignatureCompression,
};

fn detachedSignatureBase(name: []const u8) ?[]const u8 {
    for ([_][]const u8{ ".sig", ".sign", ".asc" }) |extension| {
        if (std.mem.endsWith(u8, name, extension)) return name[0 .. name.len - extension.len];
    }
    return null;
}

fn isDetachedSignatureName(name: []const u8) bool {
    return detachedSignatureBase(name) != null;
}

fn findDetachedPayload(
    prepared: []const PreparedSource,
    signature: *const PreparedSource,
) !DetachedPayload {
    const base = detachedSignatureBase(signature.source.name) orelse return error.InvalidSignatureSource;
    var exact: ?*const PreparedSource = null;
    for (prepared) |*candidate| {
        if (candidate.index == signature.index or isDetachedSignatureName(candidate.source.name)) continue;
        if (!std.mem.eql(u8, candidate.source.name, base)) continue;
        if (exact != null) return error.AmbiguousSignedSource;
        exact = candidate;
    }
    if (exact) |source| return .{ .source = source, .compression = null };

    // makepkg tries compressed variants in this fixed order and stops at the
    // first one it finds. An uncompressed source above always wins.
    for (std.meta.tags(SignatureCompression)) |kind| {
        var match: ?*const PreparedSource = null;
        for (prepared) |*candidate| {
            if (candidate.index == signature.index or isDetachedSignatureName(candidate.source.name)) continue;
            if (candidate.source.name.len != base.len + kind.suffix().len or
                !std.mem.startsWith(u8, candidate.source.name, base) or
                !std.mem.endsWith(u8, candidate.source.name, kind.suffix())) continue;
            if (match != null) return error.AmbiguousSignedSource;
            match = candidate;
        }
        if (match) |source| return .{ .source = source, .compression = kind };
    }
    return error.MissingSignedSource;
}

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

const ChecksumAlgorithm = enum { sha512, sha384, sha256, sha224, sha1, md5, b2 };

const ChecksumSet = struct {
    algorithm: ChecksumAlgorithm,
    sums: ?[][]const u8,
};

fn checksumSets(package_build: *const PackageBuild) [7]ChecksumSet {
    return .{
        .{ .algorithm = .sha512, .sums = package_build.sha_512_sums },
        .{ .algorithm = .sha384, .sums = package_build.sha_384_sums },
        .{ .algorithm = .sha256, .sums = package_build.sha_256_sums },
        .{ .algorithm = .sha224, .sums = package_build.sha_224_sums },
        .{ .algorithm = .sha1, .sums = package_build.sha_1_sums },
        .{ .algorithm = .md5, .sums = package_build.md_5_sums },
        .{ .algorithm = .b2, .sums = package_build.b_2_sums },
    };
}

fn hasSourceChecksums(package_build: *const PackageBuild) bool {
    for (checksumSets(package_build)) |set|
        if (set.sums) |sums| if (sums.len > 0) return true;
    return false;
}

fn requireSkippedVcsChecksums(package_build: *const PackageBuild, index: usize) !void {
    for (checksumSets(package_build)) |set| {
        const sums = set.sums orelse continue;
        if (sums.len > 0 and !std.ascii.eqlIgnoreCase(sums[index], "SKIP"))
            return error.UnsupportedVcsChecksum;
    }
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, needle)) return true;
    return false;
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
    operation: *op_context.Operation,
    package_name: []const u8,
};

fn forwardStepLine(data: ?*anyopaque, stream: process_runner.StreamKind, line: []const u8) void {
    const context: *StepStreamContext = @ptrCast(@alignCast(data.?));
    const event_type: events.EventType = if (stream == .stderr) .aur_build_error else .aur_build_output;
    context.operation.status(
        if (stream == .stderr) .warning else .information,
        line,
        @tagName(event_type),
        @intFromEnum(event_type),
    );
    if (stream == .stdout) if (process_runner.parseBuildProgress(line)) |progress| {
        context.operation.progress(.{
            .stage = "makepkg_build",
            .percentage = @floatFromInt(progress.percent),
            .message = progress.message,
            .native_code = @intFromEnum(events.ProgressType.makepkg_build),
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

test "signed Git source parser accepts query before or after fragment" {
    for ([_][]const u8{
        "git+https://example.invalid/demo.git?signed#tag=v1",
        "git+https://example.invalid/demo.git#tag=v1?signed",
    }) |raw| {
        var source = try ParsedSource.parse(std.testing.allocator, raw);
        defer source.deinit(std.testing.allocator);
        try std.testing.expect(source.signed);
        try std.testing.expectEqual(SourceKind.git, source.kind);
        try std.testing.expectEqualStrings("https://example.invalid/demo.git", source.location);
        try std.testing.expectEqual(GitReferenceKind.tag, source.reference.?.kind);
        try std.testing.expectEqualStrings("v1", source.reference.?.value);
    }
}

test "detached source pairing handles exact renamed and compressed payload names" {
    const names = [_][]const u8{ "release.tar.xz", "release.tar.sign" };
    var prepared: [2]PreparedSource = undefined;
    var initialized: usize = 0;
    defer for (prepared[0..initialized]) |*source| source.deinit(std.testing.allocator);
    for (names, &prepared, 0..) |name, *source, index| {
        source.* = .{
            .source = .{
                .name = try std.testing.allocator.dupe(u8, name),
                .location = try std.testing.allocator.dupe(u8, name),
                .kind = .local,
            },
            .destination = try std.testing.allocator.dupe(u8, name),
            .index = index,
        };
        initialized += 1;
    }
    const pairing = try findDetachedPayload(&prepared, &prepared[1]);
    try std.testing.expectEqual(@as(usize, 0), pairing.source.index);
    try std.testing.expectEqual(SignatureCompression.xz, pairing.compression.?);

    const exact_source: PreparedSource = blk: {
        const name = try std.testing.allocator.dupe(u8, "release.tar");
        errdefer std.testing.allocator.free(name);
        const location = try std.testing.allocator.dupe(u8, "release.tar");
        errdefer std.testing.allocator.free(location);
        const destination = try std.testing.allocator.dupe(u8, "release.tar");
        errdefer std.testing.allocator.free(destination);
        break :blk .{
            .source = .{ .name = name, .location = location, .kind = .local },
            .destination = destination,
            .index = 2,
        };
    };
    var with_exact = [_]PreparedSource{ prepared[0], prepared[1], exact_source };
    defer with_exact[2].deinit(std.testing.allocator);
    const exact_pairing = try findDetachedPayload(&with_exact, &with_exact[1]);
    try std.testing.expectEqual(@as(usize, 2), exact_pairing.source.index);
    try std.testing.expectEqual(@as(?SignatureCompression, null), exact_pairing.compression);
}

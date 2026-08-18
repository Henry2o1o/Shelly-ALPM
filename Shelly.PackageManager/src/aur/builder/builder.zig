const std = @import("std");
const builtin = @import("builtin");
pub const ShellyBuildConfiguration = @import("../shellybuild.zig").ShellyBuildConfiguration;
const pkgbuild_parser = @import("../../pkgbuild/pkgbuild_parser.zig");
const package_metadata = @import("../../pkgbuild/package_metadata.zig");
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
const package_signer = @import("../../shared/package_signer.zig");
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
    run_verify: bool = true,
    overwrite: bool,
    clean_after_success: bool,
    skip_source_pgp_verification: bool = false,
    /// Optional keyring override for isolated builds and tests. Production
    /// callers normally leave this null so GnuPG uses the invoking user's
    /// keyring through the builder's sanitized environment.
    source_pgp_gnupg_home: ?[]const u8 = null,
    /// Signs each published package archive with a detached binary OpenPGP
    /// signature, matching makepkg's --sign behavior.
    sign: bool = false,
    /// Key id or fingerprint passed to GPG's --local-user when signing; null
    /// selects the default key from the invoking user's keyring, matching
    /// makepkg's GPGKEY.
    sign_key: ?[]const u8 = null,
    /// Optional signing keyring override for isolated builds and tests.
    /// Production callers normally leave this null so GnuPG uses the
    /// invoking user's keyring through the builder's sanitized environment.
    sign_gnupg_home: ?[]const u8 = null,
    start_directory: []const u8,
    work_directory: []const u8,
    package_destination: []const u8,
    source_destination: []const u8,
    log_destination: []const u8,
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
    /// Byte-exact local and auxiliary files retained by package review.
    reviewed_files: []const pkgbuild_review.ReviewedFile = &.{},
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

const BuildLog = struct {
    file: std.Io.File,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    failed: std.atomic.Value(bool) = .init(false),

    fn writeRecord(self: *BuildLog, kind: []const u8, message: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.file.writeStreamingAll(self.io, "[");
        try self.file.writeStreamingAll(self.io, kind);
        try self.file.writeStreamingAll(self.io, "] ");
        try self.file.writeStreamingAll(self.io, message);
        try self.file.writeStreamingAll(self.io, "\n");
        try self.file.sync(self.io);
    }

    fn writeStream(self: *BuildLog, stream: process_runner.StreamKind, line: []const u8) void {
        self.writeRecord(if (stream == .stderr) "stderr" else "stdout", line) catch
            self.failed.store(true, .release);
    }

    fn ensureHealthy(self: *const BuildLog) !void {
        if (self.failed.load(.acquire)) return error.BuildLogWriteFailed;
    }

    fn close(self: *BuildLog) void {
        self.file.close(self.io);
    }
};

pub fn requireNonRootEffectiveUid(effective_uid: u32) error{BuilderMustNotRunAsRoot}!void {
    if (effective_uid == 0) return error.BuilderMustNotRunAsRoot;
}

pub fn uniqueWorkDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    build_root: []const u8,
    package_base: []const u8,
) ![]u8 {
    const normalized = try archive.normalizeEntryPath(allocator, package_base);
    defer allocator.free(normalized);
    if (std.mem.indexOfScalar(u8, normalized, '/') != null) return error.InvalidPackageBase;
    var random_suffix: [8]u8 = undefined;
    io.random(&random_suffix);
    const suffix = std.fmt.bytesToHex(random_suffix, .lower);
    return std.fmt.allocPrint(allocator, "{s}/{s}-{s}", .{ build_root, normalized, suffix });
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
    shellybuild_config: ShellyBuildConfiguration,
    requested_names: []const []const u8,
    options: BuildOptions,
    environ: std.process.Environ,
    io: std.Io,
    failure_location: FailureLocation = .{},
    active_operation: ?*op_context.Operation = null,
    active_log: ?*BuildLog = null,

    pub fn init(
        allocator: std.mem.Allocator,
        package_builds: []PackageBuild,
        operation_context: *op_context.OperationContext,
        shellybuild_configuration: ShellyBuildConfiguration,
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
            .shellybuild_config = shellybuild_configuration,
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
                self.options.start_directory,
                current_pkgbuild,
                self.package_builds,
            );
            defer current_review.deinit();
            if (!std.mem.eql(u8, &reviewed_digest, &current_review.digest))
                return error.ReviewedPkgbuildChanged;
            if (!self.installScriptsMatch(current_review.install_scripts))
                return error.ReviewedPkgbuildChanged;
            if (!self.reviewedFilesMatch(current_review.reviewed_files))
                return error.ReviewedPkgbuildChanged;
            self.options.pkgbuild_sha256sum = current_review.pkgbuild_digest;
        } else if (!builtin.is_test) return error.UnreviewedBuilderRequest;
        if (self.active_operation != null) return error.BuildAlreadyRunning;
        self.active_operation = operation;
        defer self.active_operation = null;
        try self.validateBuildDirectories();
        var log = try self.openBuildLog();
        defer log.close();
        self.active_log = &log;
        defer self.active_log = null;
        try log.writeRecord("build", "started");
        const artifacts = self.buildPackage(operation) catch |err| {
            log.writeRecord("status", if (err == error.Cancelled) "cancelled" else "failed") catch {};
            return err;
        };
        log.writeRecord("status", "success") catch |err| {
            deinitArtifacts(self.allocator, artifacts);
            return err;
        };
        return artifacts;
    }

    fn buildPackage(self: *PackageBuilder, operation: *op_context.Operation) ![]BuildArtifact {
        try secureBuilderProcess();
        try self.validatePackageFunctions();
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
                null,
            );
        }

        var artifacts: std.ArrayList(BuildArtifact) = .empty;
        errdefer {
            for (artifacts.items) |artifact| {
                self.removePublishedArtifact(artifact.path);
                artifact.deinit(self.allocator);
            }
            artifacts.deinit(self.allocator);
        }

        for (self.package_builds, self.requested_names) |*package_build, requested_name| {
            if (!self.packageSupportsArchitecture(package_build)) continue;
            try self.preparePackageDirectory(package_build);
            const approved_install = if (package_build.install_file) |value|
                try self.allocator.dupe(u8, value)
            else
                null;
            defer if (approved_install) |value| self.allocator.free(value);
            const approved_changelog = if (package_build.changelog_file) |value|
                try self.allocator.dupe(u8, value)
            else
                null;
            defer if (approved_changelog) |value| self.allocator.free(value);
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
                null,
            );
            if (!reviewedAuxiliarySelectionMatches(approved_install, package_build.install_file) or
                !reviewedAuxiliarySelectionMatches(approved_changelog, package_build.changelog_file))
                return error.ReviewedPkgbuildChanged;
            const artifact = try self.assemblePackage(package_build);
            artifacts.append(self.allocator, artifact) catch |err| {
                self.removePublishedArtifact(artifact.path);
                artifact.deinit(self.allocator);
                return err;
            };
        }

        if (self.options.clean_after_success) {
            for ([_][]const u8{ "src", "pkg" }) |name| {
                const path = try std.fs.path.join(self.allocator, &.{ self.options.work_directory, name });
                defer self.allocator.free(path);
                std.Io.Dir.cwd().deleteTree(self.io, path) catch {};
            }
        }

        return artifacts.toOwnedSlice(self.allocator);
    }

    fn validatePackageFunctions(self: *const PackageBuilder) !void {
        for (self.package_builds) |package_build| {
            if (package_build.has_invalid_package_assignment)
                return error.InvalidPackageFunctionVariable;
            if (package_build.is_split) {
                if (package_build.has_generic_package_function)
                    return error.ExtraSplitPackageFunction;
                if (!package_build.has_complete_split_functions or
                    !package_build.has_selected_package_function)
                    return error.MissingSplitPackageFunction;
                continue;
            }
            if (package_build.has_generic_package_function and
                package_build.has_selected_package_function)
                return error.ConflictingPackageFunctions;
            if (package_build.has_build_function and
                !package_build.has_generic_package_function and
                !package_build.has_selected_package_function)
                return error.MissingPackageFunction;
        }
    }

    fn prepareSources(self: *PackageBuilder, operation: *op_context.Operation) !void {
        try self.logPhase("sources");
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

        const srcdir = try std.fs.path.join(self.allocator, &.{ self.options.work_directory, "src" });
        defer self.allocator.free(srcdir);
        const source_staging = try std.fs.path.join(self.allocator, &.{ self.options.work_directory, ".sources.shelly-staging" });
        defer self.allocator.free(source_staging);
        const extraction_staging = try std.fs.path.join(self.allocator, &.{ self.options.work_directory, ".src.shelly-staging" });
        defer self.allocator.free(extraction_staging);

        std.Io.Dir.cwd().deleteTree(self.io, source_staging) catch {
            self.reportUnwritableBuildDirectory(source_staging);
            return error.BuildDirectoryNotWritable;
        };
        std.Io.Dir.cwd().deleteTree(self.io, extraction_staging) catch {
            self.reportUnwritableBuildDirectory(extraction_staging);
            return error.BuildDirectoryNotWritable;
        };
        std.Io.Dir.cwd().createDirPath(self.io, source_staging) catch {
            self.reportUnwritableBuildDirectory(source_staging);
            return error.BuildDirectoryNotWritable;
        };
        defer std.Io.Dir.cwd().deleteTree(self.io, source_staging) catch {};
        errdefer std.Io.Dir.cwd().deleteTree(self.io, extraction_staging) catch {};

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
            const destination = std.fs.path.join(self.allocator, &.{ source_staging, source.name }) catch |err| {
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
                .http => try self.acquireHttpSource(operation, source, destination, false),
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
                self.verifySourceChecksums(package_build, source.index, source.destination) catch |err| {
                    if (err != error.SourceChecksumMismatch or source.source.kind != .http) return err;
                    try self.acquireHttpSource(operation, source.source, source.destination, true);
                    try self.verifySourceChecksums(package_build, source.index, source.destination);
                };
            }
        }

        if (!self.options.skip_source_pgp_verification)
            try self.verifyPreparedSourceSignatures(operation, package_build, prepared, source_staging);

        // makepkg runs the optional verify() function in $startdir after
        // built-in integrity checks and before extracting any source. Expose
        // staged remote/renamed sources there through temporary symlinks;
        // existing direct local sources are already visible in $startdir.
        if (self.options.run_verify and !self.options.skip_source_pgp_verification) {
            const execution = package_build.execution orelse return error.MissingExecutionSteps;
            if (execution.verify_step) |step| {
                const links = try self.exposeSourcesForVerify(prepared);
                defer {
                    for (links) |path| {
                        std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
                        self.allocator.free(path);
                    }
                    self.allocator.free(links);
                }
                try self.runStep(
                    operation,
                    self.requested_names[0],
                    step.name,
                    execution.shared_prelude,
                    execution.shared_helpers,
                    step.body,
                    self.options.start_directory,
                );
                // Direct local sources are the real files in $startdir rather
                // than temporary links. Carry any intentional verify()
                // mutation forward into extraction, as makepkg does.
                for (prepared) |*source| if (source.source.kind == .local and
                    std.mem.eql(u8, source.source.location, source.source.name))
                {
                    try self.copyLocalSource(source.source.location, source.destination);
                };
            }
        }

        std.Io.Dir.cwd().createDirPath(self.io, extraction_staging) catch {
            self.reportUnwritableBuildDirectory(extraction_staging);
            return error.BuildDirectoryNotWritable;
        };
        for (prepared) |*source| {
            try operation.checkCancelled();
            const materialized = try std.fs.path.join(
                self.allocator,
                &.{ extraction_staging, source.source.name },
            );
            defer self.allocator.free(materialized);
            if (source.source.kind == .git) {
                try self.materializeGitSource(operation, source.source, source.destination, materialized);
            } else {
                try std.Io.Dir.copyFile(.cwd(), source.destination, .cwd(), materialized, self.io, .{});
                if (isExtractableArchive(source.source.name) and
                    !containsString(package_build.no_extract orelse &.{}, source.source.name))
                    try self.extractSourceArchive(operation, source.destination, extraction_staging);
            }
        }
        // Only a fully prepared staging tree is committed. Sources are
        // reproducible, so retaining a second backup tree adds state without
        // improving recovery.
        std.Io.Dir.cwd().deleteTree(self.io, srcdir) catch {
            self.reportUnwritableBuildDirectory(srcdir);
            return error.BuildDirectoryNotWritable;
        };
        std.Io.Dir.rename(.cwd(), extraction_staging, .cwd(), srcdir, self.io) catch {
            self.reportUnwritableBuildDirectory(srcdir);
            return error.BuildDirectoryNotWritable;
        };
    }

    fn copyLocalSource(self: *PackageBuilder, source_name: []const u8, destination: []const u8) !void {
        const normalized = try archive.normalizeEntryPath(self.allocator, source_name);
        defer self.allocator.free(normalized);
        const source_path = try std.fs.path.join(self.allocator, &.{ self.options.start_directory, normalized });
        defer self.allocator.free(source_path);
        const stat = try std.Io.Dir.cwd().statFile(self.io, source_path, .{ .follow_symlinks = false });
        if (stat.kind != .file) return error.InvalidLocalSource;
        try std.Io.Dir.copyFile(.cwd(), source_path, .cwd(), destination, self.io, .{});
    }

    fn exposeSourcesForVerify(self: *PackageBuilder, prepared: []const PreparedSource) ![][]u8 {
        var links: std.ArrayList([]u8) = .empty;
        errdefer {
            for (links.items) |path| {
                std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
                self.allocator.free(path);
            }
            links.deinit(self.allocator);
        }
        for (prepared) |*source| {
            const visible_path = try std.fs.path.join(
                self.allocator,
                &.{ self.options.start_directory, source.source.name },
            );
            errdefer self.allocator.free(visible_path);
            const exists = if (std.Io.Dir.cwd().statFile(
                self.io,
                visible_path,
                .{ .follow_symlinks = false },
            )) |_| true else |err| switch (err) {
                error.FileNotFound => false,
                else => return err,
            };
            if (exists) {
                // A direct local source already occupies its makepkg-visible
                // path. Never replace an unrelated user path for a renamed,
                // downloaded, or VCS source.
                if (source.source.kind == .local and
                    std.mem.eql(u8, source.source.location, source.source.name))
                {
                    self.allocator.free(visible_path);
                    continue;
                }
                return error.SourceVerificationViewConflict;
            }
            try std.Io.Dir.cwd().symLink(
                self.io,
                source.destination,
                visible_path,
                .{ .is_directory = source.source.kind == .git },
            );
            errdefer std.Io.Dir.cwd().deleteFile(self.io, visible_path) catch {};
            try links.append(self.allocator, visible_path);
        }
        return links.toOwnedSlice(self.allocator);
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

    fn acquireHttpSource(
        self: *PackageBuilder,
        operation: *op_context.Operation,
        source: ParsedSource,
        destination: []const u8,
        force_refresh: bool,
    ) !void {
        const cache_path = try std.fs.path.join(
            self.allocator,
            &.{ self.options.source_destination, source.name },
        );
        defer self.allocator.free(cache_path);
        if (force_refresh) std.Io.Dir.cwd().deleteFile(self.io, cache_path) catch {};
        const cached = std.Io.Dir.cwd().statFile(
            self.io,
            cache_path,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (cached) |stat| {
            if (stat.kind != .file) return error.InvalidSourceCacheEntry;
        } else {
            var random_suffix: [8]u8 = undefined;
            self.io.random(&random_suffix);
            const suffix = std.fmt.bytesToHex(random_suffix, .lower);
            const temporary_path = try std.fmt.allocPrint(
                self.allocator,
                "{s}.shelly-{s}.tmp",
                .{ cache_path, suffix },
            );
            defer self.allocator.free(temporary_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, temporary_path) catch {};
            try self.downloadSource(operation, source.location, temporary_path);
            std.Io.Dir.cwd().renamePreserve(temporary_path, std.Io.Dir.cwd(), cache_path, self.io) catch |err| switch (err) {
                error.PathAlreadyExists => std.Io.Dir.cwd().deleteFile(self.io, temporary_path) catch {},
                else => return err,
            };
        }
        std.Io.Dir.cwd().deleteFile(self.io, destination) catch {};
        try std.Io.Dir.copyFile(.cwd(), cache_path, .cwd(), destination, self.io, .{});
    }

    fn cloneGitSource(
        self: *PackageBuilder,
        operation: *op_context.Operation,
        source: ParsedSource,
        destination: []const u8,
    ) !void {
        const cache_path = try std.fs.path.join(
            self.allocator,
            &.{ self.options.source_destination, source.name },
        );
        defer self.allocator.free(cache_path);
        const cached = std.Io.Dir.cwd().statFile(
            self.io,
            cache_path,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (cached) |stat| {
            if (stat.kind != .directory) return error.InvalidSourceCacheEntry;
            try self.runSourceCommand(operation, &.{ "-C", cache_path, "remote", "set-url", "origin", source.location });
            try self.runSourceCommand(operation, &.{ "-C", cache_path, "remote", "update", "--prune" });
        } else {
            var random_suffix: [8]u8 = undefined;
            self.io.random(&random_suffix);
            const suffix = std.fmt.bytesToHex(random_suffix, .lower);
            const temporary_path = try std.fmt.allocPrint(
                self.allocator,
                "{s}.shelly-{s}.tmp",
                .{ cache_path, suffix },
            );
            defer self.allocator.free(temporary_path);
            errdefer std.Io.Dir.cwd().deleteTree(self.io, temporary_path) catch {};
            try self.runSourceCommand(operation, &.{ "clone", "--mirror", "--", source.location, temporary_path });
            std.Io.Dir.cwd().renamePreserve(temporary_path, std.Io.Dir.cwd(), cache_path, self.io) catch |err| switch (err) {
                error.PathAlreadyExists => std.Io.Dir.cwd().deleteTree(self.io, temporary_path) catch {},
                else => return err,
            };
        }
        try self.materializeGitSource(operation, source, cache_path, destination);
    }

    fn materializeGitSource(
        self: *PackageBuilder,
        operation: *op_context.Operation,
        source: ParsedSource,
        acquired_repository: []const u8,
        destination: []const u8,
    ) !void {
        try self.runSourceCommand(operation, &.{
            "clone",
            "--local",
            "--no-hardlinks",
            "--",
            acquired_repository,
            destination,
        });
        if (source.reference) |reference| switch (reference.kind) {
            .branch => try self.runSourceCommand(operation, &.{
                "-C",
                destination,
                "checkout",
                "--force",
                reference.value,
            }),
            .tag, .commit => try self.runSourceCommand(operation, &.{
                "-C",
                destination,
                "checkout",
                "--detach",
                reference.value,
            }),
        };
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
            .log = self.active_log,
        };
        const effective_options = try effectivePackageOptions(
            self.allocator,
            self.shellybuild_config.package.options,
            self.package_builds[0].options orelse &.{},
        );
        defer freeOwnedStrings(self.allocator, effective_options);
        const exit_code = try process_runner.runStreamingWithBuildEnvironmentOperation(
            self.allocator,
            self.io,
            self.environ,
            self.buildEnvironment(effective_options),
            command.items,
            self.options.source_destination,
            null,
            .{ .function = forwardStepLine, .data = &stream_context },
            operation,
        );
        if (self.active_log) |log| try log.ensureHealthy();
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
        const start_stat = try cwd.statFile(self.io, self.options.start_directory, .{});
        if (start_stat.kind != .directory) return error.InvalidStartDirectory;

        for ([_][]const u8{
            self.options.work_directory,
            self.options.package_destination,
            self.options.source_destination,
            self.options.log_destination,
        }) |root| {
            cwd.createDirPath(self.io, root) catch {
                self.reportUnwritableBuildDirectory(root);
                return error.BuildDirectoryNotWritable;
            };
            try self.validateWritableDirectory(root);
        }

        for ([_][]const u8{ "src", "pkg", ".src.shelly-staging" }) |name| {
            const path = try std.fs.path.join(self.allocator, &.{ self.options.work_directory, name });
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

    fn openBuildLog(self: *PackageBuilder) !BuildLog {
        const package_base = self.package_builds[0].variables.get("pkgbase") orelse
            self.package_builds[0].pkg_name orelse self.requested_names[0];
        const normalized = try archive.normalizeEntryPath(self.allocator, package_base);
        defer self.allocator.free(normalized);
        if (std.mem.indexOfScalar(u8, normalized, '/') != null) return error.InvalidPackageBase;
        var random_suffix: [8]u8 = undefined;
        self.io.random(&random_suffix);
        const suffix = std.fmt.bytesToHex(random_suffix, .lower);
        const timestamp = std.Io.Clock.real.now(self.io).toSeconds();
        const path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}-{d}-{s}.log",
            .{ self.options.log_destination, normalized, timestamp, suffix },
        );
        defer self.allocator.free(path);
        const file = try std.Io.Dir.cwd().createFile(self.io, path, .{ .exclusive = true });
        return .{ .file = file, .io = self.io };
    }

    fn logPhase(self: *PackageBuilder, name: []const u8) !void {
        if (self.active_log) |log| try log.writeRecord("phase", name);
    }

    fn runStep(
        self: *PackageBuilder,
        operation: *op_context.Operation,
        package_name: []const u8,
        step_name: []const u8,
        execution_prelude: []const u8,
        helper_definitions: []const u8,
        body: []const u8,
        working_directory: ?[]const u8,
    ) !void {
        try self.logPhase(step_name);
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
            "{s}\n{s}\n{s}\ndeclare -- startdir=\"$4\"\ndeclare -- srcdir=\"$5\"\n{s}\n{s}\n{s}\ndeclare -- pkgver=\"$1\"\n__shelly_step() {{\n{s}\n}}\n{s}",
            .{
                if (package_step) virtualMetadataShellPrelude else "",
                if (package_step) package_metadata.shell_capture_prelude else "",
                execution_prelude,
                if (package_step) "declare -- pkgdir=\"$6\"" else "",
                messagingShellPrelude,
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
            &.{ self.options.work_directory, "src" },
        );
        defer self.allocator.free(srcdir);

        const pkgver_result_path = try std.fs.path.join(
            self.allocator,
            &.{ self.options.work_directory, ".shelly-pkgver" },
        );
        defer self.allocator.free(pkgver_result_path);
        const runtime_pkgdir = try std.fs.path.join(
            self.allocator,
            &.{ self.options.work_directory, "pkg", package_name },
        );
        defer self.allocator.free(runtime_pkgdir);
        const metadata_result_path = try std.fs.path.join(
            self.allocator,
            &.{ self.options.work_directory, ".shelly-package-metadata" },
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
        const runtime_startdir = self.options.start_directory;
        const runtime_working_directory = working_directory orelse srcdir;

        var stream_context: StepStreamContext = .{
            .operation = operation,
            .package_name = package_name,
            .log = self.active_log,
        };
        const effective_options = try effectivePackageOptions(
            self.allocator,
            self.shellybuild_config.package.options,
            self.package_builds[0].options orelse &.{},
        );
        defer freeOwnedStrings(self.allocator, effective_options);
        const exit_code = try process_runner.runStreamingWithBuildEnvironmentOperation(
            self.allocator,
            self.io,
            self.environ,
            self.buildEnvironment(effective_options),
            &.{ "/bin/bash", "-e", "-c", command_body, "shelly-step", current_pkgver, pkgver_result_path, metadata_result_path, runtime_startdir, srcdir, runtime_pkgdir },
            runtime_working_directory,
            null,
            .{ .function = forwardStepLine, .data = &stream_context },
            operation,
        );
        if (self.active_log) |log| try log.ensureHealthy();
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

    fn buildEnvironment(
        self: *const PackageBuilder,
        effective_options: []const []u8,
    ) process_runner.BuildEnvironment {
        const buildflags = !optionExplicitlyDisabled(effective_options, "buildflags");
        const makeflags = !optionExplicitlyDisabled(effective_options, "makeflags");
        const lto = buildflags and !optionExplicitlyDisabled(effective_options, "lto");
        return .{
            .cppflags = if (buildflags) self.shellybuild_config.build.cppflags else null,
            .cflags = if (buildflags) self.shellybuild_config.build.cflags else null,
            .cxxflags = if (buildflags) self.shellybuild_config.build.cxxflags else null,
            .ldflags = if (buildflags) self.shellybuild_config.build.ldflags else null,
            .ltoflags = if (lto) self.shellybuild_config.build.ltoflags else null,
            .makeflags = if (makeflags) self.shellybuild_config.build.makeflags else null,
            .chost = self.shellybuild_config.build.chost,
            .distcc_hosts = if (self.shellybuild_config.build.distcc)
                self.shellybuild_config.build.distcc_hosts
            else
                null,
            .ccache = self.shellybuild_config.build.ccache,
            .distcc = self.shellybuild_config.build.distcc,
        };
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

        const entries = try package_metadata.decode(self.allocator, encoded);
        defer package_metadata.deinitEntries(self.allocator, entries);
        if (entries.len != package_metadata.captured_field_count)
            return error.InvalidPackageMetadata;

        // Base values are authoritative first. Architecture-specific values
        // are appended in a second pass, matching makepkg's merge_arch_attrs.
        for (entries) |entry| {
            if (package_metadata.architectureBase(entry.name, self.shellybuild_config.build.carch) != null)
                continue;
            try self.applyPackageMetadataEntry(package_build, entry, false);
        }
        for (entries) |entry| {
            const base = package_metadata.architectureBase(entry.name, self.shellybuild_config.build.carch) orelse
                continue;
            var effective = entry;
            effective.name = base;
            try self.applyPackageMetadataEntry(package_build, effective, true);
        }
    }

    fn applyPackageMetadataEntry(
        self: *PackageBuilder,
        package_build: *PackageBuild,
        entry: package_metadata.Entry,
        append: bool,
    ) !void {
        if (package_metadata.isScalarField(entry.name)) {
            if (append) return error.InvalidPackageMetadata;
            const value = switch (entry.value) {
                .scalar => |scalar| scalar,
                .array => return error.InvalidPackageMetadata,
            };
            if (std.mem.eql(u8, entry.name, "pkgdesc"))
                try replaceOptionalString(self.allocator, &package_build.pkg_desc, value)
            else if (std.mem.eql(u8, entry.name, "url"))
                try replaceOptionalString(self.allocator, &package_build.url, value)
            else if (std.mem.eql(u8, entry.name, "install"))
                try replaceOptionalFileName(self.allocator, &package_build.install_file, value)
            else if (std.mem.eql(u8, entry.name, "changelog"))
                try replaceOptionalFileName(self.allocator, &package_build.changelog_file, value)
            else
                return error.InvalidPackageMetadata;
            return;
        }

        if (!package_metadata.isArrayField(entry.name)) return error.InvalidPackageMetadata;
        const values = switch (entry.value) {
            .array => |array| array,
            .scalar => return error.InvalidPackageMetadata,
        };
        if (std.mem.eql(u8, entry.name, "license"))
            try updateOptionalStrings(self.allocator, &package_build.license, values, append)
        else if (std.mem.eql(u8, entry.name, "groups"))
            try updateOptionalStrings(self.allocator, &package_build.groups, values, append)
        else if (std.mem.eql(u8, entry.name, "arch") and !append and values.len == 0)
            return
        else if (std.mem.eql(u8, entry.name, "arch"))
            try updateOptionalStrings(self.allocator, &package_build.arch, values, append)
        else if (std.mem.eql(u8, entry.name, "depends")) {
            try updateOptionalStrings(self.allocator, &package_build.depends, values, append);
            if (package_build.parsed_depends) |dependencies| {
                for (dependencies) |dependency| dependency.deinit(self.allocator);
                self.allocator.free(dependencies);
            }
            package_build.parsed_depends = null;
        } else if (std.mem.eql(u8, entry.name, "optdepends"))
            try updateOptionalStrings(self.allocator, &package_build.opt_depends, values, append)
        else if (std.mem.eql(u8, entry.name, "provides"))
            try updateOptionalStrings(self.allocator, &package_build.provides, values, append)
        else if (std.mem.eql(u8, entry.name, "conflicts"))
            try updateOptionalStrings(self.allocator, &package_build.conflicts, values, append)
        else if (std.mem.eql(u8, entry.name, "replaces"))
            try updateOptionalStrings(self.allocator, &package_build.replaces, values, append)
        else if (std.mem.eql(u8, entry.name, "backup"))
            try updateOptionalStrings(self.allocator, &package_build.backup, values, append)
        else if (std.mem.eql(u8, entry.name, "options"))
            try updateOptionalStrings(self.allocator, &package_build.options, values, append)
        else
            return error.InvalidPackageMetadata;
    }

    fn preparePackageDirectory(self: *PackageBuilder, package_build: *const PackageBuild) !void {
        const package_name = package_build.pkg_name orelse return error.MissingPackageName;
        const pkgdir = try std.fs.path.join(
            self.allocator,
            &.{ self.options.work_directory, "pkg", package_name },
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
            self.shellybuild_config.package.options,
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
            const flags = switch (kind orelse continue) {
                .binary => self.shellybuild_config.package.strip_binaries,
                .shared => self.shellybuild_config.package.strip_shared,
                .static => self.shellybuild_config.package.strip_static,
            };
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
            &.{ self.options.work_directory, "pkg", package_name },
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
        if (package_build.changelog_file) |changelog_file| {
            const reviewed_file = self.findReviewedFile(changelog_file) orelse return error.MissingChangelogFile;
            try writeMetadataFile(pkgdir_handle, self.io, ".CHANGELOG", reviewed_file.contents);
        } else {
            try deleteFileIgnoreMissing(pkgdir_handle, self.io, ".CHANGELOG");
        }

        const mtree_path = try std.fs.path.join(self.allocator, &.{ pkgdir, ".MTREE" });
        defer self.allocator.free(mtree_path);
        const virtual_metadata: archive.VirtualMetadata = .{};
        try archive.writeMtreeWithMetadata(self.allocator, self.io, pkgdir, mtree_path, virtual_metadata);
        var mtree_file = try pkgdir_handle.openFile(self.io, ".MTREE", .{});
        defer mtree_file.close(self.io);
        try mtree_file.setPermissions(self.io, .fromMode(0o644));

        try std.Io.Dir.cwd().createDirPath(self.io, self.options.package_destination);
        const file_name = try std.fmt.allocPrint(
            self.allocator,
            "{s}-{s}-{s}{s}",
            .{ package_name, full_version, package_arch, self.shellybuild_config.package.extension },
        );
        defer self.allocator.free(file_name);
        const output_path = try std.fs.path.joinZ(
            self.allocator,
            &.{ self.options.package_destination, file_name },
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
        var random_suffix: [8]u8 = undefined;
        self.io.random(&random_suffix);
        const suffix = std.fmt.bytesToHex(random_suffix, .lower);
        const temporary_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/.shelly-{s}-{s}",
            .{ self.options.package_destination, suffix, file_name },
        );
        defer self.allocator.free(temporary_path);
        errdefer std.Io.Dir.cwd().deleteFile(self.io, temporary_path) catch {};

        {
            var writer = try archive.Writer.initWithMetadata(self.allocator, self.io, temporary_path, virtual_metadata);
            defer writer.deinit();
            try writer.addDirectory(pkgdir);
            try writer.finish();
        }

        var temporary_signature_path: ?[]u8 = null;
        defer if (temporary_signature_path) |path| self.allocator.free(path);
        errdefer if (temporary_signature_path) |path| {
            std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
        };
        if (self.options.sign) {
            try self.logPhase("signing");
            temporary_signature_path = try std.fmt.allocPrint(
                self.allocator,
                "{s}.sig",
                .{temporary_path},
            );
            try self.signPackageArchive(temporary_path, temporary_signature_path.?);
        }

        try std.Io.Dir.cwd().rename(temporary_path, std.Io.Dir.cwd(), output_path, self.io);
        errdefer if (self.options.sign) {
            std.Io.Dir.cwd().deleteFile(self.io, output_path) catch {};
        };
        if (self.options.sign) {
            const output_signature_path = try std.fmt.allocPrint(
                self.allocator,
                "{s}.sig",
                .{output_path},
            );
            defer self.allocator.free(output_signature_path);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, output_signature_path) catch {};
            try std.Io.Dir.cwd().rename(
                temporary_signature_path.?,
                std.Io.Dir.cwd(),
                output_signature_path,
                self.io,
            );
        }

        const owned_name = try self.allocator.dupe(u8, package_name);
        errdefer self.allocator.free(owned_name);
        return .{ .path = output_path, .package_name = owned_name };
    }

    fn signPackageArchive(
        self: *PackageBuilder,
        payload_path: []const u8,
        signature_path: []const u8,
    ) !void {
        const signer = package_signer.Signer{
            .allocator = self.allocator,
            .io = self.io,
            .environ = self.environ,
            .gnupg_home = self.options.sign_gnupg_home,
        };
        try signer.signDetached(payload_path, signature_path, self.options.sign_key);
    }

    /// Removes a published archive together with its detached signature, if
    /// one exists, so rollbacks never leave orphaned signature files.
    fn removePublishedArtifact(self: *PackageBuilder, path: []const u8) void {
        std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
        const signature_path = std.fmt.allocPrint(self.allocator, "{s}.sig", .{path}) catch return;
        defer self.allocator.free(signature_path);
        std.Io.Dir.cwd().deleteFile(self.io, signature_path) catch {};
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

    fn findReviewedFile(
        self: *const PackageBuilder,
        file_name: []const u8,
    ) ?*const pkgbuild_review.ReviewedFile {
        for (self.options.reviewed_files) |*file| {
            if (std.mem.eql(u8, file.name, file_name)) return file;
        }
        return null;
    }

    fn reviewedFilesMatch(
        self: *const PackageBuilder,
        current_files: []const pkgbuild_review.ReviewedFile,
    ) bool {
        if (self.options.reviewed_files.len != current_files.len) return false;
        for (current_files) |current| {
            const reviewed = self.findReviewedFile(current.name) orelse return false;
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
        return self.shellybuild_config.build.carch;
    }

    fn packageSupportsArchitecture(
        self: *const PackageBuilder,
        package_build: *const PackageBuild,
    ) bool {
        const architectures = package_build.arch orelse return true;
        if (architectures.len == 0) return true;
        for (architectures) |architecture| {
            if (std.mem.eql(u8, architecture, "any") or
                std.mem.eql(u8, architecture, self.shellybuild_config.build.carch)) return true;
        }
        return false;
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
        try writeKeyValue(writer, "xdata", if (package_build.is_split) "pkgtype=split" else "pkgtype=pkg");
        try writeKeyValues(writer, "xdata", package_build.xdata);
        try writeKeyValue(writer, "pkgver", full_version);
        if (package_build.pkg_desc) |value| try writeKeyValue(writer, "pkgdesc", value);
        if (package_build.url) |value| try writeKeyValue(writer, "url", value);
        try writer.print("builddate = {d}\n", .{build_date});
        try writeKeyValue(writer, "packager", self.shellybuild_config.package.packager);
        try writer.print("size = {d}\n", .{payload_size});
        try writeKeyValue(writer, "arch", package_arch);
        try writeKeyValues(writer, "license", package_build.license);
        try writeKeyValues(writer, "replaces", package_build.replaces);
        try writeKeyValues(writer, "group", package_build.groups);
        try writeKeyValues(writer, "conflict", package_build.conflicts);
        try writeKeyValues(writer, "provides", package_build.provides);
        try writeKeyValues(writer, "backup", package_build.backup);
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
        try writeKeyValue(writer, "packager", self.shellybuild_config.package.packager);
        try writer.print("builddate = {d}\n", .{build_date});
        try writeKeyValue(writer, "builddir", self.options.work_directory);
        try writeKeyValue(
            writer,
            "startdir",
            if (self.options.pkgbuild_path) |path|
                std.fs.path.dirname(path) orelse self.options.start_directory
            else
                self.options.start_directory,
        );
        try writeKeyValue(writer, "buildtool", "shelly");
        try writeKeyValue(writer, "buildtoolver", package_options.version);

        try writeKeyValue(writer, "buildenv", if (self.options.run_check) "check" else "!check");
        try writeKeyValue(writer, "buildenv", if (self.shellybuild_config.build.ccache) "ccache" else "!ccache");
        try writeKeyValue(writer, "buildenv", if (self.shellybuild_config.build.distcc) "distcc" else "!distcc");

        const effective_options = try effectivePackageOptions(
            self.allocator,
            self.shellybuild_config.package.options,
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

fn replaceOptionalString(
    allocator: std.mem.Allocator,
    destination: *?[]const u8,
    value: []const u8,
) !void {
    const owned = try allocator.dupe(u8, value);
    if (destination.*) |old| allocator.free(old);
    destination.* = owned;
}

fn replaceOptionalFileName(
    allocator: std.mem.Allocator,
    destination: *?[]const u8,
    value: []const u8,
) !void {
    if (value.len == 0) {
        if (destination.*) |old| allocator.free(old);
        destination.* = null;
        return;
    }
    try replaceOptionalString(allocator, destination, value);
}

fn reviewedAuxiliarySelectionMatches(
    approved: ?[]const u8,
    runtime: ?[]const u8,
) bool {
    const selected = runtime orelse return true;
    const expected = approved orelse return false;
    return std.mem.eql(u8, expected, selected);
}

fn updateOptionalStrings(
    allocator: std.mem.Allocator,
    destination: *?[][]const u8,
    values: []const []const u8,
    append: bool,
) !void {
    const old = if (append) destination.* orelse &.{} else &.{};
    const combined = try allocator.alloc([]const u8, old.len + values.len);
    var populated: usize = 0;
    errdefer {
        for (combined[0..populated]) |value| allocator.free(value);
        allocator.free(combined);
    }
    for (old) |value| {
        combined[populated] = try allocator.dupe(u8, value);
        populated += 1;
    }
    for (values) |value| {
        combined[populated] = try allocator.dupe(u8, value);
        populated += 1;
    }
    if (destination.*) |previous| {
        for (previous) |value| allocator.free(value);
        allocator.free(previous);
    }
    destination.* = combined;
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

fn duplicateOwnedStrings(allocator: std.mem.Allocator, values: []const []const u8) ![][]u8 {
    const duplicated = try allocator.alloc([]u8, values.len);
    var count: usize = 0;
    errdefer {
        for (duplicated[0..count]) |value| allocator.free(value);
        allocator.free(duplicated);
    }
    for (values, duplicated) |value, *destination| {
        destination.* = try allocator.dupe(u8, value);
        count += 1;
    }
    return duplicated;
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

fn optionExplicitlyDisabled(options: []const []u8, name: []const u8) bool {
    for (options) |option| {
        if (std.mem.eql(u8, optionName(option), name))
            return std.mem.startsWith(u8, option, "!");
    }
    return false;
}

fn effectivePackageOptions(
    allocator: std.mem.Allocator,
    configured: []const []const u8,
    overrides: []const []const u8,
) ![][]u8 {
    var options = try duplicateOwnedStrings(allocator, configured);
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

/// makepkg messaging helpers (util/message.sh). PKGBUILDs call these from any
/// lifecycle function; step output is piped, so colors stay off like makepkg
/// does for non-terminal output. Defined before PKGBUILD helpers so a
/// PKGBUILD that ships its own definitions keeps overriding them.
const messagingShellPrelude =
    \\msg() {
    \\  local mesg=$1; shift
    \\  printf "==> ${mesg}\n" "$@"
    \\}
    \\msg2() {
    \\  local mesg=$1; shift
    \\  printf "  -> ${mesg}\n" "$@"
    \\}
    \\plain() {
    \\  local mesg=$1; shift
    \\  printf "    ${mesg}\n" "$@"
    \\}
    \\plainerr() {
    \\  plain "$@" >&2
    \\}
    \\warning() {
    \\  local mesg=$1; shift
    \\  printf "==> WARNING: ${mesg}\n" "$@" >&2
    \\}
    \\error() {
    \\  local mesg=$1; shift
    \\  printf "==> ERROR: ${mesg}\n" "$@" >&2
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
        const has_git_prefix = std.ascii.startsWithIgnoreCase(git_location, "git+");
        const is_git = has_git_prefix or std.ascii.startsWithIgnoreCase(git_location, "git://");
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

        const effective_location = if (has_git_prefix)
            git_location["git+".len..]
        else if (is_git)
            git_location
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
    log: ?*BuildLog,
};

fn forwardStepLine(data: ?*anyopaque, stream: process_runner.StreamKind, line: []const u8) void {
    const context: *StepStreamContext = @ptrCast(@alignCast(data.?));
    if (context.log) |log| log.writeStream(stream, line);
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

test "bare Git protocol source parser preserves location and supports metadata" {
    var plain = try ParsedSource.parse(std.testing.allocator, "git://example.invalid/demo.git");
    defer plain.deinit(std.testing.allocator);
    try std.testing.expectEqual(SourceKind.git, plain.kind);
    try std.testing.expectEqualStrings("git://example.invalid/demo.git", plain.location);
    try std.testing.expectEqualStrings("demo", plain.name);
    try std.testing.expectEqual(@as(?GitReference, null), plain.reference);
    try std.testing.expect(!plain.signed);

    var annotated = try ParsedSource.parse(
        std.testing.allocator,
        "renamed::git://example.invalid/demo.git?signed#commit=0123456789abcdef",
    );
    defer annotated.deinit(std.testing.allocator);
    try std.testing.expectEqual(SourceKind.git, annotated.kind);
    try std.testing.expectEqualStrings("git://example.invalid/demo.git", annotated.location);
    try std.testing.expectEqualStrings("renamed", annotated.name);
    try std.testing.expectEqual(GitReferenceKind.commit, annotated.reference.?.kind);
    try std.testing.expectEqualStrings("0123456789abcdef", annotated.reference.?.value);
    try std.testing.expect(annotated.signed);
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

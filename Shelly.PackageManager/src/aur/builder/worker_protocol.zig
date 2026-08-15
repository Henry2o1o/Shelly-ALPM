const std = @import("std");

pub const protocol_version: u8 = 1;
pub const result_prefix = "SHELLY_BUILDER_RESULT:";

pub const RequestOptions = struct {
    run_check: bool,
    overwrite: bool,
    clean_after_success: bool,
    skip_source_pgp_verification: bool,
    sources_prepared: bool,
};

pub const MakepkgConfiguration = struct {
    package_extension: []const u8,
    package_carch: []const u8,
    packager: []const u8,
    build_environment: []const u8,
    options: []const u8,
};

/// Data-only request passed as one argv value. It deliberately contains no
/// shell source: after de-escalation the worker reads PKGBUILD once, parses
/// that exact buffer, and verifies it plus all reviewed local/install files.
pub const Request = struct {
    version: u8 = protocol_version,
    build_directory: []const u8,
    requested_names: []const []const u8,
    options: RequestOptions,
    makepkg: MakepkgConfiguration,
    reviewed_pkgbuild_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,
};

pub const ResponseArtifact = struct {
    path: []const u8,
    package_name: []const u8,
};

pub const FailureCode = enum {
    out_of_memory,
    cancelled,
    already_built,
    builder_must_not_run_as_root,
    builder_deescalation_failed,
    builder_worker_unavailable,
    unreviewed_builder_request,
    reviewed_pkgbuild_changed,
    build_directory_not_writable,
    privileged_package_operation_unsupported,
    missing_source_checksums,
    source_checksum_count_mismatch,
    invalid_source_checksum,
    source_checksum_mismatch,
    unsupported_vcs_checksum,
    missing_execution_steps,
    missing_package_step,
    selected_package_not_found,
    step_failed,
    build_failed,

    pub fn fromError(err: anyerror) FailureCode {
        return switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.Cancelled => .cancelled,
            error.AlreadyBuilt => .already_built,
            error.BuilderMustNotRunAsRoot => .builder_must_not_run_as_root,
            error.BuilderDeescalationFailed, error.InvokingUserUnavailable => .builder_deescalation_failed,
            error.BuilderWorkerUnavailable => .builder_worker_unavailable,
            error.UnreviewedBuilderRequest => .unreviewed_builder_request,
            error.ReviewedPkgbuildChanged => .reviewed_pkgbuild_changed,
            error.BuildDirectoryNotWritable => .build_directory_not_writable,
            error.PrivilegedPackageOperationUnsupported => .privileged_package_operation_unsupported,
            error.MissingSourceChecksums => .missing_source_checksums,
            error.SourceChecksumCountMismatch => .source_checksum_count_mismatch,
            error.InvalidSourceChecksum => .invalid_source_checksum,
            error.SourceChecksumMismatch => .source_checksum_mismatch,
            error.UnsupportedVcsChecksum => .unsupported_vcs_checksum,
            error.MissingExecutionSteps => .missing_execution_steps,
            error.MissingPackageStep => .missing_package_step,
            error.SelectedPackageNotFound => .selected_package_not_found,
            error.StepFailed => .step_failed,
            else => .build_failed,
        };
    }

    pub fn toError(self: FailureCode) anyerror {
        return switch (self) {
            .out_of_memory => error.OutOfMemory,
            .cancelled => error.Cancelled,
            .already_built => error.AlreadyBuilt,
            .builder_must_not_run_as_root => error.BuilderMustNotRunAsRoot,
            .builder_deescalation_failed => error.BuilderDeescalationFailed,
            .builder_worker_unavailable => error.BuilderWorkerUnavailable,
            .unreviewed_builder_request => error.UnreviewedBuilderRequest,
            .reviewed_pkgbuild_changed => error.ReviewedPkgbuildChanged,
            .build_directory_not_writable => error.BuildDirectoryNotWritable,
            .privileged_package_operation_unsupported => error.PrivilegedPackageOperationUnsupported,
            .missing_source_checksums => error.MissingSourceChecksums,
            .source_checksum_count_mismatch => error.SourceChecksumCountMismatch,
            .invalid_source_checksum => error.InvalidSourceChecksum,
            .source_checksum_mismatch => error.SourceChecksumMismatch,
            .unsupported_vcs_checksum => error.UnsupportedVcsChecksum,
            .missing_execution_steps => error.MissingExecutionSteps,
            .missing_package_step => error.MissingPackageStep,
            .selected_package_not_found => error.SelectedPackageNotFound,
            .step_failed => error.StepFailed,
            .build_failed => error.BuildFailed,
        };
    }
};

pub const Failure = struct {
    code: FailureCode,
    package_name: ?[]const u8 = null,
    step_name: ?[]const u8 = null,
};

pub const Response = struct {
    version: u8 = protocol_version,
    failure: ?Failure = null,
    artifacts: []const ResponseArtifact = &.{},
};

test "worker protocol preserves reviewed build request" {
    const request: Request = .{
        .build_directory = "/cache/demo",
        .requested_names = &.{"demo"},
        .options = .{
            .run_check = true,
            .overwrite = false,
            .clean_after_success = true,
            .skip_source_pgp_verification = false,
            .sources_prepared = false,
        },
        .makepkg = .{
            .package_extension = ".pkg.tar.zst",
            .package_carch = "x86_64",
            .packager = "Shelly Builder",
            .build_environment = "(check)",
            .options = "(strip)",
        },
        .reviewed_pkgbuild_digest = [_]u8{0x5a} ** std.crypto.hash.sha2.Sha256.digest_length,
    };
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, request, .{});
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(Request, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(protocol_version, parsed.value.version);
    try std.testing.expectEqualStrings("demo", parsed.value.requested_names[0]);
    try std.testing.expectEqualSlices(u8, &request.reviewed_pkgbuild_digest, &parsed.value.reviewed_pkgbuild_digest);
}

test "worker protocol uses typed failure codes" {
    const response: Response = .{ .failure = .{
        .code = .step_failed,
        .package_name = "demo",
        .step_name = "package_demo",
    } };
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, response, .{});
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(Response, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(FailureCode.step_failed, parsed.value.failure.?.code);
    try std.testing.expectEqualStrings("package_demo", parsed.value.failure.?.step_name.?);
    try std.testing.expectEqual(error.StepFailed, parsed.value.failure.?.code.toError());
}

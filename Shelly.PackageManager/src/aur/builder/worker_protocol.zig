const std = @import("std");
const archive = @import("archive");

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
    virtual_ownership_overrides: []const archive.OwnershipOverride = &.{},
};

pub const ResponseArtifact = struct {
    path: []const u8,
    package_name: []const u8,
};

pub const Response = struct {
    version: u8 = protocol_version,
    error_name: ?[]const u8 = null,
    artifacts: []const ResponseArtifact = &.{},
};

test "worker protocol preserves reviewed request and virtual ownership" {
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
        .virtual_ownership_overrides = &.{.{
            .path = "usr/share/demo",
            .ownership = .{ .uid = 12, .gid = 34 },
        }},
    };
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, request, .{});
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(Request, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(protocol_version, parsed.value.version);
    try std.testing.expectEqualStrings("demo", parsed.value.requested_names[0]);
    try std.testing.expectEqual(@as(i64, 12), parsed.value.virtual_ownership_overrides[0].ownership.uid);
    try std.testing.expectEqualSlices(u8, &request.reviewed_pkgbuild_digest, &parsed.value.reviewed_pkgbuild_digest);
}

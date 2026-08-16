const std = @import("std");
const validation = @import("../../pkgbuild/shared_validtor.zig");
const pkgbuild_parser = @import("../../pkgbuild/pkgbuild_parser.zig");
const homograph_validator = @import("../../pkgbuild/homograph_validator.zig");
const post_install_validator = @import("../../pkgbuild/post_install_validator.zig");
const local_source_validator = @import("../../pkgbuild/local_source_validator.zig");

pub const ValidationFinding = validation.ValidationFinding;

pub const PkgbuildValidation = struct {
    post_install: validation.ValidationResult,
    homograph: validation.ValidationResult,
    local_source: validation.ValidationResult,

    pub fn deinit(self: *PkgbuildValidation, allocator: std.mem.Allocator) void {
        self.post_install.deinit(allocator);
        self.homograph.deinit(allocator);
        self.local_source.deinit(allocator);
        self.* = undefined;
    }

    pub fn hasFindings(self: *const PkgbuildValidation) bool {
        return self.post_install.has_findings or self.homograph.has_findings or self.local_source.has_findings;
    }

    pub fn flatten(self: *const PkgbuildValidation, allocator: std.mem.Allocator) ![]ValidationFinding {
        const post = self.post_install.findings.items;
        const homograph = self.homograph.findings.items;
        const local_source = self.local_source.findings.items;
        const findings = try allocator.alloc(ValidationFinding, post.len + homograph.len + local_source.len);
        @memcpy(findings[0..post.len], post);
        @memcpy(findings[post.len .. post.len + homograph.len], homograph);
        @memcpy(findings[post.len + homograph.len ..], local_source);
        return findings;
    }
};

pub fn validatePkgbuild(
    allocator: std.mem.Allocator,
    io: std.Io,
    content: []const u8,
    base_directory: ?[]const u8,
) !PkgbuildValidation {
    const parser = pkgbuild_parser.PkgbuildParser{ .allocator = allocator, .io = io };
    var info = try parser.parser_content(content, base_directory);
    defer info.deinit(allocator);

    return validatePkgbuildInfo(allocator, io, &info, base_directory, content);
}

pub fn validatePkgbuildInfo(
    allocator: std.mem.Allocator,
    io: std.Io,
    info: *const pkgbuild_parser.Pkgbuild,
    base_directory: ?[]const u8,
    content: ?[]const u8,
) !PkgbuildValidation {
    var post_install = try (post_install_validator.PostInstallValidator{ .allocator = allocator }).validateWithContent(info.*, content);
    errdefer post_install.deinit(allocator);
    var homograph = try (homograph_validator.HomographValidator{ .allocator = allocator }).validate(info.*);
    errdefer homograph.deinit(allocator);
    return .{
        .post_install = post_install,
        .homograph = homograph,
        .local_source = try (local_source_validator.LocalSourceValidator{ .allocator = allocator, .io = io }).validate(info.*, base_directory),
    };
}

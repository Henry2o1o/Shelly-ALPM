const std = @import("std");
const validation = @import("../../pkgbuild/shared_validtor.zig");

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

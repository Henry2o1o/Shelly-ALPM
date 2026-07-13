const std = @import("std");
const pkgbuild = @import("pkgbuild_parser.zig");
const shared_validator = @import("shared_validator.zig");

pub const HomographValidator = struct {
    allocator: std.mem.Allocator,

    pub fn validate(self: HomographValidator, pkg_build: pkgbuild.pkgbuild_info) shared_validator.ValidationResult {
        _ = self;
        _ = pkg_build;
    }

    pub fn validate_field(value: ?[]const u8, field: []const u8) bool {
        _ = value;
        _ = field;
    }
};

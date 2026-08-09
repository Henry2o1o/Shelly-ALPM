const std = @import("std");
const MakePkgConfiguration = @import("../makepackage.zig").MakePackageConfiguration;
const PackageBuild = @import("../../pkgbuild/pkgbuild_parser.zig").Pkgbuild;

pub const Builder = struct {
    allocator: std.mem.Allocator,
    package_build: PackageBuild,

    pub fn init(allocator: std.mem.Allocator, package_build: PackageBuild) !*Builder {
        const self = allocator.create(Builder) catch |err| {
            return err;
        };

        self.* = Builder{
            .allocator = allocator,
            .package_build = package_build,
        };

        return self;
    }

    pub fn deint(self: *Builder) !void {
        self.package_build.deinit(self.allocator);
        self.*;
    }
};

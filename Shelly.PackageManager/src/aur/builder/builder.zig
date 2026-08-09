const std = @import("std");
const MakePkgConfiguration = @import("../makepackage.zig").MakePackageConfiguration;
const PackageBuild = @import("../../pkgbuild/pkgbuild_parser.zig").Pkgbuild;
const events = @import("../events.zig");
const op_context = @import("../../shared/operation_context.zig");

/// Builder expects to be passed all items and should not construct
/// these items as it's context only exists to serve inside manager
pub const PackageBuilder = struct {
    allocator: std.mem.Allocator,
    package_build: PackageBuild,
    dispatcher: events.Dispatcher,
    operation_context: op_context.OperationContext,
    makepkg_config: MakePkgConfiguration,

    pub fn init(
        allocator: std.mem.Allocator,
        package_build: PackageBuild,
        dispatcher: events.Dispatcher,
        operation_context: op_context.OperationContext,
        makepackage_configuration: MakePkgConfiguration,
    ) !*PackageBuilder {
        const self = allocator.create(PackageBuilder) catch |err| {
            return err;
        };

        self.* = PackageBuilder{
            .allocator = allocator,
            .package_build = package_build,
            .dispatcher = dispatcher,
            .operation_context = operation_context,
            .makepkg_config = makepackage_configuration,
        };

        return self;
    }

    pub fn deint(self: *PackageBuilder) !void {
        self.package_build.deinit(self.allocator);
        self.dispatcher.deinit();
        self.*;
    }

    pub fn BuildPackage(self: *PackageBuilder) !void {
        const buildPath = self.makepkg_config.build_directory;
        for (self.package_build.execution_steps.?) |step| {
            const child: std.process.Child = .init{&.{ "/bin/sh", "-c", step.body }};
            _ = buildPath;
            _ = child;
        }
    }
};

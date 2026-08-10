const std = @import("std");
const MakePkgConfiguration = @import("../makepackage.zig").MakePackageConfiguration;
const PackageBuild = @import("../../pkgbuild/pkgbuild_parser.zig").Pkgbuild;
const events = @import("../events.zig");
const op_context = @import("../../shared/operation_context.zig");

pub const BuildArtifact = struct {
    path: [:0]u8,
    package_name: []const u8,

    pub fn deinit(self: BuildArtifact, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.package_name);
    }
};

/// Builder expects to be passed all items and should not construct
/// these items as it's context only exists to serve inside manager
pub const PackageBuilder = struct {
    allocator: std.mem.Allocator,
    package_build: PackageBuild,
    dispatcher: events.Dispatcher,
    operation_context: op_context.OperationContext,
    makepkg_config: MakePkgConfiguration,
    io: std.Io,

    pub fn init(
        allocator: std.mem.Allocator,
        package_build: PackageBuild,
        dispatcher: events.Dispatcher,
        operation_context: op_context.OperationContext,
        makepackage_configuration: MakePkgConfiguration,
        io: std.Io,
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
            .io = io,
        };

        return self;
    }

    pub fn deint(self: *PackageBuilder) !void {
        self.package_build.deinit(self.allocator);
        self.dispatcher.deinit();
        self.*;
    }

    pub fn BuildPackage(self: *PackageBuilder) !BuildArtifact {
        var operation = self.operation_context.begin(op_context.OperationDescriptor{ .backend = .aur, .kind = .build, .subject = "Package Build" });
        defer operation.finish(.cancelled);
        for (self.package_build.execution_steps.?) |step| {
            var child = try std.process.spawn(self.io, .{ .argv = &.{ "/bin/sh", "-c", step.expanded_body }, .stdout = .inherit, .stderr = .inherit, .cwd = self.makepkg_config.build_directory });
            const term = try child.wait(self.io);
            switch (term) {
                .exited => |code| {
                    if (code != 0) {
                        self.dispatcher.raiseError(.{
                            .message = code,
                        });
                        operation.finish(.failed);
                        return;
                    }
                    self.dispatcher.raiseInformational(.{
                        .message = "Finished step",
                    });
                },
                .signal => {
                    self.dispatcher.raiseError(.{
                        .message = "Failed step",
                    });
                    operation.finish(.failed);
                    return;
                },
            }
        }
        operation.finish(.success);
        return .{
            .package_name = self.package_build.pkg_name,
            .path = self.makepkg_config.build_directory,
        };
    }
};

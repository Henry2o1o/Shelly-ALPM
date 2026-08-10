const std = @import("std");
const MakePkgConfiguration = @import("../makepackage.zig").MakePackageConfiguration;
const PackageBuild = @import("../../pkgbuild/pkgbuild_parser.zig").Pkgbuild;
const events = @import("../events.zig");
const op_context = @import("operation_context");

pub const BuildArtifact = struct {
    path: [:0]u8,
    package_name: []const u8,

    pub fn deinit(self: BuildArtifact, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.package_name);
    }
};

pub const BuilderErrors = error{ BuildFailed, OutOfMemory };

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

    pub fn BuildPackage(self: *PackageBuilder) BuilderErrors!BuildArtifact {
        var operation = self.operation_context.begin(op_context.OperationDescriptor{ .backend = .aur, .kind = .build, .subject = "Package Build" });
        defer operation.finish(.cancelled);
        for (self.package_build.execution_steps.?) |step| {
            var child = std.process.spawn(self.io, .{ .argv = &.{ "/bin/sh", "-c", step.expanded_body }, .stdout = .inherit, .stderr = .inherit, .cwd = .{ .path = self.makepkg_config.build_directory } }) catch {
                return BuilderErrors.BuildFailed;
            };
            const term = child.wait(self.io) catch return BuilderErrors.BuildFailed;
            switch (term) {
                .exited => |code| {
                    if (code != 0) {
                        const message = std.fmt.allocPrint(self.allocator, "Failed with error code: {d}", .{code}) catch return BuilderErrors.OutOfMemory;
                        defer self.allocator.free(message);
                        self.dispatcher.raiseError(.{
                            .message = message,
                        });
                        operation.finish(.failed);
                        return BuilderErrors.BuildFailed;
                    }
                    self.dispatcher.raiseInformational(.{
                        .event_type = .aur_build_start,
                        .message = "Finished step",
                        .package_name = self.package_build.pkg_name orelse "",
                    });
                },
                .signal => {
                    self.dispatcher.raiseError(.{
                        .message = "Failed step",
                    });
                    operation.finish(.failed);
                    return BuilderErrors.BuildFailed;
                },
                .stopped => {
                    self.dispatcher.raiseError(.{
                        .message = "Failed step",
                    });
                    operation.finish(.failed);
                    return BuilderErrors.BuildFailed;
                },
                .unknown => {
                    self.dispatcher.raiseError(.{
                        .message = "Failed step",
                    });
                    operation.finish(.failed);
                    return BuilderErrors.BuildFailed;
                },
            }
        }
        operation.finish(.success);
        const path = self.allocator.dupeSentinel(u8, self.makepkg_config.build_directory, 0) catch return BuilderErrors.OutOfMemory;
        defer self.allocator.free(path);
        return .{
            .package_name = self.package_build.pkg_name orelse "",
            .path = path,
        };
    }
};

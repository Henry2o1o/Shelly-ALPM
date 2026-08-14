const std = @import("std");
const MakePkgConfiguration = @import("../makepackage.zig").MakePackageConfiguration;
const PackageBuild = @import("../../pkgbuild/pkgbuild_parser.zig").Pkgbuild;
const events = @import("../events.zig");
const op_context = @import("operation_context");
const archive = @import("archive");

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
        const steps = self.package_build.execution_steps orelse {
            self.dispatcher.raiseError(.{ .message = "PKGBUILD defines no execution steps" });
            operation.finish(.failed);
            return BuilderErrors.BuildFailed;
        };
        for (steps) |step| {
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
        const package_name = self.allocator.dupe(u8, self.package_build.pkg_name orelse "") catch return BuilderErrors.OutOfMemory;
        errdefer self.allocator.free(package_name);
        const path = self.assemblePackage() catch |err| {
            const message = std.fmt.allocPrint(
                self.allocator,
                "Failed to assemble package: {s}",
                .{@errorName(err)},
            ) catch return BuilderErrors.OutOfMemory;
            defer self.allocator.free(message);
            self.dispatcher.raiseError(.{ .message = message });
            operation.finish(.failed);
            return if (err == error.OutOfMemory)
                BuilderErrors.OutOfMemory
            else
                BuilderErrors.BuildFailed;
        };
        operation.finish(.success);
        return .{ .package_name = package_name, .path = path };
    }

    fn assemblePackage(self: *PackageBuilder) ![:0]u8 {
        const package_name = self.package_build.pkg_name orelse return error.MissingPackageName;
        const full_version = try self.package_build.get_full_version(self.allocator);
        defer self.allocator.free(full_version);
        if (full_version.len == 0) return error.MissingPackageVersion;

        const package_arch = self.packageArchitecture();
        const pkgdir = try std.fs.path.join(
            self.allocator,
            &.{ self.makepkg_config.build_directory, "pkg", package_name },
        );
        defer self.allocator.free(pkgdir);

        var pkgdir_handle = try std.Io.Dir.cwd().openDir(self.io, pkgdir, .{ .iterate = true });
        defer pkgdir_handle.close(self.io);

        const payload_size = try directorySize(self.allocator, self.io, pkgdir_handle);
        const build_date = std.Io.Clock.real.now(self.io).toSeconds();
        try self.writePackageInfo(pkgdir_handle, full_version, package_arch, payload_size, build_date);
        try self.writeBuildInfo(pkgdir_handle, full_version, package_arch, build_date);
        if (self.package_build.install_file != null) {
            const install_contents = self.package_build.post_install orelse return error.MissingInstallFile;
            try writeMetadataFile(pkgdir_handle, self.io, ".INSTALL", install_contents);
        } else {
            try deleteFileIgnoreMissing(pkgdir_handle, self.io, ".INSTALL");
        }

        const mtree_path = try std.fs.path.join(self.allocator, &.{ pkgdir, ".MTREE" });
        defer self.allocator.free(mtree_path);
        try archive.writeMtree(self.allocator, self.io, pkgdir, mtree_path);
        var mtree_file = try pkgdir_handle.openFile(self.io, ".MTREE", .{});
        defer mtree_file.close(self.io);
        try mtree_file.setPermissions(self.io, .fromMode(0o644));

        try std.Io.Dir.cwd().createDirPath(self.io, self.makepkg_config.package_destination);
        const file_name = try std.fmt.allocPrint(
            self.allocator,
            "{s}-{s}-{s}{s}",
            .{ package_name, full_version, package_arch, self.makepkg_config.package_extension },
        );
        defer self.allocator.free(file_name);
        const output_path = try std.fs.path.joinZ(
            self.allocator,
            &.{ self.makepkg_config.package_destination, file_name },
        );
        errdefer self.allocator.free(output_path);
        errdefer std.Io.Dir.cwd().deleteFile(self.io, output_path) catch {};

        var writer = try archive.Writer.init(self.allocator, self.io, output_path);
        defer writer.deinit();
        try writer.addDirectory(pkgdir);
        try writer.finish();

        return output_path;
    }

    fn packageArchitecture(self: *const PackageBuilder) []const u8 {
        if (self.package_build.arch) |architectures| {
            for (architectures) |architecture| {
                if (std.mem.eql(u8, architecture, "any")) return "any";
            }
        }
        return self.makepkg_config.package_carch;
    }

    fn writePackageInfo(
        self: *PackageBuilder,
        pkgdir: std.Io.Dir,
        full_version: []const u8,
        package_arch: []const u8,
        payload_size: u64,
        build_date: i64,
    ) !void {
        const package_name = self.package_build.pkg_name orelse return error.MissingPackageName;
        const package_base = self.package_build.variables.get("pkgbase") orelse package_name;

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        const writer = &output.writer;
        try writeKeyValue(writer, "pkgname", package_name);
        try writeKeyValue(writer, "pkgbase", package_base);
        try writeKeyValue(writer, "xdata", "pkgtype=pkg");
        try writeKeyValue(writer, "pkgver", full_version);
        if (self.package_build.pkg_desc) |value| try writeKeyValue(writer, "pkgdesc", value);
        if (self.package_build.url) |value| try writeKeyValue(writer, "url", value);
        try writer.print("builddate = {d}\n", .{build_date});
        try writeKeyValue(writer, "packager", self.makepkg_config.packager);
        try writer.print("size = {d}\n", .{payload_size});
        try writeKeyValue(writer, "arch", package_arch);
        try writeKeyValues(writer, "license", self.package_build.license);
        try writeKeyValues(writer, "replaces", self.package_build.replaces);
        try writeKeyValues(writer, "conflict", self.package_build.conflicts);
        try writeKeyValues(writer, "provides", self.package_build.provides);
        try writeKeyValues(writer, "depend", self.package_build.depends);
        try writeKeyValues(writer, "optdepend", self.package_build.opt_depends);
        try writeKeyValues(writer, "makedepend", self.package_build.make_depends);
        try writeKeyValues(writer, "checkdepend", self.package_build.check_depends);
        try writeMetadataFile(pkgdir, self.io, ".PKGINFO", output.written());
    }

    fn writeBuildInfo(
        self: *PackageBuilder,
        pkgdir: std.Io.Dir,
        full_version: []const u8,
        package_arch: []const u8,
        build_date: i64,
    ) !void {
        const package_name = self.package_build.pkg_name orelse return error.MissingPackageName;
        const package_base = self.package_build.variables.get("pkgbase") orelse package_name;

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        const writer = &output.writer;
        try writeKeyValue(writer, "format", "2");
        try writeKeyValue(writer, "pkgname", package_name);
        try writeKeyValue(writer, "pkgbase", package_base);
        try writeKeyValue(writer, "pkgver", full_version);
        try writeKeyValue(writer, "pkgarch", package_arch);
        try writeKeyValue(writer, "packager", self.makepkg_config.packager);
        try writer.print("builddate = {d}\n", .{build_date});
        try writeKeyValue(writer, "builddir", self.makepkg_config.build_directory);
        try writeKeyValue(writer, "buildtool", "shelly");
        try writeKeyValue(writer, "buildtoolver", "1");
        try writeKeyValue(writer, "buildenv", self.makepkg_config.build_environment);
        try writeKeyValue(writer, "options", self.makepkg_config.options);
        try writeMetadataFile(pkgdir, self.io, ".BUILDINFO", output.written());
    }
};

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

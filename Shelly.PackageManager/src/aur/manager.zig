const std = @import("std");

const alpm_module = @import("../alpm/manager.zig");
const alpm_bindings = @import("../alpm/bindings.zig");
const alpm_events = @import("../alpm/events.zig");
const xdg_paths = @import("../shared/xdg_paths.zig").xdg_paths;
const pkgbuild_parser = @import("../pkgbuild/pkgbuild_parser.zig");
const homograph_validator = @import("../pkgbuild/homograph_validator.zig");
const post_install_validator = @import("../pkgbuild/post_install_validator.zig");
const validation = @import("../pkgbuild/shared_validtor.zig");

pub const models = @import("models.zig");
pub const rpc = @import("rpc_client.zig");
pub const vcs = @import("vcs.zig");
pub const srcinfo = @import("srcinfo.zig");
pub const events = @import("events.zig");
pub const builder = @import("builder.zig");
pub const dependency_resolver = @import("dependency_resolver.zig");
pub const version = @import("version.zig");

const AlpmManager = alpm_module.Manager;
const TransFlag = alpm_bindings.libalpm.TransFlag;
const PkgbuildInfo = pkgbuild_parser.pkgbuild_info;
const ParsedDependency = pkgbuild_parser.parsed_dep;
const ValidationFinding = validation.ValidationFinding;
const max_file_size = 32 * 1024 * 1024;

pub const InitOptions = struct {
    config_path: ?[]const u8 = null,
    root: bool = false,
    use_temp_path: bool = false,
    use_chroot: bool = false,
    chroot_path: []const u8 = "/var/lib/shelly/chroot",
    temp_path: ?[]const u8 = null,
    show_hidden_packages: bool = false,
    no_check: bool = true,
};

pub const PkgbuildDiffRequest = struct {
    package_name: []const u8,
    old_pkgbuild: []const u8,
    new_pkgbuild: []const u8,
    warnings: []const ValidationFinding,
    source_files: *const std.StringHashMap([]const u8),
};

pub const PkgbuildApprovalHandler = struct {
    function: *const fn (data: ?*anyopaque, request: PkgbuildDiffRequest) bool,
    data: ?*anyopaque = null,
};

pub const PkgbuildValidation = struct {
    post_install: validation.ValidationResult,
    homograph: validation.ValidationResult,

    pub fn deinit(self: *PkgbuildValidation, allocator: std.mem.Allocator) void {
        self.post_install.deinit(allocator);
        self.homograph.deinit(allocator);
        self.* = undefined;
    }

    pub fn hasFindings(self: *const PkgbuildValidation) bool {
        return self.post_install.has_findings or self.homograph.has_findings;
    }

    pub fn flatten(self: *const PkgbuildValidation, allocator: std.mem.Allocator) ![]ValidationFinding {
        const post = self.post_install.findings.items;
        const homograph = self.homograph.findings.items;
        const findings = try allocator.alloc(ValidationFinding, post.len + homograph.len);
        @memcpy(findings[0..post.len], post);
        @memcpy(findings[post.len..], homograph);
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

    var post_install = try (post_install_validator.PostInstallValidator{ .allocator = allocator }).validate(info);
    errdefer post_install.deinit(allocator);
    return .{
        .post_install = post_install,
        .homograph = try (homograph_validator.HomographValidator{ .allocator = allocator }).validate(info),
    };
}

pub const InstalledSnapshot = struct {
    name: []const u8,
    version: []const u8,
    explicit: bool,
};

pub fn applyInstalledState(
    allocator: std.mem.Allocator,
    packages: []models.Package,
    installed: []const InstalledSnapshot,
) !void {
    for (packages) |*package| {
        for (installed) |local| {
            if (!std.mem.eql(u8, package.name, local.name)) continue;
            const owned_version = try allocator.dupe(u8, local.version);
            allocator.free(package.version);
            package.version = owned_version;
            package.explicit = local.explicit;
            break;
        }
    }
}

pub fn collectVersionUpdates(
    allocator: std.mem.Allocator,
    installed: []const InstalledSnapshot,
    aur_packages: []const models.Package,
) ![]models.Update {
    var updates: std.ArrayList(models.Update) = .empty;
    errdefer {
        for (updates.items) |*update| update.deinit(allocator);
        updates.deinit(allocator);
    }
    for (aur_packages) |package| {
        for (installed) |local| {
            if (!std.mem.eql(u8, package.name, local.name)) continue;
            if (!(try version.isNewer(allocator, package.version, local.version))) break;
            try updates.append(allocator, try models.Update.init(
                allocator,
                package.name,
                local.version,
                package.version,
                package.url orelse "",
                package.package_base,
                package.description orelse "",
            ));
            break;
        }
    }
    return updates.toOwnedSlice(allocator);
}

pub const Manager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    alpm: *AlpmManager,
    aur_client: rpc.Client,
    dispatcher: events.Dispatcher,
    vcs_store: vcs.Store,
    pkgbase_cache: std.StringHashMap([]u8),
    bin_variant_cache: std.StringHashMap(?[]u8),
    currently_installing_dependencies: std.StringHashMap(void),
    cache_root: []u8,
    vcs_store_path: []u8,
    chroot_path: []u8,
    use_chroot: bool,
    no_check: bool,
    skip_optional_dependency_prompt: bool = false,
    pkgbuild_approval_handler: ?PkgbuildApprovalHandler = null,

    pub fn init(
        allocator: std.mem.Allocator,
        environ: std.process.Environ,
        options: InitOptions,
    ) !*Self {
        const cache_home = try xdg_paths.xdgCacheHome(allocator, environ);
        defer allocator.free(cache_home);
        const data_home = try xdg_paths.xdgDataHome(allocator, environ);
        defer allocator.free(data_home);
        const cache_root = try std.fs.path.join(allocator, &.{ cache_home, "Shelly" });
        errdefer allocator.free(cache_root);
        const vcs_store_path = try std.fs.path.join(allocator, &.{ data_home, "Shelly", "vcs.json" });
        errdefer allocator.free(vcs_store_path);
        const chroot_path = try allocator.dupe(u8, options.chroot_path);
        errdefer allocator.free(chroot_path);

        const temporary_root = if (options.use_temp_path) options.temp_path else null;
        const alpm = try AlpmManager.init(allocator, environ, options.config_path, options.root, temporary_root);
        errdefer alpm.deinit();
        try std.Io.Dir.cwd().createDirPath(alpm.io(), cache_root);
        if (options.show_hidden_packages and !alpm.show_hidden_packages) _ = alpm.toggle_hidden_packages();

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .environ = environ,
            .alpm = alpm,
            .aur_client = rpc.Client.init(allocator, alpm.io()),
            .dispatcher = events.Dispatcher.init(allocator),
            .vcs_store = vcs.Store.init(allocator),
            .pkgbase_cache = std.StringHashMap([]u8).init(allocator),
            .bin_variant_cache = std.StringHashMap(?[]u8).init(allocator),
            .currently_installing_dependencies = std.StringHashMap(void).init(allocator),
            .cache_root = cache_root,
            .vcs_store_path = vcs_store_path,
            .chroot_path = chroot_path,
            .use_chroot = options.use_chroot,
            .no_check = options.no_check,
        };
        self.vcs_store.loadFile(self.io(), self.vcs_store_path) catch {};
        self.importOtherAurHelperCaches() catch {};
        return self;
    }

    pub fn deinit(self: *Self) void {
        const allocator = self.allocator;
        self.vcs_store.saveFile(self.io(), self.vcs_store_path) catch {};
        self.vcs_store.deinit();
        var package_bases = self.pkgbase_cache.iterator();
        while (package_bases.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.pkgbase_cache.deinit();
        var bin_variants = self.bin_variant_cache.iterator();
        while (bin_variants.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.*) |value| allocator.free(value);
        }
        self.bin_variant_cache.deinit();
        var installing = self.currently_installing_dependencies.keyIterator();
        while (installing.next()) |key| allocator.free(key.*);
        self.currently_installing_dependencies.deinit();
        self.dispatcher.deinit();
        self.aur_client.deinit();
        self.alpm.deinit();
        allocator.free(self.cache_root);
        allocator.free(self.vcs_store_path);
        allocator.free(self.chroot_path);
        allocator.destroy(self);
    }

    pub fn io(self: *Self) std.Io {
        return self.alpm.io();
    }

    pub fn alpmDispatcher(self: *Self) *alpm_events.Dispatcher {
        return &self.alpm.dispatcher;
    }

    pub fn setPkgbuildApprovalHandler(self: *Self, handler: ?PkgbuildApprovalHandler) void {
        self.pkgbuild_approval_handler = handler;
    }

    pub fn getInstalledPackages(self: *Self) ![]models.Package {
        const foreign = try self.alpm.get_foreign_packages();
        defer alpm_bindings.libalpm.OwnedPackage.deinitSlice(self.allocator, foreign);
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.allocator);
        var installed: std.ArrayList(InstalledSnapshot) = .empty;
        defer installed.deinit(self.allocator);
        for (foreign) |package| {
            const name = package.name() orelse continue;
            try names.append(self.allocator, name);
            try installed.append(self.allocator, .{
                .name = name,
                .version = package.version() orelse "",
                .explicit = package.install_reason() == .Explicit,
            });
        }
        const response = try self.aur_client.getInfo(names.items);
        defer {
            self.allocator.free(response.response_type);
            if (response.error_message) |message| self.allocator.free(message);
        }
        try applyInstalledState(self.allocator, response.results, installed.items);
        return response.results;
    }

    pub fn searchPackages(self: *Self, query: []const u8) ![]models.Package {
        var search_response = try self.aur_client.search(query);
        defer search_response.deinit(self.allocator);
        std.mem.sort(models.Package, search_response.results, {}, struct {
            fn lessThan(_: void, lhs: models.Package, rhs: models.Package) bool {
                return lhs.popularity > rhs.popularity;
            }
        }.lessThan);
        const count = @min(search_response.results.len, 100);
        if (count == 0) return self.allocator.alloc(models.Package, 0);
        const names = try self.allocator.alloc([]const u8, count);
        defer self.allocator.free(names);
        for (search_response.results[0..count], names) |package, *name| name.* = package.name;
        const info_response = try self.aur_client.getInfo(names);
        self.allocator.free(info_response.response_type);
        if (info_response.error_message) |message| self.allocator.free(message);
        return info_response.results;
    }

    pub fn getPackagesNeedingUpdate(self: *Self, check_devel: bool) ![]models.Update {
        const foreign = try self.alpm.get_foreign_packages();
        defer alpm_bindings.libalpm.OwnedPackage.deinitSlice(self.allocator, foreign);
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.allocator);
        var installed: std.ArrayList(InstalledSnapshot) = .empty;
        defer installed.deinit(self.allocator);
        for (foreign) |package| {
            const name = package.name() orelse continue;
            try names.append(self.allocator, name);
            try installed.append(self.allocator, .{
                .name = name,
                .version = package.version() orelse "",
                .explicit = package.install_reason() == .Explicit,
            });
        }
        var response = try self.aur_client.getInfo(names.items);
        defer response.deinit(self.allocator);
        const base_updates = try collectVersionUpdates(self.allocator, installed.items, response.results);
        if (!check_devel) return base_updates;

        var updates: std.ArrayList(models.Update) = .fromOwnedSlice(base_updates);
        errdefer {
            for (updates.items) |*update| update.deinit(self.allocator);
            updates.deinit(self.allocator);
        }
        for (installed.items) |local| {
            if (!isVcsPackage(local.name) or containsUpdate(updates.items, local.name)) continue;
            if (!(self.checkVcsPackageNeedsUpdate(local.name) catch false)) continue;
            const metadata = findPackage(response.results, local.name);
            try updates.append(self.allocator, try models.Update.init(
                self.allocator,
                local.name,
                local.version,
                "latest-commit",
                if (metadata) |package| package.url orelse "" else "",
                if (metadata) |package| package.package_base else local.name,
                if (metadata) |package| package.description orelse "" else "",
            ));
        }
        return updates.toOwnedSlice(self.allocator);
    }

    pub fn updatePackages(self: *Self, package_names: []const []const u8) !void {
        const message = try std.mem.join(self.allocator, ", ", package_names);
        defer self.allocator.free(message);
        const text = try std.fmt.allocPrint(self.allocator, "Updating {d} packages: {s}", .{ package_names.len, message });
        defer self.allocator.free(text);
        self.raiseInfo(.informational_output, null, text, null, null);
        try self.installPackages(package_names);
    }

    pub fn fetchPkgbuild(self: *Self, package_name: []const u8) ![]u8 {
        const package_base = try self.resolvePkgbase(package_name);
        const message = try std.fmt.allocPrint(self.allocator, "Fetching PKGBUILD for {s} ({s})", .{ package_name, package_base });
        defer self.allocator.free(message);
        self.raiseInfo(.informational_output, package_name, message, null, null);
        return self.aur_client.fetchPkgbuild(package_base);
    }

    pub fn installDependenciesOnly(self: *Self, package_name: []const u8, include_make_dependencies: bool) !void {
        self.raisePackageProgress(.aur_download_start, package_name, 1, 1, "Downloading PKGBUILD to analyze dependencies");
        if (!try self.downloadPackage(package_name)) {
            self.raisePackageProgress(.aur_package_failed, package_name, 1, 1, "Failed to download package");
            return error.DownloadFailed;
        }
        const package_base = try self.resolvePkgbase(package_name);
        const cache_path = try self.cachePath(package_base);
        defer self.allocator.free(cache_path);
        const pkgbuild_path = try std.fs.path.join(self.allocator, &.{ cache_path, "PKGBUILD" });
        defer self.allocator.free(pkgbuild_path);
        var info = try (pkgbuild_parser.PkgbuildParser{ .allocator = self.allocator, .io = self.io() }).parser(pkgbuild_path);
        defer info.deinit(self.allocator);

        var direct = try self.resolveSelectedDependencies(&info, include_make_dependencies);
        defer direct.deinit(self.allocator);
        if (direct.repo_packages.len == 0 and direct.aur_packages.len == 0) {
            self.raisePackageProgress(.aur_package_completed, package_name, 1, 1, "All dependencies are already installed");
            return;
        }
        try self.installResolution(&direct);
        self.raisePackageProgress(.aur_package_completed, package_name, 1, 1, "Dependencies installed successfully");
    }

    pub fn installPackages(self: *Self, package_names: []const []const u8) !void {
        for (package_names, 0..) |package_name, index| {
            const current = index + 1;
            self.raisePackageProgress(.aur_download_start, package_name, current, package_names.len, "");
            if (!(try self.shouldProceedWithPkgbuild(package_name))) continue;
            if (!try self.downloadPackage(package_name)) {
                self.raisePackageProgress(.aur_package_failed, package_name, current, package_names.len, "Failed to download package");
                continue;
            }

            const package_base = try self.resolvePkgbase(package_name);
            const cache_path = try self.cachePath(package_base);
            defer self.allocator.free(cache_path);
            const pkgbuild_path = try std.fs.path.join(self.allocator, &.{ cache_path, "PKGBUILD" });
            defer self.allocator.free(pkgbuild_path);
            var info = try (pkgbuild_parser.PkgbuildParser{ .allocator = self.allocator, .io = self.io() }).parser(pkgbuild_path);
            defer info.deinit(self.allocator);

            const selected_optional = try self.selectOptionalDependencies(&info);
            defer self.allocator.free(selected_optional);
            const backend = self.dependencyBackend();
            const build_only = try dependency_resolver.collectBuildOnlyDependencies(self.allocator, &info, self.no_check, backend);
            defer builder.deinitPaths(self.allocator, build_only);

            var collection = DependencyCollection.init(self.allocator);
            defer collection.deinit();
            var visited = std.StringHashMap(void).init(self.allocator);
            defer {
                var keys = visited.keyIterator();
                while (keys.next()) |key| self.allocator.free(key.*);
                visited.deinit();
            }
            try self.collectDependenciesRecursive(&info, &collection, &visited);
            try self.installCollection(&collection);

            try self.prepareBuildDirectory(cache_path);
            self.raisePackageProgress(.aur_build_start, package_name, current, package_names.len, "Building package with makepkg");
            if (!(try self.buildPackage(package_name, cache_path))) {
                self.raisePackageProgress(.aur_package_failed, package_name, current, package_names.len, "Failed to build package with makepkg");
                continue;
            }
            const package_files = try builder.selectBuiltPackageFiles(self.allocator, self.io(), cache_path, package_name);
            defer builder.deinitPaths(self.allocator, package_files);
            if (package_files.len == 0) {
                self.raisePackageProgress(.aur_package_failed, package_name, current, package_names.len, "No matching package files produced by makepkg");
                continue;
            }
            self.raisePackageProgress(.aur_install_start, package_name, current, package_names.len, "");
            try self.alpm.install_local_packages(package_files, .{});
            self.updateVcsStoreForPackage(package_name, pkgbuild_path) catch |err|
                self.raiseBestEffortFailure(package_name, "Failed to update VCS metadata", err);
            self.installSelectedOptionalDependencies(package_name, selected_optional) catch |err|
                self.raiseBestEffortFailure(package_name, "Failed to install some optional dependencies", err);
            if (build_only.len > 0) {
                self.raisePackageProgress(.aur_cleanup_start, package_name, current, package_names.len, "Removing build-only dependencies");
                const build_names: []const []const u8 = @ptrCast(build_only);
                self.removeRepoPackages(build_names, .{}, true) catch {};
            }
            builder.cleanBuildArtifacts(self.io(), cache_path);
            self.raisePackageProgress(.aur_package_completed, package_name, current, package_names.len, "");
        }
    }

    pub fn removePackages(
        self: *Self,
        package_names: []const []const u8,
        flags: TransFlag,
        remove_optional_dependencies: bool,
    ) !void {
        try self.removeRepoPackages(package_names, flags, !remove_optional_dependencies);
        for (package_names) |package_name| {
            self.vcs_store.remove(package_name);
            const package_base = try self.resolvePkgbase(package_name);
            const cache_path = try self.cachePath(package_base);
            defer self.allocator.free(cache_path);
            std.Io.Dir.cwd().deleteTree(self.io(), cache_path) catch {};
        }
        try self.vcs_store.saveFile(self.io(), self.vcs_store_path);
    }

    pub fn installPackageVersion(self: *Self, package_name: []const u8, commit: []const u8) !void {
        self.raisePackageProgress(.aur_download_start, package_name, 1, 1, "");
        if (!(try self.downloadPackageAtCommit(package_name, commit))) return error.DownloadFailed;
        const package_base = try self.resolvePkgbase(package_name);
        const cache_path = try self.cachePath(package_base);
        defer self.allocator.free(cache_path);
        const pkgbuild_path = try std.fs.path.join(self.allocator, &.{ cache_path, "PKGBUILD" });
        defer self.allocator.free(pkgbuild_path);
        var info = try (pkgbuild_parser.PkgbuildParser{ .allocator = self.allocator, .io = self.io() }).parser(pkgbuild_path);
        defer info.deinit(self.allocator);
        const build_only = try dependency_resolver.collectBuildOnlyDependencies(self.allocator, &info, self.no_check, self.dependencyBackend());
        defer builder.deinitPaths(self.allocator, build_only);
        var collection = DependencyCollection.init(self.allocator);
        defer collection.deinit();
        var visited = std.StringHashMap(void).init(self.allocator);
        defer {
            var keys = visited.keyIterator();
            while (keys.next()) |key| self.allocator.free(key.*);
            visited.deinit();
        }
        try self.collectDependenciesRecursive(&info, &collection, &visited);
        try self.installCollection(&collection);
        if (!(try self.buildPackage(package_name, cache_path))) return error.BuildFailed;
        const package_files = try builder.selectBuiltPackageFiles(self.allocator, self.io(), cache_path, package_name);
        defer builder.deinitPaths(self.allocator, package_files);
        if (package_files.len == 0) return error.NoBuiltPackages;
        try self.alpm.install_local_packages(package_files, .{});
        if (build_only.len > 0) {
            self.raisePackageProgress(.aur_cleanup_start, package_name, 1, 1, "Removing build-only dependencies");
            const build_names: []const []const u8 = @ptrCast(build_only);
            self.removeRepoPackages(build_names, .{}, true) catch {};
        }
        self.raisePackageProgress(.aur_package_completed, package_name, 1, 1, "");
    }

    fn resolveSelectedDependencies(self: *Self, info: *const PkgbuildInfo, include_make: bool) !dependency_resolver.Resolution {
        var selected = info.*;
        if (!include_make) {
            selected.parsed_make_depends = null;
            selected.parsed_check_depends = null;
        }
        return dependency_resolver.resolve(self.allocator, &selected, true, self.dependencyBackend());
    }

    fn dependencyBackend(self: *Self) dependency_resolver.Backend {
        return .{
            .context = self,
            .is_installed = dependencyIsInstalled,
            .find_repo_satisfier = dependencyRepoSatisfier,
        };
    }

    fn dependencyIsInstalled(context: ?*anyopaque, dependency: [:0]const u8) bool {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.alpm.is_dependency_satisfied_by_installed_packages(dependency) catch false;
    }

    fn dependencyRepoSatisfier(context: ?*anyopaque, dependency: [:0]const u8) ?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.alpm.find_remote_satisfier_for_dependency(dependency) catch null;
    }

    fn installResolution(self: *Self, resolution: *const dependency_resolver.Resolution) !void {
        if (resolution.repo_packages.len > 0) try self.installRepoPackages(resolution.repo_packages, .{ .alldeps = true });
        for (resolution.aur_packages) |dependency| try self.buildAndInstallDependency(dependency);
    }

    fn collectDependenciesRecursive(
        self: *Self,
        info: *const PkgbuildInfo,
        collection: *DependencyCollection,
        visited: *std.StringHashMap(void),
    ) !void {
        var resolution = try dependency_resolver.resolve(self.allocator, info, self.no_check, self.dependencyBackend());
        defer resolution.deinit(self.allocator);
        for (resolution.repo_packages) |name| try collection.addRepo(name);
        for (resolution.aur_packages) |dependency| {
            var preferred = try self.preferBinaryVariant(dependency);
            defer preferred.deinit(self.allocator);
            if (visited.contains(preferred.name)) continue;
            try visited.put(try self.allocator.dupe(u8, preferred.name), {});
            if (!(try self.downloadPackage(preferred.name))) {
                const providers = self.aur_client.findProviders(preferred.name) catch continue;
                defer rpc.deinitStrings(self.allocator, providers);
                if (providers.len == 0) continue;
                const chosen = self.chooseProvider(preferred.name, providers) orelse continue;
                preferred.deinit(self.allocator);
                preferred = try dependency_resolver.cloneDependency(self.allocator, dependency);
                self.allocator.free(preferred.name);
                preferred.name = try self.allocator.dupe(u8, chosen);
                if (visited.contains(preferred.name)) continue;
                try visited.put(try self.allocator.dupe(u8, preferred.name), {});
                if (!(try self.downloadPackage(preferred.name))) continue;
            }
            const package_base = try self.resolvePkgbase(preferred.name);
            const cache_path = try self.cachePath(package_base);
            defer self.allocator.free(cache_path);
            const path = try std.fs.path.join(self.allocator, &.{ cache_path, "PKGBUILD" });
            defer self.allocator.free(path);
            var child_info = (pkgbuild_parser.PkgbuildParser{ .allocator = self.allocator, .io = self.io() }).parser(path) catch continue;
            defer child_info.deinit(self.allocator);
            if (preferred.operator.len != 0) {
                const child_version = try child_info.get_full_version(self.allocator);
                defer self.allocator.free(child_version);
                if (!(try version.satisfies(self.allocator, child_version, preferred.operator, preferred.version))) continue;
            }
            try self.collectDependenciesRecursive(&child_info, collection, visited);
            try collection.addAur(preferred);
        }
    }

    fn installCollection(self: *Self, collection: *const DependencyCollection) !void {
        if (collection.repo.items.len > 0) try self.installRepoPackages(collection.repo.items, .{ .alldeps = true });
        for (collection.aur.items) |dependency| try self.buildAndInstallDependency(dependency);
    }

    fn buildAndInstallDependency(self: *Self, dependency: ParsedDependency) !void {
        if (self.currently_installing_dependencies.contains(dependency.name)) return;
        const key = try self.allocator.dupe(u8, dependency.name);
        try self.currently_installing_dependencies.put(key, {});
        defer {
            _ = self.currently_installing_dependencies.remove(dependency.name);
            self.allocator.free(key);
        }
        if (!(try self.downloadPackage(dependency.name))) return error.DownloadFailed;
        const package_base = try self.resolvePkgbase(dependency.name);
        const cache_path = try self.cachePath(package_base);
        defer self.allocator.free(cache_path);
        if (!(try self.buildPackage(dependency.name, cache_path))) return error.BuildFailed;
        const files = try builder.selectBuiltPackageFiles(self.allocator, self.io(), cache_path, dependency.name);
        defer builder.deinitPaths(self.allocator, files);
        if (files.len == 0) return error.NoBuiltPackages;
        try self.alpm.install_local_packages(files, .{ .alldeps = true });
    }

    fn installRepoPackages(self: *Self, names: []const []u8, flags: TransFlag) !void {
        const values: []const []const u8 = @ptrCast(names);
        try self.installRepoPackagesConst(values, flags);
    }

    fn installRepoPackagesConst(self: *Self, names: []const []const u8, flags: TransFlag) !void {
        var terminated: std.ArrayList([:0]const u8) = .empty;
        defer {
            for (terminated.items) |name| self.allocator.free(name);
            terminated.deinit(self.allocator);
        }
        for (names) |name| try terminated.append(self.allocator, try self.allocator.dupeZ(u8, name));
        try self.alpm.install_packages(terminated.items, flags);
    }

    fn removeRepoPackages(self: *Self, names: []const []const u8, flags: TransFlag, keep_optional_dependencies: bool) !void {
        var terminated: std.ArrayList([:0]const u8) = .empty;
        defer {
            for (terminated.items) |name| self.allocator.free(name);
            terminated.deinit(self.allocator);
        }
        for (names) |name| try terminated.append(self.allocator, try self.allocator.dupeZ(u8, name));
        try self.alpm.remove_packages(terminated.items, flags, keep_optional_dependencies);
    }

    fn selectOptionalDependencies(self: *Self, info: *const PkgbuildInfo) ![][]const u8 {
        if (self.skip_optional_dependency_prompt) return self.allocator.alloc([]const u8, 0);
        const raw_options = info.opt_depends orelse return self.allocator.alloc([]const u8, 0);
        var options: std.ArrayList(events.ProviderOption) = .empty;
        defer options.deinit(self.allocator);
        for (raw_options) |raw| {
            const parsed = dependency_resolver.parseOptionalDependency(raw);
            if (!dependency_resolver.isValidPackageName(parsed.name)) continue;
            const name_z = try self.allocator.dupeZ(u8, parsed.name);
            defer self.allocator.free(name_z);
            try options.append(self.allocator, .{
                .name = parsed.name,
                .description = parsed.description,
                .is_installed = self.alpm.is_package_installed(name_z),
            });
        }
        if (options.items.len == 0) return self.allocator.alloc([]const u8, 0);
        const response = self.dispatcher.ask(.{
            .question_type = .select_optional_dependencies,
            .question = "Select optional dependencies",
            .options = options.items,
        });
        var selected: std.ArrayList([]const u8) = .empty;
        errdefer selected.deinit(self.allocator);
        for (response.selected_indices) |index| {
            if (index >= options.items.len or options.items[index].is_installed) continue;
            try selected.append(self.allocator, options.items[index].name);
        }
        return selected.toOwnedSlice(self.allocator);
    }

    fn installSelectedOptionalDependencies(self: *Self, parent: []const u8, selected: []const []const u8) !void {
        var repo_names: std.ArrayList([]const u8) = .empty;
        defer repo_names.deinit(self.allocator);
        var aur_names: std.ArrayList([]const u8) = .empty;
        defer aur_names.deinit(self.allocator);
        for (selected) |raw| {
            const parsed = dependency_resolver.parseOptionalDependency(raw);
            const name_z = try self.allocator.dupeZ(u8, parsed.name);
            defer self.allocator.free(name_z);
            if (self.alpm.find_remote_satisfier_for_dependency(name_z)) |satisfier| {
                if (!containsConst(repo_names.items, satisfier)) try repo_names.append(self.allocator, satisfier);
            } else |_| if (!containsConst(aur_names.items, parsed.name)) try aur_names.append(self.allocator, parsed.name);
        }
        if (repo_names.items.len > 0) {
            self.raiseBuildLine(parent, "Installing optional dependencies from repositories", false);
            if (self.installRepoPackagesConst(repo_names.items, .{})) |_| {
                for (repo_names.items) |name| {
                    const name_z = try self.allocator.dupeZ(u8, name);
                    defer self.allocator.free(name_z);
                    self.alpm.update_package_reason(name_z, .Dependency) catch {};
                }
            } else |err| {
                self.raiseBestEffortFailure(parent, "Failed to install repository optional dependencies", err);
            }
        }
        const previous = self.skip_optional_dependency_prompt;
        self.skip_optional_dependency_prompt = true;
        defer self.skip_optional_dependency_prompt = previous;
        for (aur_names.items) |name| {
            const providers = self.aur_client.findProviders(name) catch continue;
            defer rpc.deinitStrings(self.allocator, providers);
            const chosen = self.chooseProvider(name, providers) orelse {
                const message = try std.fmt.allocPrint(self.allocator, "Optional dependency '{s}' has no selected AUR provider", .{name});
                defer self.allocator.free(message);
                self.dispatcher.raiseError(.{ .message = message });
                continue;
            };
            self.installPackages(&.{chosen}) catch continue;
            const chosen_z = try self.allocator.dupeZ(u8, chosen);
            defer self.allocator.free(chosen_z);
            self.alpm.update_package_reason(chosen_z, .Dependency) catch {};
        }
    }

    fn chooseProvider(self: *Self, dependency: []const u8, provider_names: []const []u8) ?[]const u8 {
        if (provider_names.len == 0) return null;
        if (provider_names.len == 1) return provider_names[0];
        var options: std.ArrayList(events.ProviderOption) = .empty;
        defer options.deinit(self.allocator);
        for (provider_names) |name| {
            const name_z = self.allocator.dupeZ(u8, name) catch continue;
            defer self.allocator.free(name_z);
            options.append(self.allocator, .{
                .name = name,
                .description = "No Description",
                .is_installed = self.alpm.is_package_installed(name_z),
            }) catch continue;
        }
        const response = self.dispatcher.ask(.{
            .question_type = .select_provider,
            .question = "Select an AUR provider",
            .options = options.items,
            .dependency_name = dependency,
        });
        const index = if (response.selected_indices.len > 0) response.selected_indices[0] else 0;
        return if (index < provider_names.len) provider_names[index] else provider_names[0];
    }

    fn shouldProceedWithPkgbuild(self: *Self, package_name: []const u8) !bool {
        const old_pkgbuild = try self.readCachedPkgbuild(package_name);
        defer if (old_pkgbuild) |content| self.allocator.free(content);
        const new_pkgbuild = self.fetchPkgbuild(package_name) catch null;
        defer if (new_pkgbuild) |content| self.allocator.free(content);
        if (new_pkgbuild == null) return true;
        const package_base = try self.resolvePkgbase(package_name);
        const base_directory = try self.cachePath(package_base);
        defer self.allocator.free(base_directory);
        self.fetchLocalSourceFiles(new_pkgbuild.?, package_base, base_directory) catch |err|
            self.raiseBestEffortFailure(package_name, "Failed to fetch PKGBUILD source files", err);
        return self.requestPkgbuildApproval(package_name, old_pkgbuild orelse "", new_pkgbuild.?, base_directory);
    }

    fn requestPkgbuildApproval(
        self: *Self,
        package_name: []const u8,
        old_pkgbuild: []const u8,
        new_pkgbuild: []const u8,
        base_directory: ?[]const u8,
    ) !bool {
        const handler = self.pkgbuild_approval_handler orelse return true;
        const parser = pkgbuild_parser.PkgbuildParser{ .allocator = self.allocator, .io = self.io() };
        var info = parser.parser_content(new_pkgbuild, base_directory) catch |err| {
            self.raiseBestEffortFailure(package_name, "Failed to validate PKGBUILD", err);
            var empty_sources = std.StringHashMap([]const u8).init(self.allocator);
            defer empty_sources.deinit();
            return handler.function(handler.data, .{
                .package_name = package_name,
                .old_pkgbuild = old_pkgbuild,
                .new_pkgbuild = new_pkgbuild,
                .warnings = &.{},
                .source_files = &empty_sources,
            });
        };
        defer info.deinit(self.allocator);
        var results = validatePkgbuild(self.allocator, self.io(), new_pkgbuild, base_directory) catch |err| {
            self.raiseBestEffortFailure(package_name, "Failed to validate PKGBUILD", err);
            return handler.function(handler.data, .{
                .package_name = package_name,
                .old_pkgbuild = old_pkgbuild,
                .new_pkgbuild = new_pkgbuild,
                .warnings = &.{},
                .source_files = &info.local_source_contents,
            });
        };
        defer results.deinit(self.allocator);
        const findings = try results.flatten(self.allocator);
        defer self.allocator.free(findings);
        return handler.function(handler.data, .{
            .package_name = package_name,
            .old_pkgbuild = old_pkgbuild,
            .new_pkgbuild = new_pkgbuild,
            .warnings = findings,
            .source_files = &info.local_source_contents,
        });
    }

    fn fetchLocalSourceFiles(self: *Self, content: []const u8, package_base: []const u8, base_directory: []const u8) !void {
        var info = try (pkgbuild_parser.PkgbuildParser{ .allocator = self.allocator, .io = self.io() }).parser_content(content, base_directory);
        defer info.deinit(self.allocator);
        const files = info.local_source_files orelse return;
        try std.Io.Dir.cwd().createDirPath(self.io(), base_directory);
        for (files) |file_name| {
            if (!std.mem.eql(u8, std.fs.path.basename(file_name), file_name)) continue;
            const path = try std.fs.path.join(self.allocator, &.{ base_directory, file_name });
            defer self.allocator.free(path);
            if (std.Io.Dir.cwd().statFile(self.io(), path, .{})) |_| continue else |_| {}
            const source_content = self.aur_client.fetchSourceFile(package_base, file_name) catch continue;
            defer self.allocator.free(source_content);
            var file = std.Io.Dir.cwd().createFile(self.io(), path, .{}) catch continue;
            defer file.close(self.io());
            file.writeStreamingAll(self.io(), source_content) catch continue;
        }
    }

    fn readCachedPkgbuild(self: *Self, package_name: []const u8) !?[]u8 {
        const package_base = try self.resolvePkgbase(package_name);
        const primary_dir = try self.cachePath(package_base);
        defer self.allocator.free(primary_dir);
        const primary = try std.fs.path.join(self.allocator, &.{ primary_dir, "PKGBUILD" });
        defer self.allocator.free(primary);
        if (std.Io.Dir.cwd().readFileAlloc(self.io(), primary, self.allocator, .limited(max_file_size))) |content| return content else |_| {}
        const legacy_dir = try self.cachePath(package_name);
        defer self.allocator.free(legacy_dir);
        const legacy = try std.fs.path.join(self.allocator, &.{ legacy_dir, "PKGBUILD" });
        defer self.allocator.free(legacy);
        return std.Io.Dir.cwd().readFileAlloc(self.io(), legacy, self.allocator, .limited(max_file_size)) catch null;
    }

    fn resolvePkgbase(self: *Self, package_name: []const u8) ![]const u8 {
        if (std.mem.trim(u8, package_name, " \t\r\n").len == 0) return package_name;
        if (self.pkgbase_cache.get(package_name)) |cached| return cached;
        if (try self.tryResolveFromSrcinfo(package_name)) |package_base| {
            defer self.allocator.free(package_base);
            return self.cachePkgbase(package_name, package_base);
        }
        if (try self.tryResolveFromGitRemote(package_name)) |package_base| {
            defer self.allocator.free(package_base);
            return self.cachePkgbase(package_name, package_base);
        }
        const remote = self.aur_client.getPackageBase(package_name) catch return self.cachePkgbase(package_name, package_name);
        defer self.allocator.free(remote);
        return self.cachePkgbase(package_name, remote);
    }

    fn cachePkgbase(self: *Self, package_name: []const u8, package_base: []const u8) ![]const u8 {
        const key = try self.allocator.dupe(u8, package_name);
        errdefer self.allocator.free(key);
        const value = try self.allocator.dupe(u8, package_base);
        errdefer self.allocator.free(value);
        try self.pkgbase_cache.put(key, value);
        return value;
    }

    fn tryResolveFromSrcinfo(self: *Self, package_name: []const u8) !?[]u8 {
        const direct_dir = try self.cachePath(package_name);
        defer self.allocator.free(direct_dir);
        const direct = try std.fs.path.join(self.allocator, &.{ direct_dir, ".SRCINFO" });
        defer self.allocator.free(direct);
        if (srcinfo.parseFile(self.allocator, self.io(), direct)) |info_value| {
            var info = info_value;
            defer info.deinit(self.allocator);
            if (info.contains(package_name) and info.package_base != null)
                return self.allocator.dupe(u8, info.package_base.?);
        } else |_| {}

        var root = std.Io.Dir.cwd().openDir(self.io(), self.cache_root, .{ .iterate = true }) catch return null;
        defer root.close(self.io());
        var iterator = root.iterate();
        while (try iterator.next(self.io())) |entry| {
            if (entry.kind != .directory) continue;
            const path = try std.fs.path.join(self.allocator, &.{ self.cache_root, entry.name, ".SRCINFO" });
            defer self.allocator.free(path);
            var info = srcinfo.parseFile(self.allocator, self.io(), path) catch continue;
            defer info.deinit(self.allocator);
            if (info.contains(package_name) and info.package_base != null)
                return self.allocator.dupe(u8, info.package_base.?);
        }
        return null;
    }

    fn tryResolveFromGitRemote(self: *Self, package_name: []const u8) !?[]u8 {
        const directory = try self.cachePath(package_name);
        defer self.allocator.free(directory);
        const git_directory = try std.fs.path.join(self.allocator, &.{ directory, ".git" });
        defer self.allocator.free(git_directory);
        _ = std.Io.Dir.cwd().statFile(self.io(), git_directory, .{}) catch return null;
        var result = try self.runAsInvokingUser(&.{ "git", "-C", directory, "remote", "get-url", "origin" }, null, null);
        defer result.deinit(self.allocator);
        if (result.exit_code != 0) return null;
        return parseAurGitRemote(self.allocator, std.mem.trim(u8, result.stdout, " \t\r\n"));
    }

    fn downloadPackage(self: *Self, package_name: []const u8) !bool {
        const package_base = try self.resolvePkgbase(package_name);
        const cache_path = try self.cachePath(package_base);
        defer self.allocator.free(cache_path);
        const expected_remote = try std.fmt.allocPrint(self.allocator, "https://aur.archlinux.org/{s}.git", .{package_base});
        defer self.allocator.free(expected_remote);
        const git_dir = try std.fs.path.join(self.allocator, &.{ cache_path, ".git" });
        defer self.allocator.free(git_dir);
        var clone_needed = true;
        if (std.Io.Dir.cwd().statFile(self.io(), git_dir, .{})) |_| {
            var remote = try self.runAsInvokingUser(&.{ "git", "-C", cache_path, "remote", "get-url", "origin" }, null, null);
            defer remote.deinit(self.allocator);
            if (remote.exit_code == 0 and std.mem.eql(u8, std.mem.trim(u8, remote.stdout, " \t\r\n"), expected_remote)) {
                var pull = try self.runAsInvokingUser(&.{ "git", "-C", cache_path, "pull", "--ff-only" }, null, null);
                defer pull.deinit(self.allocator);
                clone_needed = pull.exit_code != 0;
            }
        } else |_| {}
        if (clone_needed) {
            builder.cleanBuildArtifacts(self.io(), cache_path);
            std.Io.Dir.cwd().deleteTree(self.io(), cache_path) catch {};
            var clone = try self.runAsInvokingUser(&.{ "git", "clone", expected_remote, cache_path }, null, null);
            defer clone.deinit(self.allocator);
            if (clone.exit_code != 0) return false;
        }
        const pkgbuild_path = try std.fs.path.join(self.allocator, &.{ cache_path, "PKGBUILD" });
        defer self.allocator.free(pkgbuild_path);
        _ = std.Io.Dir.cwd().statFile(self.io(), pkgbuild_path, .{}) catch return false;
        return true;
    }

    fn downloadPackageAtCommit(self: *Self, package_name: []const u8, commit: []const u8) !bool {
        const package_base = try self.resolvePkgbase(package_name);
        const cache_path = try self.cachePath(package_base);
        defer self.allocator.free(cache_path);
        const remote = try std.fmt.allocPrint(self.allocator, "https://aur.archlinux.org/{s}.git", .{package_base});
        defer self.allocator.free(remote);
        std.Io.Dir.cwd().deleteTree(self.io(), cache_path) catch {};
        var clone = try self.runAsInvokingUser(&.{ "git", "clone", remote, cache_path }, null, null);
        defer clone.deinit(self.allocator);
        if (clone.exit_code != 0) return false;
        var checkout = try self.runAsInvokingUser(&.{ "git", "checkout", commit }, cache_path, null);
        defer checkout.deinit(self.allocator);
        return checkout.exit_code == 0;
    }

    fn prepareBuildDirectory(self: *Self, cache_path: []const u8) !void {
        const pkgbuild_path = try std.fs.path.join(self.allocator, &.{ cache_path, "PKGBUILD" });
        defer self.allocator.free(pkgbuild_path);
        if (std.Io.Dir.cwd().statFile(self.io(), pkgbuild_path, .{})) |_| {
            const previous_versions = try std.fs.path.join(self.allocator, &.{ cache_path, "PreviousVersions" });
            defer self.allocator.free(previous_versions);
            var mkdir = try self.runAsInvokingUser(&.{ "mkdir", "-p", previous_versions }, null, null);
            defer mkdir.deinit(self.allocator);
            if (mkdir.exit_code == 0) {
                var backup_count: usize = 0;
                if (std.Io.Dir.cwd().openDir(self.io(), previous_versions, .{ .iterate = true })) |directory_value| {
                    var directory = directory_value;
                    defer directory.close(self.io());
                    var iterator = directory.iterate();
                    while (try iterator.next(self.io())) |entry| {
                        if (entry.kind == .file and std.mem.startsWith(u8, entry.name, "PKGBUILD.")) backup_count += 1;
                    }
                } else |_| {}
                const backup_name = try std.fmt.allocPrint(self.allocator, "PKGBUILD.{d}", .{backup_count + 1});
                defer self.allocator.free(backup_name);
                const backup_path = try std.fs.path.join(self.allocator, &.{ previous_versions, backup_name });
                defer self.allocator.free(backup_path);
                var copy = try self.runAsInvokingUser(&.{ "cp", pkgbuild_path, backup_path }, null, null);
                defer copy.deinit(self.allocator);
            }
        } else |_| {}

        var directory = std.Io.Dir.cwd().openDir(self.io(), cache_path, .{ .iterate = true }) catch return;
        defer directory.close(self.io());
        var iterator = directory.iterate();
        var stale_paths: std.ArrayList([]u8) = .empty;
        defer {
            for (stale_paths.items) |path| self.allocator.free(path);
            stale_paths.deinit(self.allocator);
        }
        while (try iterator.next(self.io())) |entry| {
            if (entry.kind != .file or !builder.isPackageArchiveArtifact(entry.name)) continue;
            try stale_paths.append(self.allocator, try std.fs.path.join(self.allocator, &.{ cache_path, entry.name }));
        }
        for (stale_paths.items) |path| {
            var remove = try self.runAsInvokingUser(&.{ "rm", "-f", path }, null, null);
            remove.deinit(self.allocator);
        }
    }

    fn buildPackage(self: *Self, package_name: []const u8, cache_path: []const u8) !bool {
        if (self.use_chroot) try self.ensureChrootExists();
        var command = try builder.makepkgCommand(self.allocator, self.io(), self.environ, self.use_chroot, self.chroot_path, self.no_check);
        defer command.deinit(self.allocator);
        var result = try builder.runWithEnvironment(self.allocator, self.io(), self.environ, command.asConst(), cache_path, null);
        defer result.deinit(self.allocator);
        var output_lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (output_lines.next()) |line| {
            if (line.len == 0) continue;
            self.raiseBuildLine(package_name, line, false);
            if (builder.parseBuildProgress(line)) |progress| self.dispatcher.raiseProgress(.{
                .progress_type = .makepkg_build,
                .package_name = package_name,
                .percent = progress.percent,
                .message = progress.message,
            });
        }
        var error_lines = std.mem.splitScalar(u8, result.stderr, '\n');
        while (error_lines.next()) |line| if (line.len != 0) self.raiseBuildLine(package_name, line, true);
        return result.exit_code == 0;
    }

    fn ensureChrootExists(self: *Self) !void {
        const root = try std.fs.path.join(self.allocator, &.{ self.chroot_path, "root" });
        defer self.allocator.free(root);
        if (std.Io.Dir.cwd().statFile(self.io(), root, .{})) |_| {
            var update = try builder.runWithEnvironment(self.allocator, self.io(), self.environ, &.{ "arch-nspawn", root, "shelly", "upgrade", "-n" }, null, null);
            defer update.deinit(self.allocator);
        } else |_| {
            try std.Io.Dir.cwd().createDirPath(self.io(), self.chroot_path);
            var create = try builder.runWithEnvironment(self.allocator, self.io(), self.environ, &.{ "mkarchroot", root, "base-devel" }, null, null);
            defer create.deinit(self.allocator);
            if (create.exit_code != 0) return error.ChrootFailed;
        }
        const destination = try std.fs.path.join(self.allocator, &.{ root, "etc", "makepkg.conf" });
        defer self.allocator.free(destination);
        var copy = try builder.runWithEnvironment(self.allocator, self.io(), self.environ, &.{ "cp", "/etc/makepkg.conf", destination }, null, null);
        defer copy.deinit(self.allocator);
        if (copy.exit_code != 0) return error.ChrootFailed;
    }

    fn preferBinaryVariant(self: *Self, dependency: ParsedDependency) !ParsedDependency {
        if (hasNoBinRemapSuffix(dependency.name)) return dependency_resolver.cloneDependency(self.allocator, dependency);
        if (self.bin_variant_cache.get(dependency.name)) |cached| {
            var clone = try dependency_resolver.cloneDependency(self.allocator, dependency);
            if (cached) |name| {
                self.allocator.free(clone.name);
                clone.name = try self.allocator.dupe(u8, name);
            }
            return clone;
        }
        const bin_name = try std.fmt.allocPrint(self.allocator, "{s}-bin", .{dependency.name});
        defer self.allocator.free(bin_name);
        var resolved: ?[]const u8 = null;
        if (self.aur_client.getInfo(&.{bin_name})) |response_value| {
            var response = response_value;
            defer response.deinit(self.allocator);
            if (response.results.len > 0) {
                const candidate = response.results[0];
                if (std.mem.eql(u8, candidate.name, bin_name) and candidate.maintainer != null and candidate.maintainer.?.len > 0) {
                    if (dependency.operator.len == 0 or try version.satisfies(self.allocator, candidate.version, dependency.operator, dependency.version))
                        resolved = candidate.name;
                }
            }
        } else |_| {}
        const cache_key = try self.allocator.dupe(u8, dependency.name);
        errdefer self.allocator.free(cache_key);
        const cache_value = if (resolved) |name| try self.allocator.dupe(u8, name) else null;
        try self.bin_variant_cache.put(cache_key, cache_value);
        var clone = try dependency_resolver.cloneDependency(self.allocator, dependency);
        if (resolved) |name| {
            self.allocator.free(clone.name);
            clone.name = try self.allocator.dupe(u8, name);
        }
        return clone;
    }

    fn checkVcsPackageNeedsUpdate(self: *Self, package_name: []const u8) !bool {
        const stored = self.vcs_store.get(package_name);
        if (stored.len == 0) {
            const entries = try self.getVcsSourceEntries(package_name);
            defer if (entries) |values| vcs.deinitEntries(self.allocator, values);
            if (entries == null or entries.?.len == 0) return false;
            for (entries.?) |*entry| {
                if (try self.getRemoteCommitSha(entry.url, entry.branch)) |sha| {
                    self.allocator.free(entry.commit_sha);
                    entry.commit_sha = sha;
                }
            }
            try self.vcs_store.set(package_name, entries.?);
            try self.vcs_store.saveFile(self.io(), self.vcs_store_path);
            return false;
        }
        for (stored) |entry| {
            if (entry.commit_sha.len == 0) continue;
            const remote = try self.getRemoteCommitSha(entry.url, entry.branch) orelse continue;
            defer self.allocator.free(remote);
            if (!std.mem.eql(u8, remote, entry.commit_sha)) return true;
        }
        return false;
    }

    fn getVcsSourceEntries(self: *Self, package_name: []const u8) !?[]vcs.SourceEntry {
        const package_base = try self.resolvePkgbase(package_name);
        const cache_path = try self.cachePath(package_base);
        defer self.allocator.free(cache_path);
        const path = try std.fs.path.join(self.allocator, &.{ cache_path, "PKGBUILD" });
        defer self.allocator.free(path);
        _ = std.Io.Dir.cwd().statFile(self.io(), path, .{}) catch {
            if (!(try self.downloadPackage(package_name))) return null;
        };
        var info = try (pkgbuild_parser.PkgbuildParser{ .allocator = self.allocator, .io = self.io() }).parser(path);
        defer info.deinit(self.allocator);
        const sources = info.source orelse return null;
        const entries = try vcs.parseSources(self.allocator, sources, &info.variables);
        return if (entries.len == 0) blk: {
            self.allocator.free(entries);
            break :blk null;
        } else entries;
    }

    fn getRemoteCommitSha(self: *Self, url: []const u8, branch: []const u8) !?[]u8 {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);
        try args.appendSlice(self.allocator, &.{ "git", "ls-remote", url });
        if (branch.len != 0) try args.append(self.allocator, branch);
        var result = try builder.runWithEnvironment(self.allocator, self.io(), self.environ, args.items, null, 15);
        defer result.deinit(self.allocator);
        if (result.exit_code != 0) return null;
        const line_end = std.mem.indexOfScalar(u8, result.stdout, '\n') orelse result.stdout.len;
        const line = result.stdout[0..line_end];
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return null;
        const sha = std.mem.trim(u8, line[0..tab], " \t\r");
        return if (sha.len == 0) null else self.allocator.dupe(u8, sha);
    }

    fn updateVcsStoreForPackage(self: *Self, package_name: []const u8, _: []const u8) !void {
        if (!isVcsPackage(package_name)) return;
        const entries = try self.getVcsSourceEntries(package_name) orelse return;
        defer vcs.deinitEntries(self.allocator, entries);
        for (entries) |*entry| {
            if (try self.getRemoteCommitSha(entry.url, entry.branch)) |sha| {
                self.allocator.free(entry.commit_sha);
                entry.commit_sha = sha;
            }
        }
        try self.vcs_store.set(package_name, entries);
        try self.vcs_store.saveFile(self.io(), self.vcs_store_path);
    }

    fn importOtherAurHelperCaches(self: *Self) !void {
        const home = self.environ.getPosix("HOME") orelse return;
        const foreign = try self.alpm.get_foreign_packages();
        defer alpm_bindings.libalpm.OwnedPackage.deinitSlice(self.allocator, foreign);
        for ([_][]const u8{ ".cache/paru/clone", ".cache/yay" }) |relative| {
            const source = try std.fs.path.join(self.allocator, &.{ home, relative });
            defer self.allocator.free(source);
            try self.importHelperCache(source, foreign);
        }
    }

    fn importHelperCache(self: *Self, source_root: []const u8, foreign: []const alpm_bindings.libalpm.OwnedPackage) !void {
        var directory = std.Io.Dir.cwd().openDir(self.io(), source_root, .{ .iterate = true }) catch return;
        defer directory.close(self.io());
        var iterator = directory.iterate();
        while (try iterator.next(self.io())) |entry| {
            if (entry.kind != .directory) continue;
            const source = try std.fs.path.join(self.allocator, &.{ source_root, entry.name });
            defer self.allocator.free(source);
            const pkgbuild = try std.fs.path.join(self.allocator, &.{ source, "PKGBUILD" });
            defer self.allocator.free(pkgbuild);
            _ = std.Io.Dir.cwd().statFile(self.io(), pkgbuild, .{}) catch continue;
            var identity = try self.resolveCloneIdentity(source, entry.name);
            defer identity.deinit(self.allocator);
            var installed = false;
            const identity_names: []const []const u8 = @ptrCast(identity.package_names);
            for (foreign) |package| if (cloneIdentityMatches(identity.package_base, identity_names, package.name() orelse "")) {
                installed = true;
                break;
            };
            if (!installed) continue;
            const destination = try self.cachePath(identity.package_base);
            defer self.allocator.free(destination);
            if (std.Io.Dir.cwd().statFile(self.io(), destination, .{})) |_| continue else |_| {}
            var copy = try builder.runWithEnvironment(self.allocator, self.io(), self.environ, &.{ "cp", "-r", source, destination }, null, null);
            defer copy.deinit(self.allocator);
            if (copy.exit_code == 0) {
                const git = try std.fs.path.join(self.allocator, &.{ destination, ".git" });
                defer self.allocator.free(git);
                std.Io.Dir.cwd().deleteTree(self.io(), git) catch {};
            }
        }
    }

    fn resolveCloneIdentity(self: *Self, clone_directory: []const u8, fallback: []const u8) !CloneIdentity {
        const path = try std.fs.path.join(self.allocator, &.{ clone_directory, ".SRCINFO" });
        defer self.allocator.free(path);
        if (srcinfo.parseFile(self.allocator, self.io(), path)) |info_value| {
            var info = info_value;
            defer info.deinit(self.allocator);
            if (info.package_base) |base| return CloneIdentity.init(self.allocator, base, info.package_names);
        } else |_| {}

        const git_directory = try std.fs.path.join(self.allocator, &.{ clone_directory, ".git" });
        defer self.allocator.free(git_directory);
        if (std.Io.Dir.cwd().statFile(self.io(), git_directory, .{})) |_| {
            var remote = try self.runAsInvokingUser(&.{ "git", "-C", clone_directory, "remote", "get-url", "origin" }, null, null);
            defer remote.deinit(self.allocator);
            if (remote.exit_code == 0) {
                if (try parseAurGitRemote(self.allocator, std.mem.trim(u8, remote.stdout, " \t\r\n"))) |package_base| {
                    defer self.allocator.free(package_base);
                    return CloneIdentity.init(self.allocator, package_base, &.{});
                }
            }
        } else |_| {}
        return CloneIdentity.init(self.allocator, fallback, &.{});
    }

    fn cachePath(self: *Self, package_base: []const u8) ![]u8 {
        return std.fs.path.join(self.allocator, &.{ self.cache_root, package_base });
    }

    fn runAsInvokingUser(
        self: *Self,
        command_and_args: []const []const u8,
        working_directory: ?[]const u8,
        timeout_seconds: ?u32,
    ) !builder.ProcessResult {
        if (command_and_args.len == 0) return error.EmptyCommand;
        var command = try builder.invokingUserCommand(
            self.allocator,
            self.io(),
            self.environ,
            command_and_args[0],
            command_and_args[1..],
        );
        defer command.deinit(self.allocator);
        return builder.runWithEnvironment(self.allocator, self.io(), self.environ, command.asConst(), working_directory, timeout_seconds);
    }

    fn raisePackageProgress(
        self: *Self,
        event_type: events.EventType,
        package_name: []const u8,
        current: usize,
        total: usize,
        message: []const u8,
    ) void {
        self.raiseInfo(event_type, package_name, message, current, total);
    }

    fn raiseBuildLine(self: *Self, package_name: []const u8, line: []const u8, is_error: bool) void {
        self.raiseInfo(if (is_error) .aur_build_error else .aur_build_output, package_name, line, null, null);
    }

    fn raiseBestEffortFailure(self: *Self, package_name: []const u8, context: []const u8, err: anyerror) void {
        const message = std.fmt.allocPrint(self.allocator, "[Shelly] Warning: {s}: {s}", .{ context, @errorName(err) }) catch {
            self.raiseBuildLine(package_name, "[Shelly] Warning: a best-effort AUR operation failed", true);
            return;
        };
        defer self.allocator.free(message);
        self.raiseBuildLine(package_name, message, true);
    }

    fn raiseInfo(
        self: *Self,
        event_type: events.EventType,
        package_name: ?[]const u8,
        message: []const u8,
        current: ?usize,
        total: ?usize,
    ) void {
        self.dispatcher.raiseInformational(.{
            .event_type = event_type,
            .message = message,
            .package_name = package_name,
            .current = current,
            .total = total,
        });
    }
};

const DependencyCollection = struct {
    allocator: std.mem.Allocator,
    repo: std.ArrayList([]u8) = .empty,
    aur: std.ArrayList(ParsedDependency) = .empty,

    fn init(allocator: std.mem.Allocator) DependencyCollection {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *DependencyCollection) void {
        for (self.repo.items) |name| self.allocator.free(name);
        self.repo.deinit(self.allocator);
        for (self.aur.items) |dependency| dependency.deinit(self.allocator);
        self.aur.deinit(self.allocator);
    }

    fn addRepo(self: *DependencyCollection, name: []const u8) !void {
        if (!containsMutable(self.repo.items, name)) try self.repo.append(self.allocator, try self.allocator.dupe(u8, name));
    }

    fn addAur(self: *DependencyCollection, dependency: ParsedDependency) !void {
        for (self.aur.items) |existing| if (std.mem.eql(u8, existing.name, dependency.name)) return;
        try self.aur.append(self.allocator, try dependency_resolver.cloneDependency(self.allocator, dependency));
    }
};

const CloneIdentity = struct {
    package_base: []u8,
    package_names: [][]u8,

    fn init(allocator: std.mem.Allocator, package_base: []const u8, package_names: []const []u8) !CloneIdentity {
        const owned_base = try allocator.dupe(u8, package_base);
        errdefer allocator.free(owned_base);
        var owned_names: std.ArrayList([]u8) = .empty;
        errdefer {
            for (owned_names.items) |name| allocator.free(name);
            owned_names.deinit(allocator);
        }
        for (package_names) |name| try owned_names.append(allocator, try allocator.dupe(u8, name));
        return .{
            .package_base = owned_base,
            .package_names = try owned_names.toOwnedSlice(allocator),
        };
    }

    fn deinit(self: *CloneIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.package_base);
        for (self.package_names) |name| allocator.free(name);
        allocator.free(self.package_names);
        self.* = undefined;
    }
};

fn cloneIdentityMatches(package_base: []const u8, package_names: []const []const u8, installed_name: []const u8) bool {
    if (std.mem.eql(u8, package_base, installed_name)) return true;
    for (package_names) |name| if (std.mem.eql(u8, name, installed_name)) return true;
    return false;
}

fn parseAurGitRemote(allocator: std.mem.Allocator, remote: []const u8) !?[]u8 {
    const prefix = "https://aur.archlinux.org/";
    if (!std.mem.startsWith(u8, remote, prefix)) return null;
    var package_base = std.mem.trim(u8, remote[prefix.len..], " /\t\r\n");
    if (std.mem.endsWith(u8, package_base, ".git")) package_base = package_base[0 .. package_base.len - 4];
    if (package_base.len == 0) return null;
    return @as(?[]u8, try allocator.dupe(u8, package_base));
}

fn isVcsPackage(package_name: []const u8) bool {
    for ([_][]const u8{ "-git", "-svn", "-hg", "-bzr", "-darcs", "-cvs" }) |suffix|
        if (endsWithIgnoreCase(package_name, suffix)) return true;
    return false;
}

fn hasNoBinRemapSuffix(package_name: []const u8) bool {
    return endsWithIgnoreCase(package_name, "-bin") or isVcsPackage(package_name);
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    return value.len >= suffix.len and std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

fn containsUpdate(updates: []const models.Update, name: []const u8) bool {
    for (updates) |update| if (std.mem.eql(u8, update.name, name)) return true;
    return false;
}

fn findPackage(packages: []const models.Package, name: []const u8) ?*const models.Package {
    for (packages) |*package| if (std.mem.eql(u8, package.name, name)) return package;
    return null;
}

fn containsMutable(values: []const []u8, expected: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, expected)) return true;
    return false;
}

fn containsConst(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, expected)) return true;
    return false;
}

test "PKGBUILD validation combines post-install and homograph findings" {
    var results = try validatePkgbuild(
        std.testing.allocator,
        std.testing.io,
        "pkgname='dеmo'\npkgver=1\npkgrel=1\npost_install() { eval echo bad; }\n",
        null,
    );
    defer results.deinit(std.testing.allocator);
    try std.testing.expect(results.post_install.has_findings);
    try std.testing.expect(results.homograph.has_findings);
    const flattened = try results.flatten(std.testing.allocator);
    defer std.testing.allocator.free(flattened);
    try std.testing.expect(flattened.len >= 2);
}

test "installed AUR metadata uses local version and install reason" {
    const payload =
        \\{"version":5,"type":"info","resultcount":1,"results":[{
        \\"Name":"demo","PackageBase":"demo","Version":"2.0-1"
        \\}]}
    ;
    var response = try models.Response.parse(std.testing.allocator, payload);
    defer response.deinit(std.testing.allocator);
    try applyInstalledState(std.testing.allocator, response.results, &.{.{
        .name = "demo",
        .version = "1.0-1",
        .explicit = true,
    }});
    try std.testing.expectEqualStrings("1.0-1", response.results[0].version);
    try std.testing.expect(response.results[0].explicit);
}

test "AUR update projection compares remote and installed versions" {
    const payload =
        \\{"version":5,"type":"info","resultcount":2,"results":[
        \\{"Name":"newer","PackageBase":"newer","Version":"2.0-1","Description":"update"},
        \\{"Name":"same","PackageBase":"same","Version":"1.0-1"}
        \\]}
    ;
    var response = try models.Response.parse(std.testing.allocator, payload);
    defer response.deinit(std.testing.allocator);
    const updates = try collectVersionUpdates(std.testing.allocator, &.{
        .{ .name = "newer", .version = "1.0-1", .explicit = true },
        .{ .name = "same", .version = "1.0-1", .explicit = false },
    }, response.results);
    defer models.Update.deinitSlice(std.testing.allocator, updates);
    try std.testing.expectEqual(@as(usize, 1), updates.len);
    try std.testing.expectEqualStrings("newer", updates[0].name);
    try std.testing.expectEqualStrings("1.0-1", updates[0].version);
    try std.testing.expectEqualStrings("2.0-1", updates[0].new_version);
}

test "AUR git remote and VCS suffix parsing mirror the C# manager" {
    const package_base = (try parseAurGitRemote(std.testing.allocator, "https://aur.archlinux.org/split-base.git\n")).?;
    defer std.testing.allocator.free(package_base);
    try std.testing.expectEqualStrings("split-base", package_base);
    try std.testing.expect((try parseAurGitRemote(std.testing.allocator, "ssh://aur@aur.archlinux.org/demo.git")) == null);
    try std.testing.expect(isVcsPackage("demo-GIT"));
    try std.testing.expect(!isVcsPackage("demo"));
    try std.testing.expect(hasNoBinRemapSuffix("demo-bin"));
}

test "helper cache identity recognizes installed split-package members" {
    const package_names = [_][]const u8{ "demo-cli", "demo-ui" };
    try std.testing.expect(cloneIdentityMatches("demo-suite", &package_names, "demo-ui"));
    try std.testing.expect(cloneIdentityMatches("demo-suite", &package_names, "demo-suite"));
    try std.testing.expect(!cloneIdentityMatches("demo-suite", &package_names, "unrelated"));
}

test {
    std.testing.refAllDecls(@This());
}

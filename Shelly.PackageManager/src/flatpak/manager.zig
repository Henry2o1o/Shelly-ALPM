const bindings = @import("bindings.zig");
const std = @import("std");
const remotes = @import("remote_manager.zig");

const flatpak = bindings.libflatpak;
const rawflatpak = bindings.libflatpak.flatpak;

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn install_flatpak(self: Manager, flatpak_id: [:0]const u8, remote_name: [:0]const u8, scope: flatpak.Scope, branch: [:0]const u8, runtime: bool) !bool {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        var installation: ?*rawflatpak.FlatpakInstallation = null;

        if (scope == flatpak.Scope.SYSTEM) {
            installation = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
        } else {
            installation = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        }

        const arch = std.mem.span(rawflatpak.flatpak_get_default_arch());
        const ref_str = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/{s}/{s}",
            .{ if (runtime) "runtime" else "app", flatpak_id, arch, branch },
        );
        defer self.allocator.free(ref_str);

        const ref_string = try self.allocator.dupeZ(u8, ref_str);
        defer self.allocator.free(ref_string);

        const trans_ptr = rawflatpak.flatpak_transaction_new_for_installation(installation, cancellable, &g_error);

        _ = rawflatpak.flatpak_installation_update_remote_sync(installation, remote_name, cancellable, &g_error);

        _ = rawflatpak.flatpak_transaction_add_install(trans_ptr, remote_name, ref_string, null, &g_error);

        //hook up callback
        _ = rawflatpak.g_signal_connect_data(trans_ptr, "new-operation", @ptrCast(&onNewOperation), null, null, 0);
        _ = rawflatpak.g_signal_connect_data(trans_ptr, "ready", @ptrCast(&onReady), null, null, 0);

        const result = rawflatpak.flatpak_transaction_run(trans_ptr, cancellable, &g_error);

        if (g_error) |err| {
            const msg = std.mem.span(err.message);
            std.log.err("flatpak error: {s}", .{msg});
            return error.FlatpakError;
        }

        return result != 0;
    }

    pub fn list_installed_flatpak(self: Manager) ![]flatpak.Flatpak {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        var list: std.ArrayList(flatpak.Flatpak) = .empty;
        errdefer list.deinit(self.allocator);

        var installation = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);

        var installed_refs_ptr = rawflatpak.flatpak_installation_list_installed_refs(installation, cancellable, &g_error);
        var j: usize = 0;
        while (j < installed_refs_ptr.*.len) : (j += 1) {
            const raw: *rawflatpak.FlatpakRef = @ptrCast(@alignCast(installed_refs_ptr.*.pdata[j]));
            try list.append(self.allocator, flatpak.Flatpak.new(raw, flatpak.Scope.SYSTEM));
        }

        installation = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
        installed_refs_ptr = rawflatpak.flatpak_installation_list_installed_refs(installation, cancellable, &g_error);
        j = 0;
        while (j < installed_refs_ptr.*.len) : (j += 1) {
            const raw: *rawflatpak.FlatpakRef = @ptrCast(@alignCast(installed_refs_ptr.*.pdata[j]));
            try list.append(self.allocator, flatpak.Flatpak.new(raw, flatpak.Scope.USER));
        }

        return list.toOwnedSlice(self.allocator);
    }

    pub fn upgrade_flatpaks(self: Manager) !bool {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        const installation_system = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
        const sys_result = try upgrade_installation(self, installation_system);

        const installation_user = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        const user_result = try upgrade_installation(self, installation_user);

        return sys_result and user_result;
    }

    pub fn uninstall_flatpak(self: Manager, flatpak_id: [:0]const u8, scope: flatpak.Scope, remove_unused: bool) !bool {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        var installation: ?*rawflatpak.FlatpakInstallation = null;

        if (scope == flatpak.Scope.SYSTEM) {
            installation = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
        } else {
            installation = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        }

        const trans_ptr = rawflatpak.flatpak_transaction_new_for_installation(installation, cancellable, &g_error);

        const flatpak_struct = try get_ref_id_and_installation(self, flatpak_id, installation);

        const ref_string = try flatpak.refToString(self.allocator, flatpak_struct.ptr);
        defer self.allocator.free(ref_string);

        _ = rawflatpak.flatpak_transaction_add_uninstall(trans_ptr, ref_string, &g_error);

        _ = rawflatpak.g_signal_connect_data(trans_ptr, "new-operation", @ptrCast(&onNewOperation), null, null, 0);
        _ = rawflatpak.g_signal_connect_data(trans_ptr, "ready", @ptrCast(&onReady), null, null, 0);

        const result = rawflatpak.flatpak_transaction_run(trans_ptr, cancellable, &g_error);

        if (remove_unused) {
            _ = try removed_unused(self, installation);
        }

        return result != 0;
    }

    pub fn update_flatpak(self: Manager, flatpak_id: [:0]const u8, scope: flatpak.Scope, commit: ?[:0]const u8) !bool {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        var installation: ?*rawflatpak.FlatpakInstallation = null;

        if (scope == flatpak.Scope.SYSTEM) {
            installation = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
        } else {
            installation = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        }

        const trans_ptr = rawflatpak.flatpak_transaction_new_for_installation(installation, cancellable, &g_error);
        const flatpak_struct = try get_ref_id_and_installation(self, flatpak_id, installation);
        const ref_string = try flatpak.refToString(self.allocator, flatpak_struct.ptr);
        defer self.allocator.free(ref_string);

        const commit_c_safe: ?[:0]u8 = if (commit) |c|
            try self.allocator.dupeZ(u8, c)
        else
            null;
        defer if (commit_c_safe) |c| self.allocator.free(c);

        const commit_ptr: [*c]const u8 = if (commit_c_safe) |c| c.ptr else null;

        _ = rawflatpak.flatpak_transaction_add_update(trans_ptr, ref_string, null, commit_ptr, &g_error);
        _ = rawflatpak.g_signal_connect_data(trans_ptr, "new-operation", @ptrCast(&onNewOperation), null, null, 0);
        _ = rawflatpak.g_signal_connect_data(trans_ptr, "ready", @ptrCast(&onReady), null, null, 0);

        const result = rawflatpak.flatpak_transaction_run(trans_ptr, cancellable, &g_error);

        return result != 0;
    }

    pub fn launch_flatpak(self: Manager, flatpak_id: [:0]const u8) !bool {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        const installation_system = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
        const sys_flatpak: ?flatpak.Flatpak = get_ref_id_and_installation(self, flatpak_id, installation_system) catch null;
        if (sys_flatpak) |sf| {
            const result = rawflatpak.flatpak_installation_launch(installation_system, cStr(sf.id()), cStr(sf.arch()), cStr(sf.branch()), null, cancellable, &g_error);
            if (result != 0) {
                return true;
            }
        }

        const installation_user = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        const user_flatpak: ?flatpak.Flatpak = get_ref_id_and_installation(self, flatpak_id, installation_user) catch null;
        if (user_flatpak) |uf| {
            const result = rawflatpak.flatpak_installation_launch(installation_user, cStr(uf.id()), cStr(uf.arch()), cStr(uf.branch()), null, cancellable, &g_error);
            if (result != 0) {
                return true;
            }
        }

        return false;
    }

    pub fn install_from_ref_flatpak(self: Manager, flatpak_location: [:0]const u8, scope: flatpak.Scope) !bool {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        var installation: ?*rawflatpak.FlatpakInstallation = null;
        if (scope == flatpak.Scope.SYSTEM) {
            installation = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
        } else {
            installation = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        }
        if (installation == null) {
            if (g_error) |e| std.debug.print("failed to create installation: {s}\n", .{e.*.message});
            return error.InstallationCreateFailed;
        }

        const ref_data = try self.readRefBytes(flatpak_location);
        defer self.allocator.free(ref_data);

        const g_bytes_ptr = rawflatpak.g_bytes_new(ref_data.ptr, ref_data.len);
        defer rawflatpak.g_bytes_unref(g_bytes_ptr);

        const trans_ptr = rawflatpak.flatpak_transaction_new_for_installation(installation, cancellable, &g_error);
        if (trans_ptr == null) {
            if (g_error) |e| std.debug.print("failed to create transaction: {s}\n", .{e.*.message});
            return error.TransactionCreateFailed;
        }

        const added = rawflatpak.flatpak_transaction_add_install_flatpakref(trans_ptr, g_bytes_ptr, &g_error);
        if (added == 0) {
            if (g_error) |e| std.debug.print("failed to add flatpakref to transaction: {s}\n", .{e.*.message});
            return error.AddInstallFailed;
        }

        _ = rawflatpak.g_signal_connect_data(trans_ptr, "new-operation", @ptrCast(&onNewOperation), null, null, 0);
        _ = rawflatpak.g_signal_connect_data(trans_ptr, "ready", @ptrCast(&onReady), null, null, 0);

        const result = rawflatpak.flatpak_transaction_run(trans_ptr, cancellable, &g_error);
        if (result == 0) {
            if (g_error) |e| std.debug.print("transaction run failed: {s}\n", .{e.*.message});
            return false;
        }

        return true;
    }

    pub fn install_from_bundle_flatpak(_: Manager, flatpak_location: [:0]const u8, scope: flatpak.Scope) !bool {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        var installation: ?*rawflatpak.FlatpakInstallation = null;
        if (scope == flatpak.Scope.SYSTEM) {
            installation = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
        } else {
            installation = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        }
        if (installation == null) {
            if (g_error) |e| std.debug.print("failed to create installation: {s}\n", .{e.*.message});
            return error.InstallationCreateFailed;
        }

        const file_ptr = rawflatpak.g_file_new_for_path(flatpak_location);

        const trans_ptr = rawflatpak.flatpak_transaction_new_for_installation(installation, cancellable, &g_error);
        if (trans_ptr == null) {
            if (g_error) |e| std.debug.print("failed to create transaction: {s}\n", .{e.*.message});
            return error.TransactionCreateFailed;
        }

        const added = rawflatpak.flatpak_transaction_add_install_bundle(trans_ptr, file_ptr, null, &g_error);
        if (added == 0) {
            if (g_error) |e| std.debug.print("failed to add flatpakref to transaction: {s}\n", .{e.*.message});
            return error.AddInstallFailed;
        }

        _ = rawflatpak.g_signal_connect_data(trans_ptr, "new-operation", @ptrCast(&onNewOperation), null, null, 0);
        _ = rawflatpak.g_signal_connect_data(trans_ptr, "ready", @ptrCast(&onReady), null, null, 0);

        const result = rawflatpak.flatpak_transaction_run(trans_ptr, cancellable, &g_error);
        if (result == 0) {
            if (g_error) |e| std.debug.print("transaction run failed: {s}\n", .{e.*.message});
            return false;
        }

        return true;
    }

    pub fn search_remote_refs_flatpak(self: Manager, query: [:0]const u8) ![]flatpak.Flatpak {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        var list: std.ArrayList(flatpak.Flatpak) = .empty;
        errdefer list.deinit(self.allocator);

        const installation_system = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
        const sys_result = try get_remote_refs_by_query(self, query, flatpak.Scope.SYSTEM, installation_system);
        defer self.allocator.free(sys_result);
        try list.appendSlice(self.allocator, sys_result);

        const installation_user = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        const user_result = try get_remote_refs_by_query(self, query, flatpak.Scope.USER, installation_user);
        defer self.allocator.free(user_result);
        try list.appendSlice(self.allocator, user_result);

        return list.toOwnedSlice(self.allocator);
    }

    pub fn get_flatpaks_from_remote(self: Manager, remote_name: [:0]const u8) ![]flatpak.Flatpak {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        var list: std.ArrayList(flatpak.Flatpak) = .empty;
        errdefer list.deinit(self.allocator);

        const remote_manager = remotes.RemoteManager{ .allocator = self.allocator, .io = self.io };
        const configured_remotes = try remote_manager.listRemotesWithDetails();
        defer self.allocator.free(configured_remotes);

        //safe guards against calling in with differently named remotes that wont exist
        for (configured_remotes) |remote| {
            if (remote.name()) |name| {
                if (std.mem.eql(u8, name, remote_name) and !remote.disabled() and remote.get_scope() == flatpak.Scope.SYSTEM) {
                    //collect sys
                    const installation_system = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
                    const sys_result = try get_all_flatpaks_by_remote(self, remote_name, flatpak.Scope.USER, installation_system);
                    defer self.allocator.free(sys_result);
                    try list.appendSlice(self.allocator, sys_result);
                }
            }

            if (remote.name()) |name| {
                if (std.mem.eql(u8, name, remote_name) and !remote.disabled() and remote.get_scope() == flatpak.Scope.USER) {
                    //collect user
                    const installation_user = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
                    const user_result = try get_all_flatpaks_by_remote(self, remote_name, flatpak.Scope.USER, installation_user);
                    defer self.allocator.free(user_result);
                    try list.appendSlice(self.allocator, user_result);
                }
            }
        }

        return list.toOwnedSlice(self.allocator);
    }

    fn get_all_flatpaks_by_remote(self: Manager, remote: [:0]const u8, scope: flatpak.Scope, installation: [*c]rawflatpak.FlatpakInstallation) ![]flatpak.Flatpak {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        var list: std.ArrayList(flatpak.Flatpak) = .empty;
        errdefer list.deinit(self.allocator);

        const updated = rawflatpak.flatpak_installation_update_remote_sync(installation, remote, cancellable, &g_error);
        if (updated == 0) {
            if (g_error) |e| std.debug.print("failed to update remote cache: {s}\n", .{e.*.message});
            return error.RemoteUpdateFailed;
        }

        const refs_ptr = rawflatpak.flatpak_installation_list_remote_refs_sync_full(installation, remote, 1, cancellable, &g_error);
        if (refs_ptr == null) {
            if (g_error) |e| std.debug.print("failed to list remote refs: {s}\n", .{e.*.message});
            return error.ListRemoteRefsFailed;
        }

        var j: usize = 0;
        while (j < refs_ptr.*.len) : (j += 1) {
            const raw: *rawflatpak.FlatpakRef = @ptrCast(@alignCast(refs_ptr.*.pdata[j]));
            const flatpak_ref = flatpak.Flatpak.new(raw, scope);
            try list.append(self.allocator, flatpak_ref);
        }

        return list.toOwnedSlice(self.allocator);
    }

    fn get_remote_refs_by_query(self: Manager, query: [:0]const u8, scope: flatpak.Scope, installation: [*c]rawflatpak.FlatpakInstallation) ![]flatpak.Flatpak {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        const remote_manager = remotes.RemoteManager{ .allocator = self.allocator, .io = self.io };
        const configured_remotes = try remote_manager.listRemotesWithDetails();
        defer self.allocator.free(configured_remotes);

        var list: std.ArrayList(flatpak.Flatpak) = .empty;
        errdefer list.deinit(self.allocator);

        for (configured_remotes) |remote| {
            if (remote.get_scope() == scope and remote.disabled() != true) {
                const refs_ptr = rawflatpak.flatpak_installation_list_remote_refs_sync_full(installation, cStr(remote.name()), 1, cancellable, &g_error);
                if (refs_ptr == null) {
                    if (g_error) |e| std.debug.print("failed to list remote refs: {s}\n", .{e.*.message});
                    return error.ListRemoteRefsFailed;
                }

                var j: usize = 0;
                while (j < refs_ptr.*.len) : (j += 1) {
                    const raw: *rawflatpak.FlatpakRef = @ptrCast(@alignCast(refs_ptr.*.pdata[j]));
                    const flatpak_ref = flatpak.Flatpak.new(raw, scope);
                    const matches_id = if (flatpak_ref.id()) |id| containsIgnoreCase(id, query) else false;

                    if (matches_id) {
                        try list.append(self.allocator, flatpak_ref);
                    }
                }
            }
        }
        return list.toOwnedSlice(self.allocator);
    }

    fn readRefBytes(self: Manager, flatpak_location: []const u8) ![]u8 {
        const ref_data = try std.Io.Dir.readFileAlloc(
            std.Io.Dir.cwd(),
            self.io,
            flatpak_location,
            self.allocator,
            .unlimited,
        );
        return ref_data;
    }

    fn get_ref_id_and_installation(_: Manager, flatpak_id: [:0]const u8, installation: [*c]rawflatpak.FlatpakInstallation) !flatpak.Flatpak {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        const ref_ptrs = rawflatpak.flatpak_installation_list_installed_refs(installation, cancellable, &g_error);
        var j: usize = 0;
        while (j < ref_ptrs.*.len) : (j += 1) {
            const raw: *rawflatpak.FlatpakRef = @ptrCast(@alignCast(ref_ptrs.*.pdata[j]));
            const flatpak_struct = flatpak.Flatpak.new(raw, flatpak.Scope.SYSTEM);
            const id = flatpak_struct.id() orelse return error.FlatpakError;
            if (std.mem.eql(u8, id, flatpak_id)) {
                return flatpak_struct;
            }
        }

        return error.FlatpakError;
    }

    fn upgrade_installation(self: Manager, installation: [*c]rawflatpak.FlatpakInstallation) !bool {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        const update_refs_ptr = rawflatpak.flatpak_installation_list_installed_refs_for_update(installation, cancellable, &g_error);
        const trans_ptr = rawflatpak.flatpak_transaction_new_for_installation(installation, cancellable, &g_error);

        var j: usize = 0;
        while (j < update_refs_ptr.*.len) : (j += 1) {
            const raw: *rawflatpak.FlatpakRef = @ptrCast(@alignCast(update_refs_ptr.*.pdata[j]));
            const ref_string = try flatpak.refToString(self.allocator, raw);
            defer self.allocator.free(ref_string);

            _ = rawflatpak.flatpak_transaction_add_update(trans_ptr, ref_string, null, null, &g_error);
        }

        _ = rawflatpak.g_signal_connect_data(trans_ptr, "new-operation", @ptrCast(&onNewOperation), null, null, 0);
        _ = rawflatpak.g_signal_connect_data(trans_ptr, "ready", @ptrCast(&onReady), null, null, 0);

        const result = rawflatpak.flatpak_transaction_run(trans_ptr, cancellable, &g_error);
        return result != 0;
    }

    fn removed_unused_deps(self: Manager) !bool {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        const installation_system = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
        const sys_result = try removed_unused(self, installation_system);

        const installation_user = rawflatpak.flatpak_installation_new_user(cancellable, &g_error);
        const user_result = try removed_unused(self, installation_user);

        return sys_result and user_result;
    }

    fn removed_unused(self: Manager, installation: [*c]rawflatpak.FlatpakInstallation) !bool {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        var g_error: ?*rawflatpak.GError = null;
        defer rawflatpak.g_object_unref(cancellable);
        defer if (g_error) |e| rawflatpak.g_error_free(e);

        const arch = std.mem.span(rawflatpak.flatpak_get_default_arch());
        const unused_ref_ptrs = rawflatpak.flatpak_installation_list_unused_refs(installation, arch, cancellable, &g_error);
        const trans_ptr = rawflatpak.flatpak_transaction_new_for_installation(installation, cancellable, &g_error);

        var j: usize = 0;
        while (j < unused_ref_ptrs.*.len) : (j += 1) {
            const raw: *rawflatpak.FlatpakRef = @ptrCast(@alignCast(unused_ref_ptrs.*.pdata[j]));
            const ref_string = try flatpak.refToString(self.allocator, raw);
            defer self.allocator.free(ref_string);
            _ = rawflatpak.flatpak_transaction_add_uninstall(trans_ptr, ref_string, &g_error);
        }

        const result = rawflatpak.flatpak_transaction_run(trans_ptr, cancellable, &g_error);
        return result != 0;
    }

    fn onProgressChanged(
        progress: *rawflatpak.FlatpakTransactionProgress,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const percent = rawflatpak.flatpak_transaction_progress_get_progress(progress);
        std.log.info("progress: {d}%", .{percent});
    }

    fn onNewOperation(
        _: *rawflatpak.FlatpakTransaction,
        _: *rawflatpak.FlatpakTransactionOperation,
        progress: *rawflatpak.FlatpakTransactionProgress,
        _: ?*anyopaque,
    ) callconv(.c) void {
        _ = rawflatpak.g_signal_connect_data(progress, "changed", @ptrCast(&onProgressChanged), null, null, 0);
    }

    fn onReady(
        _: *rawflatpak.FlatpakTransaction,
        _: ?*anyopaque,
    ) callconv(.c) rawflatpak.gboolean {
        return 1;
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;

        var i: usize = 0;
        while (i <= haystack.len - needle.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) {
                return true;
            }
        }
        return false;
    }

    pub fn cStr(s: ?[:0]const u8) [*c]const u8 {
        return if (s) |str| str.ptr else null;
    }
};

//disabled until uninstall is added.
test "test installFlatpak" {
    // const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
    // const result = try manager.install_app("it.mijorus.gearlever", "flathub", flatpak.Scope.SYSTEM, "stable", false);
    // try std.testing.expect(result);
}

test "test listFlatpak" {
    // const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
    // const result = try manager.installed_flatpaks();
    // defer std.testing.allocator.free(result);
    // try std.testing.expectEqualStrings("app.drey.Elastic", result[0].name().?);
}

// test "test removeUnused" {
//     const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
//     const result = try manager.removed_unused_deps();
//     try std.testing.expect(result);
// }

// test "test upgrade" {
//     const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
//     const result = try manager.upgrade_flatpaks();
//     try std.testing.expect(result);
// }

// test "test flatById" {
//     const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
//     var g_error: ?*rawflatpak.GError = null;
//     defer rawflatpak.g_object_unref(cancellable);
//     defer if (g_error) |e| rawflatpak.g_error_free(e);

//     const installation_system = rawflatpak.flatpak_installation_new_system(cancellable, &g_error);
//     const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
//     const result = try manager.get_ref_id_and_installation("app.drey.Elastic", installation_system);
//     try std.testing.expectEqualStrings("app.drey.Elastic", result.id().?);
// }

// test "test removeflatpak" {
//     const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
//     const result = try manager.uninstall_flatpak("app.drey.Elastic", flatpak.Scope.SYSTEM, false);
//     try std.testing.expect(result);
// }

// test "test flatpakupdate" {
//     const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
//     const result = try manager.update_flatpak("it.mijorus.gearlever", flatpak.Scope.SYSTEM, "5f08f18ed0e02d1a728ba89403240fdeb5235d7453bbc77c7aa56bea63b74e77");
//     try std.testing.expect(result);
// }

test "test laucnhFlatpak" {
    const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try manager.launch_flatpak("it.x.gearlever");
    try std.testing.expect(!result);
}

test "test searchremoteref" {
    const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try manager.search_remote_refs_flatpak("spotify");
    defer std.testing.allocator.free(result);
    try std.testing.expect(result.len > 0);
}

test "test getAllFlatpaksFromRemotes" {
    const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
    const result = try manager.get_flatpaks_from_remote("flathub");
    defer std.testing.allocator.free(result);
    try std.testing.expect(result.len > 500);
}

// test "test installfromref" {
//     const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
//     const result = try manager.install_from_ref_flatpak("/home/caro/Downloads/org.gimp.GIMP.flatpakref", flatpak.Scope.USER);
//     try std.testing.expect(result);
// }

// TODO: revisit bundles later
// test "test installfrombundle" {
//     const manager = Manager{ .allocator = std.testing.allocator, .io = std.testing.io };
//     const result = try manager.install_from_bundle_flatpak("/home/caro/Downloads/deadlock-mod-manager.flatpak", flatpak.Scope.USER);
//     try std.testing.expect(result);
// }

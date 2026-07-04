const bindings = @import("bindings.zig");
const std = @import("std");

const flatpak = bindings.libflatpak;
const rawflatpak = bindings.libflatpak.flatpak;

pub const Manager = struct {
    allocator: std.mem.Allocator,

    pub fn listRemotesWithDetails(self: Manager) ![]flatpak.Remote {
        const cancellable: *rawflatpak.GCancellable = rawflatpak.g_cancellable_new();
        const g_error: *rawflatpak.GError = rawflatpak.g_error_new();
        defer rawflatpak.g_object_unref(cancellable);
        defer rawflatpak.g_error_free(g_error);

        //TODO: Maybe make a shared function but who cares ill mention bob ross in 3 months after our 4th refactor :)

        const system_installations = rawflatpak.flatpak_get_system_installations(cancellable, g_error);
        if (g_error != null) {
            return;
        }
        const ptr_remotes = rawflatpak.flatpak_installation_list_remotes(system_installations, cancellable, g_error);
        if (g_error != null) {
            return;
        }

        var list: std.ArrayList(flatpak.Remote) = .empty;
        errdefer list.deinit(self.allocator);

        var it = std.mem.Iterator(ptr_remotes);
        while (it.next()) |remote| {
            list.append(flatpak.Remote.new(remote), flatpak.Scope.SYSTEM);
        }

        const user_installations = rawflatpak.flatpak_get_user_installations(cancellable, g_error);
        if (g_error != null) {
            return;
        }

        const ptr_user_remotes = rawflatpak.flatpak_installation_list_remotes(user_installations, cancellable, g_error);
        if (g_error != null) {
            return;
        }

        var it_user = std.mem.Iterator(ptr_user_remotes);
        while (it_user.next()) |remote| {
            list.append(flatpak.Remote.new(remote), flatpak.Scope.USER);
        }

        return list.toOwnedSlice(self.allocator);
    }

    test "test listRemotesWithDetails" {
        const manager: Manager = @This();
        const x = manager.listRemotesWithDetails();
        try std.testing.expectEqual("flathub", x[0].Name);
    }
};

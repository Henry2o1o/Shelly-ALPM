const std = @import("std");

pub const libflatpak = struct {
    pub const flatpak = @import("flatpak");

    pub fn str(ptr: [*c]const u8) ?[:0]const u8 {
        if (ptr == null) return null;
        return std.mem.span(ptr);
    }

    pub const Scope = enum(i32) {
        SYSTEM = 0,
        USER = 1,
    };

    pub const Remote = struct {
        ptr: *flatpak.FlatpakRemote,
        scope: Scope,

        pub fn new(ptr: *flatpak.FlatpakRemote, scope: Scope) Remote {
            return .{ .ptr = ptr, .scope = scope };
        }

        pub fn name(self: Remote) ?[:0]const u8 {
            return str(flatpak.flatpak_remote_get_name(self.ptr));
        }

        pub fn url(self: Remote) ?[:0]const u8 {
            return str(flatpak.flatpak_remote_get_url(self.ptr));
        }

        pub fn get_scope(self: Remote) Scope {
            return self.scope;
        }
    };
};

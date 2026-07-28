const std = @import("std");

pub const libostree = struct {
    pub const ostree = @import("ostree");

    pub fn str(ptr: [*c]const u8) ?[:0]const u8 {
        if (ptr == null) return null;
        return std.mem.span(ptr);
    }

    pub const Repo = struct {
        ptr: *ostree.OstreeRepo,

        pub fn init(ptr: *ostree.OstreeRepo) Repo {
            return .{
                .ptr = ptr,
            };
        }

        pub fn path(self: Repo) ?*ostree.GFile {
            return ostree.ostree_repo_get_path(self.ptr);
        }
        
    };
};
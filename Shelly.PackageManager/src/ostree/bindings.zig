const std = @import("std");

// Methods to port over for Flatpak Repair
// --
// Repo
// --
// ostree_repo_fsck_object()
// ostree_repo_delete_object()
// ostree_repo_load_variant()
// ostree_repo_load_commit()
// ostree_repo_list_refs()
// ostree_repo_set_ref_immediate()
// ostree_repo_mark_commit_partial_reason()
// --
// Commit traversal
// ostree_repo_commit_traverse_iter_init_dirtree()
// ostree_repo_commit_traverse_iter_next()
// ostree_repo_commit_traverse_iter_get_file()
// ostree_repo_commit_traverse_iter_get_dir()
// --
// Helpers
// --
// ostree_parse_refspec()
// ostree_checksum_from_bytes()
// ostree_checksum_bytes_peek()
// ostree_object_name_serialize()
// ostree_object_type_to_string()
// 

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
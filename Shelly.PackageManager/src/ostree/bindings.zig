const std = @import("std");

// Methods to port over for Flatpak Repair
// --
// Repo
// --
// ostree_repo_fsck_object() x
// ostree_repo_delete_object() x
// ostree_repo_load_variant() x
// ostree_repo_load_commit() x
// ostree_repo_list_refs() x
// ostree_repo_set_ref_immediate() x
// ostree_repo_mark_commit_partial_reason() x
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

    pub const OstreeError = error{
        NotFound,
        InvalidObject,
        IoError,
        Unknown,
    };

    pub const CommitResult = struct {
        variant: *ostree.GVariant,
        state: ostree.OstreeRepoCommitState,
    };
    
    fn mapError(err: ?*ostree.GError) OstreeError!void {
        if (err == null)
            return error.Unknown;
    
        if (ostree.g_error_matches(err, ostree.G_IO_ERROR, ostree.G_IO_ERROR_NOT_FOUND) != 0)
            return error.NotFound;
    
        if (ostree.g_error_matches(err, ostree.G_IO_ERROR, ostree.G_IO_ERROR_INVALID_DATA) != 0)
            return error.InvalidObject;
    
        if (ostree.g_error_matches(err, ostree.G_IO_ERROR, ostree.G_IO_ERROR_FAILED) != 0)
            return error.IoError;
    
        return error.Unknown;
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

        pub fn fsckObject(
            self: Repo, 
            object_type: ostree.OstreeObjectType, 
            checksum: [:0]const u8) OstreeError!void {

                var err: ?*ostree.GError = null;

                defer if (err) |e| ostree.g_error_free(e);

                const ok = ostree.ostree_repo_fsck_object(
                    self.ptr,
                    object_type,
                    checksum.ptr,
                    null,
                    &err,
                );
                if(ok == 0) try mapError(err);
            }    

        pub fn deleteObject(
            self: Repo, 
            object_type: ostree.OstreeObjectType, 
            checksum: [:0]const u8) OstreeError!void {

                var err: ?*ostree.GError = null;

                defer if (err) |e| ostree.g_error_free(e);

                const ok = ostree.ostree_repo_delete_object(
                    self.ptr,
                    object_type,
                    checksum.ptr,
                    null,
                    &err,
                );
                if(ok == 0) try mapError(err);
            }       

        pub fn loadVariant(
            self: Repo, 
            object_type: ostree.OstreeObjectType, 
            checksum: [:0]const u8) OstreeError!*ostree.GVariant {

                var variant: ?*ostree.GVariant = null;
                var err: ?*ostree.GError = null;

                defer if (err) |e| ostree.g_error_free(e);

                const ok = ostree.ostree_repo_load_variant(
                    self.ptr,
                    object_type,
                    checksum.ptr,
                    &variant,
                    &err,
                );
                if(ok == 0) try mapError(err);
                return variant orelse error.Unknown;
            }       

        pub fn loadCommit(
            self: Repo,
            checksum: [:0]const u8) OstreeError!CommitResult {
                var variant: ?*ostree.GVariant = null;
                var state: ostree.OstreeRepoCommitState = 0;
                var err: ?*ostree.GError = null;
        
                defer if (err) |e| ostree.g_error_free(e);
        
                const ok = ostree.ostree_repo_load_commit(
                    self.ptr,
                    checksum.ptr,
                    &variant,
                    &state,
                    &err,
                );
                if (ok == 0) try mapError(err);
                return .{
                    .variant = variant orelse return error.Unknown,
                    .state = state,
                };
            }

        pub fn listRefs(
            self: Repo,
            refspec_prefix: ?[:0]const u8) OstreeError!*ostree.GHashTable {
                var refs: ?*ostree.GHashTable = null;
                var err: ?*ostree.GError = null;
        
                defer if (err) |e| ostree.g_error_free(e);
        
                const ok = ostree.ostree_repo_list_refs(
                    self.ptr,
                    if (refspec_prefix) |p| p.ptr else null,
                    &refs,
                    null,
                    &err,
                );
                if (ok == 0) try mapError(err);
                return refs orelse error.Unknown;
            }              
          
        pub fn setRefImmediate(
            self: Repo,
            remote: ?[:0]const u8,
            ref: [:0]const u8,
            checksum: [:0]const u8) OstreeError!void {
                var err: ?*ostree.GError = null;
                defer if (err) |e| ostree.g_error_free(e);
        
                const ok = ostree.ostree_repo_set_ref_immediate(
                    self.ptr,
                    if (remote) |r| r.ptr else null,
                    ref.ptr,
                    checksum.ptr,
                    null,
                    &err,
                );
                if (ok == 0) try mapError(err);
            }
        
        pub fn markCommitPartialReason(
            self: Repo,
            checksum: [:0]const u8,
            is_partial: bool,
            in_state: ostree.OstreeRepoCommitState) OstreeError!void {
                var err: ?*ostree.GError = null;
                defer if (err) |e| ostree.g_error_free(e);
        
                const ok = ostree.ostree_repo_mark_commit_partial_reason(
                    self.ptr,
                    checksum.ptr,
                    if (is_partial) 1 else 0,
                    in_state,
                    &err,
                );
                if (ok == 0) try mapError(err);
            }        
        };
    };

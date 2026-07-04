const std = @import("std");

pub const libalpm = struct {
    // Raw libalpm symbols come from the committed translate-c dump (`alpm.zig`),
    // exposed as the `alpm_c` module by build.zig.
    pub const alpm = @import("alpm_c");

    pub fn str(ptr: [*c]const u8) ?[:0]const u8 {
        if (ptr == null) return null;
        return std.mem.span(ptr);
    }

    pub const Handle = ?*alpm.alpm_handle_t;
    pub const Database = ?*alpm.alpm_db_t;
    pub const DatabaseList = ?*alpm.alpm_list_t;
    pub const List = ?*alpm.alpm_list_t;

    pub const Error = enum(i32) { Ok = 0, Memory, System, BadPerms, NotAFile, NotADir, WrongArgs, DiskSpace, HandleNull, HandleNotNull, HandleLock, DbOpen, DbCreate, DbNull, DbNotNull, DbNotFound, DbInvalid, DbInvalidSig, DbVersion, DbWrite, DbRemove, ServerBadUrl, ServerNone, TransNotNull, TransNull, TransDupTarget, TransDupFilename, TransNotInitialized, TransNotPrepared, TransAbort, TransType, TransNotLocked, TransHookFailed, PkgNotFound, PkgIgnored, PkgInvalid, PkgInvalidChecksum, PkgInvalidSig, PkgMissingSig, PkgOpen, PkgCantRemove, PkgInvalidName, PkgInvalidArch, SigMissing, SigInvalid, UnsatisfiedDeps, ConflictingDeps, FileConflicts, DownloadFailed, Gpgme, ExternalDownload, SandboxFailed };

    pub const Config = struct {
        cache_dir: ?[:0]const u8 = null,
        db_dir: ?[:0]const u8 = null,
        log_file: ?[:0]const u8 = null,
        root_dir: ?[:0]const u8 = null,
        mirrorlist: ?[:0]const u8 = null,
        gpg_dir: ?[:0]const u8 = null,
        lock_file: ?[:0]const u8 = null,
        gpg_args: ?[:0]const u8 = null,
        use_delta: bool = false,
        download_only: bool = false,
        SigLevel: ?[:0]const u8 = null,
        LocalFileSigLevel: ?[:0]const u8 = null,
        RemoteFileSigLevel: ?[:0]const u8 = null,
        IgnorePkg: ?[:0]const u8 = null,
        IgnoreGroup: ?[:0]const u8 = null,
        Architecture: ?[:0]const u8 = null,
        CheckSpace: bool = true,
        VerbosePkgLists: bool = true,
        Color: bool = true,
        I686: ?[:0]const u8 = null,
        UseSyslog: bool = false,
        TerminalColors: ?[:0]const u8 = null,
        Umbrella: ?[:0]const u8 = null,
        KeyringDir: ?[:0]const u8 = null,
        Keyring: ?[:0]const u8 = null,
        DropPermissions: bool = true,
        NoUpgrade: ?[:0]const u8 = null,
    };

    pub const Package = struct {
        ptr: *alpm.aplm_pkg_t,

        pub fn from(data: ?*anyopaque) Package {
            return .{ .ptr = @ptrCast(@alignCast(data.?)) };
        }

        pub fn name(self: Package) ?[:0]const u8 {
            return str(alpm.alpm_pkg_get_name(self.ptr));
        }

        pub fn version(self: Package) ?[:0]const u8 {
            return str(alpm.alpm_pkg_get_version(self.ptr));
        }
    };
};

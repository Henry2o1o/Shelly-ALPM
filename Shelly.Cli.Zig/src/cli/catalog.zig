const std = @import("std");

pub const Type = struct {
    name: []const u8,
    code: ?u8,
    description: []const u8,
};

pub const types = [_]Type{
    .{ .name = "standard", .code = 'S', .description = "Arch Linux repository and local ALPM packages" },
    .{ .name = "aur", .code = 'A', .description = "Arch User Repository packages" },
    .{ .name = "flatpak", .code = 'F', .description = "Flatpak applications and runtimes" },
    .{ .name = "appimage", .code = 'I', .description = "AppImage applications" },
    .{ .name = "utility", .code = 'U', .description = "System and Shelly utility operations" },
    .{ .name = "config", .code = 'C', .description = "Shelly configuration" },
    .{ .name = "keyring", .code = 'K', .description = "Pacman keyring operations" },
    .{ .name = "all", .code = 'X', .description = "All supported package backends" },
};

pub const Variant = struct {
    source_path: []const u8,
    action: []const u8,
    type_name: []const u8,
    action_code: ?u8,
    type_code: ?u8,
    keyring_action: ?[]const u8 = null,
    default_for_action: bool = false,
    help: Help = .{},
};

pub const HelpText = struct {
    name: []const u8,
    description: []const u8,
};

pub const Help = struct {
    description: ?[]const u8 = null,
    implementation: ?[]const u8 = null,
    arguments: []const HelpText = &.{},
    options: []const HelpText = &.{},
};

// This is the authoritative action/type routing table. The source paths identify
// metadata in the frozen C# snapshot; only the action-first paths are exposed by
// the Zig manifest.
pub const variants = [_]Variant{
    .{
        .source_path = "shelly query",
        .action = "search",
        .type_name = "standard",
        .action_code = 'S',
        .type_code = 'S',
        .help = .{
            .description = "Search ALPM repository and installed packages, or Shelly-managed local binary packages. With a package and no source modifier, show exact package details.",
            .implementation = "Zigalpm.AlpmManager.get_installed_packages / get_available_packages; Zigalpm.LocalManager.getInstalledBinaryPackages for --local",
            .arguments = &.{.{
                .name = "package",
                .description = "Package name or search term; without a source modifier, an exact name opens package details",
            }},
            .options = &.{
                .{ .name = "--repos", .description = "List repositories parsed from pacman.conf and ignore other search modifiers" },
                .{ .name = "--available", .description = "Search packages from the configured ALPM synchronization databases" },
                .{ .name = "--installed", .description = "Search packages from the local ALPM database" },
                .{ .name = "--local", .description = "Search Shelly-managed binary packages installed under /opt/shelly" },
                .{ .name = "--show-hidden", .description = "Include packages hidden by pacman IgnorePkg configuration" },
                .{ .name = "--detail", .description = "Show complete metadata for one exact ALPM package name" },
                .{ .name = "--group", .description = "List package groups or restrict available packages to the requested group" },
            },
        },
    },
    .{ .source_path = "shelly install", .action = "install", .type_name = "standard", .action_code = 'I', .type_code = 'S' },
    .{ .source_path = "shelly upgrade", .action = "upgrade", .type_name = "standard", .action_code = 'U', .type_code = 'S' },
    .{ .source_path = "shelly upgrade-all", .action = "upgrade", .type_name = "all", .action_code = 'U', .type_code = 'X' },
    .{ .source_path = "shelly downgrade", .action = "downgrade", .type_name = "standard", .action_code = 'D', .type_code = 'S' },
    .{ .source_path = "shelly ignore", .action = "ignore", .type_name = "standard", .action_code = 'G', .type_code = 'S' },
    .{ .source_path = "shelly news", .action = "news", .type_name = "standard", .action_code = 'N', .type_code = 'S' },
    .{ .source_path = "shelly cache-clean", .action = "cache-clean", .type_name = "utility", .action_code = 'C', .type_code = 'U' },
    .{ .source_path = "shelly check-updates", .action = "check-updates", .type_name = "utility", .action_code = 'K', .type_code = 'U' },
    .{ .source_path = "shelly list-updates", .action = "list-updates", .type_name = "standard", .action_code = 'P', .type_code = 'S' },
    .{ .source_path = "shelly export", .action = "export", .type_name = "utility", .action_code = 'E', .type_code = 'U' },
    .{ .source_path = "shelly fix-permissions", .action = "fix-permissions", .type_name = "utility", .action_code = 'F', .type_code = 'U' },
    .{ .source_path = "shelly mark", .action = "mark", .type_name = "standard", .action_code = 'M', .type_code = 'S' },
    .{ .source_path = "shelly pacfile", .action = "pacfile", .type_name = "utility", .action_code = null, .type_code = 'U' },
    .{ .source_path = "shelly purify", .action = "purify", .type_name = "standard", .action_code = 'Z', .type_code = 'S' },
    .{ .source_path = "shelly remove", .action = "remove", .type_name = "standard", .action_code = 'R', .type_code = 'S' },
    .{
        .source_path = "shelly sync",
        .action = "sync",
        .type_name = "standard",
        .action_code = 'Y',
        .type_code = 'S',
        .default_for_action = true,
        .help = .{
            .description = "Synchronize the configured ALPM package databases; use --force to refresh databases even when they appear current.",
            .implementation = "Zigalpm.AlpmManager.sync",
            .options = &.{.{
                .name = "--force",
                .description = "Force every configured ALPM package database to refresh",
            }},
        },
    },
    .{ .source_path = "shelly update", .action = "update", .type_name = "standard", .action_code = 'T', .type_code = 'S' },
    .{ .source_path = "shelly docs", .action = "docs", .type_name = "utility", .action_code = null, .type_code = 'U' },
    .{ .source_path = "shelly completions", .action = "completions", .type_name = "utility", .action_code = null, .type_code = 'U' },

    .{ .source_path = "shelly appimage install", .action = "install", .type_name = "appimage", .action_code = 'I', .type_code = 'I' },
    .{ .source_path = "shelly appimage remove", .action = "remove", .type_name = "appimage", .action_code = 'R', .type_code = 'I' },
    .{ .source_path = "shelly appimage list", .action = "list", .type_name = "appimage", .action_code = 'L', .type_code = 'I' },
    .{ .source_path = "shelly appimage upgrade", .action = "upgrade", .type_name = "appimage", .action_code = 'U', .type_code = 'I' },
    .{ .source_path = "shelly appimage sync-meta", .action = "sync-meta", .type_name = "appimage", .action_code = 'Y', .type_code = 'I' },
    .{ .source_path = "shelly appimage list-updates", .action = "list-updates", .type_name = "appimage", .action_code = 'P', .type_code = 'I' },
    .{ .source_path = "shelly appimage configure-updates", .action = "configure-updates", .type_name = "appimage", .action_code = 'C', .type_code = 'I' },
    .{ .source_path = "shelly appimage migrate-manager", .action = "migrate-manager", .type_name = "appimage", .action_code = 'M', .type_code = 'I' },

    .{
        .source_path = "shelly config get",
        .action = "get",
        .type_name = "config",
        .action_code = 'G',
        .type_code = 'C',
        .help = .{ .implementation = "config_manager.Manager.get" },
    },
    .{
        .source_path = "shelly config set",
        .action = "set",
        .type_name = "config",
        .action_code = 'S',
        .type_code = 'C',
        .help = .{ .implementation = "config_manager.Manager.update" },
    },
    .{
        .source_path = "shelly config list",
        .action = "list",
        .type_name = "config",
        .action_code = 'L',
        .type_code = 'C',
        .help = .{ .implementation = "config_manager.Manager.read" },
    },
    .{
        .source_path = "shelly config reset",
        .action = "reset",
        .type_name = "config",
        .action_code = 'R',
        .type_code = 'C',
        .help = .{ .implementation = "config_manager.Manager.reset" },
    },
    .{
        .source_path = "shelly config parallel",
        .action = "parallel",
        .type_name = "config",
        .action_code = 'P',
        .type_code = 'C',
        .help = .{ .implementation = "config_manager.Manager.update(\"ParallelDownloadCount\", value)" },
    },

    .{ .source_path = "shelly aur install", .action = "install", .type_name = "aur", .action_code = 'I', .type_code = 'A' },
    .{ .source_path = "shelly aur install-version", .action = "install-version", .type_name = "aur", .action_code = 'V', .type_code = 'A' },
    .{ .source_path = "shelly aur remove", .action = "remove", .type_name = "aur", .action_code = 'R', .type_code = 'A' },
    .{ .source_path = "shelly aur update", .action = "update", .type_name = "aur", .action_code = 'T', .type_code = 'A' },
    .{ .source_path = "shelly aur upgrade", .action = "upgrade", .type_name = "aur", .action_code = 'U', .type_code = 'A' },
    .{ .source_path = "shelly aur list", .action = "list", .type_name = "aur", .action_code = 'L', .type_code = 'A' },
    .{ .source_path = "shelly aur list-updates", .action = "list-updates", .type_name = "aur", .action_code = 'P', .type_code = 'A' },
    .{
        .source_path = "shelly aur search",
        .action = "search",
        .type_name = "aur",
        .action_code = 'S',
        .type_code = 'A',
        .help = .{
            .description = "Search the AUR RPC through the native Zig package manager; optionally append high-confidence standard repository matches.",
            .implementation = "Zigalpm.AurManager.searchPackages; Zigalpm.AlpmManager.get_available_packages when --standard is passed",
            .arguments = &.{.{
                .name = "query",
                .description = "One or more words joined and passed to the AUR RPC package search",
            }},
            .options = &.{.{
                .name = "--standard",
                .description = "Append high-confidence standard ALPM repository matches to the AUR results",
            }},
        },
    },
    .{ .source_path = "shelly aur search-pkgbuild", .action = "search-pkgbuild", .type_name = "aur", .action_code = 'B', .type_code = 'A' },

    .{
        .source_path = "shelly keyring",
        .action = "init",
        .type_name = "keyring",
        .action_code = 'I',
        .type_code = 'K',
        .keyring_action = "init",
        .help = .{ .description = "Initialize the pacman keyring." },
    },
    .{
        .source_path = "shelly keyring",
        .action = "list",
        .type_name = "keyring",
        .action_code = 'L',
        .type_code = 'K',
        .keyring_action = "list",
        .help = .{ .description = "List keys in the pacman keyring." },
    },
    .{
        .source_path = "shelly keyring",
        .action = "refresh",
        .type_name = "keyring",
        .action_code = 'R',
        .type_code = 'K',
        .keyring_action = "refresh",
        .help = .{ .description = "Refresh pacman keyring keys from the configured keyserver." },
    },
    .{
        .source_path = "shelly keyring",
        .action = "lsign",
        .type_name = "keyring",
        .action_code = 'S',
        .type_code = 'K',
        .keyring_action = "lsign",
        .help = .{ .description = "Locally sign one or more keys in the pacman keyring." },
    },
    .{
        .source_path = "shelly keyring",
        .action = "populate",
        .type_name = "keyring",
        .action_code = 'P',
        .type_code = 'K',
        .keyring_action = "populate",
        .help = .{ .description = "Populate the pacman keyring with the default distribution keys." },
    },
    .{
        .source_path = "shelly keyring",
        .action = "recv",
        .type_name = "keyring",
        .action_code = 'V',
        .type_code = 'K',
        .keyring_action = "recv",
        .help = .{ .description = "Receive one or more keys from the configured keyserver." },
    },

    .{ .source_path = "shelly flatpak install", .action = "install", .type_name = "flatpak", .action_code = 'I', .type_code = 'F' },
    .{ .source_path = "shelly flatpak update", .action = "update", .type_name = "flatpak", .action_code = 'T', .type_code = 'F' },
    .{ .source_path = "shelly flatpak list", .action = "list", .type_name = "flatpak", .action_code = 'L', .type_code = 'F' },
    .{ .source_path = "shelly flatpak list-updates", .action = "list-updates", .type_name = "flatpak", .action_code = 'P', .type_code = 'F' },
    .{ .source_path = "shelly flatpak running", .action = "running", .type_name = "flatpak", .action_code = 'N', .type_code = 'F' },
    .{ .source_path = "shelly flatpak repair", .action = "repair", .type_name = "flatpak", .action_code = 'H', .type_code = 'F' },
    .{ .source_path = "shelly flatpak uninstall", .action = "remove", .type_name = "flatpak", .action_code = 'R', .type_code = 'F' },
    .{ .source_path = "shelly flatpak run", .action = "run", .type_name = "flatpak", .action_code = 'X', .type_code = 'F' },
    .{ .source_path = "shelly flatpak kill", .action = "kill", .type_name = "flatpak", .action_code = 'K', .type_code = 'F' },
    .{
        .source_path = "shelly flatpak search",
        .action = "search",
        .type_name = "flatpak",
        .action_code = 'S',
        .type_code = 'F',
        .help = .{
            .description = "Search cached AppStream catalogs from every configured system and user Flatpak remote, with local pagination.",
            .implementation = "Zigalpm.flatpak.AppstreamManager.getAllRemoteCatalogs",
            .arguments = &.{.{
                .name = "query",
                .description = "Application name or ID matched against the configured remotes' local AppStream catalogs",
            }},
        },
    },
    .{
        .source_path = "shelly flatpak sync-remote-appstream",
        .action = "sync",
        .type_name = "flatpak",
        .action_code = 'Y',
        .type_code = 'F',
        .help = .{
            .description = "Update cached AppStream metadata for every configured system and user Flatpak remote.",
            .implementation = "Zigalpm.flatpak.AppstreamManager.updateAllAppstreams",
        },
    },
    .{ .source_path = "shelly flatpak get-remote-appstream", .action = "get-remote-appstream", .type_name = "flatpak", .action_code = 'G', .type_code = 'F' },
    .{ .source_path = "shelly flatpak upgrade", .action = "upgrade", .type_name = "flatpak", .action_code = 'U', .type_code = 'F' },
    .{ .source_path = "shelly flatpak list-remotes", .action = "list-remotes", .type_name = "flatpak", .action_code = 'M', .type_code = 'F' },
    .{ .source_path = "shelly flatpak add-remotes", .action = "add-remotes", .type_name = "flatpak", .action_code = 'A', .type_code = 'F' },
    .{ .source_path = "shelly flatpak remove-remotes", .action = "remove-remotes", .type_name = "flatpak", .action_code = 'D', .type_code = 'F' },
    .{ .source_path = "shelly flatpak install-ref-file", .action = "install-ref-file", .type_name = "flatpak", .action_code = 'E', .type_code = 'F' },
    .{ .source_path = "shelly flatpak install-bundle", .action = "install-bundle", .type_name = "flatpak", .action_code = 'B', .type_code = 'F' },
    .{ .source_path = "shelly flatpak app-remote-info", .action = "app-remote-info", .type_name = "flatpak", .action_code = 'O', .type_code = 'F' },
    .{ .source_path = "shelly flatpak purify", .action = "purify", .type_name = "flatpak", .action_code = 'Z', .type_code = 'F' },
};

pub const SharedModifier = struct {
    action: []const u8,
    type_names: []const []const u8,
    source_names: []const []const u8,
    name: []const u8,
    aliases: []const []const u8,
    description: []const u8,

    pub fn appliesTo(self: SharedModifier, action: []const u8, type_name: []const u8, source_name: []const u8) bool {
        if (!std.mem.eql(u8, self.action, action)) return false;
        var has_type = false;
        for (self.type_names) |candidate| {
            if (std.mem.eql(u8, candidate, type_name)) {
                has_type = true;
                break;
            }
        }
        if (!has_type) return false;
        for (self.source_names) |candidate| {
            if (std.mem.eql(u8, candidate, source_name)) return true;
        }
        return false;
    }
};

// Shared semantic modifiers are defined once here. A type still receives only
// the modifiers that apply to it; all other source options remain type-specific.
pub const shared_modifiers = [_]SharedModifier{
    .{
        .action = "install",
        .type_names = &.{ "standard", "aur" },
        .source_names = &.{"--build-deps"},
        .name = "--build-deps",
        .aliases = &.{"-b"},
        .description = "Install build dependencies for the requested packages",
    },
    .{
        .action = "install",
        .type_names = &.{ "standard", "aur" },
        .source_names = &.{"--make-deps"},
        .name = "--make-deps",
        .aliases = &.{"-m"},
        .description = "Install make dependencies for the requested packages",
    },
    .{
        .action = "remove",
        .type_names = &.{ "standard", "aur" },
        .source_names = &.{"--cascade"},
        .name = "--cascade",
        .aliases = &.{"-c"},
        .description = "Remove dependencies that are no longer needed",
    },
    .{
        .action = "remove",
        .type_names = &.{ "standard", "aur" },
        .source_names = &.{"--opt-deps"},
        .name = "--opt-deps",
        .aliases = &.{"-o"},
        .description = "Remove unused optional dependencies installed with the packages",
    },
    .{
        .action = "remove",
        .type_names = &.{ "standard", "aur" },
        .source_names = &.{"--ripple"},
        .name = "--ripple",
        .aliases = &.{"-i"},
        .description = "Remove packages that depend on the removed packages",
    },
    .{
        .action = "remove",
        .type_names = &.{ "standard", "flatpak", "appimage" },
        .source_names = &.{ "--remove-config", "--config" },
        .name = "--remove-config",
        .aliases = &.{},
        .description = "Remove configuration associated with the removed package",
    },
    .{
        .action = "search",
        .type_names = &.{ "standard", "flatpak" },
        .source_names = &.{ "--take", "--limit" },
        .name = "--limit",
        .aliases = &.{"-t"},
        .description = "Maximum number of search results to return per page",
    },
    .{
        .action = "search",
        .type_names = &.{ "standard", "flatpak" },
        .source_names = &.{"--page"},
        .name = "--page",
        .aliases = &.{"-p"},
        .description = "Page number for paginated results",
    },
};

pub fn findVariantByCodes(action_code: u8, type_code: u8) ?*const Variant {
    for (&variants) |*variant| {
        if (variant.action_code == action_code and variant.type_code == type_code) return variant;
    }
    return null;
}

pub fn findTypeByCode(code: u8) ?Type {
    for (types) |command_type| {
        if (command_type.code == code) return command_type;
    }
    return null;
}

pub fn findTypeByName(name: []const u8) ?Type {
    for (types) |command_type| {
        if (std.mem.eql(u8, command_type.name, name)) return command_type;
    }
    return null;
}

pub fn findSharedModifier(action: []const u8, type_name: []const u8, source_name: []const u8) ?SharedModifier {
    for (shared_modifiers) |modifier| {
        if (modifier.appliesTo(action, type_name, source_name)) return modifier;
    }
    return null;
}

pub fn actionDescription(action: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, action, "search"))
        return "Search packages through the native ALPM, AUR RPC, or local Flatpak AppStream implementation.";
    if (std.mem.eql(u8, action, "install"))
        return "Install packages or applications from ALPM repositories, the AUR, AppImages, or Flatpak remotes.";
    if (std.mem.eql(u8, action, "upgrade"))
        return "Upgrade standard, AUR, AppImage, or Flatpak packages, including all supported backends together.";
    if (std.mem.eql(u8, action, "list"))
        return "List installed AppImages, AUR packages, Flatpak applications, Shelly configuration values, or pacman keyring keys.";
    if (std.mem.eql(u8, action, "list-updates"))
        return "List available updates for standard, AUR, AppImage, or Flatpak packages.";
    if (std.mem.eql(u8, action, "purify"))
        return "Remove corrupted or orphaned ALPM packages, or unused Flatpak dependencies.";
    if (std.mem.eql(u8, action, "remove"))
        return "Remove standard or local packages, AUR packages, AppImages, or Flatpak applications.";
    if (std.mem.eql(u8, action, "sync"))
        return "Synchronize ALPM package databases or cached Flatpak AppStream metadata.";
    if (std.mem.eql(u8, action, "update"))
        return "Update selected standard, AUR, or Flatpak packages.";
    return null;
}

pub fn hasActionCode(code: u8) bool {
    for (variants) |variant| {
        if (variant.action_code == code) return true;
    }
    return false;
}

test "shortcode action-type pairs are unique" {
    for (variants, 0..) |variant, index| {
        if (variant.action_code == null or variant.type_code == null) continue;
        for (variants[index + 1 ..]) |other| {
            if (other.action_code == null or other.type_code == null) continue;
            try std.testing.expect(
                variant.action_code.? != other.action_code.? or
                    variant.type_code.? != other.type_code.?,
            );
        }
    }
}

test "every shared modifier is actually shared" {
    for (shared_modifiers) |modifier| {
        try std.testing.expect(modifier.type_names.len >= 2);
        try std.testing.expect(modifier.source_names.len >= 1);
    }
}

test "an action has at most one default type" {
    for (variants, 0..) |variant, index| {
        if (!variant.default_for_action) continue;
        for (variants[index + 1 ..]) |other| {
            try std.testing.expect(
                !other.default_for_action or !std.mem.eql(u8, variant.action, other.action),
            );
        }
    }
}

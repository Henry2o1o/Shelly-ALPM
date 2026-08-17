const types = @import("types.zig");

const flag = types.flag;

fn hiddenFlag(name: []const u8, description: []const u8) types.Option {
    var option = types.flag(name, &.{}, description);
    option.hidden = true;
    return option;
}

fn hiddenStringOption(name: []const u8, description: []const u8) types.Option {
    var option = types.stringOption(name, &.{}, description, false);
    option.hidden = true;
    return option;
}

pub const variants = [_]types.Variant{.{
    .action = .build,
    .name = "build",
    .default_for_action = true,
    .description = "Builds a PKGBUILD into an installable package",
    .options = &.{
        flag("--reviewed", &.{"-r"}, "Marks the package as reviewed"),
        flag("--sync-deps", &.{"-s"}, "Installs missing dependencies"),
        flag("--check", &.{"-c"}, "Performs check on PKGBUILD and installs check depends"),
        flag("--isolated", &.{"-i"}, "Runs isolated root build. (This is currently nonfunctional and is being worked on)"),
        hiddenFlag("--coordinator-child", "Runs as a non-root child of an elevated package operation"),
        hiddenStringOption("--review-digest", "Requires the reviewed PKGBUILD input digest"),
        hiddenStringOption("--package", "Builds only the selected split-package member; repeatable"),
        hiddenFlag("--skip-source-pgp-verification", "Skips source PGP verification for coordinator builds"),
        hiddenFlag("--no-overwrite", "Rejects an existing package artifact"),
        hiddenFlag("--keep-workdirs", "Keeps src and pkg work directories after success"),
    },
    .arguments = &.{types.optionalArgument("pkgbuild", "File path of PKGBUILD. If left empty will look in executed directory for file named PKGBUILD.")},
}};

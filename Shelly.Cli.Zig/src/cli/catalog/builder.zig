const types = @import("types.zig");

const flag = types.flag;
const stringOption = types.stringOption;

pub const variants = [_]types.Variant{.{
    .action = .build,
    .name = "build",
    .default_for_action = true,
    .description = "Builds a PKGBUILD into an installable package",
    .options = &.{ flag("--reviewed", &.{"-r"}, "Marks the package as reviewed"), flag("--sync-deps", &.{"-s"}, "Installs missing dependencies"), flag(
        "--check",
        &.{"-c"},
        "Performs check on PKGBUILD and installs check depends",
        flag("--isolated", &.{"-i"}, "Runs isolated root build. (This is currently nonfunctional and is being worked on"),
    ) },
    .arguments = &.{types.optionalArgument("pkgbuild", "File path of PKGBUILD. If left empty will look in executed directory for file named PKGBUILD.")},
}};

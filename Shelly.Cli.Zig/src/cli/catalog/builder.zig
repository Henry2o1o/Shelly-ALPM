const types = @import("types.zig");

const flag = types.flag;
const stringOption = types.stringOption;

pub const variants = [_]types.Variant{.{
    .action = .build,
    .name = "build",
    .default_for_action = true,
    .description = "Builds a PKGBUILD into an installable package",
    .options = &.{flag("--reviewed", &.{"-r"}, "Marks the package as reviewed")},
    .arguments = &.{types.optionalArgument("pkgbuild", "File path of PKGBUILD. If left empty will look in executed directory for file named PKGBUILD.")},
}};

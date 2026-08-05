const types = @import("types.zig");

const repeatedArgument = types.repeatedArgument;
const stringOption = types.stringOption;

pub const variants = [_]types.Variant{
    .{
        .action = .keyring,
        .name = "init",
        .type_code = 'i',
        .description = "Initialize the pacman keyring.",
        .implementation = "pacman-key --init",
    },
    .{
        .action = .keyring,
        .name = "list",
        .type_code = 'l',
        .description = "List keys in the pacman keyring.",
        .implementation = "pacman-key --list-keys",
    },
    .{
        .action = .keyring,
        .name = "refresh",
        .type_code = 'r',
        .description = "Refresh pacman keyring keys from the configured keyserver.",
        .implementation = "pacman-key --refresh-keys",
    },
    .{
        .action = .keyring,
        .name = "lsign",
        .type_code = 's',
        .description = "Locally sign one or more keys in the pacman keyring.",
        .implementation = "pacman-key --lsign-key for each requested key",
        .arguments = &.{repeatedArgument(
            "keys",
            1,
            "One or more key identifiers",
        )},
    },
    .{
        .action = .keyring,
        .name = "populate",
        .type_code = 'p',
        .description = "Populate the pacman keyring with default or named distribution keys.",
        .implementation = "pacman-key --populate",
        .arguments = &.{repeatedArgument(
            "keys",
            0,
            "Distribution keyring names; omit to populate the defaults",
        )},
    },
    .{
        .action = .keyring,
        .name = "recv",
        .type_code = 'v',
        .description = "Receive one or more keys from the configured or requested keyserver.",
        .implementation = "pacman-key --recv-keys [keys...] [--keyserver server]",
        .arguments = &.{repeatedArgument(
            "keys",
            1,
            "One or more key identifiers",
        )},
        .options = &.{stringOption(
            "--keyserver",
            &.{},
            "Keyserver from which to receive keys",
            false,
        )},
    },
};

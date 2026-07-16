pub const app = @import("cli/app.zig");
pub const parser = @import("cli/parser.zig");
pub const runtime = @import("runtime/context.zig");
pub const log = @import("runtime/log.zig");
pub const signals = @import("runtime/signals.zig");
pub const elevation = @import("runtime/elevation.zig");
pub const xdg = @import("runtime/xdg.zig");
pub const shortcodes = @import("cli/shortcodes.zig");
pub const catalog = @import("cli/catalog.zig");
pub const spec = @import("cli/spec.zig");
pub const commands = @import("commands/dispatcher.zig");
pub const sync_command = @import("commands/sync.zig");
pub const config = @import("config/manager.zig");
pub const config_model = @import("config/model.zig");
pub const config_output = @import("output/config.zig");

test {
    _ = app;
    _ = parser;
    _ = runtime;
    _ = log;
    _ = signals;
    _ = elevation;
    _ = xdg;
    _ = shortcodes;
    _ = catalog;
    _ = spec;
    _ = commands;
    _ = sync_command;
    _ = config;
    _ = config_model;
    _ = config_output;
}

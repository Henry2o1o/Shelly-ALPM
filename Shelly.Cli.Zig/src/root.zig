pub const app = @import("cli/app.zig");
pub const parser = @import("cli/parser.zig");
pub const runtime = @import("runtime/context.zig");
pub const log = @import("runtime/log.zig");
pub const signals = @import("runtime/signals.zig");
pub const xdg = @import("runtime/xdg.zig");
pub const shortcodes = @import("cli/shortcodes.zig");
pub const spec = @import("cli/spec.zig");
pub const commands = @import("commands/dispatcher.zig");
pub const config = @import("config/manager.zig");
pub const config_model = @import("config/model.zig");
pub const config_output = @import("output/config.zig");

test {
    _ = app;
    _ = parser;
    _ = runtime;
    _ = log;
    _ = signals;
    _ = xdg;
    _ = shortcodes;
    _ = spec;
    _ = commands;
    _ = config;
    _ = config_model;
    _ = config_output;
}

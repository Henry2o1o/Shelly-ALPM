const config = @import("config.zig");
const install = @import("install.zig");
const list = @import("list.zig");
const list_updates = @import("list_updates.zig");
const remove = @import("remove.zig");
const search = @import("search.zig");
const sync = @import("sync.zig");
const update = @import("update.zig");
const upgrade = @import("upgrade.zig");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");

pub fn dispatch(
    _: ?*anyopaque,
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !u8 {
    if (try upgrade.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try sync.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try update.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try install.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try list.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try list_updates.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try search.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try config.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try remove.dispatch(context, invocation)) |exit_code| return exit_code;
    return runtime.unimplemented(null, context, invocation);
}

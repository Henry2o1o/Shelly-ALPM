const config = @import("config.zig");
const sync = @import("sync.zig");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");

pub fn dispatch(
    _: ?*anyopaque,
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !u8 {
    if (try sync.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try config.dispatch(context, invocation)) |exit_code| return exit_code;
    return runtime.unimplemented(null, context, invocation);
}

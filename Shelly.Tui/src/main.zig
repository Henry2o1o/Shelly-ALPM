const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Shelly_Tui = @import("Shelly_Tui");
const Model = Shelly_Tui.model.Model;

pub fn main(init: std.process.Init) !void {
    var buffer: [1024]u8 = undefined;
    var app: vxfw.App = try .init(init.io, init.gpa, init.environ_map, &buffer);
    defer app.deinit();

    // The model is heap allocated because vxfw widgets hold a stable pointer
    // to it across frames
    const model = try init.gpa.create(Model);
    defer init.gpa.destroy(model);
    model.* = .{};

    try app.run(model.widget(), .{});
}

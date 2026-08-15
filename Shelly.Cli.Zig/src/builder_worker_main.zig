const std = @import("std");
const Zigalpm = @import("Zigalpm");

pub fn main(init: std.process.Init) !void {
    try Zigalpm.aur.builder_worker.main(init);
}

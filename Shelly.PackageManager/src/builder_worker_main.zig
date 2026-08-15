const std = @import("std");
const worker = @import("aur/builder/worker.zig");

pub fn main(init: std.process.Init) !void {
    try worker.main(init);
}

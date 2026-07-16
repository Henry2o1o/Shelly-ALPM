const std = @import("std");

pub var io: std.Io = undefined;
pub var environ_map: *std.process.Environ.Map = undefined;

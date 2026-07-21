const std = @import("std");
const zz = @import("zigzag");
const RunResult = std.process.RunResult;
const builtin = std.builtin;
const runtime = @import("runtime.zig");

pub const Model = struct {
    group: zz.TabGroup,
    package_grid: zz.DataTable,
    aur_grid: zz.DataTable,

    fn run(self: *Model, args: []const []const u8) !RunResult {
        const shelly_bin = if (builtin.mode == .Debug)
            "../Shelly.Cli.Zig/zig-out/bin/shelly"
        else
            "shelly";

        var argv = try self.allocator.alloc([]const u8, args.len + 2);
        defer self.allocator.free(argv);
        argv[0] = shelly_bin;
        @memcpy(argv[1 .. 1 + args.len], args);
        argv[argv.len - 1] = "--ui-mode";

        const result = try std.process.run(self.allocator, self.io, .{
            .argv = argv,
            .environ_map = runtime.environ_map,
        });
        errdefer self.allocator.free(result.stdout);
        errdefer self.allocator.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("failed: term={any} stderr='{s}' stdout='{s}'\n", .{
                result.term, result.stderr, result.stdout[0..@min(500, result.stdout.len)],
            });
            return error.CommandFailed;
        }

        return result;
    }
};

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const RunResult = std.process.RunResult;
const builtin = @import("builtin");
const runtime = @import("runtime.zig");
const shelly_cli = @import("shelly_cli.zig");
const ShellyCli = shelly_cli.ShellyCli;

pub const Tab = enum {
    packages,
    aur,

    pub const all: []const Tab = &.{ .packages, .aur };

    pub fn title(self: Tab) []const u8 {
        return switch (self) {
            .packages => "Packages",
            .aur => "AUR",
        };
    }

    pub fn placeholder(self: Tab) []const u8 {
        return switch (self) {
            .packages => "No packages loaded",
            .aur => "No AUR packages loaded",
        };
    }
};

pub const Model = struct {
    active: Tab = .packages,

    pub fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .key_press => |key| {
                if (key.matches('q', .{}) or
                    key.matches(vaxis.Key.escape, .{}) or
                    key.matches('c', .{ .ctrl = true }))
                {
                    ctx.quit = true;
                    return;
                }
                if (key.matches(vaxis.Key.left, .{})) {
                    self.selectRelative(-1);
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.right, .{})) {
                    self.selectRelative(1);
                    return ctx.consumeAndRedraw();
                }
                for (Tab.all, 1..) |tab, number| {
                    if (key.matches('0' + @as(u21, @intCast(number)), .{})) {
                        self.active = tab;
                        return ctx.consumeAndRedraw();
                    }
                }
            },
            else => {},
        }
    }

    fn selectRelative(self: *Model, delta: i32) void {
        const count: i32 = @intCast(Tab.all.len);
        const current: i32 = @intFromEnum(self.active);
        var next = @rem(current + delta, count);
        if (next < 0) next += count;
        self.active = @enumFromInt(@as(std.meta.Tag(Tab), @intCast(next)));
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const arena = ctx.arena;
        const max_size = ctx.max.size();

        // Too small to draw anything meaningful
        if (max_size.width == 0 or max_size.height < 3) {
            return .{
                .size = max_size,
                .widget = self.widget(),
                .buffer = &.{},
                .children = &.{},
            };
        }

        const tab_bar = try self.drawTabBar(arena);

        const content = try arena.create(vxfw.Text);
        content.* = .{
            .text = self.active.placeholder(),
            .style = .{ .fg = .{ .index = 245 } },
        };

        const hints = try arena.create(vxfw.Text);
        hints.* = .{
            .text = "q: quit | ←/→: switch | 1..2: jump",
            .style = .{ .fg = .{ .index = 245 } },
        };

        const children = try arena.alloc(vxfw.FlexItem, 3);
        children[0] = .{ .widget = tab_bar, .flex = 0 };
        children[1] = .{ .widget = content.widget(), .flex = 1 };
        children[2] = .{ .widget = hints.widget(), .flex = 0 };

        const column = try arena.create(vxfw.FlexColumn);
        column.* = .{ .children = children };

        const subsurfaces = try arena.alloc(vxfw.SubSurface, 1);
        subsurfaces[0] = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try column.draw(ctx),
        };

        return .{
            .size = max_size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = subsurfaces,
        };
    }

    fn drawTabBar(self: *const Model, arena: std.mem.Allocator) std.mem.Allocator.Error!vxfw.Widget {
        const spans = try arena.alloc(vxfw.RichText.TextSpan, Tab.all.len);
        for (Tab.all, 0..) |tab, i| {
            spans[i] = .{
                .text = try std.fmt.allocPrint(arena, " {s} ", .{tab.title()}),
                .style = if (tab == self.active)
                    .{ .bold = true, .reverse = true }
                else
                    .{ .fg = .{ .index = 245 } },
            };
        }
        const bar = try arena.create(vxfw.RichText);
        bar.* = .{ .text = spans, .softwrap = false };
        return bar.widget();
    }

    fn run(self: ShellyCli, args: []const []const u8) !RunResult {
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

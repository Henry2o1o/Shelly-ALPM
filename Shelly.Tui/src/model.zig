const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const shelly_cli = @import("shelly_cli.zig");
const ShellyCli = shelly_cli.ShellyCli;
const Package = @import("packages.zig").Package;

const Allocator = std.mem.Allocator;

/// Shared state between the UI and the background package loader. The
/// loader writes exactly once; `done` is published with release semantics
/// after the result fields are written, so the UI can read them with an
/// acquire load and no lock.
const LoadState = struct {
    result: ?std.json.Parsed([]Package) = null,
    failed: bool = false,
    done: std.atomic.Value(bool) = .init(false),
};

pub const Model = struct {
    gpa: Allocator,

    /// All known packages, borrowed from `parsed`.
    packages: []const Package = &.{},
    /// Owns the package data returned by the CLI.
    parsed: ?std.json.Parsed([]Package) = null,

    load: *LoadState,
    loading: bool = true,
    load_failed: bool = false,

    /// Packages matching `query`, in display order.
    filtered: std.ArrayList(*const Package),
    /// Owned by `gpa` unless empty.
    query: []const u8 = "",

    list_view: vxfw.ListView,
    text_field: vxfw.TextField,

    pub fn init(gpa: Allocator) !*Model {
        const load = try gpa.create(LoadState);
        errdefer gpa.destroy(load);
        load.* = .{};

        const model = try gpa.create(Model);
        errdefer gpa.destroy(model);

        model.* = .{
            .gpa = gpa,
            .load = load,
            .filtered = .empty,
            .list_view = .{
                .children = .{ .builder = .{
                    .userdata = model,
                    .buildFn = Model.buildRow,
                } },
            },
            .text_field = .{
                .buf = .init(gpa),
                .userdata = model,
                .onChange = Model.onQueryChange,
            },
        };
        return model;
    }

    pub fn deinit(self: *Model) void {
        const gpa = self.gpa;
        self.text_field.deinit();
        self.filtered.deinit(gpa);
        if (self.query.len > 0) gpa.free(self.query);
        if (self.parsed) |*parsed| parsed.deinit();
        // `load` is intentionally leaked: the loader thread may still hold a
        // reference to it when the app exits.
        gpa.destroy(self);
    }

    pub fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    // -- events ------------------------------------------------------------

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => {
                try self.startLoad(ctx);
                ctx.redraw = true;
                return ctx.requestFocus(self.text_field.widget());
            },
            .focus_in => {
                return ctx.requestFocus(self.text_field.widget());
            },
            .tick => {
                return self.pollLoad(ctx);
            },
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                    return;
                }
                if (key.matches(vaxis.Key.escape, .{})) {
                    if (self.query.len > 0) {
                        self.text_field.clearRetainingCapacity();
                        try self.setQuery("");
                        return ctx.consumeAndRedraw();
                    }
                    ctx.quit = true;
                    return;
                }
                // Let the list handle whatever the search field ignored
                // (arrow keys, page up/down, mouse wheel, ...)
                return self.list_view.handleEvent(ctx, event);
            },
            else => {},
        }
    }

    // -- loading -----------------------------------------------------------

    fn startLoad(self: *Model, ctx: *vxfw.EventContext) !void {
        const thread = try std.Thread.spawn(.{}, loadPackages, .{self.load});
        thread.detach();
        try ctx.tick(100, self.widget());
    }

    fn loadPackages(load: *LoadState) void {
        // The loader runs its own threaded IO and uses the page allocator so
        // it never shares state with the UI thread.
        const alloc = std.heap.page_allocator;
        var threaded: std.Io.Threaded = .init(alloc, .{});
        defer threaded.deinit();

        const cli: ShellyCli = .{ .allocator = alloc, .io = threaded.io() };
        const parsed = cli.get_packages() catch {
            load.failed = true;
            load.done.store(true, .release);
            return;
        };

        load.result = parsed;
        load.done.store(true, .release);
    }

    fn pollLoad(self: *Model, ctx: *vxfw.EventContext) anyerror!void {
        if (!self.load.done.load(.acquire)) {
            // Keep polling until the loader finishes
            return ctx.tick(100, self.widget());
        }
        const failed = self.load.failed;
        const parsed = self.load.result;

        self.loading = false;
        self.load_failed = failed;
        if (parsed) |p| {
            self.parsed = p;
            self.packages = p.value;
        }
        try self.rebuildFilter();
        return ctx.consumeAndRedraw();
    }

    // -- filtering ---------------------------------------------------------

    fn onQueryChange(maybe_ptr: ?*anyopaque, _: *vxfw.EventContext, str: []const u8) anyerror!void {
        const ptr = maybe_ptr orelse return;
        const self: *Model = @ptrCast(@alignCast(ptr));
        try self.setQuery(str);
    }

    fn setQuery(self: *Model, str: []const u8) Allocator.Error!void {
        const duped = if (str.len > 0) try self.gpa.dupe(u8, str) else "";
        if (self.query.len > 0) self.gpa.free(self.query);
        self.query = duped;
        try self.rebuildFilter();
    }

    fn rebuildFilter(self: *Model) Allocator.Error!void {
        self.filtered.clearRetainingCapacity();
        for (self.packages) |*pkg| {
            if (self.query.len == 0 or
                containsFold(pkg.Name, self.query) or
                containsFold(pkg.Description, self.query))
            {
                try self.filtered.append(self.gpa, pkg);
            }
        }
        self.list_view.item_count = @intCast(self.filtered.items.len);
        self.list_view.jumpToItem(0);
    }

    /// Case-insensitive substring match (ASCII folding only, which is all
    /// that package names need).
    fn containsFold(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (haystack.len < needle.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            var j: usize = 0;
            while (j < needle.len and
                std.ascii.toLower(haystack[i + j]) == std.ascii.toLower(needle[j])) j += 1;
            if (j == needle.len) return true;
        }
        return false;
    }

    // -- drawing -----------------------------------------------------------

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const arena = ctx.arena;
        const max = ctx.max.size();

        if (max.width == 0 or max.height < 3) {
            return .{
                .size = max,
                .widget = self.widget(),
                .buffer = &.{},
                .children = &.{},
            };
        }

        // Row 0: search prompt + field
        var prompt: vxfw.Text = .{ .text = "❯", .style = .{ .fg = .{ .index = 4 } } };
        const prompt_surface = try prompt.draw(ctx.withConstraints(
            ctx.min,
            .{ .width = 2, .height = 1 },
        ));
        const search_surface = try self.text_field.draw(ctx.withConstraints(
            ctx.min,
            .{ .width = max.width -| 2, .height = 1 },
        ));

        // Rows 1..height-2: package list
        const list_surface = try self.list_view.draw(ctx.withConstraints(
            .{ .width = 0, .height = 0 },
            .{ .width = max.width, .height = max.height - 2 },
        ));

        // Bottom row: status bar
        var status: vxfw.Text = .{
            .text = try self.statusText(arena),
            .style = .{ .fg = .{ .index = 245 } },
        };
        const status_surface = try status.draw(ctx.withConstraints(
            ctx.min,
            .{ .width = max.width, .height = 1 },
        ));

        var children: std.ArrayList(vxfw.SubSurface) = .empty;
        try children.appendSlice(arena, &.{
            .{ .origin = .{ .row = 0, .col = 0 }, .surface = prompt_surface },
            .{ .origin = .{ .row = 0, .col = 2 }, .surface = search_surface },
            .{ .origin = .{ .row = 1, .col = 0 }, .surface = list_surface },
            .{ .origin = .{ .row = max.height - 1, .col = 0 }, .surface = status_surface },
        });

        if (self.loading or self.load_failed) {
            var message: vxfw.Text = if (self.loading)
                .{ .text = "Loading packages…", .style = .{ .fg = .{ .index = 245 } } }
            else
                .{ .text = "Failed to load packages. Is the shelly CLI available?", .style = .{ .fg = .{ .index = 1 } } };
            try children.append(arena, .{
                .origin = .{ .row = 2, .col = 2 },
                .surface = try message.draw(ctx.withConstraints(
                    ctx.min,
                    .{ .width = max.width -| 2, .height = 1 },
                )),
            });
        }

        return .{
            .size = max,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children.items,
        };
    }

    fn statusText(self: *const Model, arena: Allocator) Allocator.Error![]const u8 {
        if (self.loading) return "Loading packages…";
        if (self.load_failed) return "Failed to load packages";
        if (self.query.len > 0) {
            return std.fmt.allocPrint(arena, "{d} of {d} packages match", .{
                self.filtered.items.len, self.packages.len,
            });
        }
        return std.fmt.allocPrint(arena, "{d} packages", .{self.packages.len});
    }

    /// ListView builder: constructs the widget for a single row on demand, so
    /// only visible rows are ever built.
    fn buildRow(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const Model = @ptrCast(@alignCast(ptr));
        if (idx >= self.filtered.items.len) return null;
        const pkg = self.filtered.items[idx];
        return .{
            .userdata = @constCast(pkg),
            .drawFn = drawPackageRow,
        };
    }

    fn drawPackageRow(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const pkg: *const Package = @ptrCast(@alignCast(ptr));
        const arena = ctx.arena;

        var spans: std.ArrayList(vxfw.RichText.TextSpan) = .empty;
        if (pkg.Installed) {
            try spans.append(arena, .{ .text = "● ", .style = .{ .fg = .{ .index = 2 } } });
        } else {
            try spans.append(arena, .{ .text = "  " });
        }
        try spans.append(arena, .{ .text = pkg.Name, .style = .{ .bold = true } });
        try spans.append(arena, .{ .text = " " });
        try spans.append(arena, .{ .text = pkg.Version, .style = .{ .fg = .{ .index = 245 } } });
        if (pkg.Description.len > 0) {
            try spans.append(arena, .{ .text = " — " });
            try spans.append(arena, .{
                .text = pkg.Description,
                .style = .{ .fg = .{ .index = 245 } },
            });
        }

        const rich = try arena.create(vxfw.RichText);
        rich.* = .{
            .text = spans.items,
            .softwrap = false,
            .overflow = .ellipsis,
        };
        return rich.draw(ctx);
    }
};

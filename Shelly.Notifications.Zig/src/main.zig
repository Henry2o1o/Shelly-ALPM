const std = @import("std");
const zsn = @import("zsn");
const runtime = @import("runtime.zig");
const ShellyCli = @import("services/shelly-cli.zig").ShellyCli;
const ShellyConfig = @import("services/config.zig").ConfigResolver;
const next_notification = @import("services/next_notification.zig");

const CheckUpdatesPackage = @import("models/update.zig").CheckUpdatesPackage;
const CheckUpdatesAur = @import("models/update.zig").CheckUpdatesAur;
const CheckUpdatesFlatpak = @import("models/update.zig").CheckUpdatesFlatpak;

const Service = zsn.Service;
const MenuController = zsn.MenuController;
const Notifier = zsn.Notifier;
const MenuState = zsn.MenuState;
const Tree = zsn.Tree;
const Tray = zsn.Tray;
const MenuItem = zsn.MenuItem;
const ItemType = zsn.ItemType;

const Repo = @import("models/update.zig").CheckUpdatesPackage;
const Aur = @import("models/update.zig").CheckUpdatesAur;
const Flatpak = @import("models/update.zig").CheckUpdatesFlatpak;

var quit_index: usize = 0;
var open_index: usize = 0;

const Updates = struct {
    mutex: std.Io.Mutex = .init,
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: std.ArrayListUnmanaged(Repo) = .empty,
    aur: std.ArrayListUnmanaged(Aur) = .empty,
    flatpak: std.ArrayListUnmanaged(Flatpak) = .empty,

    fn init(allocator: std.mem.Allocator, io: std.Io) Updates {
        return .{ .allocator = allocator, .io = io };
    }

    fn deinit(self: *Updates) void {
        self.mutex.lockUncancelable(self.io);
        self.clear();
        self.mutex.unlock(self.io);
        self.repo.deinit(self.allocator);
        self.aur.deinit(self.allocator);
        self.flatpak.deinit(self.allocator);
    }

    fn clear(self: *Updates) void {
        for (self.repo.items) |*e| {
            self.allocator.free(e.Name);
            self.allocator.free(e.CurrentVersion);
            self.allocator.free(e.NewVersion);
        }
        for (self.aur.items) |*e| {
            self.allocator.free(e.Name);
            self.allocator.free(e.Version);
            self.allocator.free(e.NewVersion);
        }
        for (self.flatpak.items) |*e| {
            self.allocator.free(e.Name);
            self.allocator.free(e.Version);
        }
        self.repo.clearRetainingCapacity();
        self.aur.clearRetainingCapacity();
        self.flatpak.clearRetainingCapacity();
    }

    fn total(self: *Updates) usize {
        return self.repo.items.len + self.aur.items.len + self.flatpak.items.len;
    }
};

const Worker = struct {
    updates: *Updates,
    ctrl: *MenuController,
    cli: ShellyCli,
    io: std.Io,
    gpa: std.mem.Allocator,
    config: *const ShellyConfig,

    fn run(self: *Worker) void {
        while (true) {
            self.pollOnce() catch |e| {
                std.debug.print("[worker] check failed: {any}\n", .{e});
            };

            const secs = //next_notification.getNextSeconds(self.gpa, self.io, self.config.) catch |e| {
                //std.debug.print("[worker] schedule calc failed: {any}, using 10h\n", .{e});
                36000;
            // };

            std.debug.print("[worker] sleeping {d}s until next check\n", .{secs});
            self.io.sleep(.fromSeconds(secs), .awake) catch break;
        }
    }

    fn pollOnce(self: *Worker) !void {
        const parsed = try self.cli.check_updates();
        defer parsed.deinit();

        self.updates.mutex.lockUncancelable(self.io);
        defer self.updates.mutex.unlock(self.io);

        self.updates.clear();

        const a = self.updates.allocator;

        for (parsed.value.Packages) |pkg| {
            try self.updates.repo.append(a, .{
                .Name = try a.dupe(u8, pkg.Name),
                .CurrentVersion = try a.dupe(u8, pkg.CurrentVersion),
                .NewVersion = try a.dupe(u8, pkg.NewVersion),
            });
        }
        for (parsed.value.Aur) |pkg| {
            try self.updates.aur.append(a, .{
                .Name = try a.dupe(u8, pkg.Name),
                .Version = try a.dupe(u8, pkg.Version),
                .NewVersion = try a.dupe(u8, pkg.NewVersion),
            });
        }
        for (parsed.value.Flatpak) |pkg| {
            try self.updates.flatpak.append(a, .{
                .Name = try a.dupe(u8, pkg.Name),
                .Version = try a.dupe(u8, pkg.Version),
            });
        }

        std.debug.print("[worker] {d} updates found\n", .{self.updates.total()});

        self.ctrl.invalidate() catch {};
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    runtime.allocator = allocator;
    runtime.io = init.io;
    runtime.environ_map = init.environ_map;

    var svc = try Service.init(allocator, init.io, init.environ_map);
    defer svc.deinit();

    var t = try Tray.init(&svc, .{
        .id = "shelly.shellyorg.Notifications",
        .title = "Shelly Notifications",
        .icon_name = "shelly",
        .attention_icon_name = "dialog-warning",
    });
    defer t.deinit();
    const item_handle = try t.register();

    const conn = svc.connection();

    var updates = Updates.init(allocator, init.io);
    defer updates.deinit();

    var mstate = MenuState.init(allocator, buildMenu);
    defer mstate.deinit();
    mstate.ctx = &updates;
    mstate.on_event = onEvent;

    var menu_ctrl = MenuController.init(&svc, &mstate, t.name, "/MenuBar");
    _ = try menu_ctrl.register();

    const config = try ShellyConfig.init(allocator, runtime.io, runtime.environ_map);

    var worker = Worker{
        .updates = &updates,
        .ctrl = &menu_ctrl,
        .cli = ShellyCli{
            .allocator = allocator,
            .io = init.io,
            .environ_map = init.environ_map,
        },
        .io = init.io,
        .gpa = allocator,
        .config = &config,
    };
    const worker_thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    defer worker_thread.join();

    try conn.waitOnHandle(item_handle);
}

fn buildMenu(ctx: ?*anyopaque, arena: std.mem.Allocator) !Tree {
    const updates: *Updates = @ptrCast(@alignCast(ctx.?));

    updates.mutex.lockUncancelable(updates.io);
    defer updates.mutex.unlock(updates.io);
    var items = std.ArrayList(MenuItem).empty;
    var tray_index: usize = 0;

    try addItem(arena, &items, &tray_index, "Open Shelly", true, true, .normal);
    try addItem(arena, &items, &tray_index, "Update Packages", true, true, .normal);
    try addItem(arena, &items, &tray_index, "Check for updates", true, true, .normal);
    try addItem(arena, &items, &tray_index, "", false, true, .separator);

    const count = updates.total();
    if (count == 0) {
        tray_index += 1;
        try addItem(arena, &items, &tray_index, "No updates", false, true, .normal);
    } else {
        if (updates.repo.items.len > 0) {
            tray_index += 1;
            try addItemWithSubmenu(
                @TypeOf(updates.repo.items[0]),
                arena,
                &items,
                &tray_index,
                updates.repo.items,
                repoLabel,
                "Standard",
                .normal,
            );
        }

        if (updates.aur.items.len > 0) {
            tray_index += 1;
            try addItemWithSubmenu(
                @TypeOf(updates.aur.items[0]),
                arena,
                &items,
                &tray_index,
                updates.aur.items,
                aurLabel,
                "AUR",
                .normal,
            );
        }

        try addItemWithSubmenu(
            @TypeOf(updates.flatpak.items[0]),
            arena,
            &items,
            &tray_index,
            updates.flatpak.items,
            flatpakLabel,
            "Standard",
            .normal,
        );
    }

    try addItem(arena, &items, &tray_index, "", true, true, .separator);
    try addItem(arena, &items, &tray_index, "Exit", true, true, .normal);

    return .{ .root = .{ .id = 0, .children = try items.toOwnedSlice(arena) } };
}

fn addItem(arena: std.mem.Allocator, items: *std.ArrayList(MenuItem), id: *usize, label: []const u8, enabled: bool, visible: bool, itype: ItemType) !void {
    id.* += 1;
    const item: MenuItem = .{ .id = @as(i32, @intCast(id.*)), .label = label, .enabled = enabled, .visible = visible, .type = itype };
    try items.append(arena, item);
}

fn repoLabel(arena: std.mem.Allocator, pkg: CheckUpdatesPackage) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}  {s} -> {s}", .{
        pkg.Name, pkg.CurrentVersion, pkg.NewVersion,
    });
}

fn aurLabel(arena: std.mem.Allocator, pkg: CheckUpdatesAur) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}  {s} -> {s}", .{
        pkg.Name, pkg.Version, pkg.NewVersion,
    });
}

fn flatpakLabel(arena: std.mem.Allocator, pkg: CheckUpdatesFlatpak) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}  {s}", .{
        pkg.Name, pkg.Version,
    });
}

fn addItemWithSubmenu(
    comptime T: type,
    arena: std.mem.Allocator,
    items: *std.ArrayList(MenuItem),
    id: *usize,
    source: []const T,
    labelFn: fn (std.mem.Allocator, T) anyerror![]const u8,
    label: []const u8,
    itype: ItemType,
) !void {
    var children = std.ArrayList(MenuItem).empty;
    defer children.deinit(arena);

    for (source) |pkg| {
        const child_label = try labelFn(arena, pkg);
        try children.append(arena, .{ .id = @as(i32, @intCast(id.*)), .label = child_label });
        id.* += 1;
    }

    try items.append(arena, .{
        .id = @as(i32, @intCast(id.*)),
        .type = itype,
        .children = try children.toOwnedSlice(arena),
        .label = label,
    });
    id.* += 1;
}

fn onEvent(ctx: ?*anyopaque, id: i32) void {
    _ = ctx;
    std.debug.print("id: {}\n", .{id});
    if (id == quit_index) std.debug.print("[menu] quit requested\n", .{});
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("services/next_notification.zig");
}

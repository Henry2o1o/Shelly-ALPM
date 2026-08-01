const std = @import("std");
const zsn = @import("zsn");
const runtime = @import("runtime.zig");
const ShellyCli = @import("services/shelly-cli.zig").ShellyCli;
const ShellyConfig = @import("services/config.zig").ConfigResolver;
const next_notification = @import("services/next_notification.zig");
const ConfigWatcher = @import("services/config-watcher.zig").ConfigWatcher;
const AppRunner = @import("services/app_runner.zig").AppRunner;

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
const Action = zsn.Action;
const Pixmap = zsn.Pixmap;

const Repo = @import("models/update.zig").CheckUpdatesPackage;
const Aur = @import("models/update.zig").CheckUpdatesAur;
const Flatpak = @import("models/update.zig").CheckUpdatesFlatpak;

var quit_index: usize = 0;
var open_index: usize = 0;
var run_update_index: usize = 0;
var open_shelly_index: usize = 0;

const NotifText = struct { summary: [:0]u8, body: [:0]u8 };

const Updates = struct {
    mutex: std.Io.Mutex = .init,
    io: std.Io,
    runner: *AppRunner,
    allocator: std.mem.Allocator,
    repo: std.ArrayListUnmanaged(Repo) = .empty,
    aur: std.ArrayListUnmanaged(Aur) = .empty,
    flatpak: std.ArrayListUnmanaged(Flatpak) = .empty,

    needs_refresh: bool = false,
    pending_notif: ?NotifText = null,

    fn init(allocator: std.mem.Allocator, io: std.Io, runner: *AppRunner) Updates {
        return .{ .allocator = allocator, .io = io, .runner = runner };
    }

    fn deinit(self: *Updates) void {
        self.mutex.lockUncancelable(self.io);
        self.clear();
        if (self.pending_notif) |n| {
            self.allocator.free(n.summary);
            self.allocator.free(n.body);
            self.pending_notif = null;
        }
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

    fn signalRefresh(self: *Updates) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.needs_refresh = true;
    }

    fn queueNotif(self: *Updates, summary: []const u8, body: []const u8) void {
        const s = self.allocator.dupeZ(u8, summary) catch return;
        const b = self.allocator.dupeZ(u8, body) catch {
            self.allocator.free(s);
            return;
        };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.pending_notif) |old| {
            self.allocator.free(old.summary);
            self.allocator.free(old.body);
        }
        self.pending_notif = .{ .summary = s, .body = b };
    }

    fn takeRefresh(self: *Updates) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const r = self.needs_refresh;
        self.needs_refresh = false;
        return r;
    }

    fn takeNotif(self: *Updates) ?NotifText {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const n = self.pending_notif;
        self.pending_notif = null;
        return n;
    }

    fn freeNotif(self: *Updates, n: NotifText) void {
        self.allocator.free(n.summary);
        self.allocator.free(n.body);
    }
};

const Worker = struct {
    updates: *Updates,
    cli: ShellyCli,
    io: std.Io,
    gpa: std.mem.Allocator,
    config: *ShellyConfig,

    fn run(self: *Worker) void {
        while (true) {
            self.pollOnce() catch |e| {
                std.debug.print("[worker] check failed: {any}\n", .{e});
            };

            const secs: u32 = blk: {
                self.config.mutex.lockUncancelable(self.io);
                defer self.config.mutex.unlock(self.io);
                const cfg = self.config.get() catch |e| {
                    std.log.warn("[worker] config get failed: {any}, using 1h", .{e});
                    break :blk 36000;
                };
                break :blk next_notification.getNextSeconds(self.gpa, self.io, cfg) catch |e| {
                    std.log.warn("[worker] schedule calc failed: {any}, using 10h", .{e});
                    break :blk 36000;
                };
            };

            std.log.info("[worker] next check in: {d}", .{secs});
            std.debug.print("[worker] sleeping {d}s until next check\n", .{secs});

            _ = self.config.dirty.swap(false, .seq_cst);
            var remaining = secs;
            while (remaining > 0) {
                const chunk = @min(remaining, 30);
                self.io.sleep(.fromSeconds(chunk), .awake) catch return;
                if (self.config.dirty.swap(false, .seq_cst)) {
                    std.debug.print("[worker] config changed, recomputing schedule\n", .{});
                    break;
                }
                remaining -= chunk;
            }
        }
    }

    fn pollOnce(self: *Worker) !void {
        const parsed = try self.cli.check_updates();
        defer parsed.deinit();

        const count = blk: {
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
            break :blk self.updates.total();
        };

        std.debug.print("[worker] {d} updates found\n", .{count});

        self.updates.signalRefresh();
        if (count > 0) {
            var buf: [128]u8 = undefined;
            const body = std.fmt.bufPrintZ(&buf, "{d} updates available", .{count}) catch "0 updates";
            self.updates.queueNotif("Updates available", body);
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    runtime.allocator = allocator;
    runtime.io = init.io;
    runtime.environ_map = init.environ_map;

    var service = try Service.init(allocator, init.io, init.environ_map);
    defer service.deinit();

    var runner = AppRunner.init(allocator, init.io, init.environ_map);
    defer runner.deinit();

    var t = try Tray.init(&service, .{
        .id = "shelly.shellyorg.Notifications",
        .title = "Shelly Notifications",
        .icon_name = "shelly-shell-symbolic",
        .icon_pixmap = &.{},
        .attention_icon_name = "dialog-warning",
    });
    defer t.deinit();
    _ = try t.register();

    var notifier = Notifier.init(&service);
    defer notifier.deinit();

    var updates = Updates.init(allocator, init.io, &runner);
    defer updates.deinit();

    var mstate = MenuState.init(allocator, buildMenu);
    defer mstate.deinit();
    mstate.ctx = &updates;
    mstate.on_event = onEvent;

    var menu_ctrl = MenuController.init(&service, &mstate, t.name, "/MenuBar");
    _ = try menu_ctrl.register();

    var config = try ShellyConfig.init(allocator, runtime.io, runtime.environ_map);
    defer config.deinit();
    try config.load();

    var watcher = try ConfigWatcher.init(allocator, &config, "settings.json");
    defer watcher.deinit();
    try watcher.start();
    defer watcher.stop();
    _ = watcher.changedSinceLast();

    var worker = Worker{
        .updates = &updates,
        .cli = ShellyCli{ .allocator = allocator, .io = init.io, .environ_map = init.environ_map },
        .io = init.io,
        .gpa = allocator,
        .config = &config,
    };
    const worker_thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    defer worker_thread.join();

    while (true) {
        _ = service.tickTimeout(.{
            .duration = .{
                .raw = .fromMilliseconds(250),
                .clock = .awake,
            },
        }) catch |e| {
            std.debug.print("[loop] tick error: {any}\n", .{e});
        };

        if (updates.takeRefresh()) {
            menu_ctrl.invalidate() catch |e| std.debug.print("[loop] invalidate: {any}\n", .{e});
        }

        if (updates.takeNotif()) |n| {
            defer updates.freeNotif(n);
            _ = notifier.notify(.{
                .app_name = "Shelly",
                .icon = "shelly",
                .summary = n.summary,

                .body = n.body,
                .on_activate = &openShelly,
                .ctx = &runner,
            }) catch |e| std.debug.print("[loop] notify: {any}\n", .{e});
        }
    }
}

fn openShelly(ctx: ?*anyopaque, id: u32) void {
    _ = id;
    const runner: *AppRunner = @ptrCast(@alignCast(ctx.?));
    runner.launchApp() catch |e| std.debug.print("[shelly] launch failed: {any}\n", .{e});
}

fn buildMenu(ctx: ?*anyopaque, arena: std.mem.Allocator) !Tree {
    const updates: *Updates = @ptrCast(@alignCast(ctx.?));

    updates.mutex.lockUncancelable(updates.io);
    defer updates.mutex.unlock(updates.io);
    var items = std.ArrayList(MenuItem).empty;
    var tray_index: usize = 0;

    try addItem(arena, &items, &tray_index, "Open Shelly", true, true, .normal);
    open_shelly_index = tray_index;
    try addItem(arena, &items, &tray_index, "Update Packages", true, true, .normal);
    run_update_index = tray_index;
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

        if (updates.flatpak.items.len > 0) {
            tray_index += 1;
            try addItemWithSubmenu(
                @TypeOf(updates.flatpak.items[0]),
                arena,
                &items,
                &tray_index,
                updates.flatpak.items,
                flatpakLabel,
                "Flatpak",
                .normal,
            );
        }
    }

    try addItem(arena, &items, &tray_index, "", true, true, .separator);
    try addItem(arena, &items, &tray_index, "Exit", true, true, .normal);
    quit_index = tray_index;

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
    const updates: *Updates = @ptrCast(@alignCast(ctx.?));
    std.debug.print("id: {}\n", .{id});

    if (id == quit_index) std.process.exit(0);

    if (id == run_update_index) {
        updates.runner.spawnFixedUpdate() catch |e|
            std.debug.print("[menu] update spawn failed: {any}\n", .{e});
    }

    if (id == open_shelly_index) {
        updates.runner.launchApp() catch |e|
            std.debug.print("[menu] open failed: {any}\n", .{e});
    }
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("services/next_notification.zig");
}

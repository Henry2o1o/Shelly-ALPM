const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gio = bindings.gio;
const glib = bindings.glib;
const gobject = bindings.gobject;
const support = @import("support.zig");
const PackageObject = @import("../objects/package_object.zig").PackageObject;
const ShellyCli = @import("../shellpers/shelly_cli.zig").ShellyCli;
const SizeConverter = @import("../shellpers/size_converts.zig").SizeConverter;
const IconResolver = @import("../shellpers/icon_resolver.zig").IconResolver;
const runtime = @import("../shellpers/runtime.zig");

pub const PackagePage = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;

    pub const title: [:0]const u8 = "Package";
    pub const icon_name: [:0]const u8 = "package-x-generic-symbolic";
    const resource_path = "/com/shellyorg/shelly/ui/package_page.ui";

    const Private = struct {
        column_view: *gtk.ColumnView,
        name_column: *gtk.ColumnViewColumn,
        version_column: *gtk.ColumnViewColumn,
        size_column: *gtk.ColumnViewColumn,
        repository_column: *gtk.ColumnViewColumn,
        check_column: *gtk.ColumnViewColumn,
        selection: *gtk.SingleSelection,
        list_store: *gio.ListStore,
        loading_overlay: *gtk.Box,
        filter: *gtk.CustomFilter,
        loading_spinner: *gtk.Spinner,
        error_label: *gtk.Label,
        search_entry: *gtk.SearchEntry,
        filter_model: *gtk.FilterListModel,
        arena: ?*std.heap.ArenaAllocator,
        generation: u64,
        loaded: bool,
        resolver: IconResolver,
        search_text: [256]u8,
        search_len: usize,
        var offset: c_int = 0;
    };

    const LoadResult = struct {
        page: *Self,
        packages: []ShellyCli.Package,
        arena: *std.heap.ArenaAllocator,
        generation: u64,
        index: usize = 0,
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyPackagePage",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn priv(self: *Self) *Private {
        return gobject.ext.impl_helpers.getPrivate(self, Private, Private.offset);
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        const p = self.priv();
        p.loaded = false;
        p.arena = null;
        p.generation = 0;

        p.list_store = gio.ListStore.new(PackageObject.getGObjectType());
        p.selection = gtk.SingleSelection.new(p.list_store.as(gio.ListModel));
        gtk.ColumnView.setModel(p.column_view, p.selection.as(gtk.SelectionModel));

        p.filter = gtk.CustomFilter.new(&filter_func, self, null);
        p.filter_model = gtk.FilterListModel.new(p.list_store.as(gio.ListModel), p.filter.as(gtk.Filter));
        p.selection = gtk.SingleSelection.new(p.filter_model.as(gio.ListModel));
        gtk.ColumnView.setModel(p.column_view, p.selection.as(gtk.SelectionModel));

        setup_signal_text_label_column(p.name_column, &PackageObject.getName, gtk.Align.start);
        setup_signal_text_label_column(p.version_column, &PackageObject.getVersion, gtk.Align.start);
        setup_signal_text_label_column(p.repository_column, &PackageObject.getRepository, gtk.Align.start);

        const check_factory = gtk.SignalListItemFactory.new();
        _ = gtk.SignalListItemFactory.signals.setup.connect(check_factory, ?*anyopaque, &on_check_setup, null, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(check_factory, ?*anyopaque, &on_check_bind, null, .{});
        gtk.ColumnViewColumn.setFactory(p.check_column, check_factory.as(gtk.ListItemFactory));

        const size_factory = gtk.SignalListItemFactory.new();
        _ = gtk.SignalListItemFactory.signals.setup.connect(size_factory, ?*anyopaque, &size_setup, null, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(size_factory, ?*anyopaque, &size_bind, null, .{});
        gtk.ColumnViewColumn.setFactory(p.size_column, size_factory.as(gtk.ListItemFactory));

        _ = gtk.SearchEntry.signals.search_changed.connect(p.search_entry, *Self, &on_search_changed, self, .{});

        p.resolver = IconResolver.init(std.heap.c_allocator);

        support.connectLifecycle(Self, self);
    }

    fn setup_signal_text_label_column(column: *gtk.ColumnViewColumn, comptime getter: *const fn (*PackageObject) [:0]const u8, comptime halign: gtk.Align) void {
        const c = struct {
            fn setup(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
                const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;
                const label = gtk.Label.new("");
                gtk.Widget.setHalign(label.as(gtk.Widget), halign);
                gtk.ColumnViewCell.setChild(cell, label.as(gtk.Widget));
            }

            fn bind(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
                const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;
                const obj = gtk.ColumnViewCell.getItem(cell) orelse return;
                const pkg = gobject.ext.cast(PackageObject, obj) orelse return;
                const child = gtk.ColumnViewCell.getChild(cell) orelse return;
                const label = gobject.ext.cast(gtk.Label, child) orelse return;
                gtk.Label.setLabel(label, getter(pkg));
            }
        };

        const factory = gtk.SignalListItemFactory.new();
        _ = gtk.SignalListItemFactory.signals.setup.connect(factory, ?*anyopaque, &c.setup, null, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(factory, ?*anyopaque, &c.bind, null, .{});
        gtk.ColumnViewColumn.setFactory(column, factory.as(gtk.ListItemFactory));
    }

    fn on_check_setup(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
        const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;

        const check = gtk.CheckButton.new();
        gtk.Widget.setMarginStart(check.as(gtk.Widget), 10);
        gtk.Widget.setMarginEnd(check.as(gtk.Widget), 10);

        gobject.Object.setData(check.as(gobject.Object), "cell", cell);
        _ = gtk.CheckButton.signals.toggled.connect(check, ?*anyopaque, &on_check_toggled, null, .{});

        gtk.ColumnViewCell.setChild(cell, check.as(gtk.Widget));
    }

    fn on_check_bind(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
        const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;
        const obj = gtk.ColumnViewCell.getItem(cell) orelse return;
        const pkg = gobject.ext.cast(PackageObject, obj) orelse return;
        const child = gtk.ColumnViewCell.getChild(cell) orelse return;
        const check = gobject.ext.cast(gtk.CheckButton, child) orelse return;

        gobject.Object.setData(check.as(gobject.Object), "syncing", @ptrFromInt(1));
        gtk.CheckButton.setActive(check, @intFromBool(pkg.isSelected()));
        gobject.Object.setData(check.as(gobject.Object), "syncing", null);
    }

    fn size_bind(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
        const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;
        const obj = gtk.ColumnViewCell.getItem(cell) orelse return;
        const pkg = gobject.ext.cast(PackageObject, obj) orelse return;
        const child = gtk.ColumnViewCell.getChild(cell) orelse return;
        const label = gobject.ext.cast(gtk.Label, child) orelse return;
        var buf: [32]u8 = undefined;
        gtk.Label.setLabel(label, SizeConverter.convert_null_term(&buf, pkg.getInstalledSize()));
    }

    fn size_setup(_: *gtk.SignalListItemFactory, item: *gobject.Object, _: ?*anyopaque) callconv(.c) void {
        const cell = gobject.ext.cast(gtk.ColumnViewCell, item) orelse return;
        const label = gtk.Label.new("");
        gtk.Widget.setHalign(label.as(gtk.Widget), gtk.Align.start);
        gtk.ColumnViewCell.setChild(cell, label.as(gtk.Widget));
    }

    fn on_check_toggled(check: *gtk.CheckButton, _: ?*anyopaque) callconv(.c) void {
        if (gobject.Object.getData(check.as(gobject.Object), "syncing") != null) return;

        const cell_ptr = gobject.Object.getData(check.as(gobject.Object), "cell") orelse return;
        const cell: *gtk.ColumnViewCell = @ptrCast(@alignCast(cell_ptr));
        const obj = gtk.ColumnViewCell.getItem(cell) orelse return;
        const pkg = gobject.ext.cast(PackageObject, obj) orelse return;

        pkg.setSelected(gtk.CheckButton.getActive(check) != 0);
        // TODO: update cart / install button sensitivity
    }

    fn filter_func(item: *gobject.Object, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data.?));
        const p = self.priv();

        if (p.search_len < 1) return 1;

        const pkg = gobject.ext.cast(PackageObject, item) orelse return 0;
        const needle = p.search_text[0..p.search_len];

        return @intFromBool(contains_ignore_case(pkg.getName(), needle));
    }

    fn contains_ignore_case(haystack: []const u8, needle: []const u8) bool {
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        outer: while (i + needle.len <= haystack.len) : (i += 1) {
            for (needle, 0..) |n, j| {
                if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(n)) continue :outer;
            }
            return true;
        }
        return false;
    }

    fn on_search_changed(entry: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        const p = self.priv();

        const text = gtk.Editable.getText(entry.as(gtk.Editable));
        const slice = std.mem.span(text);
        const len = @min(slice.len, p.search_text.len);
        @memcpy(p.search_text[0..len], slice[0..len]);
        p.search_len = len;

        gtk.Filter.changed(p.filter.as(gtk.Filter), .different);
    }

    pub fn onMap(self: *Self) void {
        const p = self.priv();
        if (p.loaded) return;
        p.loaded = true;
        p.generation += 1;

        show_loading(self);

        const arena_ptr = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return;
        arena_ptr.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        p.arena = arena_ptr;

        const thread = std.Thread.spawn(.{}, load_worker, .{ self, p.generation }) catch return;
        thread.detach();
    }

    //Unmap stuff we owned
    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        if (!p.loaded) return;
        p.loaded = false;

        gio.ListStore.removeAll(p.list_store);

        if (p.arena) |a| {
            a.deinit();
            std.heap.c_allocator.destroy(a);
            p.arena = null;
        }
    }

    fn load_worker(page: *Self, generation: u64) void {
        const arena_ptr = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return;
        arena_ptr.* = std.heap.ArenaAllocator.init(std.heap.c_allocator);

        const alloc = arena_ptr.allocator();

        const p = page.priv();
        if (!p.resolver.loaded) {
            p.resolver.load(runtime.io, runtime.environ_map) catch {};
        }

        var threaded: std.Io.Threaded = .init(alloc, .{});
        defer threaded.deinit();

        const cli = ShellyCli{ .allocator = alloc, .io = threaded.io() };
        const parsed = cli.get_packages() catch |err| {
            std.debug.print("get_packages failed: {t}\n", .{err});
            return;
        };
        post_result(page, parsed.value, arena_ptr, generation);
    }

    fn post_result(page: *Self, packages: []ShellyCli.Package, arena: *std.heap.ArenaAllocator, generation: u64) void {
        const result = std.heap.c_allocator.create(LoadResult) catch return;
        result.* = .{
            .page = page,
            .packages = packages,
            .arena = arena,
            .generation = generation,
        };
        _ = glib.idleAdd(&onLoadComplete, result);
    }

    fn onLoadComplete(data: ?*anyopaque) callconv(.c) c_int {
        const result: *LoadResult = @ptrCast(@alignCast(data.?));
        const p = result.page.priv();

        if (result.generation != p.generation) {
            result.arena.deinit();
            std.heap.c_allocator.destroy(result.arena);
            std.heap.c_allocator.destroy(result);
            return 0;
        }

        const page_alloc = (p.arena orelse {
            result.arena.deinit();
            std.heap.c_allocator.destroy(result.arena);
            std.heap.c_allocator.destroy(result);
            return 0;
        }).allocator();

        const batch_size = 250;
        const end = @min(result.index + batch_size, result.packages.len);

        for (result.packages[result.index..end]) |d| {
            const pkg = PackageObject.new(page_alloc, d.Name, d.Version, d.Repository, d.Description, d.InstalledSize, false);
            gio.ListStore.append(p.list_store, pkg.as(gobject.Object));
            pkg.as(gobject.Object).unref();
        }
        result.index = end;

        if (result.index < result.packages.len) return 1;

        const page = result.page;
        result.arena.deinit();
        std.heap.c_allocator.destroy(result.arena);
        std.heap.c_allocator.destroy(result);
        hide_loading(page);
        return 0;
    }

    fn show_loading(self: *Self) void {
        const p = self.priv();
        gtk.Widget.setVisible(p.error_label.as(gtk.Widget), 0);
        gtk.Spinner.setSpinning(p.loading_spinner, 1);
        gtk.Widget.setVisible(p.loading_spinner.as(gtk.Widget), 1);
        gtk.Widget.setVisible(p.loading_overlay.as(gtk.Widget), 1);
    }

    fn hide_loading(self: *Self) void {
        const p = self.priv();
        gtk.Spinner.setSpinning(p.loading_spinner, 0);
        gtk.Widget.setVisible(p.loading_overlay.as(gtk.Widget), 0);
    }

    const template_children = .{
        .{ "package_column_view", @offsetOf(Private, "column_view") },
        .{ "name_column", @offsetOf(Private, "name_column") },
        .{ "version_column", @offsetOf(Private, "version_column") },
        .{ "size_column", @offsetOf(Private, "size_column") },
        .{ "repository_column", @offsetOf(Private, "repository_column") },
        .{ "check_column", @offsetOf(Private, "check_column") },
        .{ "loading_spinner", @offsetOf(Private, "loading_spinner") },
        .{ "loading_overlay", @offsetOf(Private, "loading_overlay") },
        .{ "loading_spinner", @offsetOf(Private, "loading_spinner") },
        .{ "error_label", @offsetOf(Private, "error_label") },
        .{ "search_entry", @offsetOf(Private, "search_entry") },
    };

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            const wc = gobject.ext.as(gtk.Widget.Class, class);
            gtk.Widget.Class.setTemplateFromResource(wc, resource_path);
            inline for (template_children) |c| {
                support.bindChild(class, Private.offset, c[0], c[1]);
            }
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "install_local", @ptrCast(&install_local));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "install_selected", @ptrCast(&install_selected));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_grid_view_toggled", @ptrCast(&on_grid_view_toggled));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_list_view_toggled", @ptrCast(&on_list_view_toggled));
        }
    };

    fn install_local(self: *Self) callconv(.c) void {
        _ = self;
    }
    fn install_selected(self: *Self) callconv(.c) void {
        _ = self;
    }
    fn on_grid_view_toggled(self: *Self) callconv(.c) void {
        _ = self;
    }
    fn on_list_view_toggled(self: *Self) callconv(.c) void {
        _ = self;
    }
};

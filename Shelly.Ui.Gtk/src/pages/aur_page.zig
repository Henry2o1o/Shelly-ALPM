const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gobject = bindings.gobject;
const glib = bindings.glib;
const support = @import("support.zig");

pub const AurPage = extern struct {
    parent_instance: Parent,
    const Self = @This();
    pub const Parent = gtk.Box;
    pub const title: [:0]const u8 = "AUR";
    pub const icon_name: [:0]const u8 = "arch-symbolic";
    const resource_path = "/com/shellyorg/shelly/ui/aur_page.ui";

    const Private = struct {
        search_entry: *gtk.SearchEntry,
        installed_toggle: *gtk.ToggleButton,
        options_menu: *gtk.MenuButton,
        install_button: *gtk.Button,
        results_stack: *gtk.Stack,
        loading_spinner: *gtk.Spinner,
        package_grid: *gtk.ColumnView,
        check_column: *gtk.ColumnViewColumn,
        name_column: *gtk.ColumnViewColumn,
        votes_column: *gtk.ColumnViewColumn,
        popularity_column: *gtk.ColumnViewColumn,
        version_column: *gtk.ColumnViewColumn,
        empty_label: *gtk.Label,
        empty_hint_label: *gtk.Label,
        error_label: *gtk.Label,
        retry_button: *gtk.Button,
        chroot_check: *gtk.CheckButton,
        run_checks_check: *gtk.CheckButton,

        loaded: bool,
        last_query: ?[:0]u8,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyAurPage",
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
        p.last_query = null;
        support.connectLifecycle(Self, self);
    }

    fn dispose(self: *Self) callconv(.c) void {
        const p = self.priv();
        if (p.last_query) |q| {
            glib.free(q.ptr);
            p.last_query = null;
        }
        gtk.Widget.disposeTemplate(self.as(gtk.Widget), getGObjectType());
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(gobject.Object));
    }

    pub fn onMap(self: *Self) void {
        const p = self.priv();
        if (p.loaded) return;
        p.loaded = true;
        _ = gtk.Widget.grabFocus(p.search_entry.as(gtk.Widget));
    }

    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        if (!p.loaded) return;
        p.loaded = false;
    }

    const State = enum {
        prompt,
        loading,
        results,
        empty,
        err,

        fn name(self: State) [:0]const u8 {
            return switch (self) {
                .prompt => "prompt",
                .loading => "loading",
                .results => "results",
                .empty => "empty",
                .err => "error",
            };
        }
    };

    fn set_state(self: *Self, state: State) void {
        const p = self.priv();
        gtk.Stack.setVisibleChildName(p.results_stack, state.name());
        if (state == .loading) {
            gtk.Spinner.start(p.loading_spinner);
        } else {
            gtk.Spinner.stop(p.loading_spinner);
        }
    }

    fn set_last_query(self: *Self, text: [*:0]const u8) void {
        const p = self.priv();
        if (p.last_query) |q| glib.free(q.ptr);
        const dup = glib.strdup(text);
        p.last_query = std.mem.span(dup.?);
    }

    fn search_text(self: *Self) [*:0]const u8 {
        const p = self.priv();
        return gtk.Editable.getText(p.search_entry.as(gtk.Editable));
    }

    fn run_search(self: *Self, term: [*:0]const u8) void {
        self.set_last_query(term);
        self.set_state(.loading);

        // TODO:
    }

    fn load_installed(self: *Self) void {
        self.set_state(.loading);
        // TODO:
    }

    fn selection_count(self: *Self) u32 {
        _ = self;
        // TODO: count checked rows in your list model.
        return 0;
    }

    fn refresh_install_sensitivity(self: *Self) void {
        const p = self.priv();
        const installed_mode = gtk.ToggleButton.getActive(p.installed_toggle) != 0;
        const enabled = !installed_mode and self.selection_count() > 0;
        gtk.Widget.setSensitive(p.install_button.as(gtk.Widget), @intFromBool(enabled));
    }

    fn on_search_changed(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        const p = self.priv();
        if (gtk.ToggleButton.getActive(p.installed_toggle) != 0) return;

        const text = self.search_text();
        if (text[0] == 0) {
            self.set_state(.prompt);
            return;
        }
        // TODO:
    }

    fn on_search_activate(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        const p = self.priv();
        if (gtk.ToggleButton.getActive(p.installed_toggle) != 0) {
            gtk.ToggleButton.setActive(p.installed_toggle, 0);
        }
        const text = self.search_text();
        if (text[0] == 0) {
            self.set_state(.prompt);
            return;
        }
        self.run_search(text);
    }

    fn on_installed_toggled(button: *gtk.ToggleButton, self: *Self) callconv(.c) void {
        const p = self.priv();
        if (gtk.ToggleButton.getActive(button) != 0) {
            self.load_installed();
        } else if (p.last_query) |q| {
            self.run_search(q.ptr);
        } else {
            self.set_state(.prompt);
        }
        self.refresh_install_sensitivity();
    }

    fn on_install_clicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const p = self.priv();
        const use_chroot = gtk.CheckButton.getActive(p.chroot_check) != 0;
        const run_checks = gtk.CheckButton.getActive(p.run_checks_check) != 0;
        _ = use_chroot;
        _ = run_checks;

        // TODO:
    }

    fn on_retry_clicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const p = self.priv();
        if (gtk.ToggleButton.getActive(p.installed_toggle) != 0) {
            self.load_installed();
        } else if (p.last_query) |q| {
            self.run_search(q.ptr);
        } else {
            self.set_state(.prompt);
        }
    }

    const template_children = .{
        .{ "search_entry", @offsetOf(Private, "search_entry") },
        .{ "installed_toggle", @offsetOf(Private, "installed_toggle") },
        .{ "options_menu", @offsetOf(Private, "options_menu") },
        .{ "install_button", @offsetOf(Private, "install_button") },
        .{ "results_stack", @offsetOf(Private, "results_stack") },
        .{ "loading_spinner", @offsetOf(Private, "loading_spinner") },
        .{ "package_grid", @offsetOf(Private, "package_grid") },
        .{ "check_column", @offsetOf(Private, "check_column") },
        .{ "name_column", @offsetOf(Private, "name_column") },
        .{ "votes_column", @offsetOf(Private, "votes_column") },
        .{ "popularity_column", @offsetOf(Private, "popularity_column") },
        .{ "version_column", @offsetOf(Private, "version_column") },
        .{ "empty_label", @offsetOf(Private, "empty_label") },
        .{ "empty_hint_label", @offsetOf(Private, "empty_hint_label") },
        .{ "error_label", @offsetOf(Private, "error_label") },
        .{ "retry_button", @offsetOf(Private, "retry_button") },
        .{ "chroot_check", @offsetOf(Private, "chroot_check") },
        .{ "run_checks_check", @offsetOf(Private, "run_checks_check") },
    };

    const template_callbacks = .{
        .{ "on_search_changed", &on_search_changed },
        .{ "on_search_activate", &on_search_activate },
        .{ "on_installed_toggled", &on_installed_toggled },
        .{ "on_install_clicked", &on_install_clicked },
        .{ "on_retry_clicked", &on_retry_clicked },
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
            inline for (template_callbacks) |cb| {
                gtk.Widget.Class.bindTemplateCallbackFull(wc, cb[0], @ptrCast(cb[1]));
            }
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }
    };
};

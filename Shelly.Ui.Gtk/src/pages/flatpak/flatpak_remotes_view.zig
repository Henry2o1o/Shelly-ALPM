const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gobject = bindings.gobject;
const support = @import("../support.zig");

pub const FlatpakRemotesView = extern struct {
    parent_instance: Parent,

    const Self = @This();
    pub const Parent = gtk.Box;

    const resource_path = "/com/shellyorg/shelly/ui/flatpak/flatpak_remotes_view.ui";

    const Private = struct {
        remotes_stack: *gtk.Stack,
        remotes_list_page: *gtk.Box,
        add_remote_page: *gtk.Box,
        list_remotes: *gtk.ListView,
        loaded: bool,
        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyFlatpakRemotesView",
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

        // name the inner stack pages so we can switch by name
        const list_page = gtk.Stack.getPage(p.remotes_stack, p.remotes_list_page.as(gtk.Widget));
        gtk.StackPage.setName(list_page, "list");
        const add_page = gtk.Stack.getPage(p.remotes_stack, p.add_remote_page.as(gtk.Widget));
        gtk.StackPage.setName(add_page, "add");

        support.connectLifecycle(Self, self);
    }

    pub fn showAddForm(self: *Self) void {
        gtk.Stack.setVisibleChildName(self.priv().remotes_stack, "add");
    }

    pub fn showList(self: *Self) void {
        gtk.Stack.setVisibleChildName(self.priv().remotes_stack, "list");
    }

    pub fn onMap(self: *Self) void {
        const p = self.priv();
        if (p.loaded) return;
        p.loaded = true;
        std.debug.print("remotes view mapped\n", .{});
    }

    pub fn onUnmap(self: *Self) void {
        const p = self.priv();
        if (!p.loaded) return;
        p.loaded = false;
        std.debug.print("remotes view unmapped\n", .{});
    }

    const template_children = .{
        .{ "remotes_stack", @offsetOf(Private, "remotes_stack") },
        .{ "remotes_list_page", @offsetOf(Private, "remotes_list_page") },
        .{ "add_remote_page", @offsetOf(Private, "add_remote_page") },
        .{ "list_remotes", @offsetOf(Private, "list_remotes") },
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
        }
    };
};

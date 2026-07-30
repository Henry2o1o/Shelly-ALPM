const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gtk = bindings.gtk;
const gobject = bindings.gobject;

const support = @import("../../pages/support.zig");

const resource_path = "/com/example/shelly/ui/polkit-dialog.ui";

pub const ShellyPolkitDialog = extern struct {
    parent_instance: Parent,

    pub const Parent = gtk.Box;
    const Self = @This();

    const Private = struct {
        title_label: *gtk.Label,
        message_label: *gtk.Label,
        confirm_button: *gtk.Button,
        cancel_button: *gtk.Button,

        on_confirm_cb: ?*const fn (*Self, ?*anyopaque) void = null,
        on_cancel_cb: ?*const fn (*Self, ?*anyopaque) void = null,
        user_data: ?*anyopaque = null,

        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ShellyPolkitDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    fn private(self: *Self) *Private {
        return gobject.ext.impl_helpers.getPrivate(self, Private, Private.offset);
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    fn on_confirm(self: *Self) callconv(.c) void {
        const p = self.private();
        if (p.on_confirm_cb) |cb| cb(self, p.user_data);
    }

    fn on_cancel(self: *Self) callconv(.c) void {
        const p = self.private();
        if (p.on_cancel_cb) |cb| cb(self, p.user_data);
    }

    fn on_activate_link(_: *gtk.Label, uri: [*:0]const u8, _: ?*anyopaque) callconv(.c) c_int {
        const launcher = gtk.UriLauncher.new(uri);
        launcher.launch(null, null, null, null);
        return 1;
    }

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    pub fn setCallbacks(
        self: *Self,
        on_confirm_cb: ?*const fn (*Self, ?*anyopaque) void,
        on_cancel_cb: ?*const fn (*Self, ?*anyopaque) void,
        user_data: ?*anyopaque,
    ) void {
        const p = self.private();
        p.on_confirm_cb = on_confirm_cb;
        p.on_cancel_cb = on_cancel_cb;
        p.user_data = user_data;
    }

    pub fn connectLink(self: *Self) void {
        const p = self.private();
        _ = gobject.signalConnectData(
            p.message_label.as(gobject.Object),
            "activate-link",
            @ptrCast(&on_activate_link),
            null,
            null,
            .{},
        );
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    const template_children = .{
        .{ "title_label", @offsetOf(Private, "title_label") },
        .{ "message_label", @offsetOf(Private, "message_label") },
        .{ "confirm_button", @offsetOf(Private, "confirm_button") },
        .{ "cancel_button", @offsetOf(Private, "cancel_button") },
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
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_confirm", @ptrCast(&on_confirm));
            gtk.Widget.Class.bindTemplateCallbackFull(wc, "on_cancel", @ptrCast(&on_cancel));
        }
    };
};

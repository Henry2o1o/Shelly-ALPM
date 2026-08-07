const std = @import("std");
const bindings = @import("Shelly_Ui_Gtk");
const gio = bindings.gio;
const gobject = bindings.gobject;
const glib = bindings.glib;

const TrayPath: [:0]const u8 = "/org/shellyorg/Notifications";
const TrayInterface: [:0]const u8 = "com.shellyorg.shelly";

pub const DBus = struct {
    connection: ?*gio.DBusConnection = null, // session
    system_connection: ?*gio.DBusConnection = null, // system

    pub fn deinit(self: *DBus) void {
        if (self.connection) |c| c.unref();
        if (self.system_connection) |c| c.unref();
    }

    pub fn updatesMadeInUi(self: *DBus) void {
        self.emitTray("Refresh");
    }

    fn ensureBus(self: *DBus, slot: *?*gio.DBusConnection, bus: gio.BusType) ?*gio.DBusConnection {
        _ = self;
        if (slot.*) |conn| return conn;
        var err: ?*glib.Error = null;
        const conn = gio.busGetSync(bus, null, &err);
        if (err) |e| {
            std.log.warn("bus_get_sync failed: {s}", .{e.f_message orelse "unknown"});
            glib.Error.free(e);
            return null;
        }
        slot.* = conn;
        return conn;
    }

    fn ensureConnection(self: *DBus) ?*gio.DBusConnection {
        return self.ensureBus(&self.connection, .session);
    }

    fn ensureSystemConnection(self: *DBus) ?*gio.DBusConnection {
        return self.ensureBus(&self.system_connection, .system);
    }

    fn emitTray(self: *DBus, signal: [:0]const u8) void {
        const conn = self.ensureConnection() orelse return;
        var err: ?*glib.Error = null;
        _ = gio.DBusConnection.emitSignal(
            conn,
            null,
            TrayPath,
            TrayInterface,
            signal,
            null,
            &err,
        );
        if (err) |e| {
            std.log.warn("emit_signal failed: {s}", .{e.f_message orelse "unknown"});
            glib.Error.free(e);
        }
    }

    pub fn polkitAvailable(self: *DBus) bool {
        const conn = self.ensureSystemConnection() orelse return false;

        const params = glib.Variant.new("(s)", "org.freedesktop.PolicyKit1");

        var call_err: ?*glib.Error = null;
        const result = conn.callSync(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "NameHasOwner",
            params,
            glib.VariantType.new("(b)"),
            .{},
            -1,
            null,
            &call_err,
        );
        if (call_err) |e| {
            std.log.warn("NameHasOwner failed: {s}", .{e.f_message orelse "unknown"});
            glib.Error.free(e);
            return false;
        }

        if (call_err) |e| {
            std.log.warn("NameHasOwner failed: {s}", .{e.f_message orelse "unknown"});
            glib.Error.free(e);
            return false;
        }
        const res = result orelse return false;
        defer res.unref();

        const child = res.getChildValue(0);
        defer child.unref();

        std.log.debug("NameHasOwner result: {}", .{child.getBoolean()});

        return child.getBoolean() != 0;
    }
};

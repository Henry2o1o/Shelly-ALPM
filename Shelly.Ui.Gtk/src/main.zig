const gtk = @import("Shelly_Ui_Gtk").gtk;

pub fn main() void {
    const application = gtk.gtk_application_new(
        "io.github.shelly",
        @as(gtk.GApplicationFlags, gtk.G_APPLICATION_DEFAULT_FLAGS),
    );
    if (application == null) return;
    defer gtk.g_object_unref(application);

    _ = gtk.g_signal_connect_data(
        application,
        "activate",
        @ptrCast(&activate),
        null,
        null,
        @as(gtk.GConnectFlags, gtk.G_CONNECT_DEFAULT),
    );

    _ = gtk.g_application_run(@ptrCast(application), 0, null);
}

fn activate(application: [*c]gtk.GtkApplication, _: gtk.gpointer) callconv(.c) void {
    const widget = gtk.gtk_application_window_new(application);
    const window: [*c]gtk.GtkWindow = @ptrCast(widget);

    gtk.gtk_window_set_title(window, "Shelly");
    gtk.gtk_window_set_default_size(window, 960, 640);
    gtk.gtk_window_present(window);
}

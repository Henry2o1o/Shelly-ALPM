//! Public API for Shelly's GTK user interface.

/// Raw GTK 4, GDK, GSK, GLib, GObject, Gio, Pango, and Cairo declarations.
///
/// The names and types intentionally follow the C API, for example:
/// `gtk.gtk_window_set_title(window, "Shelly")`.
pub const gtk = @import("gtk4");

test "GTK 4 binding is available from the package root" {
    const std = @import("std");

    try std.testing.expectEqual(
        @as(c_uint, gtk.GTK_MAJOR_VERSION),
        gtk.gtk_get_major_version(),
    );
}

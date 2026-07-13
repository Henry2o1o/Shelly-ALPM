// Wrapper used to generate the committed GTK 4 binding in gtk.zig.
//
// Regenerate from this directory with:
//
//   zig translate-c -lc $(pkg-config --cflags-only-I gtk4) gtk_include.h > gtk.zig
//
// Then re-apply the two manual fixups documented at the top of gtk.zig.

// GLib's diagnostic pragmas are irrelevant to bindings and are not currently
// understood by Zig 0.16's arocc-based C translator.
#define _Pragma(x)

// The translator can process GDK's guarded version header after gdk.h has
// undefined its umbrella sentinel. This bypasses only that inclusion guard.
#define GTK_COMPILATION 1

#include <gtk/gtk.h>

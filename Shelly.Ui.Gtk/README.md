# Shelly GTK UI

The GTK 4 bindings in `generated/zig-gobject` are generated from the pinned
zig-gobject source dependency in `build.zig.zon`. They include GTK and the
libraries discovered from its GIR dependency graph, including GLib, GObject,
GIO, and Pango. The generated package is committed; the transient `zig-pkg`
directory is recreated by Zig and is not committed.

Regenerate them against the GIR files installed on the development system with:

```sh
zig build generate-bindings
```

Update the generator to the latest upstream `main` commit, then regenerate with:

```sh
zig fetch --save=gobject_codegen git+https://github.com/ianprime0509/zig-gobject.git
zig build generate-bindings
```

Generation requires GTK 4 development files, GObject Introspection data,
`pkg-config`, and `xsltproc`.

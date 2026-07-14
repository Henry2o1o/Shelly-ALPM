#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
generator_root=$1
generated_bindings="$project_root/generated/zig-gobject"

(
    cd "$generator_root"
    zig build codegen -Dmodules=Gtk-4.0
)

rm -rf "$generated_bindings"
mkdir -p "$(dirname -- "$generated_bindings")"
cp -a "$generator_root/zig-out/bindings" "$generated_bindings"

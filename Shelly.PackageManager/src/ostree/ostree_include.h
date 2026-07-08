// ostree_include.h
//
// Wrapper header used to generate the committed static binding `ostree.zig`.
//
// Regenerate with:
//
//   zig translate-c -lc $(pkg-config --cflags ostree-1) ostree_include.h > ostree.zig
//
#define _Pragma(x)

#include <ostree-1/ostree.h>
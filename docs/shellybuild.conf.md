# `shellybuild.conf`

`shellybuild.conf` is Shelly's data-only configuration for the in-process AUR builder. It replaces `makepkg.conf` for that builder only; external `makepkg` commands and clean-chroot builds do not read it.

## Precedence

Shelly starts with compiled safe defaults and merges these optional files field by field:

1. `/etc/shellybuild.conf`
2. `$XDG_CONFIG_HOME/shelly/shellybuild.conf`
3. `~/.config/shelly/shellybuild.conf` when `XDG_CONFIG_HOME` is unset or not absolute

The later user layer overrides individual system fields without replacing unrelated fields. Elevated coordinator flows resolve the configuration from the original invoking user's home rather than the root coordinator's XDG directory.

Both files, every section, and every individual key are optional. The packaged `/etc/shellybuild.conf` is a commented template and therefore changes no compiled default until an administrator uncomments a value. An empty or comment-only file is valid.

Malformed TOML, unknown sections or keys, unsupported package option names, invalid package extensions, and non-absolute destination paths fail before PKGBUILD execution. Missing files are allowed. The format does not evaluate shell code or source fragments.

## Schema

The following are the compiled defaults and valid example values; they do not all need to appear in a configuration file:

```toml
[build]
carch = "x86_64"
chost = "x86_64-pc-linux-gnu"
cppflags = []
cflags = ["-O2", "-pipe"]
cxxflags = ["-O2", "-pipe"]
ldflags = ["-Wl,-z,relro", "-Wl,-z,now"]
ltoflags = ["-flto=auto"]
makeflags = ["-j2"]
check = true
ccache = false
distcc = false
distcc_hosts = []

[package]
packager = "Unknown Packager"
extension = ".pkg.tar.zst"
options = ["strip", "docs", "emptydirs", "zipman", "purge", "lto"]
strip_binaries = ["--strip-all"]
strip_shared = ["--strip-debug"]
strip_static = ["--strip-unneeded"]

[destinations]
build = "/var/tmp/shellybuild"
packages = "/var/cache/shelly/packages"
sources = "/var/cache/shelly/sources"
logs = "/var/log/shelly/build"
```

Flag and host arrays are joined with spaces only when a child process is launched. `ccache` prepends `/usr/lib/ccache/bin` to `PATH`; `distcc` prepends `/usr/lib/distcc/bin` and exports `DISTCC_HOSTS`. Shelly does not install those tools.

Supported package options are `strip`, `docs`, `libtool`, `staticlibs`, `emptydirs`, `zipman`, `purge`, `debug`, `lto`, `autodeps`, `buildflags`, and `makeflags`. Content tidy operations remain limited as described in the [makepkg compatibility gaps](makepkg-compatibility-gaps.md).

## PKGBUILD and CLI overrides

Global PKGBUILD `options=()` values merge over configured package options. `!buildflags` removes `CPPFLAGS`, `CFLAGS`, `CXXFLAGS`, and `LDFLAGS`; `!makeflags` removes `MAKEFLAGS`; `!lto` removes `LTOFLAGS`. `CHOST` remains available, while distcc hosts and wrapper paths follow the configured build environment.

Configured `check` is the default for in-process builds. `--check` explicitly enables `check()`, and `--no-check` explicitly disables it.

## Destinations and source cache

- `build` contains collision-resistant package-base work roots. `$srcdir`, `$pkgdir`, temporary extraction trees, and `.BUILDINFO`'s `builddir` use this location.
- `packages` receives atomically committed binary package archives.
- `sources` stores reusable HTTP files and Git mirrors. HTTP entries are downloaded to temporary siblings and renamed into place; checksum failures discard and reacquire an entry. Git mirrors refresh before local materialization.
- `logs` receives mandatory build logs.

The reviewed checkout remains `$startdir`. Local PKGBUILD sources and `verify()` exposure use that reviewed directory and are not copied into the shared cache.

## Logs

Every in-process build creates one file named `<package-base>-<unix-seconds>-<random>.log` under the configured log destination before source or lifecycle execution. The log records phase boundaries, labels stdout and stderr separately, and ends with `success`, `failed`, or `cancelled`. Output continues to stream to normal CLI and UI operation events. Logs are retained on every outcome; inability to create the log prevents PKGBUILD execution.

`SRCPKGDEST`, source-package generation, package signing, and arbitrary shell configuration are intentionally unsupported.

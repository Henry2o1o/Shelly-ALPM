#!/usr/bin/env bash

set -euo pipefail
unset LD_PRELOAD

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="${SHELLY_FLATPAK_BUILD_ROOT:-$(mktemp -d /tmp/shelly-flatpak-separation.XXXXXX)}"
keep_build_root="${SHELLY_FLATPAK_KEEP_BUILD_ROOT:-0}"

cleanup() {
    if [[ "${keep_build_root}" != "1" ]]; then
        rm -rf -- "${build_root}"
    fi
}
trap cleanup EXIT

mkdir -p \
    "${build_root}/backend" \
    "${build_root}/cli" \
    "${build_root}/cache" \
    "${build_root}/global-cache"

zig_common=(
    --cache-dir "${build_root}/cache"
    --global-cache-dir "${build_root}/global-cache"
)

(
    cd "${repo_root}/Shelly.Flatpak.Backend"
    zig build "${zig_common[@]}" \
        --prefix "${build_root}/backend" \
        -Dcpu=baseline \
        -Doptimize=ReleaseSafe
    zig build test "${zig_common[@]}"
    zig build abi-test "${zig_common[@]}"
    zig build integration-test "${zig_common[@]}"
)

(
    cd "${repo_root}/Shelly.PackageManager"
    zig build flatpak-test "${zig_common[@]}"
)

(
    cd "${repo_root}/Shelly.Cli.Zig"
    zig build "${zig_common[@]}" \
        --prefix "${build_root}/cli" \
        -Dcpu=baseline \
        -Doptimize=ReleaseSmall
    zig build test "${zig_common[@]}"
)

"${repo_root}/scripts/check-flatpak-separation.sh" \
    "${build_root}/cli/bin/shelly" \
    "${build_root}/backend/lib/libshelly-flatpak-backend.so.1"

"${build_root}/cli/bin/shelly" --help >/dev/null
"${build_root}/cli/bin/shelly" --version >/dev/null
"${build_root}/cli/bin/shelly" utility --completions bash >/dev/null

echo "Flatpak separation build and core-only smoke tests passed."

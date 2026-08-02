#!/usr/bin/env bash
#
# update-translations.sh — extract, merge, and maintain gettext translations
# for the shelly-notifications tray.
#
# What it does:
#   1. Extracts translatable strings from src/ into po/<DOMAIN>.pot
#   2. Merges the fresh .pot into every existing po/<lang>.po
#      (keeps existing translations, adds new strings, marks removed ones)
#   3. Optionally prunes obsolete/untranslated entries
#   4. Optionally compiles .po -> .mo and installs them
#
# Usage:
#   ./update-translations.sh                # extract + merge all existing .po
#   ./update-translations.sh --new es       # also create po/es.po if missing
#   ./update-translations.sh --prune        # drop obsolete (#~) entries after merge
#   ./update-translations.sh --compile      # build .mo files into build/locale
#   ./update-translations.sh --install      # install .mo into $PREFIX/share/locale
#   ./update-translations.sh --new de --prune --compile   # combine flags
#
set -euo pipefail

# ---- Config -----------------------------------------------------------------
DOMAIN="shelly-notifications"
SRC_DIR="src"
PO_DIR="po"
POT="${PO_DIR}/${DOMAIN}.pot"
# Where compiled .mo files go for local testing:
BUILD_LOCALE_DIR="build/locale"
# Where --install puts them (override with PREFIX=/foo ./update-translations.sh --install):
PREFIX="${PREFIX:-/usr}"
INSTALL_LOCALE_DIR="${PREFIX}/share/locale"
# Package metadata for the .pot header:
PKG_NAME="Shelly Notifications"
PKG_VERSION="0.0.1"
BUGS_ADDRESS="https://github.com/Seafoam-Labs/conch/issues"
# -----------------------------------------------------------------------------

NEW_LANGS=()
DO_PRUNE=0
DO_COMPILE=0
DO_INSTALL=0
FUZZY_MODE="clear"   # keep | accept | clear  (default: clear -> no fuzzy, untranslated)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --new)     NEW_LANGS+=("$2"); shift 2 ;;
        --prune)   DO_PRUNE=1; shift ;;
        --compile) DO_COMPILE=1; shift ;;
        --install) DO_INSTALL=1; DO_COMPILE=1; shift ;;   # install implies compile
        --accept-fuzzy) FUZZY_MODE="accept"; shift ;;  # un-fuzzy, keep the guessed text
        --keep-fuzzy)   FUZZY_MODE="keep";   shift ;;  # leave #, fuzzy markers as-is
        -h|--help)
            sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

for tool in xgettext msgmerge msgfmt msginit msgattrib; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "error: '$tool' not found. Install the 'gettext' package." >&2
        exit 1
    }
done

mkdir -p "$PO_DIR"

# ---- 1. Extract strings -> .pot ---------------------------------------------
echo ">> Extracting translatable strings from ${SRC_DIR}/ ..."
# Zig isn't a native xgettext language; --language=C + --keyword=_ picks up
# our _("...") wrapper. Add more --keyword flags here if you introduce other
# translation helpers (e.g. ngettext).
mapfile -t ZIG_FILES < <(find "$SRC_DIR" -name '*.zig' | sort)

xgettext \
    --language=C \
    --keyword=_ \
    --keyword=trans \
    --from-code=UTF-8 \
    --add-comments=TRANSLATORS \
    --sort-output \
    --package-name="$PKG_NAME" \
    --package-version="$PKG_VERSION" \
    --msgid-bugs-address="$BUGS_ADDRESS" \
    --output="$POT" \
    "${ZIG_FILES[@]}"

# Count how many strings were extracted.
POT_COUNT=$(grep -c '^msgid "' "$POT" || true)
echo "   ${POT}: ${POT_COUNT} message(s)"

# ---- 2. Create any requested new language .po files -------------------------
for lang in "${NEW_LANGS[@]:-}"; do
    [[ -z "$lang" ]] && continue
    target="${PO_DIR}/${lang}.po"
    if [[ -f "$target" ]]; then
        echo ">> ${target} already exists, will merge (not recreate)."
    else
        echo ">> Creating new translation ${target} ..."
        msginit \
            --no-translator \
            --input="$POT" \
            --locale="$lang" \
            --output="$target"
    fi
done

# ---- 3. Merge .pot into every existing .po ----------------------------------
shopt -s nullglob
PO_FILES=("${PO_DIR}"/*.po)
shopt -u nullglob

if [[ ${#PO_FILES[@]} -eq 0 ]]; then
    echo ">> No .po files found in ${PO_DIR}/. Create one with: $0 --new <lang>"
else
    for po in "${PO_FILES[@]}"; do
        echo ">> Merging into ${po} ..."
        # --update: modify in place; --backup=none: no .po~ files.
        # msgmerge keeps existing translations, adds new msgids, and marks
        # strings that disappeared from source as obsolete (#~ ...).
        msgmerge \
            --update \
            --backup=none \
            --sort-output \
            --previous \
            "$po" "$POT"

        # Handle fuzzy entries (msgmerge's guessed translations from similar old
        # strings). msgfmt skips fuzzy by default, so these never reach the .mo.
        case "$FUZZY_MODE" in
            clear)
                # Remove the fuzzy flag AND blank the guessed text, so the entry
                # is cleanly untranslated (no #, fuzzy, empty msgstr) for a human
                # to fill in. This is the default.
                echo "   clearing fuzzy entries in ${po} (-> untranslated) ..."
                tmp="$(mktemp)"
                msgattrib --clear-fuzzy --empty "$po" --output-file="$tmp"
                mv "$tmp" "$po"
                ;;
            accept)
                # Remove the fuzzy flag but KEEP the guessed translation as final.
                echo "   accepting fuzzy guesses in ${po} ..."
                tmp="$(mktemp)"
                msgattrib --clear-fuzzy "$po" --output-file="$tmp"
                mv "$tmp" "$po"
                ;;
            keep)
                : # leave #, fuzzy markers untouched
                ;;
        esac

        if [[ "$DO_PRUNE" -eq 1 ]]; then
            echo "   pruning obsolete entries from ${po} ..."
            # --no-obsolete drops the #~ obsolete block (strings no longer in
            # source). Existing real translations are kept.
            tmp="$(mktemp)"
            msgattrib --no-obsolete "$po" --output-file="$tmp"
            mv "$tmp" "$po"
        fi

        # Report translation status for this language.
        stats=$(msgfmt --statistics --output-file=/dev/null "$po" 2>&1 || true)
        echo "   ${po}: ${stats}"
    done
fi

# ---- 4. Compile .po -> .mo --------------------------------------------------
if [[ "$DO_COMPILE" -eq 1 ]]; then
    shopt -s nullglob
    PO_FILES=("${PO_DIR}"/*.po)
    shopt -u nullglob
    for po in "${PO_FILES[@]}"; do
        lang="$(basename "$po" .po)"
        if [[ "$DO_INSTALL" -eq 1 ]]; then
            out_dir="${INSTALL_LOCALE_DIR}/${lang}/LC_MESSAGES"
        else
            out_dir="${BUILD_LOCALE_DIR}/${lang}/LC_MESSAGES"
        fi
        mkdir -p "$out_dir"
        out="${out_dir}/${DOMAIN}.mo"
        echo ">> Compiling ${po} -> ${out}"
        # --check validates format strings and header; fails on errors.
        msgfmt --check --output-file="$out" "$po"
    done
    if [[ "$DO_INSTALL" -eq 1 ]]; then
        echo ">> Installed .mo files under ${INSTALL_LOCALE_DIR}/"
    else
        echo ">> Compiled .mo files under ${BUILD_LOCALE_DIR}/ (test with:"
        echo "     LANG=<lang>.UTF-8 TEXTDOMAINDIR=$(pwd)/${BUILD_LOCALE_DIR} ./zig-out/bin/shelly-notifications )"
    fi
fi

echo ">> Done."

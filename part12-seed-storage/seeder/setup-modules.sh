#!/usr/bin/env bash
#
# setup-modules.sh — assemble ./modules/storage_module so the logoscore daemon
# can load it. Like part11, the standalone logoscore CLI is a *dev* build and
# wants manifest.main["darwin-arm64-dev"]; a storage_module copied from a
# Basecamp install is the portable (darwin-arm64) variant and won't come up
# under the CLI runtime. So we build storage_module's **lgx (dev)** package,
# which is ABI-matched to the CLI's logos_host.
#
# Source resolution order:
#   1. $STORAGE_SRC  — a dir already containing storage_module_plugin.* + libstorage.*
#   2. $STORAGE_LGX  — a prebuilt .lgx file (we extract the dev variant)
#   3. nix build     — github:logos-co/logos-storage-module#lgx   (default)
#
# Usage:
#   ./setup-modules.sh
#   STORAGE_LGX=/path/to/x.lgx ./setup-modules.sh
#   STORAGE_SRC=/path/to/moduledir ./setup-modules.sh
#
# NOTE: the first nix build pulls the Nim/Codex toolchain and can take a long
# time (tens of minutes) on a cold cache.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HERE/modules/storage_module"
SM_FLAKE="${SM_FLAKE:-github:logos-co/logos-storage-module#lgx}"

log() { printf '\033[36m[setup]\033[0m %s\n' "$*"; }
err() { printf '\033[31m[setup] %s\033[0m\n' "$*" >&2; }

find_nix() {
    if command -v nix >/dev/null 2>&1; then command -v nix; return; fi
    [[ -x /nix/var/nix/profiles/default/bin/nix ]] && { echo /nix/var/nix/profiles/default/bin/nix; return; }
    echo ""
}

# extract the dev (or portable) variant of an .lgx into $DEST
extract_variant() {
    local lgx="$1" tmp v=""
    tmp="$(mktemp -d)"
    tar xzf "$lgx" -C "$tmp"
    for cand in darwin-arm64-dev darwin-arm64; do
        [[ -d "$tmp/variants/$cand" ]] && { v="$cand"; break; }
    done
    [[ -n "$v" ]] || { err "no darwin variant inside $lgx"; rm -rf "$tmp"; exit 1; }
    log "extracting variant '$v' from $(basename "$lgx")"
    rm -rf "$DEST"; mkdir -p "$DEST"
    cp -R "$tmp/variants/$v/." "$DEST/"
    rm -rf "$tmp"
}

rm -rf "$DEST"; mkdir -p "$DEST"

if [[ -n "${STORAGE_SRC:-}" ]]; then
    [[ -d "$STORAGE_SRC" ]] || { err "STORAGE_SRC not a dir: $STORAGE_SRC"; exit 1; }
    ls "$STORAGE_SRC"/storage_module_plugin.* >/dev/null 2>&1 || \
        { err "no storage_module_plugin.* in $STORAGE_SRC"; exit 1; }
    log "copying from STORAGE_SRC: $STORAGE_SRC"
    cp -R "$STORAGE_SRC"/. "$DEST/"
elif [[ -n "${STORAGE_LGX:-}" ]]; then
    [[ -f "$STORAGE_LGX" ]] || { err "STORAGE_LGX not found: $STORAGE_LGX"; exit 1; }
    extract_variant "$STORAGE_LGX"
else
    NIX="$(find_nix)"
    [[ -n "$NIX" ]] || { err "nix not found. Install nix, or set STORAGE_LGX / STORAGE_SRC."; exit 1; }
    log "nix building $SM_FLAKE (first build pulls Nim/Codex — can take tens of minutes)…"
    out="$(mktemp -d)/result"
    NIX_CONFIG="experimental-features = nix-command flakes" \
        "$NIX" build "$SM_FLAKE" -o "$out" --print-build-logs
    lgx="$(find -L "$out" -name '*.lgx' | head -1)"
    [[ -n "$lgx" ]] || { err "nix build produced no .lgx"; exit 1; }
    extract_variant "$lgx"
fi

# --- manifest: ensure the dev key is present ---------------------------------
libname="$(cd "$DEST" && ls storage_module_plugin.* 2>/dev/null | head -1)"
[[ -n "$libname" ]] || { err "no storage_module_plugin.* landed in $DEST"; exit 1; }

if [[ -f "$DEST/manifest.json" ]] && command -v jq >/dev/null 2>&1; then
    tmp="$(mktemp)"
    jq --arg lib "$libname" '
        .main["darwin-arm64-dev"] //= $lib
      | .main["darwin-arm64"]     //= $lib
    ' "$DEST/manifest.json" > "$tmp" && mv "$tmp" "$DEST/manifest.json"
else
    cat > "$DEST/manifest.json" <<JSON
{
  "name": "storage_module",
  "version": "1.0.0",
  "type": "core",
  "dependencies": [],
  "main": {
    "darwin-arm64-dev": "$libname",
    "darwin-arm64": "$libname",
    "linux-amd64": "storage_module_plugin.so",
    "linux-arm64": "storage_module_plugin.so"
  }
}
JSON
fi

log "done. storage_module (dev variant) ready at: $DEST"
log "contents: $(cd "$DEST" && ls | tr '\n' ' ')"
log "next: ./seeder.sh serve     (then, in another terminal: ./seeder.sh seed <file>)"

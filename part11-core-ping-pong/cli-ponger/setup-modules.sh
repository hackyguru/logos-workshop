#!/usr/bin/env bash
#
# setup-modules.sh — assemble a self-contained modules/ directory that the
# logoscore daemon can load delivery_module from.
#
# IMPORTANT — use the *dev* variant, not Basecamp's:
#   The standalone logoscore CLI is a dev build (it loads modules via a dev
#   logos_host and looks up manifest.main["darwin-arm64-dev"]). A delivery_module
#   copied from a *Basecamp* install is the "portable" (darwin-arm64) variant —
#   it loads but its Waku object never registers under the CLI runtime
#   ("Timeout waiting for replica"). So we fetch delivery_module's **lgx (dev)**
#   build, which is ABI-matched to the CLI. (Verified: dev variant → createNode
#   /start/subscribe/send all return status:ok; portable variant → replica
#   timeout.)
#
# Source resolution order:
#   1. $DELIVERY_SRC   — a dir already containing delivery_module_plugin.* + libs
#   2. $DELIVERY_LGX   — a prebuilt .lgx file (we extract the dev variant)
#   3. nix build       — github:logos-co/logos-delivery-module/v0.1.1#lgx  (default)
#
# Usage:
#   ./setup-modules.sh                       # nix-build the dev variant
#   DELIVERY_LGX=/path/to/x.lgx ./setup-modules.sh
#   DELIVERY_SRC=/path/to/moduledir ./setup-modules.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HERE/modules/delivery_module"
DM_FLAKE="${DM_FLAKE:-github:logos-co/logos-delivery-module/v0.1.1#lgx}"

log() { printf '\033[36m[setup]\033[0m %s\n' "$*"; }
err() { printf '\033[31m[setup] %s\033[0m\n' "$*" >&2; }

find_nix() {
    if command -v nix >/dev/null 2>&1; then command -v nix; return; fi
    [[ -x /nix/var/nix/profiles/default/bin/nix ]] && { echo /nix/var/nix/profiles/default/bin/nix; return; }
    echo ""
}

# extract_variant <lgx-file> : copy the dev (or darwin-arm64) variant into $DEST
extract_variant() {
    local lgx="$1" tmp
    tmp="$(mktemp -d)"
    tar xzf "$lgx" -C "$tmp"
    local v=""
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

if [[ -n "${DELIVERY_SRC:-}" ]]; then
    # --- 1. ready-made module dir ------------------------------------------
    [[ -d "$DELIVERY_SRC" ]] || { err "DELIVERY_SRC not a dir: $DELIVERY_SRC"; exit 1; }
    ls "$DELIVERY_SRC"/delivery_module_plugin.* >/dev/null 2>&1 || \
        { err "no delivery_module_plugin.* in $DELIVERY_SRC"; exit 1; }
    log "copying from DELIVERY_SRC: $DELIVERY_SRC"
    cp -R "$DELIVERY_SRC"/. "$DEST/"
elif [[ -n "${DELIVERY_LGX:-}" ]]; then
    # --- 2. prebuilt .lgx ---------------------------------------------------
    [[ -f "$DELIVERY_LGX" ]] || { err "DELIVERY_LGX not found: $DELIVERY_LGX"; exit 1; }
    extract_variant "$DELIVERY_LGX"
else
    # --- 3. nix build the dev variant (correct, ABI-matched) ---------------
    NIX="$(find_nix)"
    [[ -n "$NIX" ]] || { err "nix not found. Install nix, or set DELIVERY_LGX / DELIVERY_SRC."; exit 1; }
    log "nix building $DM_FLAKE (first time pulls Nim/Rust deps — can take a while)…"
    out="$(mktemp -d)/result"
    NIX_CONFIG="experimental-features = nix-command flakes" \
        "$NIX" build "$DM_FLAKE" -o "$out" --print-build-logs
    lgx="$(find -L "$out" -name '*.lgx' | head -1)"
    [[ -n "$lgx" ]] || { err "nix build produced no .lgx"; exit 1; }
    extract_variant "$lgx"
fi

# --- manifest: ensure the dev key is present ---------------------------------
libname="$(cd "$DEST" && ls delivery_module_plugin.* 2>/dev/null | head -1)"
[[ -n "$libname" ]] || { err "no delivery_module_plugin.* landed in $DEST"; exit 1; }

if [[ -f "$DEST/manifest.json" ]] && command -v jq >/dev/null 2>&1; then
    tmp="$(mktemp)"
    jq --arg lib "$libname" '
        .main["darwin-arm64-dev"] //= $lib
      | .main["darwin-arm64"]     //= $lib
    ' "$DEST/manifest.json" > "$tmp" && mv "$tmp" "$DEST/manifest.json"
else
    cat > "$DEST/manifest.json" <<JSON
{
  "name": "delivery_module",
  "version": "1.1.0",
  "type": "core",
  "category": "protocol",
  "description": "Logos Delivery Module - High-level message-delivery API",
  "author": "Logos Core Team",
  "dependencies": [],
  "main": {
    "darwin-arm64-dev": "$libname",
    "darwin-arm64": "$libname",
    "linux-amd64": "delivery_module_plugin.so",
    "linux-arm64": "delivery_module_plugin.so"
  }
}
JSON
fi

log "delivery_module (dev variant) ready at: $DEST"

# --- build + stage the pong_responder module --------------------------------
# pong_responder is a headless Logos module (sibling ./pong-core). It listens on
# the content topic IN-PROCESS (wires delivery_module's messageReceived directly,
# the way Basecamp modules do) and answers every ping with a pong. We use this
# instead of `logoscore watch`, whose event forwarding is broken in the current
# CLI build (events never reach the watch client). Build its dev (.#lgx) variant.
PONG_DEST="$HERE/modules/pong_responder"
PONG_CORE="$HERE/pong-core"
rm -rf "$PONG_DEST"; mkdir -p "$PONG_DEST"

if [[ -n "${PONG_LGX:-}" && -f "${PONG_LGX:-}" ]]; then
    extract_to() { local lgx="$1" dst="$2" t; t="$(mktemp -d)"; tar xzf "$lgx" -C "$t"; \
        local v; for c in darwin-arm64-dev darwin-arm64; do [[ -d "$t/variants/$c" ]] && { v="$c"; break; }; done; \
        cp -R "$t/variants/$v/." "$dst/"; cp -f "$t/manifest.json" "$dst/manifest.json" 2>/dev/null || true; rm -rf "$t"; }
    log "staging pong_responder from PONG_LGX"
    extract_to "$PONG_LGX" "$PONG_DEST"
elif [[ -d "$PONG_CORE" ]]; then
    NIX="${NIX:-$(find_nix)}"
    [[ -n "$NIX" ]] || { err "nix not found — set PONG_LGX or install nix to build pong_responder"; exit 1; }
    log "nix building pong_responder ($PONG_CORE#lgx)…"
    pout="$(mktemp -d)/result"
    NIX_CONFIG="experimental-features = nix-command flakes" \
        "$NIX" build "$PONG_CORE#lgx" -o "$pout" --print-build-logs
    plgx="$(find -L "$pout" -name '*.lgx' | head -1)"
    [[ -n "$plgx" ]] || { err "pong_responder build produced no .lgx"; exit 1; }
    t="$(mktemp -d)"; tar xzf "$plgx" -C "$t"
    cp -R "$t/variants/darwin-arm64-dev/." "$PONG_DEST/" 2>/dev/null || cp -R "$t/variants/darwin-arm64/." "$PONG_DEST/"
    rm -rf "$t"
else
    err "no pong-core/ sibling and no PONG_LGX — cannot stage pong_responder"; exit 1
fi

# pong_responder manifest (dev key + alias)
plib="$(cd "$PONG_DEST" && ls pong_responder_plugin.* 2>/dev/null | head -1)"
[[ -n "$plib" ]] || { err "pong_responder_plugin.* missing after staging"; exit 1; }
cat > "$PONG_DEST/manifest.json" <<JSON
{ "name":"pong_responder","version":"0.1.0","type":"core","dependencies":["delivery_module"],
  "main":{"darwin-arm64-dev":"$plib","darwin-arm64":"$plib"} }
JSON
log "pong_responder ready at: $PONG_DEST"

log "done. modules staged: $(cd "$HERE/modules" && ls | tr '\n' ' ')"
log "next: ./pong-responder.sh lobby"

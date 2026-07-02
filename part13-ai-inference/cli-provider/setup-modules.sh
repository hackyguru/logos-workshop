#!/usr/bin/env bash
#
# setup-modules.sh — assemble a self-contained modules/ directory that the
# logoscore daemon loads: delivery_module (the message bus) + inference_provider
# (this part's headless LLM responder).
#
# IMPORTANT — use the *dev* variant, not Basecamp's:
#   The standalone logoscore CLI is a dev build (loads modules via a dev logos_host
#   and looks up manifest.main["darwin-arm64-dev"]). A delivery_module copied from
#   a *Basecamp* install is the "portable" (darwin-arm64) variant — it loads but its
#   Waku object never registers under the CLI runtime. So we build the **lgx (dev)**
#   packages, which are ABI-matched to the CLI. (Same lesson as part11.)
#
# delivery_module source resolution order:
#   1. $DELIVERY_SRC   — a dir already containing delivery_module_plugin.* + libs
#   2. $DELIVERY_LGX   — a prebuilt .lgx file (we extract the dev variant)
#   3. nix build       — github:logos-co/logos-delivery-module/v0.1.1#lgx  (default)
#
# Usage:
#   ./setup-modules.sh
#   DELIVERY_LGX=/path/to/delivery.lgx ./setup-modules.sh
#   PROVIDER_LGX=/path/to/provider.lgx ./setup-modules.sh   # skip building provider-core
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

# extract the dev (or portable) variant of an .lgx into a destination dir
extract_variant() {
    local lgx="$1" dst="$2" tmp v=""
    tmp="$(mktemp -d)"
    tar xzf "$lgx" -C "$tmp"
    for cand in darwin-arm64-dev darwin-arm64; do
        [[ -d "$tmp/variants/$cand" ]] && { v="$cand"; break; }
    done
    [[ -n "$v" ]] || { err "no darwin variant inside $lgx"; rm -rf "$tmp"; exit 1; }
    log "extracting variant '$v' from $(basename "$lgx")"
    rm -rf "$dst"; mkdir -p "$dst"
    cp -R "$tmp/variants/$v/." "$dst/"
    cp -f "$tmp/manifest.json" "$dst/manifest.json" 2>/dev/null || true
    rm -rf "$tmp"
}

# ── delivery_module ──────────────────────────────────────────────────────────
rm -rf "$DEST"; mkdir -p "$DEST"
if [[ -n "${DELIVERY_SRC:-}" ]]; then
    [[ -d "$DELIVERY_SRC" ]] || { err "DELIVERY_SRC not a dir: $DELIVERY_SRC"; exit 1; }
    ls "$DELIVERY_SRC"/delivery_module_plugin.* >/dev/null 2>&1 || \
        { err "no delivery_module_plugin.* in $DELIVERY_SRC"; exit 1; }
    log "copying delivery_module from DELIVERY_SRC: $DELIVERY_SRC"
    cp -R "$DELIVERY_SRC"/. "$DEST/"
elif [[ -n "${DELIVERY_LGX:-}" ]]; then
    [[ -f "$DELIVERY_LGX" ]] || { err "DELIVERY_LGX not found: $DELIVERY_LGX"; exit 1; }
    extract_variant "$DELIVERY_LGX" "$DEST"
else
    NIX="$(find_nix)"
    [[ -n "$NIX" ]] || { err "nix not found. Install nix, or set DELIVERY_LGX / DELIVERY_SRC."; exit 1; }
    log "nix building $DM_FLAKE (first time pulls Nim/Rust deps — can take a while)…"
    out="$(mktemp -d)/result"
    NIX_CONFIG="experimental-features = nix-command flakes" \
        "$NIX" build "$DM_FLAKE" -o "$out" --print-build-logs
    lgx="$(find -L "$out" -name '*.lgx' | head -1)"
    [[ -n "$lgx" ]] || { err "delivery_module build produced no .lgx"; exit 1; }
    extract_variant "$lgx" "$DEST"
fi
# ensure the dev key is present in the manifest
dlib="$(cd "$DEST" && ls delivery_module_plugin.* 2>/dev/null | head -1)"
[[ -n "$dlib" ]] || { err "no delivery_module_plugin.* landed in $DEST"; exit 1; }
if [[ -f "$DEST/manifest.json" ]] && command -v jq >/dev/null 2>&1; then
    tmp="$(mktemp)"
    jq --arg lib "$dlib" '.main["darwin-arm64-dev"] //= $lib | .main["darwin-arm64"] //= $lib' \
        "$DEST/manifest.json" > "$tmp" && mv "$tmp" "$DEST/manifest.json"
else
    cat > "$DEST/manifest.json" <<JSON
{ "name":"delivery_module","version":"1.1.0","type":"core","dependencies":[],
  "main":{"darwin-arm64-dev":"$dlib","darwin-arm64":"$dlib","linux-amd64":"delivery_module_plugin.so","linux-arm64":"delivery_module_plugin.so"} }
JSON
fi
log "delivery_module (dev variant) ready at: $DEST"

# ── inference_provider ───────────────────────────────────────────────────────
PROV_DEST="$HERE/modules/inference_provider"
PROV_CORE="$HERE/provider-core"
rm -rf "$PROV_DEST"; mkdir -p "$PROV_DEST"
if [[ -n "${PROVIDER_LGX:-}" && -f "${PROVIDER_LGX:-}" ]]; then
    log "staging inference_provider from PROVIDER_LGX"
    extract_variant "$PROVIDER_LGX" "$PROV_DEST"
elif [[ -d "$PROV_CORE" ]]; then
    NIX="${NIX:-$(find_nix)}"
    [[ -n "$NIX" ]] || { err "nix not found — set PROVIDER_LGX or install nix to build provider-core"; exit 1; }
    log "nix building inference_provider ($PROV_CORE#lgx)…"
    pout="$(mktemp -d)/result"
    NIX_CONFIG="experimental-features = nix-command flakes" \
        "$NIX" build "$PROV_CORE#lgx" -o "$pout" --print-build-logs
    plgx="$(find -L "$pout" -name '*.lgx' | head -1)"
    [[ -n "$plgx" ]] || { err "inference_provider build produced no .lgx"; exit 1; }
    extract_variant "$plgx" "$PROV_DEST"
else
    err "no provider-core/ sibling and no PROVIDER_LGX — cannot stage inference_provider"; exit 1
fi
# inference_provider manifest (dev key + alias)
plib="$(cd "$PROV_DEST" && ls inference_provider_plugin.* 2>/dev/null | head -1)"
[[ -n "$plib" ]] || { err "inference_provider_plugin.* missing after staging"; exit 1; }
cat > "$PROV_DEST/manifest.json" <<JSON
{ "name":"inference_provider","version":"0.1.0","type":"core","dependencies":["delivery_module"],
  "main":{"darwin-arm64-dev":"$plib","darwin-arm64":"$plib"} }
JSON
log "inference_provider ready at: $PROV_DEST"

log "done. modules staged: $(cd "$HERE/modules" && ls | tr '\n' ' ')"
log "next: ./inference-provider.sh lobby   (needs ollama running with the model pulled)"

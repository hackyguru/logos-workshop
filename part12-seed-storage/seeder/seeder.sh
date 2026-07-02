#!/usr/bin/env bash
#
# seeder.sh — seed (pin) files onto Logos Storage from the logos-logoscore-cli
# (https://github.com/logos-co/logos-logoscore-cli), so peers on the same
# network (e.g. a Basecamp user) can fetch them by CID from this node.
#
# It drives storage_module via the CLI's own commands — the workflow the
# storage-module repo documents in docs/logoscore-overview/:
#
#   logoscore -D -m ./modules                         # daemon
#   logoscore load-module storage_module
#   logoscore call storage_module init @config.json   # returns true
#   logoscore call storage_module start               # node up = seeding while it runs
#   logoscore call storage_module uploadUrl <file> 65536   # seed a file
#   logoscore call storage_module remove <cid>             # stop seeding a file
#
# Reading CIDs back: the installed logoscore build serialises storage's
# LogosResult return values as null (so `call ... manifests` comes back empty),
# but the storage node DOES write a manifest object per seeded file to its repo:
#   <data-dir>/repo/manifests/<xx>/<CID>.dsobj
# The CID *is* that filename. We read CIDs from there and keep a small sidecar
# index (CID -> original filename + size) so `list` can show friendly names.
#
# Commands:
#   ./seeder.sh serve            # bring the storage node up and keep it seeding (Ctrl+C to stop)
#   ./seeder.sh seed <file>      # seed a file, print its CID
#   ./seeder.sh list             # list every seeded file with its CID + size
#   ./seeder.sh rm <cid>         # stop seeding / delete a file by CID
#   ./seeder.sh info             # node status + repo path
#   ./seeder.sh stop             # stop the daemon
#
# Run `serve` in one terminal (leave it up — that's what keeps files available),
# then `seed`/`list`/`rm` from another terminal.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/config.json"
DATA_DIR="$HERE/storage-data"                 # must match "data-dir" in config.json (resolved from $HERE)
MANIFEST_DIR="$DATA_DIR/repo/manifests"
INDEX="$HERE/seeded-index.json"               # our CID -> {filename,bytes,at} sidecar
DAEMON_LOG="${DAEMON_LOG:-/tmp/logoscore-seeder.log}"
CHUNK=65536

c_cyan=$'\033[36m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_red=$'\033[31m'; c_off=$'\033[0m'
log()  { printf '%s[seeder]%s %s\n' "$c_cyan" "$c_off" "$*"; }
ok()   { printf '%s[seeder]%s %s\n' "$c_grn"  "$c_off" "$*"; }
warn() { printf '%s[seeder]%s %s\n' "$c_ylw"  "$c_off" "$*"; }
die()  { printf '%s[seeder] %s%s\n' "$c_red"  "$*" "$c_off" >&2; exit 1; }

command -v jq >/dev/null || die "jq is required (brew install jq / apt install jq)"

# --- resolve the logoscore binary -------------------------------------------
# Two logoscore generations can be present in the nix store. This script drives
# the daemon.json-model CLI; the newer config-dir CLI (advertises "config-dir" in
# --help) uses an incompatible daemon model. Pick the compatible one, not just the
# first glob hit. State-independent. An explicit LOGOSCORE always wins.
_ls_compatible() { ! "$1" --help 2>&1 | grep -q "config-dir"; }
if [[ -z "${LOGOSCORE:-}" ]]; then
    _cands=()
    command -v logoscore >/dev/null 2>&1 && _cands+=("$(command -v logoscore)")
    while IFS= read -r _c; do _cands+=("$_c"); done \
        < <(ls -d /nix/store/*-logos-logoscore-cli/bin/logoscore 2>/dev/null)
    for _c in ${_cands[@]+"${_cands[@]}"}; do
        [[ -x "$_c" ]] && _ls_compatible "$_c" && { LOGOSCORE="$_c"; break; }
    done
    [[ -z "${LOGOSCORE:-}" ]] && for _c in ${_cands[@]+"${_cands[@]}"}; do
        [[ -x "$_c" ]] && { LOGOSCORE="$_c"; break; }
    done
fi
[[ -n "${LOGOSCORE:-}" && -x "$LOGOSCORE" ]] || \
    die "logoscore binary not found. Put it on PATH or set LOGOSCORE=/path/to/logoscore"

MODULES_DIR="$HERE/modules"
REAL_BIN="$(readlink -f "$LOGOSCORE" 2>/dev/null || python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$LOGOSCORE")"
CAP_MODULES="$(cd "$(dirname "$REAL_BIN")/../modules" 2>/dev/null && pwd || true)"

lc() { "$LOGOSCORE" "$@" 2>/dev/null; }
daemon_running() { lc status --json | jq -e '.daemon.status=="running"' >/dev/null 2>&1; }
need_daemon() { daemon_running || die "no storage daemon — run \"./seeder.sh serve\" first"; }

# CIDs the storage node currently holds (one manifest object per seeded dataset)
disk_cids() { ls "$MANIFEST_DIR"/*/*.dsobj 2>/dev/null | sed -E 's#.*/##; s#\.dsobj$##' | sort; }

index_init() { [[ -f "$INDEX" ]] || echo '{}' > "$INDEX"; }
index_put() { # cid filename bytes
    index_init
    local tmp; tmp="$(mktemp)"
    jq --arg c "$1" --arg f "$2" --argjson b "${3:-0}" --arg t "$(date -u +%FT%TZ)" \
       '.[$c]={filename:$f,bytes:$b,at:$t}' "$INDEX" > "$tmp" && mv "$tmp" "$INDEX"
}
index_del() { index_init; local tmp; tmp="$(mktemp)"; jq --arg c "$1" 'del(.[$c])' "$INDEX" > "$tmp" && mv "$tmp" "$INDEX"; }
index_name() { [[ -f "$INDEX" ]] && jq -r --arg c "$1" '.[$c].filename // ""' "$INDEX" 2>/dev/null; }
index_bytes() { [[ -f "$INDEX" ]] && jq -r --arg c "$1" '.[$c].bytes // ""' "$INDEX" 2>/dev/null; }

# ── serve: bring the node up and keep seeding ───────────────────────────────
cmd_serve() {
    [[ -d "$MODULES_DIR/storage_module" ]] || die "storage_module not staged — run ./setup-modules.sh first"
    [[ -f "$CONFIG" ]] || die "missing $CONFIG"

    local M_ARGS=(-m "$MODULES_DIR")
    [[ -n "$CAP_MODULES" && -d "$CAP_MODULES/capability_module" ]] && M_ARGS+=(-m "$CAP_MODULES")

    started_daemon=0   # script-scope so the EXIT trap can read it after this fn returns
    cleanup() {
        echo; log "shutting down..."
        if [[ "${started_daemon:-0}" == 1 ]]; then
            lc call storage_module stop >/dev/null 2>&1 || true
            lc stop >/dev/null 2>&1 || true
            ok "daemon stopped (seeded files are no longer served)."
        else
            warn "left the pre-existing daemon running."
        fi
    }
    trap cleanup INT TERM EXIT

    if daemon_running; then
        log "reusing the running logoscore daemon"
    else
        log "starting logoscore daemon (log: $DAEMON_LOG)"
        : > "$DAEMON_LOG"
        ( cd "$HERE" && "$LOGOSCORE" -D "${M_ARGS[@]}" >"$DAEMON_LOG" 2>&1 ) &
        started_daemon=1
        for _ in $(seq 1 30); do daemon_running && break; sleep 0.5; done
        daemon_running || die "daemon did not come up. Last log:
$(tail -n 12 "$DAEMON_LOG" 2>/dev/null)"
    fi
    ok "daemon is up"

    log "loading storage_module..."
    lc load-module storage_module --json >/dev/null 2>&1 || true
    lc list-modules --json | jq -e '.[]|select(.name=="storage_module" and .status=="loaded")' >/dev/null 2>&1 \
        || die "storage_module is not loaded — see $DAEMON_LOG"

    log "init (data-dir + network from config.json)..."
    local r; r="$(lc call storage_module init "@$CONFIG" | jq -r '.result // .status' 2>/dev/null)"
    [[ "$r" == "true" || "$r" == "ok" ]] || warn "init returned '$r' (already initialized?) — continuing"
    log "start (joining $(jq -r '.network // "?"' "$CONFIG") network, begin seeding)..."
    r="$(lc call storage_module start | jq -r '.result // .status' 2>/dev/null)"
    [[ "$r" == "true" || "$r" == "ok" ]] || warn "start returned '$r' — check $DAEMON_LOG"
    sleep 2

    ok "seeding — storage node is up"
    log "repo: $DATA_DIR"
    echo "──────────────────────────────────────────────────────────────"
    log "seed files from another terminal:  ./seeder.sh seed <file>"
    log "list / remove:                     ./seeder.sh list   ·   ./seeder.sh rm <cid>"
    log "Keep this running — files stay fetchable only while the node is up. Ctrl+C to stop."

    local last=-1
    while true; do
        local n; n="$(disk_cids | grep -c .)"
        if [[ "$n" != "$last" ]]; then ok "now seeding $n file(s)"; last="$n"; fi
        daemon_running || { warn "daemon went away"; break; }
        sleep 3
    done
}

# ── seed: upload a file, report its CID ─────────────────────────────────────
cmd_seed() {
    local file="${1:-}"
    [[ -n "$file" ]] || die "usage: ./seeder.sh seed <file>"
    [[ -f "$file" ]] || die "no such file: $file"
    need_daemon
    local abs base bytes
    abs="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"
    base="$(basename "$file")"
    bytes="$(wc -c < "$file" | tr -d ' ')"

    local before; before="$(disk_cids)"
    log "seeding $base (${bytes} bytes) ..."
    local r; r="$(lc call storage_module uploadUrl "$abs" "$CHUNK" | jq -r '.status // "?"' 2>/dev/null)"
    [[ "$r" == "ok" ]] || die "uploadUrl failed (status: $r) — is the node started? see the serve terminal"

    # CID lands asynchronously; poll the repo's manifest dir for the new object.
    local cid="" tries
    for tries in $(seq 1 40); do
        local after; after="$(disk_cids)"
        cid="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -1)"
        [[ -n "$cid" ]] && break
        sleep 1
    done

    if [[ -n "$cid" ]]; then
        index_put "$cid" "$base" "$bytes"
        ok "seeded $base"
        printf '       CID: %s%s%s\n' "$c_grn" "$cid" "$c_off"
        log "anyone on the same network can fetch it by this CID while \"serve\" runs."
    else
        warn "upload started but no new manifest appeared yet — run ./seeder.sh list shortly."
    fi
}

# ── list: all seeded files + CIDs ───────────────────────────────────────────
cmd_list() {
    local cids; cids="$(disk_cids)"
    if [[ -z "$cids" ]]; then log "no files seeded yet."; return; fi
    local n; n="$(printf '%s\n' "$cids" | grep -c .)"
    daemon_running || warn "(daemon not running — these are on disk but NOT currently served)"
    log "seeding $n file(s):"
    local cid
    while IFS= read -r cid; do
        [[ -n "$cid" ]] || continue
        local name bytes; name="$(index_name "$cid")"; bytes="$(index_bytes "$cid")"
        printf '  %s%s%s' "$c_grn" "${name:-"(unknown name)"}" "$c_off"
        [[ -n "$bytes" ]] && printf '  (%s bytes)' "$bytes"
        printf '\n      CID: %s\n' "$cid"
    done <<< "$cids"
}

# ── rm: delete a seeded file by CID ─────────────────────────────────────────
cmd_rm() {
    local cid="${1:-}"
    [[ -n "$cid" ]] || die "usage: ./seeder.sh rm <cid>"
    need_daemon
    lc call storage_module remove "$cid" >/dev/null 2>&1
    sleep 1
    if disk_cids | grep -qx "$cid"; then
        die "remove did not drop $cid from the repo (still present)"
    fi
    index_del "$cid"
    ok "removed $cid (no longer seeded)"
}

# ── info ────────────────────────────────────────────────────────────────────
cmd_info() {
    if daemon_running; then ok "daemon: running"; else warn "daemon: not running"; fi
    log "network : $(jq -r '.network // "?"' "$CONFIG" 2>/dev/null)"
    log "repo    : $DATA_DIR"
    log "seeding : $(disk_cids | grep -c .) file(s)"
    warn "note: this logoscore build returns null for storage's peerId/spr over the CLI,"
    warn "      so the node's SPR isn't printable here. Discovery still works via the"
    warn "      configured network ($(jq -r '.network // "?"' "$CONFIG" 2>/dev/null))."
}

cmd_stop() { lc stop >/dev/null 2>&1 && ok "daemon stopped." || warn "no running daemon."; }

case "${1:-}" in
    serve)         shift; cmd_serve "$@" ;;
    seed|add)      shift; cmd_seed "$@" ;;
    list|ls)       shift; cmd_list "$@" ;;
    rm|del|delete) shift; cmd_rm "$@" ;;
    info)          shift; cmd_info "$@" ;;
    stop)          shift; cmd_stop "$@" ;;
    *) cat >&2 <<EOF
seeder.sh — seed files onto Logos Storage via the logoscore CLI

  ./seeder.sh serve         bring the storage node up and keep seeding (Ctrl+C to stop)
  ./seeder.sh seed <file>   seed a file and print its CID
  ./seeder.sh list          list all seeded files with CIDs + sizes
  ./seeder.sh rm <cid>      delete / stop seeding a file
  ./seeder.sh info          node status + repo path
  ./seeder.sh stop          stop the daemon

First run ./setup-modules.sh once, then ./seeder.sh serve.
EOF
       exit 1 ;;
esac

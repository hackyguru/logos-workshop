#!/usr/bin/env bash
#
# pong-responder.sh — a headless ping responder running on the logos-logoscore-cli
# (https://github.com/logos-co/logos-logoscore-cli).
#
# It loads the `pong_responder` module into the logoscore daemon. That module
# subscribes to the ping/pong content topic and answers every "ping" with a
# "pong" — entirely in-process (it wires delivery_module's messageReceived
# directly, the same way Basecamp modules do). The ping side runs in Basecamp
# (part11's ping-ui / ping-core).
#
#   ping  (Basecamp)  ── /pingpong/1/<room>/json ──▶  pong  (this CLI module)
#                     ◀──────────  pong  ──────────
#
# Why a module and not `logoscore watch`?
#   The CLI's `watch` event-forwarding does not deliver module events in the
#   current logoscore build (verified: even test_basic_module's emitTestEvent
#   never reaches a watcher). A loaded module gets delivery_module's events via
#   the normal in-core path, which works — so the responder is a module.
#
# Pipeline:
#   logoscore -D -m ./modules            # start the daemon
#   logoscore load-module pong_responder # pulls in delivery_module
#   logoscore call pong_responder start <room>   # createNode/start/subscribe + answer pings
#   logoscore call pong_responder stats          # pingsSeen / pongsSent (polled below)
#
# Usage:
#   ./pong-responder.sh [room]                 # default room: lobby
#   ROOM=demo ./pong-responder.sh
#   PINGPONG_TCPPORT=60012 ./pong-responder.sh # change the Waku TCP port (default 60010)
#
# A logoscore daemon and Basecamp CAN run on the same machine at once (their Qt
# sockets are instance-scoped). Just give the two delivery nodes different Waku
# TCP ports — Basecamp uses 60000, this defaults to 60010.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOM="${1:-${ROOM:-lobby}}"
TOPIC="/pingpong/1/${ROOM}/json"
export PINGPONG_TCPPORT="${PINGPONG_TCPPORT:-60010}"
DAEMON_LOG="${DAEMON_LOG:-/tmp/logoscore-ponger.log}"

c_cyan=$'\033[36m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_red=$'\033[31m'; c_off=$'\033[0m'
log()  { printf '%s[ponger]%s %s\n' "$c_cyan" "$c_off" "$*"; }
ok()   { printf '%s[ponger]%s %s\n' "$c_grn"  "$c_off" "$*"; }
warn() { printf '%s[ponger]%s %s\n' "$c_ylw"  "$c_off" "$*"; }
die()  { printf '%s[ponger] %s%s\n' "$c_red"  "$*" "$c_off" >&2; exit 1; }

command -v jq >/dev/null || die "jq is required (brew install jq / apt install jq)"

# --- resolve the logoscore binary -------------------------------------------
# Two logoscore generations can be present in the nix store. This script drives
# the one whose `status` reports {"daemon":{...}} (the daemon.json model part11's
# modules were built against) — NOT just the first glob hit (which may be a newer,
# incompatible config-dir CLI). An explicit LOGOSCORE always wins.
# Compatible = the daemon.json-model CLI this script drives. The newer config-dir
# CLI advertises "config-dir" in --help (and uses an incompatible daemon model);
# the old one does not. This check is state-independent (doesn't depend on whether
# a daemon happens to be running).
_ls_compatible() { ! "$1" --help 2>&1 | grep -q "config-dir"; }
if [[ -z "${LOGOSCORE:-}" ]]; then
    _cands=()
    command -v logoscore >/dev/null 2>&1 && _cands+=("$(command -v logoscore)")
    while IFS= read -r _c; do _cands+=("$_c"); done \
        < <(ls -d /nix/store/*-logos-logoscore-cli/bin/logoscore 2>/dev/null)
    for _c in "${_cands[@]}"; do
        [[ -x "$_c" ]] && _ls_compatible "$_c" && { LOGOSCORE="$_c"; break; }
    done
    # fallback: first existing candidate if none probed compatible
    [[ -z "${LOGOSCORE:-}" ]] && for _c in "${_cands[@]}"; do
        [[ -x "$_c" ]] && { LOGOSCORE="$_c"; break; }
    done
fi
[[ -n "${LOGOSCORE:-}" && -x "$LOGOSCORE" ]] || \
    die "logoscore binary not found. Put it on PATH or set LOGOSCORE=/path/to/logoscore"
log "logoscore: $LOGOSCORE"

# --- modules dirs ------------------------------------------------------------
PONGER_MODULES="$HERE/modules"
[[ -d "$PONGER_MODULES/pong_responder" ]]  || die "pong_responder not staged — run ./setup-modules.sh first"
[[ -d "$PONGER_MODULES/delivery_module" ]] || die "delivery_module not staged — run ./setup-modules.sh first"

# capability_module ships inside the logoscore bundle (next to the binary).
REAL_BIN="$(readlink -f "$LOGOSCORE" 2>/dev/null || python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$LOGOSCORE")"
CAP_MODULES="$(cd "$(dirname "$REAL_BIN")/../modules" 2>/dev/null && pwd || true)"
M_ARGS=(-m "$PONGER_MODULES")
[[ -n "$CAP_MODULES" && -d "$CAP_MODULES/capability_module" ]] && M_ARGS+=(-m "$CAP_MODULES")

lc() { "$LOGOSCORE" "$@" 2>/dev/null; }
daemon_running() { lc status --json | jq -e '.daemon.status=="running"' >/dev/null 2>&1; }
# extract a field from a `call ... stats` result (result is an escaped JSON string)
stat_field() { lc call pong_responder stats | jq -r --arg k "$1" '.result|fromjson|.[$k]' 2>/dev/null; }

STARTED_DAEMON=0
cleanup() {
    echo
    log "shutting down..."
    if [[ "$STARTED_DAEMON" == "1" ]]; then
        lc call pong_responder stop >/dev/null 2>&1 || true
        lc stop >/dev/null 2>&1 || true
        ok "daemon stopped."
    else
        warn "left the pre-existing daemon running."
    fi
}
trap cleanup INT TERM EXIT

# --- 1. daemon ---------------------------------------------------------------
if daemon_running; then
    log "reusing the running logoscore daemon"
else
    log "starting logoscore daemon (log: $DAEMON_LOG)"
    : > "$DAEMON_LOG"
    "$LOGOSCORE" -D "${M_ARGS[@]}" >"$DAEMON_LOG" 2>&1 &
    STARTED_DAEMON=1
    for _ in $(seq 1 30); do daemon_running && break; sleep 0.5; done
    daemon_running || die "daemon did not come up. Last log:
$(tail -n 12 "$DAEMON_LOG" 2>/dev/null)"
fi
ok "daemon is up"

# --- 2. load the responder module (pulls in delivery_module) -----------------
log "loading pong_responder..."
lc load-module pong_responder --json >/dev/null 2>&1 || true
lc list-modules --json | jq -e '.[]|select(.name=="pong_responder" and .status=="loaded")' >/dev/null 2>&1 \
    || die "pong_responder is not loaded — see $DAEMON_LOG"
ok "pong_responder loaded"

# --- 3. start answering pings ------------------------------------------------
log "start(room=$ROOM, tcpPort=$PINGPONG_TCPPORT)..."
res="$(lc call pong_responder start "$ROOM" | jq -r '.result // "false"' 2>/dev/null)"
[[ "$res" == "true" ]] || warn "start did not return true (see $DAEMON_LOG) — continuing"

id="$(lc call pong_responder responderId | jq -r '.result // ""' 2>/dev/null)"
ok "ready — listening on $TOPIC"
log "responder id: ${id:-?}"
echo   "──────────────────────────────────────────────────────────────"
log "send pings from Basecamp's \"Ping <-> Pong\" app (same room). Ctrl+C to stop."

# --- 4. show live ping/pong counts ------------------------------------------
last=-1
while true; do
    seen="$(stat_field pingsSeen)"; sent="$(stat_field pongsSent)"
    if [[ "${seen:-}" =~ ^[0-9]+$ && "$seen" != "$last" ]]; then
        from="$(stat_field lastFrom)"; pid="$(stat_field lastPingId)"
        ok "pings seen: $seen  ·  pongs sent: ${sent:-0}  ·  last: ${pid:--} from ${from:--}"
        last="$seen"
    fi
    daemon_running || { warn "daemon went away"; break; }
    sleep 2
done

#!/usr/bin/env bash
# run-opencode.sh -- launch OpenCode against a local Qwen3.8-27B server,
# starting the server on demand and shutting it down when nobody is using it.
#
# Behaviour:
#   * Starts llama-server only if one is not already serving on $PORT.
#   * Registers this invocation as a client, then runs OpenCode in the
#     foreground (it is a TUI, so it needs the terminal).
#   * A single detached watcher reaps the server once no client has been alive
#     for $IDLE_TIMEOUT seconds (default 300).
#   * Running this script again registers a new client, which resets the idle
#     countdown and reuses the already-running server.
#   * Only ever stops a server this script started. A server you launched
#     yourself is left alone.
#
# Usage:
#   scripts/run-opencode.sh                 start server (if needed) + OpenCode
#   scripts/run-opencode.sh --status        show server, clients, idle timer
#   scripts/run-opencode.sh --stop          stop watcher and owned server now
#   scripts/run-opencode.sh --server-only   start server + watcher, no client
#   scripts/run-opencode.sh -- <args...>    pass args through to opencode
#
#   THINKING=0 scripts/run-opencode.sh      disable reasoning (faster, terser)
#   PROFILE=vision scripts/run-opencode.sh  enable image input
#
# Env: PORT PROFILE IDLE_TIMEOUT MODEL_ID PROVIDER
#      plus anything qwen38-27b-server understands -- CTX, KV_TYPE, VISION,
#      THINKING, THINKING_BUDGET, NP, UB -- which is passed straight through.
#      NOTE: these only apply when a server is actually started. If one is
#      already running it is reused as-is, and the script warns if your
#      requested settings differ from the running server's.

set -euo pipefail

PORT="${PORT:-8080}"
PROFILE="${PROFILE:-coding}"
IDLE_TIMEOUT="${IDLE_TIMEOUT:-300}"     # seconds with zero clients before shutdown
POLL_INTERVAL="${POLL_INTERVAL:-10}"
MODEL_ID="${MODEL_ID:-qwen3.8-27b}"
PROVIDER="${PROVIDER:-qwen38-local}"
SERVER_START_TIMEOUT="${SERVER_START_TIMEOUT:-300}"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/qwen38-27b"
CLIENTS_DIR="$STATE_DIR/clients"
SERVER_PID_FILE="$STATE_DIR/server.pid"
OWNED_FLAG="$STATE_DIR/server.owned"
WATCHER_PID_FILE="$STATE_DIR/watcher.pid"
LOCK_FILE="$STATE_DIR/lock"
LOG_FILE="$STATE_DIR/run-opencode.log"
SERVER_LOG="$STATE_DIR/server.log"
CONFIG_FILE="$STATE_DIR/server.config"
OC_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json"

mkdir -p "$CLIENTS_DIR"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }
say() { printf '%s\n' "$*" >&2; }

now() { date +%s; }

server_healthy() { curl -sf --max-time 3 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; }

# Settings that change how the server behaves. Recorded at launch so a later
# invocation asking for something different is told rather than silently
# handed a server configured the old way.
server_config_sig() {
  printf 'PROFILE=%s CTX=%s KV_TYPE=%s VISION=%s THINKING=%s THINKING_BUDGET=%s NP=%s UB=%s' \
    "$PROFILE" "${CTX:-default}" "${KV_TYPE:-default}" "${VISION:-default}" \
    "${THINKING:-1}" "${THINKING_BUDGET:-none}" "${NP:-default}" "${UB:-default}"
}

# A registered pid counts as a live client if it is alive AND looks like
# opencode. The mtime grace window covers the gap between registering and
# exec'ing opencode, when the process is still this shell.
is_live_client() {
  local pid="$1" f="$2" age
  kill -0 "$pid" 2>/dev/null || return 1
  age=$(( $(now) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
  (( age < 60 )) && return 0
  grep -qa opencode "/proc/$pid/cmdline" 2>/dev/null
}

# Prune dead registrations; echo how many clients remain.
count_clients() {
  local n=0 f pid
  shopt -s nullglob
  for f in "$CLIENTS_DIR"/*; do
    pid="$(basename "$f")"
    if is_live_client "$pid" "$f"; then n=$((n+1)); else rm -f "$f"; fi
  done
  shopt -u nullglob
  printf '%s' "$n"
}

owned_server_pid() {
  [[ -f "$OWNED_FLAG" && -f "$SERVER_PID_FILE" ]] || return 1
  local p; p="$(cat "$SERVER_PID_FILE" 2>/dev/null || true)"
  [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && printf '%s' "$p"
}

stop_server() {
  local pid
  if ! pid="$(owned_server_pid)"; then
    log "no owned server to stop"
    rm -f "$SERVER_PID_FILE" "$OWNED_FLAG"
    return 0
  fi
  log "stopping server pid $pid"
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  kill -0 "$pid" 2>/dev/null && { log "server did not exit, SIGKILL"; kill -9 "$pid" 2>/dev/null || true; }
  rm -f "$SERVER_PID_FILE" "$OWNED_FLAG" "$CONFIG_FILE"
  log "server stopped"
}

start_server() {
  if server_healthy; then
    # Something is already serving. If we did not start it, never kill it.
    if ! owned_server_pid >/dev/null; then
      log "reusing server on :$PORT that this script does not own"
      say "Reusing existing server on :${PORT} (not managed by this script)."
      return 0
    fi
    # Reusing our own server: settings passed now had no effect on it.
    local want running
    want="$(server_config_sig)"
    running="$(cat "$CONFIG_FILE" 2>/dev/null || echo '')"
    if [[ -n "$running" && "$want" != "$running" ]]; then
      say ""
      say "NOTE: reusing the server already running on :${PORT}; your settings were NOT applied."
      say "  running : $running"
      say "  you asked: $want"
      say "  To apply them: $SELF --stop  &&  <your env> $SELF"
      say ""
      log "reuse with differing config; running=[$running] wanted=[$want]"
    fi
    return 0
  fi

  command -v qwen38-27b-server >/dev/null 2>&1 || {
    say "qwen38-27b-server not found on PATH. Run scripts/setup.sh first."; exit 1; }

  say "Starting Qwen3.8-27B server (PROFILE=$PROFILE) on :${PORT}..."
  log "starting server PROFILE=$PROFILE PORT=$PORT"
  server_config_sig > "$CONFIG_FILE"
  # Everything else (CTX, KV_TYPE, VISION, THINKING, ...) is inherited from
  # this script's environment by setsid.
  PORT="$PORT" PROFILE="$PROFILE" setsid qwen38-27b-server >>"$SERVER_LOG" 2>&1 < /dev/null &
  local pid=$!
  echo "$pid" > "$SERVER_PID_FILE"
  : > "$OWNED_FLAG"

  local i
  for i in $(seq 1 "$SERVER_START_TIMEOUT"); do
    if ! kill -0 "$pid" 2>/dev/null; then
      say "Server exited during startup. Last lines of $SERVER_LOG:"
      tail -15 "$SERVER_LOG" >&2
      rm -f "$SERVER_PID_FILE" "$OWNED_FLAG"
      exit 1
    fi
    server_healthy && { say "Server ready after ${i}s."; log "server ready pid $pid after ${i}s"; return 0; }
    sleep 1
  done
  say "Server did not become healthy in ${SERVER_START_TIMEOUT}s; see $SERVER_LOG"
  exit 1
}

start_watcher() {
  local wp
  if [[ -f "$WATCHER_PID_FILE" ]]; then
    wp="$(cat "$WATCHER_PID_FILE" 2>/dev/null || true)"
    [[ -n "$wp" ]] && kill -0 "$wp" 2>/dev/null && return 0   # already watching
  fi
  setsid "$SELF" --watcher >/dev/null 2>&1 < /dev/null &
  log "watcher started pid $!"
}

# ---- the reaper -----------------------------------------------------------
watcher_loop() {
  echo $$ > "$WATCHER_PID_FILE"
  trap 'rm -f "$WATCHER_PID_FILE"' EXIT
  log "watcher running (idle timeout ${IDLE_TIMEOUT}s)"
  local last_seen n idle
  last_seen="$(now)"
  while true; do
    if ! server_healthy; then
      log "server no longer healthy; watcher exiting"
      rm -f "$SERVER_PID_FILE" "$OWNED_FLAG"
      exit 0
    fi
    n="$(count_clients)"
    if (( n > 0 )); then
      last_seen="$(now)"
    else
      idle=$(( $(now) - last_seen ))
      if (( idle >= IDLE_TIMEOUT )); then
        log "no clients for ${idle}s (>= ${IDLE_TIMEOUT}s); shutting server down"
        stop_server
        exit 0
      fi
    fi
    sleep "$POLL_INTERVAL"
  done
}

ensure_opencode_config() {
  command -v opencode >/dev/null 2>&1 || {
    say "opencode not found. Install with: npm install -g opencode-ai"; exit 1; }
  [[ -f "$OC_CONFIG" ]] && return 0
  say "Writing OpenCode provider config to $OC_CONFIG"
  mkdir -p "$(dirname "$OC_CONFIG")"
  cat > "$OC_CONFIG" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "${PROVIDER}": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Qwen3.8-27B (local)",
      "options": {
        "baseURL": "http://127.0.0.1:${PORT}/v1",
        "apiKey": "local"
      },
      "models": {
        "${MODEL_ID}": {
          "name": "Qwen3.8-27B (local)",
          "limit": { "context": 131072, "output": 32768 }
        }
      }
    }
  }
}
EOF
}

show_status() {
  local n sp
  n="$(count_clients)"
  if server_healthy; then
    sp="$(owned_server_pid || echo '')"
    echo "server    : running on :${PORT}$( [[ -n "$sp" ]] && echo " (pid $sp, managed)" || echo " (not managed by this script)" )"
    echo "model     : $(curl -s --max-time 3 "http://127.0.0.1:${PORT}/v1/models" \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["models"][0]["model"])' 2>/dev/null || echo '?')"
    echo "vram      : $(nvidia-smi --query-gpu=memory.used --format=csv,noheader 2>/dev/null | head -1)"
  else
    echo "server    : not running"
  fi
  if [[ -f "$WATCHER_PID_FILE" ]] && kill -0 "$(cat "$WATCHER_PID_FILE")" 2>/dev/null; then
    echo "watcher   : running (pid $(cat "$WATCHER_PID_FILE"), idle timeout ${IDLE_TIMEOUT}s)"
  else
    echo "watcher   : not running"
  fi
  [[ -f "$CONFIG_FILE" ]] && echo "config    : $(cat "$CONFIG_FILE")"
  echo "clients   : $n"
  echo "state dir : $STATE_DIR"
  echo "log       : $LOG_FILE"
}

# ---- entry points ---------------------------------------------------------
case "${1:-}" in
  --watcher)   watcher_loop; exit 0 ;;
  --status)    show_status; exit 0 ;;
  --stop)
      if [[ -f "$WATCHER_PID_FILE" ]]; then
        kill "$(cat "$WATCHER_PID_FILE")" 2>/dev/null || true
        rm -f "$WATCHER_PID_FILE"
      fi
      stop_server
      say "Stopped."
      exit 0 ;;
  -h|--help)
      sed -n '2,26p' "$SELF" | sed 's/^# \{0,1\}//'
      exit 0 ;;
esac

SERVER_ONLY=0
[[ "${1:-}" == "--server-only" ]] && { SERVER_ONLY=1; shift; }
[[ "${1:-}" == "--" ]] && shift

# Serialise startup so two simultaneous invocations cannot both launch a server.
exec 9>"$LOCK_FILE"
flock 9

if (( SERVER_ONLY )); then
  start_server
  start_watcher
  flock -u 9
  say "Server running on :${PORT}. Idle shutdown in ${IDLE_TIMEOUT}s if no client connects."
  say "Status: $SELF --status"
  exit 0
fi

ensure_opencode_config
start_server

# Register before exec: this shell's pid becomes opencode's pid after exec, so
# the registration dies exactly when opencode does.
touch "$CLIENTS_DIR/$$"
log "client registered pid $$ (clients now $(count_clients))"
start_watcher
flock -u 9
exec 9>&-

say "Launching OpenCode with ${PROVIDER}/${MODEL_ID} (server stops ${IDLE_TIMEOUT}s after last client exits)."
exec opencode --model "${PROVIDER}/${MODEL_ID}" "$@"

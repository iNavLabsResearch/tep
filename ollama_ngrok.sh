#!/bin/bash
#
# ollama_ngrok.sh
# Manages an Ollama server running "nemotron-3-super" and exposes it
# publicly via an ngrok tunnel.
#
# Usage:
#   ./ollama_ngrok.sh --run
#   ./ollama_ngrok.sh --logs 100
#   ./ollama_ngrok.sh --stop
#
# Notes:
#   - Ollama's server has no single global "always respond in JSON" flag.
#     JSON output is requested per-call via "format": "json" in the request
#     body. See the test_json_request() function below for an example.
#   - Default Ollama port is 11434.

set -euo pipefail

# ---------- Config ----------
MODEL="nemotron-3-super"
OLLAMA_PORT="11434"
NGROK_AUTHTOKEN="39AeIeJysk6gdiwb40JoE6yVPlt_3HyLkyg1qXX3zGVHEdPQc"

# Keep KV cache + context modest so an 87GB model has headroom on a
# ~95GB card. Override by exporting these before calling the script.
export OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-8192}"
export OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-q8_0}"

WORKDIR="$HOME/.ollama_ngrok"
LOG_DIR="$WORKDIR/logs"
PID_FILE="$WORKDIR/pids.env"
OLLAMA_LOG="$LOG_DIR/ollama.log"
NGROK_LOG="$LOG_DIR/ngrok.log"

mkdir -p "$LOG_DIR"

# ---------- Helpers ----------
log() {
  ts=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[$ts] $*"
}

check_deps() {
  command -v ollama >/dev/null 2>&1 || { echo "ERROR: ollama not found in PATH."; exit 1; }
  command -v ngrok  >/dev/null 2>&1 || { echo "ERROR: ngrok not found in PATH."; exit 1; }
}

save_pid() {
  local name="$1" pid="$2"
  # remove any existing entry for this name, then append fresh
  touch "$PID_FILE"
  grep -v "^${name}=" "$PID_FILE" > "$PID_FILE.tmp" 2>/dev/null || true
  mv "$PID_FILE.tmp" "$PID_FILE"
  echo "${name}=${pid}" >> "$PID_FILE"
}

get_pid() {
  local name="$1"
  [ -f "$PID_FILE" ] && grep "^${name}=" "$PID_FILE" | cut -d'=' -f2 || true
}

is_running() {
  local pid="$1"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# ---------- Example JSON-format request (for reference/testing) ----------
test_json_request() {
  curl -s "http://localhost:${OLLAMA_PORT}/api/generate" \
    -d "{
      \"model\": \"${MODEL}\",
      \"prompt\": \"Say hello in one word\",
      \"format\": \"json\",
      \"stream\": false
    }"
}

# ---------- Commands ----------
cmd_run() {
  check_deps

  # 1. Configure ngrok authtoken (idempotent)
  log "Configuring ngrok authtoken..."
  ngrok config add-authtoken "$NGROK_AUTHTOKEN" >/dev/null 2>&1

  # 2. Start Ollama server if not already running
  local ollama_pid
  ollama_pid="$(get_pid OLLAMA_PID)"
  if is_running "$ollama_pid"; then
    log "Ollama server already running (PID $ollama_pid)."
  else
    log "Starting Ollama server on port ${OLLAMA_PORT}..."
    OLLAMA_HOST="0.0.0.0:${OLLAMA_PORT}" nohup ollama serve >> "$OLLAMA_LOG" 2>&1 &
    ollama_pid=$!
    save_pid OLLAMA_PID "$ollama_pid"
    sleep 3
    log "Ollama server started (PID $ollama_pid)."
  fi

  # 3. Pull the model if it isn't present locally
  if ! ollama list | awk '{print $1}' | grep -qx "$MODEL"; then
    log "Model '${MODEL}' not found locally. Pulling..."
    ollama pull "$MODEL" >> "$OLLAMA_LOG" 2>&1
  else
    log "Model '${MODEL}' already present."
  fi

  # 4. Warm up / load the model in background so it's ready to serve
  log "Warming up model '${MODEL}'..."
  nohup ollama run "$MODEL" --keepalive 60m >> "$OLLAMA_LOG" 2>&1 &
  local run_pid=$!
  save_pid RUN_PID "$run_pid"

  # 5. Start ngrok tunnel exposing the Ollama port
  local ngrok_pid
  ngrok_pid="$(get_pid NGROK_PID)"
  if is_running "$ngrok_pid"; then
    log "ngrok tunnel already running (PID $ngrok_pid)."
  else
    log "Starting ngrok tunnel on port ${OLLAMA_PORT}..."
    nohup ngrok http "$OLLAMA_PORT" --log=stdout >> "$NGROK_LOG" 2>&1 &
    ngrok_pid=$!
    save_pid NGROK_PID "$ngrok_pid"
    sleep 3
  fi

  # 6. Print the public URL
  local public_url
  public_url="$(curl -s http://127.0.0.1:4040/api/tunnels 2>/dev/null | grep -o '"public_url":"[^"]*' | head -1 | cut -d'"' -f4)"
  log "----------------------------------------"
  log "Ollama running locally on: http://localhost:${OLLAMA_PORT}"
  if [ -n "$public_url" ]; then
    log "Public ngrok URL: ${public_url}"
  else
    log "ngrok URL not detected yet — check logs with: $0 --logs 50"
  fi
  log "Example JSON-format request: curl ${public_url:-http://localhost:${OLLAMA_PORT}}/api/generate -d '{\"model\":\"${MODEL}\",\"prompt\":\"hi\",\"format\":\"json\",\"stream\":false}'"
  log "----------------------------------------"
}

cmd_logs() {
  local n="${1:-50}"
  log "Last ${n} lines of Ollama log (${OLLAMA_LOG}):"
  tail -n "$n" "$OLLAMA_LOG" 2>/dev/null || echo "(no ollama log yet)"
  echo
  log "Last ${n} lines of ngrok log (${NGROK_LOG}):"
  tail -n "$n" "$NGROK_LOG" 2>/dev/null || echo "(no ngrok log yet)"
}

cmd_stop() {
  for name in NGROK_PID RUN_PID OLLAMA_PID; do
    local pid
    pid="$(get_pid "$name")"
    if is_running "$pid"; then
      log "Stopping ${name} (PID $pid)..."
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
    fi
  done
  # Extra safety: kill any stray ngrok/ollama processes started by this script
  pkill -f "ngrok http ${OLLAMA_PORT}" 2>/dev/null || true
  rm -f "$PID_FILE"
  log "All processes stopped."
}

# ---------- Argument parsing ----------
case "${1:-}" in
  --run)
    cmd_run
    ;;
  --logs)
    cmd_logs "${2:-50}"
    ;;
  --stop)
    cmd_stop
    ;;
  *)
    echo "Usage: $0 --run | --logs [N] | --stop"
    exit 1
    ;;
esac

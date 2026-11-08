#!/usr/bin/env bash
#
# colab/supervise.sh — keep the stack alive and stop it before Colab does.
#
#   bash colab/supervise.sh
#   CS_IDLE_TIMEOUT=900 CS_MAX_RUNTIME=21600 bash colab/supervise.sh
#
# Two jobs:
#   1. restart serve.sh with exponential backoff if code-server or the tunnel dies
#   2. shut the stack down when nobody is connected, or when the runtime has been
#      held for too long
#
# (2) is the honest half of "less noticeable": a GPU VM held open for hours with
# no interactive traffic is the pattern that gets accounts throttled. Releasing
# it when idle is both better manners and fewer sessions to be flagged.
#
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

PORT="${CS_PORT:-8080}"
IDLE_TIMEOUT="${CS_IDLE_TIMEOUT:-1800}"     # 30 min with zero connections
MAX_RUNTIME="${CS_MAX_RUNTIME:-39600}"      # 11 h, under Colab's hard cap
HEALTHY_AFTER="${CS_HEALTHY_AFTER:-600}"    # uptime that resets the backoff
MAX_BACKOFF="${CS_MAX_BACKOFF:-60}"
MAX_RESTARTS="${CS_MAX_RESTARTS:-20}"

[[ "$IDLE_TIMEOUT" =~ ^[0-9]+$ ]] || die "CS_IDLE_TIMEOUT must be a number of seconds"
[[ "$MAX_RUNTIME" =~ ^[0-9]+$ ]]  || die "CS_MAX_RUNTIME must be a number of seconds"

cs_need code-server "run: bash colab/install.sh"
cs_need curl

SD="$(cs_state_dir)"
cs_lock supervise
trap 'cs_unlock' EXIT

stack_alive() {
  local cs_pid
  cs_pid="$(cs_read_pid "${SD}/cs.pid")"
  [[ -n "$cs_pid" ]] && kill -0 "$cs_pid" 2>/dev/null
}

# Returns: 0 = still running, 10 = idle shutdown, 11 = max runtime reached,
#          1 = something died (caller restarts)
watch_stack() {
  local started=$SECONDS last_active=$SECONDS conns
  while stack_alive; do
    sleep 5
    conns="$(cs_active_conns "$PORT")"
    if [[ "${conns:-0}" -gt 0 ]]; then
      last_active=$SECONDS
    fi
    if ((SECONDS - last_active > IDLE_TIMEOUT)); then
      log "no connections for ${IDLE_TIMEOUT}s — shutting down"
      CS_FROM_SUPERVISOR=1 bash "${HERE}/stop.sh" || true
      return 10
    fi
    if ((SECONDS - started > MAX_RUNTIME)); then
      log "max runtime ${MAX_RUNTIME}s reached — shutting down"
      CS_FROM_SUPERVISOR=1 bash "${HERE}/stop.sh" || true
      return 11
    fi
  done
  return 1
}

restarts=0
delay=2

while :; do
  t0=$SECONDS

  srv_rc=0
  bash "${HERE}/serve.sh" "$@" 9>&- || srv_rc=$?

  if ((srv_rc == 0)); then
    rc=0
    watch_stack || rc=$?
    case "$rc" in
      10|11) log "stopped cleanly"; exit 0 ;;
    esac
    [[ "$rc" -eq 0 ]] && continue
  elif ((srv_rc == 2)); then
    # Unrecoverable (e.g. the port is held by something that is not ours).
    # Restarting would just burn the retry budget and hide the real message.
    die "cannot start on port ${PORT}; see the error above"
  else
    warn "serve.sh failed to start (exit ${srv_rc})"
  fi

  uptime=$((SECONDS - t0))
  if ((uptime >= HEALTHY_AFTER)); then
    delay=2
    restarts=0
  else
    restarts=$((restarts + 1))
    delay=$((delay * 2))
    ((delay > MAX_BACKOFF)) && delay=$MAX_BACKOFF
  fi

  if ((restarts > MAX_RESTARTS)); then
    cs_dump_log "${SD}/code-server.log" 40
    die "${restarts} failed restarts in a row; giving up"
  fi

  warn "restarting in ${delay}s (uptime ${uptime}s, attempt ${restarts})"
  sleep "$delay"
done

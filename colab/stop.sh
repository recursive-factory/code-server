#!/usr/bin/env bash
#
# colab/stop.sh — stop code-server and any tunnel started by serve.sh.
#
#   bash colab/stop.sh
#
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

SD="$(cs_state_dir)"
PORT="$(cs_resolved_port "$SD")"

# The supervisor must go first: it restarts serve.sh, so killing the children
# while it still runs just gets them relaunched a few seconds later.
sup_pid="$(cs_read_pid "${SD}/supervise.pid")"
if [[ -n "$sup_pid" ]] && kill -0 "$sup_pid" 2>/dev/null; then
  log "stopping supervisor (pid ${sup_pid})"
  # It was launched with start_new_session, so its pid is also its process group.
  kill -TERM -- "-${sup_pid}" 2>/dev/null || kill -TERM "$sup_pid" 2>/dev/null || true
  for _ in {1..15}; do
    kill -0 "$sup_pid" 2>/dev/null || break
    sleep 0.3
  done
  kill -KILL -- "-${sup_pid}" 2>/dev/null || true
elif [[ "${CS_FROM_SUPERVISOR:-0}" != "1" ]]; then
  # No pidfile (older run, or it was lost) — match the supervisor's own argv.
  pkill -f 'supervise\.sh$' 2>/dev/null || true
fi
rm -f -- "${SD}/supervise.pid"

cs_stop_pidfile "${SD}/cs.pid" code-server
cs_stop_pidfile "${SD}/ngrok.pid" ngrok
cs_stop_pidfile "${SD}/cloudflared.pid" cloudflared

# Funnel stays configured on the node after the process dies, so reset it or the
# ts.net hostname keeps advertising a dead port.
if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
  tailscale funnel reset >/dev/null 2>&1 || true
fi
cs_stop_pidfile "${SD}/tailscale.pid" tailscaled

# Fallback for a run whose pidfile was lost. The patterns are anchored to the
# full argv on purpose: this repository's directory is itself named
# "code-server", so a bare `pkill -f code-server` would also match — and kill —
# the shell that invoked this script.
# Matches the real argv of a code-server process (the wrapper re-execs to
# "node .../out/node/entry.js --bind-addr ..."), not just the wrapper name.
pkill -f 'entry\.js --bind-addr' 2>/dev/null || true
pkill -f 'code-server --bind-addr' 2>/dev/null || true
pkill -f 'ngrok http' 2>/dev/null || true
pkill -f 'cloudflared tunnel' 2>/dev/null || true

rm -f -- "${SD}/cs.pid" "${SD}/ngrok.pid" "${SD}/cloudflared.pid"

# Last resort: reclaim the port from an orphan that no pidfile knows about.
if cs_port_in_use "$PORT"; then
  cs_free_port "$PORT" || cs_port_report "$PORT"
fi

ok "stopped"

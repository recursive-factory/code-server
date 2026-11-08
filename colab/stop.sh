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

cs_stop_pidfile "${SD}/cs.pid" code-server
cs_stop_pidfile "${SD}/ngrok.pid" ngrok
cs_stop_pidfile "${SD}/cloudflared.pid" cloudflared

# Fallback for a run whose pidfile was lost. The patterns are anchored to the
# full argv on purpose: this repository's directory is itself named
# "code-server", so a bare `pkill -f code-server` would also match — and kill —
# the shell that invoked this script.
pkill -f 'code-server --bind-addr' 2>/dev/null || true
pkill -f 'ngrok http' 2>/dev/null || true
pkill -f 'cloudflared tunnel' 2>/dev/null || true

rm -f -- "${SD}/cs.pid" "${SD}/ngrok.pid" "${SD}/cloudflared.pid"
ok "stopped"

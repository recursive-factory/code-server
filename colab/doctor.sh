#!/usr/bin/env bash
#
# colab/doctor.sh — report the state of the Colab environment and the stack.
#
#   bash colab/doctor.sh
#
# Read-only: changes nothing. Run it before filing a "it doesn't work" note.
#
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

SD="$(cs_state_dir)"
PORT="${CS_PORT:-8080}"
problems=0

bad() { warn "$*"; problems=$((problems + 1)); }

kv() { printf '   %-22s %s\n' "$1" "$2"; }

section() { printf '\n%s\n' "$(printf '\033[1m%s\033[0m' "$*")"; }

section "host"
kv "architecture" "$(uname -m)"
kv "os" "$(cs_os_field PRETTY_NAME)"
kv "kernel" "$(uname -r)"
kv "user" "$(id -un) (uid $(id -u))"
kv "python" "$(command -v python3 >/dev/null 2>&1 && python3 -V 2>&1 || echo missing)"
kv "bash" "$BASH_VERSION"

section "resources"
mem_gb="$(awk '/MemTotal/ { printf "%.1f", $2 / 1048576 }' /proc/meminfo 2>/dev/null || echo '?')"
kv "memory" "${mem_gb} GB"
if [[ -d /content ]]; then
  kv "disk /content" "$(df -h /content 2>/dev/null | awk 'NR==2 { print $4 " free of " $2 }')"
fi
kv "state dir" "${SD}"
kv "state size" "$(du -sh "$SD" 2>/dev/null | awk '{ print $1 }' || echo '0')"

section "code-server"
if command -v code-server >/dev/null 2>&1; then
  kv "path" "$(command -v code-server)"
  kv "version" "$(code-server --version 2>/dev/null | head -1 || echo '?')"
  [[ -f "${SD}/.installed-version" ]] && kv "installed tag" "$(cat "${SD}/.installed-version")"
else
  bad "code-server is not on PATH (run: bash colab/install.sh)"
fi

section "tunnels"
if command -v ngrok >/dev/null 2>&1; then
  kv "ngrok" "$(ngrok --version 2>/dev/null | head -1)"
  if ngrok config check >/dev/null 2>&1; then
    kv "ngrok authtoken" "configured"
  else
    bad "ngrok authtoken not configured (ngrok config add-authtoken <token>)"
  fi
else
  kv "ngrok" "not installed"
fi
if command -v cloudflared >/dev/null 2>&1; then
  kv "cloudflared" "$(cloudflared --version 2>/dev/null | awk 'NR==1 { print $3 }')"
else
  kv "cloudflared" "not installed"
fi

section "runtime state"
if cs_alive "${SD}/cs.pid"; then
  kv "code-server" "running (pid $(cs_read_pid "${SD}/cs.pid"))"
else
  kv "code-server" "not running"
fi
if cs_alive "${SD}/ngrok.pid"; then
  kv "ngrok" "running (pid $(cs_read_pid "${SD}/ngrok.pid"))"
fi
if cs_alive "${SD}/cloudflared.pid"; then
  kv "cloudflared" "running (pid $(cs_read_pid "${SD}/cloudflared.pid"))"
fi

kv "port ${PORT}" "$(cs_port_in_use "$PORT" && echo 'in use' || echo 'free')"
owners="$(cs_port_owner_pids "$PORT")"
for pid in $owners; do
  kv "port ${PORT} owner" "pid ${pid}: $(cs_cmdline "$pid" | cut -c1-70)"
done
kv "established conns" "$(cs_active_conns "$PORT")"

if curl -fsS --max-time 2 --noproxy '*' "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
  kv "healthz" "ok"
else
  kv "healthz" "not responding"
fi

if [[ -s "${SD}/credentials.txt" ]]; then
  section "credentials (from the last serve.sh run)"
  # Password intentionally not printed here; read the 0600 file if you need it.
  sed -e 's/^password=.*/password=<hidden; see the file>/' "${SD}/credentials.txt" \
    | sed 's/^/   /'
fi

section "logs"
for f in code-server.log ngrok.log cloudflared.log extensions.log; do
  if [[ -f "${SD}/${f}" ]]; then
    printf '   %-22s %s bytes\n' "$f" "$(wc -c <"${SD}/${f}" | tr -d ' ')"
  fi
done

printf '\n'
if ((problems == 0)); then
  ok "no problems detected"
else
  warn "${problems} problem(s) detected"
fi

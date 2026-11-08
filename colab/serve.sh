#!/usr/bin/env bash
#
# colab/serve.sh — start code-server and expose it through a tunnel.
#
#   bash colab/serve.sh                      # ngrok, background, prints URL
#   bash colab/serve.sh --foreground         # block (used by supervise.sh)
#   CS_TUNNEL=cloudflared bash colab/serve.sh
#   NGROK_DOMAIN=my-dev.ngrok-free.app bash colab/serve.sh   # stable hostname
#
# Nothing here modifies code-server. It is a plain Node HTTP server; this script
# only picks flags that suit an ephemeral Colab VM.
#
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

FOREGROUND=0
TUNNEL="${CS_TUNNEL:-auto}"
PORT="${CS_PORT:-}"
AUTH="password"

usage() {
  cat <<'EOF'
usage: serve.sh [options]

  --foreground     remain in the foreground until a child exits
  --tunnel=NAME    auto | ngrok | cloudflared | tailscale | none (default: auto)
  --port=N         local port  (default: first free in $CS_PORT_RANGE, 3000-5000)
  --no-auth        disable authentication (requires CS_ALLOW_INSECURE=1)
  -h, --help
EOF
}

while (($#)); do
  case "$1" in
    --foreground) FOREGROUND=1 ;;
    --tunnel=*)   TUNNEL="${1#*=}" ;;
    --port=*)     PORT="${1#*=}" ;;
    --no-auth)    AUTH="none" ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

if [[ -n "$PORT" ]]; then
  [[ "$PORT" =~ ^[0-9]+$ ]] || die "invalid port: ${PORT}"
fi
case "$TUNNEL" in
  auto|ngrok|cloudflared|tailscale|none) ;;
  *) die "--tunnel must be auto, ngrok, cloudflared, tailscale or none (got: ${TUNNEL})" ;;
esac

# auto: ngrok if it has credentials, otherwise cloudflared quick tunnel, which
# needs no account at all. That makes a bare notebook run work with zero setup.
if [[ "$TUNNEL" == "auto" ]]; then
  if [[ -n "${NGROK_TOKEN:-}" ]]; then
    TUNNEL=ngrok
  elif command -v ngrok >/dev/null 2>&1 && ngrok config check >/dev/null 2>&1; then
    TUNNEL=ngrok
  elif [[ -n "${TS_AUTHKEY:-}" ]] && command -v tailscale >/dev/null 2>&1; then
    TUNNEL=tailscale
  elif command -v cloudflared >/dev/null 2>&1; then
    TUNNEL=cloudflared
  else
    TUNNEL=ngrok
  fi
  log "auto-selected tunnel: ${TUNNEL}"
fi

if [[ "$AUTH" == "none" ]]; then
  [[ "${CS_ALLOW_INSECURE:-0}" == "1" ]] \
    || die "--no-auth requires CS_ALLOW_INSECURE=1"
  [[ "$TUNNEL" == "none" ]] \
    || die "--no-auth cannot be combined with a public tunnel"
fi

cs_need code-server "run: bash colab/install.sh"
cs_need curl
cs_need python3

SD="$(cs_state_dir)"
cs_lock serve

# Resolve the port now that the state dir exists, and record it so stop.sh,
# supervise.sh and doctor.sh operate on the same one.
if [[ -z "$PORT" ]]; then
  read -r _pstart _pend <<<"$(cs_port_range)"
  PORT="$(cs_find_free_port)" \
    || die "no free port in ${_pstart}-${_pend}; widen CS_PORT_RANGE or pass --port=<n>"
  log "auto-selected port ${PORT} (first free in ${_pstart}-${_pend})"
fi
printf '%s\n' "$PORT" >"${SD}/port"

CS_PID=''
TUN_PID=''
PUBLIC_URL=''

cleanup_children() {
  [[ -n "$CS_PID" ]] && cs_stop_pidfile "${SD}/cs.pid" code-server
  [[ -n "$TUN_PID" ]] && cs_stop_pidfile "${SD}/${TUNNEL}.pid" "$TUNNEL"
  return 0
}

on_exit() {
  if ((FOREGROUND)); then cleanup_children; fi
  cs_unlock
}
trap on_exit EXIT
# Turn signals into a normal exit so the EXIT trap tears the children down.
trap 'exit 143' TERM INT HUP

# ------------------------------------------------------- stale instances ----
log "clearing stale instances"
cs_stop_pidfile "${SD}/cs.pid" code-server
cs_stop_pidfile "${SD}/ngrok.pid" ngrok
cs_stop_pidfile "${SD}/cloudflared.pid" cloudflared

if cs_port_in_use "$PORT"; then
  log "port ${PORT} is occupied; attempting to reclaim it"
  if ! cs_free_port "$PORT"; then
    cs_port_report "$PORT"
    printf '%serr%s port %s is busy and not reclaimable — free it or use --port=<n>\n' \
      "$CS_C_RED" "$CS_C_RESET" "$PORT" >&2
    # Exit code 2 means "retrying will not help"; supervise.sh stops on it.
    exit 2
  fi
  ok "port ${PORT} reclaimed"
fi

# --------------------------------------------------------- extensions ----
# Installed before the server starts so the marker file and the extension dir
# cannot race with the extension host.
install_extensions() {
  local sd=$1 marker ext
  marker="${sd}/.extensions-$(printf '%s' "$CS_EXTENSIONS" | cksum | cut -d' ' -f1)"
  if [[ -f "$marker" ]]; then
    ok "extensions already installed"
    return 0
  fi
  local IFS=','
  for ext in $CS_EXTENSIONS; do
    [[ -n "$ext" ]] || continue
    log "installing extension ${ext}"
    if code-server \
        --user-data-dir "${sd}/data" \
        --extensions-dir "${sd}/extensions" \
        --install-extension "$ext" --force \
        >>"${sd}/extensions.log" 2>&1; then
      ok "extension ${ext}"
    else
      warn "extension ${ext} failed (see ${sd}/extensions.log)"
    fi
  done
  : >"$marker"
}
if [[ -n "${CS_EXTENSIONS:-}" ]]; then
  install_extensions "$SD"
fi

# -------------------------------------------------------- code-server ----
CODE_PASSWORD="$(cs_password "$SD")"

cs_args=(
  --bind-addr "127.0.0.1:${PORT}"
  --auth "$AUTH"
  --user-data-dir "${SD}/data"
  --extensions-dir "${SD}/extensions"
  --disable-telemetry
  --disable-update-check
  --disable-workspace-trust
)

log "starting code-server on 127.0.0.1:${PORT}"
cs_rotate_log "${SD}/code-server.log"
PASSWORD="$CODE_PASSWORD" nohup code-server "${cs_args[@]}" \
  >"${SD}/code-server.log" 2>&1 9>&- &
CS_PID=$!
cs_write_pid "${SD}/cs.pid" "$CS_PID"

if ! cs_wait_http "http://127.0.0.1:${PORT}/healthz" "${CS_HEALTH_TIMEOUT:-90}"; then
  cs_dump_log "${SD}/code-server.log" 60
  cs_stop_pidfile "${SD}/cs.pid" code-server
  CS_PID=''
  die "code-server did not become healthy"
fi
ok "code-server healthy (pid ${CS_PID})"

# ------------------------------------------------------------- tunnels ----
ngrok_public_url() {
  curl -fsS --max-time 2 --noproxy '*' "http://127.0.0.1:4040/api/tunnels" 2>/dev/null \
    | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for t in data.get("tunnels", []):
    url = t.get("public_url", "")
    if url.startswith("https://"):
        print(url)
        break
' 2>/dev/null || true
}

start_ngrok() {
  cs_need ngrok "run: bash colab/install.sh"

  if [[ -n "${NGROK_TOKEN:-}" ]]; then
    ngrok config add-authtoken "$NGROK_TOKEN" >/dev/null 2>&1 \
      || warn "ngrok authtoken refresh failed"
  fi

  local args=(http)
  if [[ -n "${NGROK_DOMAIN:-}" ]]; then
    args+=("--url=https://${NGROK_DOMAIN}")
  fi
  if [[ -n "${NGROK_BASIC_AUTH:-}" ]]; then
    # Extra gate at ngrok's edge: rejects scanners before they ever reach
    # code-server. Free tier hostnames get probed within minutes.
    args+=("--basic-auth=${NGROK_BASIC_AUTH}")
  fi
  args+=("$PORT" --log=stdout --log-format=json)

  log "opening ngrok tunnel"
  cs_rotate_log "${SD}/ngrok.log"
  nohup ngrok "${args[@]}" >"${SD}/ngrok.log" 2>&1 9>&- &
  TUN_PID=$!
  cs_write_pid "${SD}/ngrok.pid" "$TUN_PID"

  local i
  for ((i = 0; i < 45; i++)); do
    PUBLIC_URL="$(ngrok_public_url)"
    [[ -n "$PUBLIC_URL" ]] && return 0
    kill -0 "$TUN_PID" 2>/dev/null || break
    if ((i > 0 && i % 10 == 0)); then dim "  waiting for ngrok URL (${i}s)"; fi
    sleep 1
  done

  cs_dump_log "${SD}/ngrok.log" 40
  warn "no public URL from ngrok"
  warn "common causes: missing authtoken (ngrok config add-authtoken <t>),"
  warn "free-tier session limit (one agent at a time), or a reserved-domain mismatch"
  return 1
}

start_cloudflared() {
  cs_need cloudflared "run: WITH_CLOUDFLARED=1 bash colab/install.sh"

  local args=(tunnel)
  if [[ -n "${CF_TOKEN:-}" ]]; then
    # Named tunnel: stable hostname on a domain you control, no interstitial
    # page, survives restarts. This is the answer to "the ngrok URL keeps
    # changing" — proper hosting rather than a disguise.
    args+=(run --token "$CF_TOKEN")
  else
    args+=(--url "http://127.0.0.1:${PORT}")
  fi
  args+=(--no-autoupdate)

  log "opening cloudflared tunnel"
  cs_rotate_log "${SD}/cloudflared.log"
  nohup cloudflared "${args[@]}" >"${SD}/cloudflared.log" 2>&1 9>&- &
  TUN_PID=$!
  cs_write_pid "${SD}/cloudflared.pid" "$TUN_PID"

  if [[ -n "${CF_TUNNEL_URL:-}" ]]; then
    PUBLIC_URL="$CF_TUNNEL_URL"
    return 0
  fi

  local i
  for ((i = 0; i < 45; i++)); do
    PUBLIC_URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' \
      "${SD}/cloudflared.log" 2>/dev/null | head -1 || true)"
    [[ -n "$PUBLIC_URL" ]] && return 0
    kill -0 "$TUN_PID" 2>/dev/null || break
    if ((i > 0 && i % 10 == 0)); then dim "  waiting for cloudflared URL (${i}s)"; fi
    sleep 1
  done

  cs_dump_log "${SD}/cloudflared.log" 40
  warn "no public URL from cloudflared"
  warn "with CF_TOKEN set, pass CF_TUNNEL_URL=https://your.hostname so it can be reported"
  return 1
}

tailscale_url() {
  if [[ -n "${TS_TUNNEL_URL:-}" ]]; then
    printf '%s' "$TS_TUNNEL_URL"
    return 0
  fi
  tailscale status --json </dev/null 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
name = ((d.get("Self") or {}).get("DNSName") or "").rstrip(".")
if name:
    print("https://" + name)
' 2>/dev/null || true
}

ts_backend_state() {
  tailscale status --json </dev/null 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(d.get("BackendState") or "")
' 2>/dev/null || true
}

# `tailscale status` exits 1 when the node is merely logged out, which is NOT the
# same as "daemon is down". Using it as the liveness probe started a second
# tailscaled on every retry: "safesocket.Listen: ... address already in use".
# `--json` exits 0 whenever the daemon answers, whatever the login state.
ts_daemon_up() {
  [[ -S "${TS_SOCKET:-/var/run/tailscale/tailscaled.sock}" ]] || return 1
  tailscale status --json </dev/null >/dev/null 2>&1
}

start_tailscale() {
  cs_need tailscale "run: WITH_TAILSCALE=1 bash colab/install.sh"
  [[ -n "${TS_AUTHKEY:-}" ]] \
    || die "tailscale needs TS_AUTHKEY (admin console -> Settings -> Keys; make it reusable)"

  local node
  node="$(printf '%s' "${TS_HOSTNAME:-code}" | tr '[:upper:]' '[:lower:]')"
  case "$node" in
    ''|-*|*-|*[!a-z0-9-]*)
      die "TS_HOSTNAME must be a DNS label (a-z, 0-9, hyphen, no leading/trailing hyphen): '${node}'" ;;
  esac
  TS_NODE="$node"

  # Colab has no /dev/net/tun, so tailscaled must run in userspace mode. Serve
  # and Funnel still work there because tailscaled does the dialing itself.
  if ts_daemon_up; then
    ok "tailscaled already running — reusing it"
    TUN_PID=''
  else
    log "starting tailscaled (userspace networking)"
    cs_rotate_log "${SD}/tailscaled.log"
    nohup tailscaled --tun=userspace-networking --socks5-server=localhost:1055 \
      >"${SD}/tailscaled.log" 2>&1 9>&- &
    TUN_PID=$!
    cs_write_pid "${SD}/tailscale.pid" "$TUN_PID"
    local i
    for ((i = 0; i < 20; i++)); do
      ts_daemon_up && break
      sleep 1
    done
    if ! ts_daemon_up; then
      cs_dump_log "${SD}/tailscaled.log" 30
      return 1
    fi
  fi

  local state
  state="$(ts_backend_state)"
  if [[ "$state" != "Running" ]]; then
    log "joining tailnet as ${TS_NODE} (state: ${state:-unknown})"
    # Never let this hang: an unreachable control plane would otherwise sit here
    # until the watchdog fires.
    if ! timeout 120 tailscale up \
        --authkey="$TS_AUTHKEY" \
        --hostname="$TS_NODE" \
        --accept-routes=false </dev/null >"${SD}/tailscale-up.log" 2>&1; then
      cs_dump_log "${SD}/tailscale-up.log" 20
      # Retrying cannot fix a bad credential, so exit 2 ("unrecoverable") and let
      # supervise.sh stop instead of burning its restart budget.
      printf '%serr%s tailscale could not join: expired key, or a single-use key already consumed\n' \
        "$CS_C_RED" "$CS_C_RESET" >&2
      exit 2
    fi
  else
    # Already joined: keep the name in sync without a new auth (renames on
    # restart would otherwise silently keep the old URL).
    tailscale set --hostname="$TS_NODE" </dev/null >/dev/null 2>&1 \
      || warn "could not apply TS_HOSTNAME=${TS_NODE} to a running node"
  fi

  log "enabling Funnel for 127.0.0.1:${PORT}"
  if ! timeout 60 tailscale funnel --bg "$PORT" </dev/null \
      >"${SD}/tailscale-funnel.log" 2>&1; then
    cs_dump_log "${SD}/tailscale-funnel.log" 20
    local enable_url
    enable_url="$(grep -oE 'https://login\.tailscale\.com/f/funnel[^[:space:]]*' \
      "${SD}/tailscale-funnel.log" 2>/dev/null | head -1 || true)"
    if [[ -n "$enable_url" ]]; then
      # Retrying cannot fix this: an admin has to approve Funnel for the tailnet.
      printf '%serr%s Funnel is disabled for this tailnet. Approve it once, then re-run:\n  %s\n' \
        "$CS_C_RED" "$CS_C_RESET" "$enable_url" >&2
      exit 2
    fi
    return 1
  fi

  local i
  for ((i = 0; i < 45; i++)); do
    PUBLIC_URL="$(tailscale_url)"
    [[ -n "$PUBLIC_URL" ]] && return 0
    sleep 1
  done
  warn "could not read the ts.net hostname from tailscale status"
  return 1
}

case "$TUNNEL" in
  tailscale)   start_tailscale   || die "tunnel startup failed" ;;
  ngrok)       start_ngrok       || die "tunnel startup failed" ;;
  cloudflared) start_cloudflared || die "tunnel startup failed" ;;
  none)        PUBLIC_URL="http://127.0.0.1:${PORT}" ;;
esac

# ------------------------------------------------------------- report ----
{
  printf 'url=%s\n' "$PUBLIC_URL"
  printf 'password=%s\n' "$CODE_PASSWORD"
  printf 'tunnel=%s\n' "$TUNNEL"
  printf 'port=%s\n' "$PORT"
  printf 'state=%s\n' "$SD"
} >"${SD}/credentials.txt"
chmod 600 -- "${SD}/credentials.txt" 2>/dev/null || true

printf '\n'
dim  '  ────────────────────────────────────────────────────────────'
printf '   %s  %s\n' "$(printf '\033[1mcode-server\033[0m')" "$PUBLIC_URL"
printf '   password     %s\n' "$CODE_PASSWORD"
[[ -n "${NGROK_BASIC_AUTH:-}" ]] && printf '   basic auth   %s\n' "$NGROK_BASIC_AUTH"
dim  '  ────────────────────────────────────────────────────────────'
printf '\n'
dim "  state   ${SD}"
dim "  logs    ${SD}/code-server.log  ${SD}/${TUNNEL}.log"
dim "  stop    bash colab/stop.sh"
printf '\n'

if [[ "$TUNNEL" == "tailscale" ]]; then
  dim "  ts.net hostname is fixed while TS_HOSTNAME (default: code) and a"
  dim "  reusable TS_AUTHKEY stay the same."
  printf '\n'
fi

if [[ "$TUNNEL" == "ngrok" && -z "${NGROK_DOMAIN:-}" ]]; then
  warn "ngrok free tier shows a warning page on the first browser hit."
  warn "Click through it, or the editor's JS assets come back as HTML (blank page)."
  warn "Set NGROK_DOMAIN=<reserved-domain> to keep one hostname across restarts,"
  warn "or CS_TUNNEL=cloudflared for no interstitial at all."
fi

# --------------------------------------------------------- foreground ----
if ((FOREGROUND)); then
  log "foreground mode; Ctrl-C to stop"
  while :; do
    if ! kill -0 "$CS_PID" 2>/dev/null; then
      warn "code-server exited"
      exit 1
    fi
    if [[ -n "$TUN_PID" ]] && ! kill -0 "$TUN_PID" 2>/dev/null; then
      warn "tunnel exited"
      exit 1
    fi
    sleep 2
  done
fi

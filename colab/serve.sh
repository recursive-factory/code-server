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
PORT="${CS_PORT:-8080}"
AUTH="password"

usage() {
  cat <<'EOF'
usage: serve.sh [options]

  --foreground     remain in the foreground until a child exits
  --tunnel=NAME    auto | ngrok | cloudflared | none (default: $CS_TUNNEL, auto)
  --port=N         local port                        (default: $CS_PORT, 8080)
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

[[ "$PORT" =~ ^[0-9]+$ ]] || die "invalid port: ${PORT}"
case "$TUNNEL" in
  auto|ngrok|cloudflared|none) ;;
  *) die "--tunnel must be auto, ngrok, cloudflared or none (got: ${TUNNEL})" ;;
esac

# auto: ngrok if it has credentials, otherwise cloudflared quick tunnel, which
# needs no account at all. That makes a bare notebook run work with zero setup.
if [[ "$TUNNEL" == "auto" ]]; then
  if [[ -n "${NGROK_TOKEN:-}" ]]; then
    TUNNEL=ngrok
  elif command -v ngrok >/dev/null 2>&1 && ngrok config check >/dev/null 2>&1; then
    TUNNEL=ngrok
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
  die "port ${PORT} is still in use — another process owns it (try --port=<n>)"
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
    sleep 1
  done

  cs_dump_log "${SD}/cloudflared.log" 40
  warn "no public URL from cloudflared"
  warn "with CF_TOKEN set, pass CF_TUNNEL_URL=https://your.hostname so it can be reported"
  return 1
}

case "$TUNNEL" in
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

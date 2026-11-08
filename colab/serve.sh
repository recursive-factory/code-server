#!/usr/bin/env bash
#
# colab/serve.sh — start code-server and expose it through one tunnel.
#
#   bash colab/serve.sh                    # zrok when configured, else cloudflared
#   bash colab/serve.sh --foreground       # block (used by supervise.sh)
#   bash colab/serve.sh --tunnel=cloudflared
#
# Nothing here modifies code-server; it is a plain Node HTTP server. This only
# picks flags suited to an ephemeral Colab VM and opens the tunnel.
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
  --tunnel=NAME    auto | zrok | cloudflared | none   (default: auto)
  --port=N         local port (default: first free in $CS_PORT_RANGE, 3000-5000)
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
  auto|zrok|cloudflared|none) ;;
  *) die "--tunnel must be auto, zrok, cloudflared or none (got: ${TUNNEL})" ;;
esac

# auto: zrok when it has a token and a name (fixed URL), else a Cloudflare quick
# tunnel, which needs no account at all.
if [[ "$TUNNEL" == "auto" ]]; then
  if [[ -n "${ZROK_TOKEN:-}" && -n "${ZROK_NAME:-}" ]] && command -v zrok2 >/dev/null 2>&1; then
    TUNNEL=zrok
  elif command -v cloudflared >/dev/null 2>&1; then
    TUNNEL=cloudflared
  else
    TUNNEL=cloudflared
  fi
  log "auto-selected tunnel: ${TUNNEL}"
fi

if [[ "$AUTH" == "none" ]]; then
  [[ "${CS_ALLOW_INSECURE:-0}" == "1" ]] || die "--no-auth requires CS_ALLOW_INSECURE=1"
  [[ "$TUNNEL" == "none" ]] || die "--no-auth cannot be combined with a public tunnel"
fi

cs_need code-server "run: bash colab/install.sh"
cs_need curl
cs_need python3

SD="$(cs_state_dir)"
cs_lock serve

# Resolve the port now that the state dir exists, and record it so the other
# scripts operate on the port actually in use.
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
cs_stop_pidfile "${SD}/cs.pid" code-server
cs_stop_pidfile "${SD}/zrok.pid" zrok
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
# zrok: the URL is the reserved name, so it survives new runtimes.
# Claim ZROK_NAME, or with ZROK_AUTOCLAIM=1 a deterministic variant of it.
# Prints the name in use; returns non-zero only when nothing could be claimed.
zrok_claim_name() {
  local want=$1 cand suffix
  if zrok2 list names </dev/null 2>/dev/null | grep -qw "$want"; then
    printf '%s' "$want"
    return 0
  fi
  if zrok_name_create "$want"; then
    printf '%s' "$want"
    return 0
  fi
  if [[ "${ZROK_AUTOCLAIM:-0}" != "1" ]]; then
    printf '%serr%s zrok name '%s' is not available in the shared public namespace.\n' \
      "$CS_C_RED" "$CS_C_RESET" "$want" >&2
    # 409 is the same for "yours" and "someone else's"; the listing is the tell.
    printf '  if it is yours, it appears in: zrok2 list names\n' >&2
    printf '  otherwise pick another ZROK_NAME, or set ZROK_AUTOCLAIM=1 to claim %s-<hash>\n' "$want" >&2
    return 1
  fi

  suffix="$(printf '%s' "${ZROK_TOKEN:-}" | sha256sum | cut -c1-4)"
  for cand in "${want}-${suffix}" "${want}-${suffix}-2" "${want}-${suffix}-3"; do
    if zrok_name_create "$cand"; then
      printf '%s' "$cand"
      return 0
    fi
  done
  printf '%serr%s could not claim any variant of '%s'\n' "$CS_C_RED" "$CS_C_RESET" "$want" >&2
  return 1
}

# Create one name. Success is "it exists now", not "we created it".
zrok_name_create() {
  local name=$1 out
  out="$(timeout 45 zrok2 create name -n public "$name" </dev/null 2>&1 || true)"
  printf '%s\n' "$out" >>"${SD}/zrok.log"
  case "$out" in
    *409*|*conflict*|*ERROR*|*"already"*) return 1 ;;
    *) ok "zrok name '${name}' ready"; return 0 ;;
  esac
}


start_zrok() {
  cs_need zrok2 "run: bash colab/install.sh"
  [[ -n "${ZROK_TOKEN:-}" ]] || die "zrok needs ZROK_TOKEN (account token from https://zrok.io)"
  [[ -n "${ZROK_NAME:-}" ]] || die "zrok needs ZROK_NAME — the reserved name, which becomes the URL"

  local out
  # --headless is required: without a TTY, enable aborts with "open /dev/tty".
  out="$(timeout 90 zrok2 enable "$ZROK_TOKEN" --headless </dev/null 2>&1 || true)"
  printf '%s\n' "$out" >>"${SD}/zrok.log"
  case "$out" in
    *"already have an enabled environment"*) ok "zrok environment already enabled" ;;
    *ERROR*|*error*)
      cs_dump_log "${SD}/zrok.log" 20
      printf '%serr%s zrok enable failed — check ZROK_TOKEN\n' "$CS_C_RED" "$CS_C_RESET" >&2
      exit 2 ;;
    *) ok "zrok environment enabled" ;;
  esac

  # Public names are global, so the one you want may belong to someone else.
  # ZROK_AUTOCLAIM derives a deterministic suffix from the token, so the fallback
  # name is the same on every runtime and the URL stays stable.
  local zname="${ZROK_NAME}"
  zname="$(zrok_claim_name "$zname")" || exit 2
  if [[ "$zname" != "$ZROK_NAME" ]]; then
    warn "zrok name '${ZROK_NAME}' was unavailable — claimed '${zname}' instead"
    warn "  your URL is https://${zname}.shares.zrok.io (stable while the token is)"
    warn "  set ZROK_NAME='${zname}' to make that explicit, or reserve another name"
  fi

  log "opening zrok share for 127.0.0.1:${PORT} as ${zname}"
  cs_rotate_log "${SD}/zrok.log"
  nohup zrok2 share public "127.0.0.1:${PORT}" -n "public:${zname}" --headless \
    >"${SD}/zrok.log" 2>&1 9>&- &
  TUN_PID=$!
  cs_write_pid "${SD}/zrok.pid" "$TUN_PID"

  local i host
  for ((i = 0; i < 45; i++)); do
    # zrok2 logs "access your zrok share at: <name>.shares.zrok.io" with no scheme.
    host="$(grep -oE '[a-z0-9.-]+\.shares\.zrok\.io' "${SD}/zrok.log" 2>/dev/null | head -1 || true)"
    if [[ -n "$host" ]]; then
      PUBLIC_URL="https://${host}"
      return 0
    fi
    kill -0 "$TUN_PID" 2>/dev/null || break
    if ((i > 0 && i % 10 == 0)); then dim "  waiting for zrok share (${i}s)"; fi
    sleep 1
  done
  cs_dump_log "${SD}/zrok.log" 25
  return 1
}

# cloudflared: no account needed; the hostname is per process, so it rotates.
start_cloudflared() {
  cs_need cloudflared "run: bash colab/install.sh"

  local args=(tunnel)
  if [[ -n "${CF_TOKEN:-}" ]]; then
    # Named tunnel: stable hostname on a domain you control.
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
  cs_dump_log "${SD}/cloudflared.log" 30
  return 1
}

case "$TUNNEL" in
  zrok)        start_zrok        || die "tunnel startup failed" ;;
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
dim  '  ────────────────────────────────────────────────────────────'
printf '\n'
dim "  state   ${SD}"
dim "  logs    ${SD}/code-server.log  ${SD}/${TUNNEL}.log"
dim "  stop    bash colab/stop.sh"
printf '\n'

if [[ "$TUNNEL" == "zrok" ]]; then
  dim "  zrok hostname comes from ZROK_NAME, so it is the same next time."
elif [[ -z "${CF_TUNNEL_URL:-}" && -z "${CF_TOKEN:-}" ]]; then
  warn "cloudflared quick tunnels get a new hostname every start;"
  warn "set ZROK_TOKEN + ZROK_NAME for a fixed URL, or CF_TOKEN + CF_TUNNEL_URL."
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

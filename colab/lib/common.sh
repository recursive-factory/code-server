#!/usr/bin/env bash
# colab/lib/common.sh — shared helpers for the Colab scripts.
#
# Source this file, do not execute it:
#   source "$(dirname "$0")/lib/common.sh"
#
# Everything here is deliberately side-effect free apart from installing an ERR
# trap and the colour constants.

if [[ -n "${CS_COMMON_LOADED:-}" ]]; then
  return 0
fi
CS_COMMON_LOADED=1

set -Eeuo pipefail

# shellcheck disable=SC2128  # BASH_SOURCE is the file being sourced
readonly CS_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly CS_REPO_ROOT="$(cd -- "${CS_LIB_DIR}/../.." && pwd -P)"

# --------------------------------------------------------------- output ----
if [[ -t 1 ]]; then
  CS_C_RESET=$'\033[0m'
  CS_C_BLUE=$'\033[1;34m'
  CS_C_GREEN=$'\033[1;32m'
  CS_C_RED=$'\033[1;31m'
  CS_C_YELLOW=$'\033[1;33m'
  CS_C_DIM=$'\033[2m'
else
  CS_C_RESET='' CS_C_BLUE='' CS_C_GREEN='' CS_C_RED='' CS_C_YELLOW='' CS_C_DIM=''
fi

log()  { printf '%s==>%s %s\n'   "$CS_C_BLUE"   "$CS_C_RESET" "$*"; }
ok()   { printf '%s ok%s %s\n'   "$CS_C_GREEN"  "$CS_C_RESET" "$*"; }
warn() { printf '%swarn%s %s\n'  "$CS_C_YELLOW" "$CS_C_RESET" "$*" >&2; }
die()  { printf '%serr%s %s\n'   "$CS_C_RED"    "$CS_C_RESET" "$*" >&2; exit 1; }
dim()  { printf '%s%s%s\n'       "$CS_C_DIM"    "$*" "$CS_C_RESET"; }

# Report the failing line instead of dying silently. Exempt from the usual
# `&&`/`||`/`if` cases, so it only fires on genuinely unexpected failures.
cs_on_err() {
  local ec=$? line=$1
  printf '%serr%s %s:%s exited with %d\n' \
    "$CS_C_RED" "$CS_C_RESET" "$(basename -- "${BASH_SOURCE[2]:-?}")" "$line" "$ec" >&2
  exit "$ec"
}
trap 'cs_on_err "$LINENO"' ERR

# --------------------------------------------------------------- system ----
cs_is_root() { [[ "$(id -u)" -eq 0 ]]; }

cs_root() {
  if cs_is_root; then "$@"; else sudo -- "$@"; fi
}

cs_need() {
  local cmd=$1 hint=${2:-}
  command -v "$cmd" >/dev/null 2>&1 || die "missing command: ${cmd}${hint:+ (${hint})}"
}

cs_os_field() {
  ( # shellcheck disable=SC1091
    . /etc/os-release 2>/dev/null || exit 0
    printf '%s' "${!1:-}"
  )
}

# Ubuntu 24.04+ renamed libasound2 -> libasound2t64. Colab still ships 22.04,
# but the image changes without notice, so detect instead of hardcoding.
cs_asound_pkg() {
  case "$(cs_os_field VERSION_ID)" in
    24.04*|25.*|26.*|2[7-9].*) printf 'libasound2t64' ;;
    *)                         printf 'libasound2' ;;
  esac
}

cs_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

# ------------------------------------------------------------ state dir ----
cs_state_dir() {
  local d="${CS_STATE_DIR:-/content/.code-server}"
  mkdir -p -- "$d" || die "cannot create state dir: ${d}"
  chmod 700 -- "$d" 2>/dev/null || true
  printf '%s' "$d"
}

cs_cache_dir() {
  local d="${CS_CACHE_DIR:-$(cs_state_dir)/cache}"
  mkdir -p -- "$d" || die "cannot create cache dir: ${d}"
  printf '%s' "$d"
}

# ------------------------------------------------------------------ lock ----
CS_LOCK_PATH=''

cs_lock() {
  local name=${1:-lock} sd f
  sd="$(cs_state_dir)"
  f="${sd}/${name}.lock"
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$f" || die "cannot open lock: ${f}"
    flock -n 9 || die "another instance is already running (${f})"
    CS_LOCK_PATH="$f"
  else
    local d="${f}.d"
    mkdir -- "$d" 2>/dev/null || die "another instance is already running (${d})"
    printf '%s\n' "$$" >"${d}/pid"
    CS_LOCK_PATH="$d"
  fi
}

cs_unlock() {
  [[ -n "${CS_LOCK_PATH:-}" ]] || return 0
  if [[ -d "$CS_LOCK_PATH" ]]; then
    rm -rf -- "$CS_LOCK_PATH"
  else
    : >"$CS_LOCK_PATH" 2>/dev/null || true
  fi
  CS_LOCK_PATH=''
  return 0
}

# -------------------------------------------------------------- pidfiles ----
cs_read_pid() { [[ -s "${1:-}" ]] && cat -- "$1" 2>/dev/null || printf ''; }
cs_write_pid() { printf '%s\n' "$2" >"$1"; }

cs_alive() {
  local p
  p="$(cs_read_pid "${1:-}")"
  [[ -n "$p" ]] || return 1
  kill -0 "$p" 2>/dev/null
}

cs_stop_pidfile() {
  local f=$1 label=${2:-process} p i
  p="$(cs_read_pid "$f")"
  rm -f -- "$f"
  [[ -n "$p" ]] || return 0
  kill -0 "$p" 2>/dev/null || return 0
  log "stopping ${label} (pid ${p})"
  kill -TERM "$p" 2>/dev/null || true
  for i in {1..15}; do
    kill -0 "$p" 2>/dev/null || return 0
    sleep 0.3
  done
  kill -KILL "$p" 2>/dev/null || true
  return 0
}

# ------------------------------------------------------------------ http ----
cs_wait_http() {
  local url=$1 timeout=${2:-60} i
  for ((i = 0; i < timeout; i++)); do
    # --noproxy: Colab/Jupyter sometimes exports http_proxy, which would send
    # loopback checks through a proxy that cannot reach 127.0.0.1.
    if curl -fsS --max-time 2 --noproxy '*' "$url" >/dev/null 2>&1; then
      return 0
    fi
    # First start on a fresh VM is not instant; emit a heartbeat so a slow run
    # is distinguishable from a hung one when reading the log afterwards.
    if ((i > 0 && i % 15 == 0)); then
      dim "  waiting for ${url} (${i}s)"
    fi
    sleep 1
  done
  return 1
}

cs_port_in_use() {
  local p=$1
  if command -v ss >/dev/null 2>&1; then
    ss -ltnH 2>/dev/null | awk -v pat=":${p}\$" '$4 ~ pat { found = 1 } END { exit !found }'
  else
    (exec 3<>"/dev/tcp/127.0.0.1/${p}") 2>/dev/null
  fi
}

# Established connections on a local port. Used by the idle watchdog: counting
# sockets is cheap and needs nothing from the editor itself.
cs_active_conns() {
  local p=$1 n
  if command -v ss >/dev/null 2>&1; then
    n="$(ss -Htn state established "sport = :${p}" 2>/dev/null | wc -l | tr -d ' ')"
    printf '%s' "${n:-0}"
    return 0
  fi
  n="$(python3 -c '
import sys
port = int(sys.argv[1])
want = "%04X" % port
n = 0
for f in ("/proc/net/tcp", "/proc/net/tcp6"):
    try:
        rows = open(f).read().splitlines()[1:]
    except OSError:
        continue
    for r in rows:
        c = r.split()
        if len(c) > 3 and c[1].split(":")[1].upper() == want and c[3] == "01":
            n += 1
print(n)
' "$p" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

# A code-server process does not keep "code-server --bind-addr" in its argv: the
# bin/code-server wrapper re-execs, so argv looks like
#   .../lib/code-server-<ver>/lib/node .../out/node/entry.js --bind-addr 127.0.0.1:8080
# which is why pattern-matching pkill misses orphaned instances. Resolve the
# socket owner instead.
cs_cmdline() {
  tr '\0' ' ' <"/proc/${1}/cmdline" 2>/dev/null | sed 's/ *$//' || true
}

cs_port_owner_pids() {
  local p=$1
  if command -v ss >/dev/null 2>&1; then
    ss -ltnpH 2>/dev/null | awk -v pat=":${p}\$" '$4 ~ pat' \
      | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u || true
    return 0
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -tiTCP:"$p" -sTCP:LISTEN 2>/dev/null | sort -u || true
    return 0
  fi
  if command -v fuser >/dev/null 2>&1; then
    fuser -n tcp "$p" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' | sort -u || true
  fi
  return 0
}

cs_port_report() {
  local p=$1 owners pid
  owners="$(cs_port_owner_pids "$p")"
  if [[ -z "$owners" ]]; then
    warn "port ${p} is in use but the owner could not be identified"
    return 0
  fi
  for pid in $owners; do
    warn "port ${p} owned by pid ${pid}: $(cs_cmdline "$pid" | cut -c1-100)"
  done
}

# Reclaim the port from a previous run of this stack. Refuses to touch anything
# that does not look like our own processes.
cs_free_port() {
  local p=$1 owners pid cmd i
  owners="$(cs_port_owner_pids "$p")"
  [[ -n "$owners" ]] || return 0

  for pid in $owners; do
    cmd="$(cs_cmdline "$pid")"
    case "$cmd" in
      *entry.js*|*code-server*|*zrok*|*cloudflared*)
        warn "reclaiming port ${p} from pid ${pid}: ${cmd:0:80}"
        kill -TERM "$pid" 2>/dev/null || true
        ;;
      *)
        warn "port ${p} is held by an unrelated process (pid ${pid}): ${cmd:0:80}"
        return 1
        ;;
    esac
  done

  for i in {1..20}; do
    cs_port_in_use "$p" || return 0
    sleep 0.3
  done
  for pid in $owners; do kill -KILL "$pid" 2>/dev/null || true; done
  for i in {1..10}; do
    cs_port_in_use "$p" || return 0
    sleep 0.3
  done
  return 1
}

# 8080 is not a safe default on Colab: in some runtimes Colab's own frontend
# (datalab/web/app.js) already owns it. An explicit CS_PORT wins; otherwise
# serve.sh picks the first free candidate and records it, and the other scripts
# read that record so they always agree on the port.
cs_port_range() {
  local r="${CS_PORT_RANGE:-3000-5000}" a b
  a="${r%%-*}"
  b="${r##*-}"
  if [[ ! "$a" =~ ^[0-9]+$ || ! "$b" =~ ^[0-9]+$ ]] || ((a >= b)); then
    a=3000
    b=5000
  fi
  printf '%s %s' "$a" "$b"
}

# First port in the range with no listener. One python3 process: a bash loop
# over 2000 ports costs seconds, while connect_ex() on loopback is microseconds
# per port (ECONNREFUSED comes straight back).
cs_find_free_port() {
  local start end found p
  read -r start end <<<"$(cs_port_range)"

  found="$(python3 - "$start" "$end" <<'PYSCAN' 2>/dev/null || true
import socket, sys

start, end = int(sys.argv[1]), int(sys.argv[2])
for port in range(start, end + 1):
    with socket.socket() as s:
        s.settimeout(0.05)
        # non-zero => nothing listening on loopback for that port
        if s.connect_ex(("127.0.0.1", port)) != 0:
            print(port)
            sys.exit(0)
sys.exit(1)
PYSCAN
)"
  if [[ -n "$found" ]]; then
    printf '%s' "$found"
    return 0
  fi

  # Fallback when python3 is missing or the scan failed.
  for ((p = start; p <= end; p++)); do
    if ! (exec 3<>"/dev/tcp/127.0.0.1/${p}") 2>/dev/null; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

cs_resolved_port() {
  local sd=$1
  if [[ -n "${CS_PORT:-}" ]]; then
    printf '%s' "$CS_PORT"
    return 0
  fi
  if [[ -s "${sd}/port" ]]; then
    head -1 -- "${sd}/port"
    return 0
  fi
  printf '8080'
}

# -------------------------------------------------------------- password ----
# Persisted in the state dir so a restart does not invalidate an open tab.
# CS_PASSWORD overrides without touching disk.
cs_password() {
  local sd=$1 f p
  f="${sd}/password"
  if [[ -n "${CS_PASSWORD:-}" ]]; then
    printf '%s' "$CS_PASSWORD"
    return 0
  fi
  if [[ -s "$f" ]]; then
    cat -- "$f"
    return 0
  fi
  p="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24 || true)"
  [[ ${#p} -eq 24 ]] || die "failed to generate a password"
  ( umask 077; printf '%s' "$p" >"$f" )
  chmod 600 -- "$f" 2>/dev/null || true
  printf '%s' "$p"
}

# ------------------------------------------------------------------ logs ----
cs_rotate_log() {
  local f=$1 max=${2:-5242880} sz
  [[ -f "$f" ]] || return 0
  sz="$(wc -c <"$f" 2>/dev/null || printf 0)"
  if ((sz > max)); then
    mv -f -- "$f" "${f}.1"
  fi
  return 0
}

cs_dump_log() {
  local f=$1 n=${2:-40}
  [[ -r "$f" ]] || return 0
  warn "last ${n} lines of ${f}:"
  tail -n "$n" -- "$f" >&2 || true
}

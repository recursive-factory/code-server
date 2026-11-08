#!/usr/bin/env bash
#
# colab/install.sh — install code-server + the tunnel agents inside a Colab VM.
#
#   bash colab/install.sh
#   CS_VERSION=4.145.2 bash colab/install.sh     # pin
#   CS_CACHE_DIR=/content/drive/MyDrive/.cs-cache bash colab/install.sh
#
# Installs zrok2 (fixed, name-based URL) and cloudflared (fallback, no account).
# The release tarball is cached, so a fresh runtime reinstalls in seconds.
#
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

CS_PREFIX="${CS_PREFIX:-/usr/local}"
CS_VERSION="${CS_VERSION:-}"
SKIP_APT="${SKIP_APT:-0}"

# ----------------------------------------------------- resolve the version --
resolve_version() {
  if [[ -n "$CS_VERSION" ]]; then
    printf '%s' "${CS_VERSION#v}"
    return 0
  fi
  local installed
  installed="$(code-server --version 2>/dev/null | awk 'NR==1 { print $1 }' || true)"
  if [[ -n "$installed" ]]; then
    printf '%s' "$installed"
    return 0
  fi
  # HEAD on /releases/latest follows the redirect to /releases/tag/vX.Y.Z and
  # avoids the unauthenticated GitHub API rate limit that shared Colab egress
  # IPs hit constantly.
  local tag
  tag="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
    https://github.com/coder/code-server/releases/latest 2>/dev/null || true)"
  tag="${tag##*/tag/v}"
  if [[ ! "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "could not resolve the latest code-server version; set CS_VERSION"
  fi
  printf '%s' "$tag"
}

# --------------------------------------------------------------- packages --
install_packages() {
  local pkgs
  pkgs="ca-certificates curl wget xz-utils libnss3 libsecret-1-0 libxkbfile1 libgbm1 libxshmfence1 $(cs_asound_pkg)"
  log "installing runtime libraries: ${pkgs}"
  cs_root apt-get update -qq
  # shellcheck disable=SC2086  # deliberate word splitting of the package list
  DEBIAN_FRONTEND=noninteractive cs_root apt-get install -y -qq --no-install-recommends $pkgs
}

# ------------------------------------------------------------ code-server --
# Official standalone layout, replicated so `code-server` resolves normally:
#   /usr/local/lib/code-server -> code-server-<ver>
#   /usr/local/bin/code-server -> ../lib/code-server/bin/code-server
install_code_server() {
  local version=$1 arch cache tarball root link

  arch="$(cs_arch)"
  cache="$(cs_cache_dir)"
  tarball="${cache}/code-server-${version}-linux-${arch}.tar.gz"
  root="${CS_PREFIX}/lib/code-server-${version}"
  link="${CS_PREFIX}/lib/code-server"

  if [[ -x "${root}/bin/code-server" ]]; then
    ok "code-server ${version} already unpacked at ${root}"
  else
    if [[ ! -s "$tarball" ]]; then
      local url="https://github.com/coder/code-server/releases/download/v${version}/code-server-${version}-linux-${arch}.tar.gz"
      log "downloading ${version} (${arch})"
      if ! curl -fL --retry 3 --retry-delay 2 -# -o "${tarball}.part" "$url"; then
        rm -f -- "${tarball}.part"
        warn "tarball download failed; falling back to the official install script"
        curl -fsSL https://code-server.dev/install.sh \
          | sh -s -- --method=standalone --prefix="$CS_PREFIX" --version="$version"
        return 0
      fi
      mv -f -- "${tarball}.part" "$tarball"
    else
      ok "using cached tarball $(basename -- "$tarball")"
    fi

    log "unpacking into ${CS_PREFIX}/lib"
    local stage extracted
    stage="$(mktemp -d)"
    tar -xzf "$tarball" -C "$stage"
    extracted="$(find "$stage" -maxdepth 1 -mindepth 1 -type d | head -1)"
    if [[ -z "$extracted" ]]; then
      rm -rf -- "$stage"
      die "unexpected tarball layout in $(basename -- "$tarball")"
    fi
    cs_root rm -rf -- "$root"
    cs_root mv -- "$extracted" "$root"
    rm -rf -- "$stage"
  fi

  cs_root ln -sfn -- "code-server-${version}" "$link"
  cs_root mkdir -p -- "${CS_PREFIX}/bin"
  cs_root ln -sfn -- "../lib/code-server/bin/code-server" "${CS_PREFIX}/bin/code-server"
  hash -r

  [[ -x "${CS_PREFIX}/bin/code-server" ]] || die "code-server not on PATH at ${CS_PREFIX}/bin"
  ok "code-server $(code-server --version 2>/dev/null | head -1)"
}

# -------------------------------------------------------------------- zrok --
install_zrok() {
  if command -v zrok2 >/dev/null 2>&1; then
    ok "zrok2 $(zrok2 version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    return 0
  fi
  local arch tmp url bin
  arch="$(cs_arch)"
  tmp="$(mktemp -d)"
  log "installing zrok2 (${arch})"
  url="$(curl -fsSL --max-time 25 https://api.github.com/repos/openziti/zrok/releases/latest \
    | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
arch = sys.argv[1]
for a in d.get("assets", []):
    n = a.get("name", "")
    if n.startswith("zrok_") and "linux" in n and arch in n and n.endswith(".tar.gz"):
        print(a["browser_download_url"])
        break
' "$arch" 2>/dev/null || true)"
  [[ -n "$url" ]] || die "could not resolve the zrok2 release asset"
  curl -fsSL --retry 3 "$url" -o "${tmp}/zrok.tgz" || die "zrok2 download failed"
  tar -xzf "${tmp}/zrok.tgz" -C "$tmp"
  bin="$(find "$tmp" -maxdepth 2 -type f -name 'zrok2' | head -1)"
  [[ -n "$bin" ]] || die "zrok2 binary not found in the archive"
  cs_root install -m 0755 "$bin" "${CS_PREFIX}/bin/zrok2"
  rm -rf -- "$tmp"
  hash -r
  ok "zrok2 $(zrok2 version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
}

# ------------------------------------------------------------ cloudflared --
install_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    ok "cloudflared $(cloudflared --version 2>/dev/null | awk 'NR==1 { print $3 }')"
    return 0
  fi
  local arch
  arch="$(cs_arch)"
  log "installing cloudflared (${arch})"
  curl -fsSL --retry 3 \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" \
    -o /tmp/cloudflared.bin || die "cloudflared download failed"
  cs_root install -m 0755 /tmp/cloudflared.bin "${CS_PREFIX}/bin/cloudflared"
  rm -f -- /tmp/cloudflared.bin
  hash -r
  ok "cloudflared $(cloudflared --version 2>/dev/null | awk 'NR==1 { print $3 }')"
}

# ------------------------------------------------------------------- main --
main() {
  local sd version
  sd="$(cs_state_dir)"
  version="$(resolve_version)"
  log "target code-server version: ${version}"

  if [[ "$SKIP_APT" != "1" ]]; then
    if command -v code-server >/dev/null 2>&1 \
       && [[ "$(code-server --version 2>/dev/null | awk 'NR==1 { print $1 }')" == "$version" ]]; then
      ok "runtime libraries assumed present (code-server ${version} already installed)"
    else
      install_packages
    fi
  fi

  install_code_server "$version"
  install_zrok
  install_cloudflared

  printf '%s\n' "$version" >"${sd}/.installed-version"

  cat <<EOF

  install complete

  next     bash colab/serve.sh
  or       bash colab/supervise.sh      (restarts + idle/max-runtime watchdog)
  check    bash colab/doctor.sh

EOF
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

VERSION="${VERSION:-dev}"
TARGET="${TARGET:-linux-amd64}"
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
PKG_NAME="openspeak-server-${TARGET}-${VERSION}"
STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/openspeak-release.XXXXXX")"
PKG_DIR="${STAGE_ROOT}/${PKG_NAME}"
DIST_PKG_DIR="${DIST_DIR}/${PKG_NAME}"
TARBALL="${DIST_DIR}/${PKG_NAME}.tar.gz"
OPEN_SPEAK_BIN="${OPEN_SPEAK_BIN:-${ROOT_DIR}/openspeak-linux-amd64}"
OPEN_SPEAK_CTL_BIN="${OPEN_SPEAK_CTL_BIN:-${ROOT_DIR}/openspeakctl-linux-amd64}"
WEB_ROOT="${WEB_ROOT:-${ROOT_DIR}/clients/openspeak_flutter/build/web}"
LIVEKIT_BIN="${LIVEKIT_BIN:-}"
CADDY_BIN="${CADDY_BIN:-}"
WITHOUT_LIVEKIT="${WITHOUT_LIVEKIT:-0}"
OVERWRITE="${OVERWRITE:-1}"

cleanup() {
  rm -rf "${STAGE_ROOT}"
}
trap cleanup EXIT

usage() {
  cat <<'USAGE'
Build an OpenSpeak release tarball.

Environment:
  VERSION=0.1.0
  OPEN_SPEAK_BIN=/path/to/openspeak-linux-amd64
  OPEN_SPEAK_CTL_BIN=/path/to/openspeakctl-linux-amd64
  WEB_ROOT=/path/to/flutter/build/web
  LIVEKIT_BIN=/path/to/livekit-server
  CADDY_BIN=/path/to/caddy    Caddy 2.11.3 or newer.
  WITHOUT_LIVEKIT=1     Build package without LiveKit binary.
  OVERWRITE=0           Refuse to replace an existing package. Default: 1.

Examples:
  LIVEKIT_BIN=/usr/local/bin/livekit-server VERSION=0.1.0 ./deploy/package-release.sh
  WITHOUT_LIVEKIT=1 VERSION=0.1.0 ./deploy/package-release.sh
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ ! -f "${OPEN_SPEAK_BIN}" ]]; then
  echo "missing OpenSpeak binary: ${OPEN_SPEAK_BIN}" >&2
  exit 1
fi
if [[ ! -f "${OPEN_SPEAK_CTL_BIN}" ]]; then
  echo "missing OpenSpeak control binary: ${OPEN_SPEAK_CTL_BIN}" >&2
  exit 1
fi
if [[ ! -f "${WEB_ROOT}/index.html" ]]; then
  echo "missing Flutter Web build: ${WEB_ROOT}/index.html; run 'cd clients/openspeak_flutter && flutter build web --release' first" >&2
  exit 1
fi
if [[ ! -f "${WEB_ROOT}/e2ee.worker.dart.js" ]]; then
  echo "missing Flutter Web E2EE worker: ${WEB_ROOT}/e2ee.worker.dart.js; rebuild the Flutter Web client" >&2
  exit 1
fi

if [[ -z "${CADDY_BIN}" ]] && command -v caddy >/dev/null 2>&1; then
  CADDY_BIN="$(command -v caddy)"
fi
if [[ -z "${CADDY_BIN}" || ! -f "${CADDY_BIN}" ]]; then
  echo "missing Caddy. Set CADDY_BIN=/path/to/caddy (2.11.3 or newer)." >&2
  exit 1
fi

if [[ "${WITHOUT_LIVEKIT}" != "1" ]]; then
  if [[ -z "${LIVEKIT_BIN}" ]]; then
    if command -v livekit-server >/dev/null 2>&1; then
      LIVEKIT_BIN="$(command -v livekit-server)"
    fi
  fi
  if [[ -z "${LIVEKIT_BIN}" || ! -f "${LIVEKIT_BIN}" ]]; then
    echo "missing LiveKit binary. Set LIVEKIT_BIN=/path/to/livekit-server or WITHOUT_LIVEKIT=1" >&2
    exit 1
  fi
fi

if [[ -e "${DIST_PKG_DIR}" || -e "${TARBALL}" ]]; then
  if [[ "${OVERWRITE}" == "1" ]]; then
    rm -rf "${DIST_PKG_DIR}" "${TARBALL}"
  else
    echo "release output already exists for ${PKG_NAME}; set OVERWRITE=1, remove it manually, or use a new VERSION" >&2
    exit 1
  fi
fi
install -d "${DIST_DIR}"
install -d "${PKG_DIR}/bin" "${PKG_DIR}/deploy" "${PKG_DIR}/web"

install -m 0755 "${OPEN_SPEAK_BIN}" "${PKG_DIR}/bin/openspeak-linux-amd64"
install -m 0755 "${OPEN_SPEAK_CTL_BIN}" "${PKG_DIR}/bin/openspeakctl"
install -m 0755 "${CADDY_BIN}" "${PKG_DIR}/bin/caddy"
if [[ "${WITHOUT_LIVEKIT}" != "1" ]]; then
  install -m 0755 "${LIVEKIT_BIN}" "${PKG_DIR}/bin/livekit-server"
fi
cp -R "${WEB_ROOT}/." "${PKG_DIR}/web/"

install -m 0755 "${ROOT_DIR}/deploy/openspeak_startscript.sh" "${PKG_DIR}/openspeak_startscript.sh"
install -m 0755 "${ROOT_DIR}/deploy/install-linux.sh" "${PKG_DIR}/deploy/install-linux.sh"
install -m 0644 "${ROOT_DIR}/deploy/openspeak.service" "${PKG_DIR}/deploy/openspeak.service"
install -m 0644 "${ROOT_DIR}/deploy/livekit.service" "${PKG_DIR}/deploy/livekit.service"
install -m 0644 "${ROOT_DIR}/deploy/caddy.service" "${PKG_DIR}/deploy/caddy.service"
install -m 0644 "${ROOT_DIR}/deploy/openspeak.env.example" "${PKG_DIR}/deploy/openspeak.env.example"
install -m 0644 "${ROOT_DIR}/deploy/livekit.yaml.example" "${PKG_DIR}/deploy/livekit.yaml.example"

cat > "${PKG_DIR}/README.txt" <<'EOF'
OpenSpeak Server Release Package

Portable start, similar to TeamSpeak:
  tar -xzf openspeak-server-linux-amd64-dev.tar.gz
  cd openspeak-server-linux-amd64-dev
  chmod +x openspeak_startscript.sh
  ./openspeak_startscript.sh start

Portable status/stop:
  ./openspeak_startscript.sh status
  ./openspeak_startscript.sh stop

Install:
  sudo ./deploy/install-linux.sh

Install all-in-one with bundled LiveKit and public native-client media:
  sudo ./deploy/install-linux.sh --livekit-url ws://YOUR_SERVER_IP:27420 --livekit-node-ip YOUR_SERVER_IP

Install without bundled LiveKit:
  sudo ./deploy/install-linux.sh --without-livekit

After install:
  curl http://127.0.0.1:27410/api/health
  systemctl status openspeak --no-pager -l
  systemctl status openspeak-livekit --no-pager -l
  systemctl status openspeak-caddy --no-pager -l

Owner emergency recovery:
  sudo openspeakctl owner recover

Notes:
  - Web access is disabled by default. Enable it under Server Settings > Web Settings.
  - Portable start keeps config, data, logs, and pid files inside this directory:
      config/
      data/
      logs/
      run/
  - The package installs OpenSpeak as systemd service: openspeak.service.
  - If livekit-server is bundled, it also installs: openspeak-livekit.service.
  - The installer generates LiveKit API credentials and writes them to:
      /etc/openspeak/livekit.yaml
      /etc/openspeak/openspeak.env
  - Default ports are:
      OpenSpeak API/WebSocket: TCP 27410
      OpenSpeak HTTPS/WSS/web: TCP 27412
      LiveKit signal upstream: TCP 27420 (do not expose publicly)
      LiveKit TCP fallback: TCP 27421
      LiveKit WebRTC media: UDP 27422
      Certificate renewal: TCP 80
      TCP 443 remains available for another website.
  - For browser voice/screen sharing, configure a public HTTPS/WSS domain for LiveKit.
  - If clients connect from outside the server, set rtc.node_ip in livekit.yaml
    or install with --livekit-node-ip YOUR_SERVER_IP so ICE candidates are reachable.
EOF

chmod -R u+rwX,go+rX "${PKG_DIR}"

(
  cd "${STAGE_ROOT}"
  COPYFILE_DISABLE=1 tar --format ustar -czf "${TARBALL}" "${PKG_NAME}"
)

cp -R "${PKG_DIR}" "${DIST_PKG_DIR}"

echo "${TARBALL}"

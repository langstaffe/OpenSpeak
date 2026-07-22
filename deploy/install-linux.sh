#!/usr/bin/env bash
set -euo pipefail

PREFIX="/opt/openspeak"
CONFIG_DIR="/etc/openspeak"
DATA_DIR="/var/lib/openspeak"
LOG_DIR="/var/log/openspeak"
WITH_LIVEKIT=1
LIVEKIT_URL=""
LIVEKIT_USE_EXTERNAL_IP=0
LIVEKIT_NODE_IP=""
OPENSPEAK_PORT=27410
OPENSPEAK_BACKEND_PORT=27411
OPENSPEAK_TLS_PORT=27412
LIVEKIT_SIGNAL_PORT=27420
LIVEKIT_RTC_TCP_PORT=27421
LIVEKIT_RTC_PORT_START=27422
LIVEKIT_RTC_PORT_END=27422
NEW_DATABASE=0

usage() {
  cat <<'USAGE'
OpenSpeak Linux installer

Usage:
  sudo ./install-linux.sh [options]

Options:
  --prefix PATH          Install directory. Default: /opt/openspeak
  --livekit-url URL      LiveKit URL written to openspeak.env fallback.
                         Example: ws://YOUR_SERVER_IP:27420
  --livekit-node-ip IP   Explicit public IP advertised in LiveKit ICE candidates.
                         Recommended for cloud servers behind NAT.
  --livekit-use-external-ip
                         Ask LiveKit to auto-discover a public IP.
                         Not recommended with LiveKit versions where this panics.
  --livekit-rtc-tcp-port PORT
                         LiveKit RTC TCP port. Default: 27421
  --livekit-rtc-port-range START:END
                         LiveKit UDP RTC ports. Equal values use UDP mux.
                         Default: 27422:27422
  --without-livekit      Install only OpenSpeak. Voice/screen relay needs a media node later.
  -h, --help             Show this help.

This installer is designed for release tarballs that contain:
  bin/openspeak-linux-amd64
  bin/openspeakctl
  bin/livekit-server              when installing with LiveKit
  deploy/*.service
  deploy/*.example
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      PREFIX="${2:?missing value for --prefix}"
      shift 2
      ;;
    --livekit-url)
      LIVEKIT_URL="${2:?missing value for --livekit-url}"
      shift 2
      ;;
    --livekit-node-ip)
      LIVEKIT_NODE_IP="${2:?missing value for --livekit-node-ip}"
      shift 2
      ;;
    --livekit-use-external-ip)
      LIVEKIT_USE_EXTERNAL_IP=1
      shift
      ;;
    --livekit-rtc-tcp-port)
      LIVEKIT_RTC_TCP_PORT="${2:?missing value for --livekit-rtc-tcp-port}"
      shift 2
      ;;
    --livekit-rtc-port-range)
      IFS=: read -r LIVEKIT_RTC_PORT_START LIVEKIT_RTC_PORT_END <<< "${2:?missing value for --livekit-rtc-port-range}"
      if [[ -z "${LIVEKIT_RTC_PORT_START}" || -z "${LIVEKIT_RTC_PORT_END}" ]]; then
        echo "--livekit-rtc-port-range must look like START:END" >&2
        exit 2
      fi
      shift 2
      ;;
    --without-livekit)
      WITH_LIVEKIT=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${LIVEKIT_RTC_PORT_START}" == "${LIVEKIT_RTC_PORT_END}" ]]; then
  LIVEKIT_RTC_PORT_CONFIG="  udp_port: ${LIVEKIT_RTC_PORT_START}"
  LIVEKIT_RTC_PORT_DISPLAY="${LIVEKIT_RTC_PORT_START} (UDP mux)"
else
  LIVEKIT_RTC_PORT_CONFIG="$(printf '  port_range_start: %s\n  port_range_end: %s' "${LIVEKIT_RTC_PORT_START}" "${LIVEKIT_RTC_PORT_END}")"
  LIVEKIT_RTC_PORT_DISPLAY="${LIVEKIT_RTC_PORT_START}-${LIVEKIT_RTC_PORT_END}"
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "please run as root, for example: sudo ./install-linux.sh" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

OPEN_SPEAK_BIN="${PACKAGE_DIR}/bin/openspeak-linux-amd64"
OPEN_SPEAK_CTL_BIN="${PACKAGE_DIR}/bin/openspeakctl"
LIVEKIT_BIN="${PACKAGE_DIR}/bin/livekit-server"
CADDY_BIN="${PACKAGE_DIR}/bin/caddy"
WEB_ROOT="${PACKAGE_DIR}/web"

if [[ ! -f "${OPEN_SPEAK_BIN}" ]]; then
  echo "missing ${OPEN_SPEAK_BIN}" >&2
  exit 1
fi
if [[ ! -f "${OPEN_SPEAK_CTL_BIN}" ]]; then
  echo "missing ${OPEN_SPEAK_CTL_BIN}" >&2
  exit 1
fi
if [[ ! -f "${CADDY_BIN}" ]]; then
  echo "missing ${CADDY_BIN}" >&2
  exit 1
fi
if [[ ! -f "${WEB_ROOT}/index.html" ]]; then
  echo "missing ${WEB_ROOT}/index.html" >&2
  exit 1
fi
CADDY_VERSION="$("${CADDY_BIN}" version)"
if [[ ! "${CADDY_VERSION}" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+) ]] ||
   (( BASH_REMATCH[1] < 2 || (BASH_REMATCH[1] == 2 && BASH_REMATCH[2] < 11) || (BASH_REMATCH[1] == 2 && BASH_REMATCH[2] == 11 && BASH_REMATCH[3] < 3) )); then
  echo "OpenSpeak requires Caddy 2.11.3 or newer for public IP certificate support" >&2
  exit 1
fi

if [[ "${WITH_LIVEKIT}" -eq 1 && ! -f "${LIVEKIT_BIN}" ]]; then
  echo "missing ${LIVEKIT_BIN}; rebuild the release package with LIVEKIT_BIN=/path/to/livekit-server or use --without-livekit" >&2
  exit 1
fi

rand_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "${1}"
    return
  fi
  od -An -N "${1}" -tx1 /dev/urandom | tr -d ' \n'
}

JWT_SECRET="$(rand_hex 32)"
LIVEKIT_API_KEY="os_$(rand_hex 6)"
LIVEKIT_API_SECRET="$(rand_hex 32)"
if [[ "${LIVEKIT_USE_EXTERNAL_IP}" -eq 1 ]]; then
  LIVEKIT_USE_EXTERNAL_IP_VALUE="true"
else
  LIVEKIT_USE_EXTERNAL_IP_VALUE="false"
fi
LIVEKIT_NODE_IP_CONFIG=""
if [[ -n "${LIVEKIT_NODE_IP}" ]]; then
  LIVEKIT_NODE_IP_CONFIG="  node_ip: ${LIVEKIT_NODE_IP}"
fi

if [[ -z "${LIVEKIT_URL}" && "${WITH_LIVEKIT}" -eq 1 ]]; then
  LIVEKIT_URL="ws://127.0.0.1:${LIVEKIT_SIGNAL_PORT}"
fi

if ! id openspeak >/dev/null 2>&1; then
  useradd --system --home "${DATA_DIR}" --shell /usr/sbin/nologin openspeak
fi

install -d -m 0755 "${PREFIX}"
install -d -m 0750 -o openspeak -g openspeak "${DATA_DIR}" "${DATA_DIR}/files" "${DATA_DIR}/tmp/direct_files" "${DATA_DIR}/caddy" "${LOG_DIR}"
install -d -m 0750 "${CONFIG_DIR}"

install -m 0755 "${OPEN_SPEAK_BIN}" "${PREFIX}/openspeak-linux-amd64"
install -m 0755 "${OPEN_SPEAK_CTL_BIN}" "${PREFIX}/openspeakctl"
install -m 0755 "${CADDY_BIN}" "${PREFIX}/caddy"
install -d -m 0755 "${PREFIX}/web"
cp -R "${WEB_ROOT}/." "${PREFIX}/web/"
ln -sf "${PREFIX}/openspeakctl" /usr/local/bin/openspeakctl
if [[ "${WITH_LIVEKIT}" -eq 1 ]]; then
  install -m 0755 "${LIVEKIT_BIN}" "${PREFIX}/livekit-server"
fi

if [[ -f "${CONFIG_DIR}/openspeak.env" ]]; then
  echo "keeping existing ${CONFIG_DIR}/openspeak.env"
else
  cat > "${CONFIG_DIR}/openspeak.env" <<EOF
OS_ADDR=127.0.0.1:${OPENSPEAK_BACKEND_PORT}
OS_DATABASE_PATH=${DATA_DIR}/openspeak.db
OS_FILE_ROOT=${DATA_DIR}/files
OS_DIRECT_FILE_ROOT=${DATA_DIR}/tmp/direct_files
OS_WEB_ROOT=${PREFIX}/web
OS_LOG_FILE=${LOG_DIR}/openspeak.log
OS_LOG_LEVEL=info
OS_JWT_SECRET=${JWT_SECRET}
OS_JWT_TTL_SECONDS=86400
OS_DEFAULT_ENCRYPTION_MODE=none
OS_CADDY_ADMIN_URL=unix://${DATA_DIR}/caddy/admin.sock
OS_CADDY_CONFIG_PATH=${DATA_DIR}/caddy/Caddyfile
OS_TLS_VERIFY_ADDR=127.0.0.1:${OPENSPEAK_TLS_PORT}
OS_TLS_BACKEND_UPSTREAM=127.0.0.1:${OPENSPEAK_BACKEND_PORT}
OS_TLS_LIVEKIT_UPSTREAM=127.0.0.1:${LIVEKIT_SIGNAL_PORT}
OS_PLAIN_PUBLIC_PORT=${OPENSPEAK_PORT}
OS_TLS_PUBLIC_PORT=${OPENSPEAK_TLS_PORT}
OS_DEFAULT_HISTORY_RETENTION_DAYS=30
OS_LIVEKIT_URL=${LIVEKIT_URL}
OS_LIVEKIT_API_KEY=${LIVEKIT_API_KEY}
OS_LIVEKIT_API_SECRET=${LIVEKIT_API_SECRET}
OS_LIVEKIT_TOKEN_TTL_SECONDS=3600
EOF
  chmod 0640 "${CONFIG_DIR}/openspeak.env"
  chown root:openspeak "${CONFIG_DIR}/openspeak.env"
fi

CONFIGURED_ADDR="$(sed -n 's/^OS_ADDR=//p' "${CONFIG_DIR}/openspeak.env" | tail -n 1)"
CONFIGURED_BACKEND_PORT="${CONFIGURED_ADDR##*:}"
if [[ ! "${CONFIGURED_BACKEND_PORT}" =~ ^[0-9]+$ ]]; then
  CONFIGURED_BACKEND_PORT="${OPENSPEAK_BACKEND_PORT}"
fi
append_env_if_missing() {
  grep -q "^${1}=" "${CONFIG_DIR}/openspeak.env" || printf '%s=%s\n' "$1" "$2" >> "${CONFIG_DIR}/openspeak.env"
}
append_env_if_missing OS_CADDY_ADMIN_URL "unix://${DATA_DIR}/caddy/admin.sock"
append_env_if_missing OS_CADDY_CONFIG_PATH "${DATA_DIR}/caddy/Caddyfile"
if grep -qx 'OS_TLS_VERIFY_ADDR=127.0.0.1:443' "${CONFIG_DIR}/openspeak.env"; then
  sed -i "s/^OS_TLS_VERIFY_ADDR=127\.0\.0\.1:443$/OS_TLS_VERIFY_ADDR=127.0.0.1:${OPENSPEAK_TLS_PORT}/" "${CONFIG_DIR}/openspeak.env"
fi
append_env_if_missing OS_TLS_VERIFY_ADDR "127.0.0.1:${OPENSPEAK_TLS_PORT}"
append_env_if_missing OS_TLS_BACKEND_UPSTREAM "127.0.0.1:${CONFIGURED_BACKEND_PORT}"
append_env_if_missing OS_PLAIN_PUBLIC_PORT "${OPENSPEAK_PORT}"
append_env_if_missing OS_TLS_PUBLIC_PORT "${OPENSPEAK_TLS_PORT}"
append_env_if_missing OS_TLS_LIVEKIT_UPSTREAM "127.0.0.1:${LIVEKIT_SIGNAL_PORT}"
append_env_if_missing OS_WEB_ROOT "${PREFIX}/web"

CONFIGURED_CADDY_ADMIN_URL="$(sed -n 's/^OS_CADDY_ADMIN_URL=//p' "${CONFIG_DIR}/openspeak.env" | tail -n 1)"
CADDY_ADMIN_PRESTART=""
if [[ "${CONFIGURED_CADDY_ADMIN_URL}" == unix://* ]]; then
  CADDY_ADMIN_ADDR="unix/${CONFIGURED_CADDY_ADMIN_URL#unix://}"
  CADDY_ADMIN_PRESTART="ExecStartPre=/usr/bin/rm -f ${CONFIGURED_CADDY_ADMIN_URL#unix://}"
else
  CADDY_ADMIN_ADDR="${CONFIGURED_CADDY_ADMIN_URL#http://}"
fi

if [[ ! -f "${DATA_DIR}/caddy/Caddyfile" ]]; then
  if [[ "${CONFIGURED_BACKEND_PORT}" == "${OPENSPEAK_PORT}" ]]; then
    cat > "${DATA_DIR}/caddy/Caddyfile" <<EOF
http://127.0.0.1:27419 {
  respond "OpenSpeak TLS gateway is ready"
}
EOF
  else
    cat > "${DATA_DIR}/caddy/Caddyfile" <<EOF
http://:${OPENSPEAK_PORT} {
  reverse_proxy 127.0.0.1:${CONFIGURED_BACKEND_PORT}
}
EOF
  fi
  chown openspeak:openspeak "${DATA_DIR}/caddy/Caddyfile"
  chmod 0640 "${DATA_DIR}/caddy/Caddyfile"
fi

if [[ ! -e "${DATA_DIR}/openspeak.db" ]]; then
  NEW_DATABASE=1
fi

if [[ "${WITH_LIVEKIT}" -eq 1 ]]; then
  if [[ -f "${CONFIG_DIR}/livekit.yaml" ]]; then
    echo "keeping existing ${CONFIG_DIR}/livekit.yaml"
  else
    cat > "${CONFIG_DIR}/livekit.yaml" <<EOF
port: ${LIVEKIT_SIGNAL_PORT}
bind_addresses:
  - "0.0.0.0"

rtc:
  tcp_port: ${LIVEKIT_RTC_TCP_PORT}
${LIVEKIT_RTC_PORT_CONFIG}
  use_external_ip: ${LIVEKIT_USE_EXTERNAL_IP_VALUE}
${LIVEKIT_NODE_IP_CONFIG}

keys:
  ${LIVEKIT_API_KEY}: ${LIVEKIT_API_SECRET}
EOF
    chmod 0640 "${CONFIG_DIR}/livekit.yaml"
    chown root:openspeak "${CONFIG_DIR}/livekit.yaml"
  fi
fi

cat > /etc/systemd/system/openspeak.service <<EOF
[Unit]
Description=OpenSpeak Server
After=network-online.target openspeak-caddy.service
Wants=network-online.target
Requires=openspeak-caddy.service

[Service]
Type=simple
User=openspeak
Group=openspeak
EnvironmentFile=${CONFIG_DIR}/openspeak.env
ExecStart=${PREFIX}/openspeak-linux-amd64
Restart=on-failure
RestartSec=3
WorkingDirectory=${PREFIX}

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${DATA_DIR} ${LOG_DIR}

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/openspeak-caddy.service <<EOF
[Unit]
Description=OpenSpeak TLS Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=openspeak
Group=openspeak
Environment=HOME=${DATA_DIR}
Environment=CADDY_ADMIN=${CADDY_ADMIN_ADDR}
${CADDY_ADMIN_PRESTART}
ExecStart=${PREFIX}/caddy run --config ${DATA_DIR}/caddy/Caddyfile --adapter caddyfile
ExecReload=${PREFIX}/caddy reload --config ${DATA_DIR}/caddy/Caddyfile --adapter caddyfile
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${DATA_DIR} ${LOG_DIR}

[Install]
WantedBy=multi-user.target
EOF

if [[ "${WITH_LIVEKIT}" -eq 1 ]]; then
  cat > /etc/systemd/system/openspeak-livekit.service <<EOF
[Unit]
Description=OpenSpeak LiveKit Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=openspeak
Group=openspeak
ExecStart=${PREFIX}/livekit-server --config ${CONFIG_DIR}/livekit.yaml
Restart=on-failure
RestartSec=3
WorkingDirectory=${PREFIX}

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${LOG_DIR}

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
systemctl enable openspeak-caddy >/dev/null
systemctl restart openspeak-caddy
systemctl enable openspeak >/dev/null
if [[ "${NEW_DATABASE}" -eq 1 ]]; then
  echo
  echo "Initializing OpenSpeak owner identity..."
  runuser -u openspeak -- "${PREFIX}/openspeakctl" owner bootstrap
  echo
fi
if [[ "${WITH_LIVEKIT}" -eq 1 ]]; then
  systemctl enable openspeak-livekit >/dev/null
  systemctl restart openspeak-livekit
fi
systemctl restart openspeak

cat <<EOF
OpenSpeak installed.

OpenSpeak health:
  curl http://127.0.0.1:${CONFIGURED_BACKEND_PORT}/api/health

Connect from the desktop client with a local nickname and this server's
optional server password. Owner identity setup uses the one-time claim key
printed during `openspeakctl owner bootstrap`.

LiveKit fallback URL written to:
  ${CONFIG_DIR}/openspeak.env
EOF

cat <<EOF
Caddy TLS gateway:
  systemctl status openspeak-caddy --no-pager -l
  Open TCP 80, ${OPENSPEAK_PORT}, and ${OPENSPEAK_TLS_PORT} before enabling transport encryption.
EOF

if [[ "${WITH_LIVEKIT}" -eq 1 ]]; then
  cat <<EOF
LiveKit systemd service:
  systemctl status openspeak-livekit --no-pager -l

LiveKit ports to open for external clients:
  TCP ${OPENSPEAK_TLS_PORT} (HTTPS/WSS signal gateway)
  TCP ${LIVEKIT_RTC_TCP_PORT}
  UDP ${LIVEKIT_RTC_PORT_DISPLAY}

For browser clients, replace ws://127.0.0.1:${LIVEKIT_SIGNAL_PORT} with a public wss:// domain.
EOF
else
  cat <<'EOF'
LiveKit was not installed by this run. Add a media node later from the
OpenSpeak API/client when you deploy LiveKit on this or another server.
EOF
fi

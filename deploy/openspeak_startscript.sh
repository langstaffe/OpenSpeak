#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${BASE_DIR}/bin"
CONFIG_DIR="${OS_CONFIG_DIR:-${BASE_DIR}/config}"
DATA_DIR="${OS_DATA_DIR:-${BASE_DIR}/data}"
LOG_DIR="${OS_LOG_DIR:-${BASE_DIR}/logs}"
RUN_DIR="${OS_RUN_DIR:-${BASE_DIR}/run}"
OPENSPEAK_PORT="${OS_PORT:-27410}"
OPENSPEAK_BACKEND_PORT="${OS_BACKEND_PORT:-27411}"
OPENSPEAK_TLS_PORT="${OS_TLS_PORT:-27412}"
LIVEKIT_SIGNAL_PORT="${OS_LIVEKIT_SIGNAL_PORT:-27420}"
LIVEKIT_RTC_TCP_PORT="${OS_LIVEKIT_RTC_TCP_PORT:-27421}"
LIVEKIT_RTC_PORT_START="${OS_LIVEKIT_RTC_PORT_START:-27422}"
LIVEKIT_RTC_PORT_END="${OS_LIVEKIT_RTC_PORT_END:-27422}"
LIVEKIT_NODE_IP="${OS_LIVEKIT_NODE_IP:-}"

if [[ "${LIVEKIT_RTC_PORT_START}" == "${LIVEKIT_RTC_PORT_END}" ]]; then
  LIVEKIT_RTC_PORT_CONFIG="  udp_port: ${LIVEKIT_RTC_PORT_START}"
else
  LIVEKIT_RTC_PORT_CONFIG="$(printf '  port_range_start: %s\n  port_range_end: %s' "${LIVEKIT_RTC_PORT_START}" "${LIVEKIT_RTC_PORT_END}")"
fi

OPENSPEAK_BIN="${BIN_DIR}/openspeak-linux-amd64"
OPENSPEAK_CTL_BIN="${BIN_DIR}/openspeakctl"
LIVEKIT_BIN="${BIN_DIR}/livekit-server"
CADDY_BIN="${BIN_DIR}/caddy"
OPENSPEAK_ENV="${CONFIG_DIR}/openspeak.env"
LIVEKIT_CONFIG="${CONFIG_DIR}/livekit.yaml"
OPENSPEAK_PID="${RUN_DIR}/openspeak.pid"
LIVEKIT_PID="${RUN_DIR}/livekit.pid"
CADDY_PID="${RUN_DIR}/caddy.pid"
CADDY_CONFIG="${DATA_DIR}/caddy/Caddyfile"
CADDY_ADMIN_SOCKET="${DATA_DIR}/caddy/admin.sock"

usage() {
  cat <<'USAGE'
OpenSpeak start script

Usage:
  ./openspeak_startscript.sh start
  ./openspeak_startscript.sh stop
  ./openspeak_startscript.sh restart
  ./openspeak_startscript.sh status
  ./openspeak_startscript.sh run

This script is for a TeamSpeak-style portable install. It stores config,
database, uploaded files, logs, and pid files inside the extracted directory.
For systemd installation, use: sudo ./deploy/install-linux.sh
USAGE
}

rand_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "${1}"
    return
  fi
  od -An -N "${1}" -tx1 /dev/urandom | tr -d ' \n'
}

ensure_layout() {
  if [[ ! -x "${OPENSPEAK_BIN}" ]]; then
    echo "missing or non-executable ${OPENSPEAK_BIN}" >&2
    exit 1
  fi
  if [[ ! -x "${OPENSPEAK_CTL_BIN}" ]]; then
    echo "missing or non-executable ${OPENSPEAK_CTL_BIN}" >&2
    exit 1
  fi
  if [[ ! -x "${CADDY_BIN}" ]]; then
    echo "missing or non-executable ${CADDY_BIN}" >&2
    exit 1
  fi
  local caddy_version
  caddy_version="$("${CADDY_BIN}" version)"
  if [[ ! "${caddy_version}" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+) ]] ||
     (( BASH_REMATCH[1] < 2 || (BASH_REMATCH[1] == 2 && BASH_REMATCH[2] < 11) || (BASH_REMATCH[1] == 2 && BASH_REMATCH[2] == 11 && BASH_REMATCH[3] < 3) )); then
    echo "OpenSpeak requires Caddy 2.11.3 or newer for public IP certificate support" >&2
    exit 1
  fi
  mkdir -p "${CONFIG_DIR}" "${DATA_DIR}/files" "${DATA_DIR}/caddy" "${LOG_DIR}" "${RUN_DIR}"
}

ensure_openspeak_env() {
  if [[ -f "${OPENSPEAK_ENV}" ]]; then
    return
  fi

  local jwt_secret livekit_key livekit_secret livekit_url
  jwt_secret="$(rand_hex 32)"
  livekit_key="os_$(rand_hex 6)"
  livekit_secret="$(rand_hex 32)"
  livekit_url="${OS_LIVEKIT_URL:-ws://127.0.0.1:${LIVEKIT_SIGNAL_PORT}}"

  local livekit_node_ip_config=""
  if [[ -n "${LIVEKIT_NODE_IP}" ]]; then
    livekit_node_ip_config="  node_ip: ${LIVEKIT_NODE_IP}"
  fi

  cat > "${OPENSPEAK_ENV}" <<EOF
OS_ADDR=127.0.0.1:${OPENSPEAK_BACKEND_PORT}
OS_DATABASE_PATH=${DATA_DIR}/openspeak.db
OS_FILE_ROOT=${DATA_DIR}/files
OS_DIRECT_FILE_ROOT=${DATA_DIR}/tmp/direct_files
OS_LOG_FILE=${LOG_DIR}/openspeak.log
OS_LOG_LEVEL=info
OS_JWT_SECRET=${jwt_secret}
OS_JWT_TTL_SECONDS=86400
OS_DEFAULT_ENCRYPTION_MODE=none
OS_DEFAULT_HISTORY_RETENTION_DAYS=30
OS_CADDY_ADMIN_URL=unix://${CADDY_ADMIN_SOCKET}
OS_CADDY_CONFIG_PATH=${CADDY_CONFIG}
OS_TLS_VERIFY_ADDR=127.0.0.1:${OPENSPEAK_TLS_PORT}
OS_TLS_BACKEND_UPSTREAM=127.0.0.1:${OPENSPEAK_BACKEND_PORT}
OS_TLS_LIVEKIT_UPSTREAM=127.0.0.1:${LIVEKIT_SIGNAL_PORT}
OS_PLAIN_PUBLIC_PORT=${OPENSPEAK_PORT}
OS_TLS_PUBLIC_PORT=${OPENSPEAK_TLS_PORT}
OS_LIVEKIT_URL=${livekit_url}
OS_LIVEKIT_API_KEY=${livekit_key}
OS_LIVEKIT_API_SECRET=${livekit_secret}
OS_LIVEKIT_TOKEN_TTL_SECONDS=3600
EOF
  chmod 0600 "${OPENSPEAK_ENV}"

  if [[ -x "${LIVEKIT_BIN}" && ! -f "${LIVEKIT_CONFIG}" ]]; then
    cat > "${LIVEKIT_CONFIG}" <<EOF
port: ${LIVEKIT_SIGNAL_PORT}
bind_addresses:
  - "0.0.0.0"

rtc:
  tcp_port: ${LIVEKIT_RTC_TCP_PORT}
${LIVEKIT_RTC_PORT_CONFIG}
  use_external_ip: false
${livekit_node_ip_config}

keys:
  ${livekit_key}: ${livekit_secret}
EOF
    chmod 0600 "${LIVEKIT_CONFIG}"
  fi
}

append_env_if_missing() {
  grep -q "^${1}=" "${OPENSPEAK_ENV}" || printf '%s=%s\n' "$1" "$2" >> "${OPENSPEAK_ENV}"
}

ensure_tls_config() {
  local configured_addr configured_backend_port
  configured_addr="$(sed -n 's/^OS_ADDR=//p' "${OPENSPEAK_ENV}" | tail -n 1)"
  configured_backend_port="${configured_addr##*:}"
  if [[ ! "${configured_backend_port}" =~ ^[0-9]+$ ]]; then
    configured_backend_port="${OPENSPEAK_BACKEND_PORT}"
  fi
  append_env_if_missing OS_CADDY_ADMIN_URL "unix://${CADDY_ADMIN_SOCKET}"
  append_env_if_missing OS_CADDY_CONFIG_PATH "${CADDY_CONFIG}"
  if grep -qx 'OS_TLS_VERIFY_ADDR=127.0.0.1:443' "${OPENSPEAK_ENV}"; then
    sed -i.bak "s/^OS_TLS_VERIFY_ADDR=127\.0\.0\.1:443$/OS_TLS_VERIFY_ADDR=127.0.0.1:${OPENSPEAK_TLS_PORT}/" "${OPENSPEAK_ENV}"
    rm -f "${OPENSPEAK_ENV}.bak"
  fi
  append_env_if_missing OS_TLS_VERIFY_ADDR "127.0.0.1:${OPENSPEAK_TLS_PORT}"
  append_env_if_missing OS_TLS_BACKEND_UPSTREAM "127.0.0.1:${configured_backend_port}"
  append_env_if_missing OS_TLS_LIVEKIT_UPSTREAM "127.0.0.1:${LIVEKIT_SIGNAL_PORT}"
  append_env_if_missing OS_PLAIN_PUBLIC_PORT "${OPENSPEAK_PORT}"
  append_env_if_missing OS_TLS_PUBLIC_PORT "${OPENSPEAK_TLS_PORT}"
  if [[ ! -f "${CADDY_CONFIG}" ]]; then
    if [[ "${configured_backend_port}" == "${OPENSPEAK_PORT}" ]]; then
      cat > "${CADDY_CONFIG}" <<EOF
http://127.0.0.1:27419 {
  respond "OpenSpeak TLS gateway is ready"
}
EOF
    else
      cat > "${CADDY_CONFIG}" <<EOF
http://:${OPENSPEAK_PORT} {
  reverse_proxy 127.0.0.1:${configured_backend_port}
}
EOF
    fi
  fi
}

load_env() {
  set -a
  # shellcheck disable=SC1090
  source "${OPENSPEAK_ENV}"
  set +a
}

ensure_owner_bootstrap() {
  if [[ -e "${DATA_DIR}/openspeak.db" ]]; then
    return
  fi
  load_env
  echo "Initializing OpenSpeak owner identity..."
  "${OPENSPEAK_CTL_BIN}" owner bootstrap
}

pid_running() {
  local pid_file="$1"
  [[ -f "${pid_file}" ]] || return 1
  local pid
  pid="$(cat "${pid_file}")"
  [[ -n "${pid}" ]] || return 1
  kill -0 "${pid}" >/dev/null 2>&1
}

start_livekit() {
  if [[ ! -x "${LIVEKIT_BIN}" ]]; then
    return
  fi
  if pid_running "${LIVEKIT_PID}"; then
    echo "LiveKit already running, pid $(cat "${LIVEKIT_PID}")"
    return
  fi
  if [[ ! -f "${LIVEKIT_CONFIG}" ]]; then
    echo "missing ${LIVEKIT_CONFIG}" >&2
    exit 1
  fi
  nohup "${LIVEKIT_BIN}" --config "${LIVEKIT_CONFIG}" >> "${LOG_DIR}/livekit.stdout.log" 2>&1 &
  echo "$!" > "${LIVEKIT_PID}"
  echo "LiveKit started, pid $(cat "${LIVEKIT_PID}")"
}

start_openspeak() {
  if pid_running "${OPENSPEAK_PID}"; then
    echo "OpenSpeak already running, pid $(cat "${OPENSPEAK_PID}")"
    return
  fi
  load_env
  nohup "${OPENSPEAK_BIN}" >> "${LOG_DIR}/openspeak.stdout.log" 2>&1 &
  echo "$!" > "${OPENSPEAK_PID}"
  echo "OpenSpeak started, pid $(cat "${OPENSPEAK_PID}")"
}

warn_tls_binding_permissions() {
  if [[ "$(id -u)" == "0" ]]; then
    return
  fi
  local unprivileged_start=1024
  if command -v sysctl >/dev/null 2>&1; then
    unprivileged_start="$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || echo 1024)"
  fi
  if [[ "${unprivileged_start}" =~ ^[0-9]+$ ]] && (( unprivileged_start <= 80 )); then
    return
  fi
  if command -v getcap >/dev/null 2>&1 && getcap "${CADDY_BIN}" 2>/dev/null | grep -q 'cap_net_bind_service'; then
    return
  fi
  echo "warning: Caddy may not be able to bind port 80 for certificate renewal as this user." >&2
  echo "Use the systemd installer, run as root, or grant: sudo setcap cap_net_bind_service=+ep ${CADDY_BIN}" >&2
}

start_caddy() {
  if [[ ! -x "${CADDY_BIN}" ]]; then
    echo "missing ${CADDY_BIN}; TLS configuration is unavailable" >&2
    exit 1
  fi
  if pid_running "${CADDY_PID}"; then
    echo "Caddy already running, pid $(cat "${CADDY_PID}")"
    return
  fi
  warn_tls_binding_permissions
  local caddy_admin
  caddy_admin="$(sed -n 's/^OS_CADDY_ADMIN_URL=//p' "${OPENSPEAK_ENV}" | tail -n 1)"
  caddy_admin="${caddy_admin:-unix://${CADDY_ADMIN_SOCKET}}"
  if [[ "${caddy_admin}" == unix://* ]]; then
    caddy_admin="unix/${caddy_admin#unix://}"
    rm -f "${caddy_admin#unix/}"
  else
    caddy_admin="${caddy_admin#http://}"
  fi
  HOME="${DATA_DIR}" CADDY_ADMIN="${caddy_admin}" nohup "${CADDY_BIN}" run --config "${CADDY_CONFIG}" --adapter caddyfile >> "${LOG_DIR}/caddy.stdout.log" 2>&1 &
  echo "$!" > "${CADDY_PID}"
  echo "Caddy started, pid $(cat "${CADDY_PID}")"
}

start_all() {
  ensure_layout
  ensure_openspeak_env
  ensure_tls_config
  ensure_owner_bootstrap
  start_caddy
  start_livekit
  start_openspeak
  echo "Health check before TLS: curl http://127.0.0.1:${OPENSPEAK_PORT}/api/health"
}

stop_pid() {
  local name="$1"
  local pid_file="$2"
  if ! pid_running "${pid_file}"; then
    echo "${name} is not running"
    rm -f "${pid_file}"
    return
  fi
  local pid
  pid="$(cat "${pid_file}")"
  kill "${pid}" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    if ! kill -0 "${pid}" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  if kill -0 "${pid}" >/dev/null 2>&1; then
    echo "${name} did not stop gracefully; sending SIGKILL"
    kill -9 "${pid}" >/dev/null 2>&1 || true
  fi
  rm -f "${pid_file}"
  echo "${name} stopped"
}

stop_all() {
  stop_pid "OpenSpeak" "${OPENSPEAK_PID}"
  stop_pid "LiveKit" "${LIVEKIT_PID}"
  stop_pid "Caddy" "${CADDY_PID}"
}

status_one() {
  local name="$1"
  local pid_file="$2"
  if pid_running "${pid_file}"; then
    echo "${name}: running, pid $(cat "${pid_file}")"
  else
    echo "${name}: stopped"
  fi
}

status_all() {
  status_one "OpenSpeak" "${OPENSPEAK_PID}"
  status_one "Caddy" "${CADDY_PID}"
  if [[ -x "${LIVEKIT_BIN}" ]]; then
    status_one "LiveKit" "${LIVEKIT_PID}"
  else
    echo "LiveKit: not bundled"
  fi
}

run_foreground() {
  ensure_layout
  ensure_openspeak_env
  ensure_tls_config
  ensure_owner_bootstrap
  start_caddy
  start_livekit
  load_env
  exec "${OPENSPEAK_BIN}"
}

case "${1:-}" in
  start)
    start_all
    ;;
  stop)
    stop_all
    ;;
  restart)
    stop_all
    start_all
    ;;
  status)
    status_all
    ;;
  run)
    run_foreground
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

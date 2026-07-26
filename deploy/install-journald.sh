#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "please run as root, for example: sudo ./install-journald.sh" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/openspeak-journald.conf"

install -d -m 0755 /etc/systemd/journald.conf.d
install -m 0644 "${CONFIG}" /etc/systemd/journald.conf.d/60-openspeak.conf
systemctl restart systemd-journald

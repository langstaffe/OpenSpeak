#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WEB_ROOT="${WEB_ROOT:-${ROOT_DIR}/clients/openspeak_flutter/build/web}"
COSCLI="${COSCLI:-coscli}"
COS_ALIAS="${COS_ALIAS:-openspeak-static}"
VERSION_FILE="${WEB_ROOT}/asset-version.txt"
STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/openspeak-cos-assets.XXXXXX")"
GZIP_ROOT="${STAGE_ROOT}/gzip"
RAW_ROOT="${STAGE_ROOT}/raw"

cleanup() {
  rm -rf "${STAGE_ROOT:?}"
}
trap cleanup EXIT

if [[ ! -f "${WEB_ROOT}/main.dart.js" || ! -d "${WEB_ROOT}/canvaskit" || ! -d "${WEB_ROOT}/assets" || ! -d "${WEB_ROOT}/fonts" ]]; then
  echo "missing Flutter Web build under ${WEB_ROOT}; run 'cd clients/openspeak_flutter && flutter build web --release' first" >&2
  exit 1
fi
if ! command -v "${COSCLI}" >/dev/null 2>&1; then
  echo "missing COSCLI: ${COSCLI}" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  BUILD_HASH="$(sha256sum "${WEB_ROOT}/main.dart.js" | awk '{print substr($1, 1, 20)}')"
else
  BUILD_HASH="$(shasum -a 256 "${WEB_ROOT}/main.dart.js" | awk '{print substr($1, 1, 20)}')"
fi
VERSION="$(date -u +%Y%m%d%H%M%S)-${BUILD_HASH}"
DESTINATION="cos://${COS_ALIAS}/assets-v-${VERSION}/"

rm -f "${VERSION_FILE}"
mkdir -p "${GZIP_ROOT}" "${RAW_ROOT}"
while IFS= read -r -d '' source; do
  relative="${source#"${WEB_ROOT}/"}"
  case "${source}" in
    *.png|*.woff2)
      destination="${RAW_ROOT}/${relative}"
      mkdir -p "$(dirname -- "${destination}")"
      cp "${source}" "${destination}"
      ;;
    *.js|*.json|*.wasm|*.wav|*.otf|*.ttf|*.md|*.txt|*.bin|*.frag|*.symbols|*/NOTICES|*/SHA256SUMS)
      destination="${GZIP_ROOT}/${relative}"
      mkdir -p "$(dirname -- "${destination}")"
      gzip -9 -c "${source}" > "${destination}"
      ;;
    *)
      echo "unsupported web asset type: ${relative}" >&2
      exit 1
      ;;
  esac
done < <(find "${WEB_ROOT}/main.dart.js" "${WEB_ROOT}/canvaskit" "${WEB_ROOT}/assets" "${WEB_ROOT}/fonts" -type f -print0)

upload() {
  local source_root="$1"
  local include="$2"
  local content_type="$3"
  local encoding="${4:-}"
  local metadata="Cache-Control:public,max-age=31536000,immutable#Content-Type:${content_type}"
  if [[ -n "${encoding}" ]]; then
    metadata="${metadata}#Content-Encoding:${encoding}"
  fi
  "${COSCLI}" cp "${source_root}/" "${DESTINATION}" -r --skip-dir --routines 8 \
    --include "${include}" --meta "${metadata}" \
    --process-log=false --fail-output=false
}

upload "${GZIP_ROOT}" '.*\.js$' 'application/javascript' gzip
upload "${GZIP_ROOT}" '.*\.json$' 'application/json' gzip
upload "${GZIP_ROOT}" '.*\.wasm$' 'application/wasm' gzip
upload "${GZIP_ROOT}" '.*\.wav$' 'audio/wav' gzip
upload "${GZIP_ROOT}" '.*\.otf$' 'font/otf' gzip
upload "${GZIP_ROOT}" '.*\.ttf$' 'font/ttf' gzip
upload "${GZIP_ROOT}" '.*\.(md|txt)$|.*(NOTICES|SHA256SUMS)$' 'text/plain' gzip
upload "${GZIP_ROOT}" '.*\.(bin|frag|symbols)$' 'application/octet-stream' gzip
upload "${RAW_ROOT}" '.*\.woff2$' 'font/woff2'
upload "${RAW_ROOT}" '.*\.png$' 'image/png'

printf '%s\n' "${VERSION}" > "${VERSION_FILE}"
echo "published ${DESTINATION}"

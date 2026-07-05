#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

status=0

check() {
  local name="$1" url="$2"
  if curl -fsS --max-time 3 "$url" >/dev/null 2>&1; then
    printf '🟢 %s %s\n' "$name" "$url"
  else
    printf '🔴 %s %s\n' "$name" "$url"
    status=1
  fi
}

check "Qdrant" "http://${EMBARSY_HOST}:${EMBARSY_QDRANT_REST_PORT}/readyz"
check "Ollama" "${OLLAMA_BASE_URL%/}/api/tags"
check "Embarsy API" "http://${EMBARSY_HOST}:${EMBARSY_API_PORT}/health"

exit "$status"

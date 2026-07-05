#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/native-binaries.sh
source "${SCRIPT_DIR}/lib/native-binaries.sh"

allow_missing=false

usage() {
  cat <<'EOF'
Usage: scripts/validate-bundled-binaries.sh [options]

Validates local bin/ binaries before packaging Embarsy.app.

Options:
  --allow-missing   Print missing binaries as warnings instead of failing.
  -h, --help        Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-missing)
      allow_missing=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

missing=0

check_executable() {
  local label="$1" path="$2"
  if [[ -x "${path}" ]]; then
    echo "OK ${label}: ${path}"
    return 0
  fi

  if [[ "${allow_missing}" == true ]]; then
    echo "WARN missing ${label}: ${path}"
    return 0
  fi

  echo "FAIL missing ${label}: ${path}" >&2
  missing=1
}

check_executable "Qdrant" "${EMBARSY_QDRANT_BIN}"
check_executable "Ollama" "${EMBARSY_OLLAMA_BIN}"
check_executable "Embarsy API" "${EMBARSY_API_BIN}"

if [[ "${missing}" -ne 0 ]]; then
  exit 1
fi

if [[ -x "${EMBARSY_QDRANT_BIN}" ]]; then
  qdrant_actual="$(${EMBARSY_QDRANT_BIN} --version || true)"
  version_contains "${qdrant_actual}" "${QDRANT_VERSION}" || {
    echo "FAIL Qdrant version mismatch. Expected '${QDRANT_VERSION}', got: ${qdrant_actual}" >&2
    exit 1
  }
  echo "OK Qdrant version: ${qdrant_actual}"
fi

if [[ -x "${EMBARSY_OLLAMA_BIN}" ]]; then
  ollama_actual="$(${EMBARSY_OLLAMA_BIN} --version || true)"
  version_contains "${ollama_actual}" "${OLLAMA_VERSION}" || {
    echo "FAIL Ollama version mismatch. Expected '${OLLAMA_VERSION}', got: ${ollama_actual}" >&2
    exit 1
  }
  echo "OK Ollama version: ${ollama_actual}"
fi

if [[ -x "${EMBARSY_API_BIN}" ]]; then
  api_actual="$(${EMBARSY_API_BIN} --version || true)"
  version_contains "${api_actual}" "${EMBARSY_API_VERSION}" || {
    echo "FAIL Embarsy API version mismatch. Expected '${EMBARSY_API_VERSION}', got: ${api_actual}" >&2
    exit 1
  }
  "${SCRIPT_DIR}/smoke-api-binary.sh"
fi

echo "Bundled binary validation completed."


#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

delete_app_support=false
keep_model=false

usage() {
  cat <<'EOF'
Usage: scripts/uninstall.sh [options]

Stops the native Embarsy services and optionally removes App Support data.

Options:
  --delete-data      Delete App Support data: Qdrant storage, Ollama models, logs, configs.
  --keep-model       Do not remove the Ollama model through the local Ollama API before data deletion.
  -h, --help         Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete-data|--delete-vectors)
      delete_app_support=true
      ;;
    --keep-model)
      keep_model=true
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

echo "Stopping Embarsy services..."
"${SCRIPT_DIR}/stop.sh" all || true

if [[ "$keep_model" == false ]]; then
  if [[ -x "${EMBARSY_OLLAMA_BIN}" ]] && OLLAMA_MODELS="${OLLAMA_MODELS}" OLLAMA_HOST="${OLLAMA_HOST}" \
    "${EMBARSY_OLLAMA_BIN}" list | awk '{print $1}' | grep -qx "${OLLAMA_MODEL}"; then
    echo "Removing Ollama model: ${OLLAMA_MODEL}"
    OLLAMA_MODELS="${OLLAMA_MODELS}" OLLAMA_HOST="${OLLAMA_HOST}" \
      "${EMBARSY_OLLAMA_BIN}" rm "${OLLAMA_MODEL}" || true
  else
    echo "Ollama model not found or managed Ollama is unavailable: ${OLLAMA_MODEL}"
  fi
fi

if [[ "$delete_app_support" == true ]]; then
  echo "Deleting Embarsy App Support data: ${EMBARSY_APP_SUPPORT}"
  rm -rf "${EMBARSY_APP_SUPPORT}"
else
  echo "Leaving App Support data in place: ${EMBARSY_APP_SUPPORT}"
fi

echo "Embarsy uninstall completed."

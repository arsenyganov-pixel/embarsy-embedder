#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_executable "${EMBARSY_OLLAMA_BIN}" "Ollama"
ensure_native_dirs

if ! curl -fsS --max-time 2 "${OLLAMA_BASE_URL%/}/api/tags" >/dev/null 2>&1; then
  echo "Starting Ollama server..."
  OLLAMA_MODELS="${OLLAMA_MODELS}" \
    OLLAMA_HOST="${OLLAMA_HOST}" \
    nohup "${EMBARSY_OLLAMA_BIN}" serve > "${EMBARSY_LOG_DIR}/ollama.log" 2>&1 &
  echo $! > "${EMBARSY_RUN_DIR}/ollama.pid"
  sleep 3
fi

echo "Pulling source model: ${OLLAMA_SOURCE_MODEL}"
OLLAMA_MODELS="${OLLAMA_MODELS}" OLLAMA_HOST="${OLLAMA_HOST}" \
  "${EMBARSY_OLLAMA_BIN}" pull "${OLLAMA_SOURCE_MODEL}"

if OLLAMA_MODELS="${OLLAMA_MODELS}" OLLAMA_HOST="${OLLAMA_HOST}" \
  "${EMBARSY_OLLAMA_BIN}" list | awk '{print $1}' | grep -qx "${OLLAMA_MODEL}"; then
  echo "Model alias already exists: ${OLLAMA_MODEL}"
  exit 0
fi

if OLLAMA_MODELS="${OLLAMA_MODELS}" OLLAMA_HOST="${OLLAMA_HOST}" \
  "${EMBARSY_OLLAMA_BIN}" cp "${OLLAMA_SOURCE_MODEL}" "${OLLAMA_MODEL}" >/dev/null 2>&1; then
  echo "Created Ollama alias ${OLLAMA_MODEL} -> ${OLLAMA_SOURCE_MODEL}"
  exit 0
fi

python3 "${SCRIPT_DIR}/optimize_gguf.py" \
  --source-model "${OLLAMA_SOURCE_MODEL}" \
  --target-model "${OLLAMA_MODEL}" \
  --output-dir "${EMBARSY_RUN_DIR}"
OLLAMA_MODELS="${OLLAMA_MODELS}" OLLAMA_HOST="${OLLAMA_HOST}" \
  "${EMBARSY_OLLAMA_BIN}" create "${OLLAMA_MODEL}" -f "${EMBARSY_RUN_DIR}/Modelfile.${OLLAMA_MODEL}"

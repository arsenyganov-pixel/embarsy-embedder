#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/native-binaries.sh
source "${SCRIPT_DIR}/lib/native-binaries.sh"

source_bin="${EMBARSY_OLLAMA_SOURCE_BIN}"
if [[ -z "${source_bin}" ]]; then
  source_bin="$(command -v ollama || true)"
fi

if [[ -z "${source_bin}" ]]; then
  echo "Ollama source binary was not provided and was not found in PATH." >&2
  echo "Set EMBARSY_OLLAMA_SOURCE_BIN in config/native-binaries.env or install Ollama locally for acquisition." >&2
  exit 1
fi

copy_binary "${source_bin}" "${EMBARSY_OLLAMA_BIN}" "Ollama"

actual_version="$(${EMBARSY_OLLAMA_BIN} --version || true)"
if ! version_contains "${actual_version}" "${OLLAMA_VERSION}"; then
  echo "Ollama version mismatch. Expected '${OLLAMA_VERSION}', got: ${actual_version}" >&2
  exit 1
fi

echo "Ollama version OK: ${actual_version}"


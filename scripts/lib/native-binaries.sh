#!/usr/bin/env bash
set -euo pipefail

NATIVE_BINARIES_MANIFEST="${NATIVE_BINARIES_MANIFEST:-${EMBARSY_HOME}/config/native-binaries.env}"

env_EMBARSY_API_VERSION="${EMBARSY_API_VERSION:-}"
env_QDRANT_VERSION="${QDRANT_VERSION:-}"
env_OLLAMA_VERSION="${OLLAMA_VERSION:-}"
env_EMBARSY_QDRANT_SOURCE_BIN="${EMBARSY_QDRANT_SOURCE_BIN:-}"
env_EMBARSY_QDRANT_SOURCE_DIR="${EMBARSY_QDRANT_SOURCE_DIR:-}"
env_EMBARSY_OLLAMA_SOURCE_BIN="${EMBARSY_OLLAMA_SOURCE_BIN:-}"

if [[ -f "${NATIVE_BINARIES_MANIFEST}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${NATIVE_BINARIES_MANIFEST}"
  set +a
fi

export EMBARSY_API_VERSION="${EMBARSY_API_VERSION:-0.1.0}"
export QDRANT_VERSION="${QDRANT_VERSION:-}"
export OLLAMA_VERSION="${OLLAMA_VERSION:-}"
export EMBARSY_QDRANT_SOURCE_BIN="${EMBARSY_QDRANT_SOURCE_BIN:-}"
export EMBARSY_QDRANT_SOURCE_DIR="${EMBARSY_QDRANT_SOURCE_DIR:-}"
export EMBARSY_OLLAMA_SOURCE_BIN="${EMBARSY_OLLAMA_SOURCE_BIN:-}"

export EMBARSY_API_VERSION="${env_EMBARSY_API_VERSION:-${EMBARSY_API_VERSION}}"
export QDRANT_VERSION="${env_QDRANT_VERSION:-${QDRANT_VERSION}}"
export OLLAMA_VERSION="${env_OLLAMA_VERSION:-${OLLAMA_VERSION}}"
export EMBARSY_QDRANT_SOURCE_BIN="${env_EMBARSY_QDRANT_SOURCE_BIN:-${EMBARSY_QDRANT_SOURCE_BIN}}"
export EMBARSY_QDRANT_SOURCE_DIR="${env_EMBARSY_QDRANT_SOURCE_DIR:-${EMBARSY_QDRANT_SOURCE_DIR}}"
export EMBARSY_OLLAMA_SOURCE_BIN="${env_EMBARSY_OLLAMA_SOURCE_BIN:-${EMBARSY_OLLAMA_SOURCE_BIN}}"

copy_binary() {
  local source_path="$1" target_path="$2" label="$3"
  if [[ ! -x "${source_path}" ]]; then
    echo "${label} source is not executable: ${source_path}" >&2
    exit 1
  fi

  mkdir -p "$(dirname "${target_path}")"
  cp "${source_path}" "${target_path}"
  chmod +x "${target_path}"
  echo "Prepared ${label}: ${target_path}"
}

version_contains() {
  local actual="$1" expected="$2"
  [[ -z "${expected}" || "${actual}" == *"${expected}"* ]]
}

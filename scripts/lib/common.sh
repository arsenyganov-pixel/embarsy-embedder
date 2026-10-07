#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Keep this variable private to the shared library. Do not overwrite caller scripts'
# SCRIPT_DIR: setup/start/stop scripts use their own SCRIPT_DIR after sourcing this file.
COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export EMBARSY_HOME="${EMBARSY_HOME:-$(cd "${COMMON_LIB_DIR}/../.." && pwd)}"

if [[ -f "${EMBARSY_HOME}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${EMBARSY_HOME}/.env"
  set +a
fi

export EMBARSY_RUN_DIR="${EMBARSY_RUN_DIR:-${EMBARSY_HOME}/.run}"
export EMBARSY_APP_SUPPORT="${EMBARSY_APP_SUPPORT:-${HOME}/Library/Application Support/Embarsy}"
export EMBARSY_BIN_DIR="${EMBARSY_BIN_DIR:-${EMBARSY_HOME}/bin}"
export EMBARSY_LOG_DIR="${EMBARSY_LOG_DIR:-${EMBARSY_APP_SUPPORT}/logs}"
export EMBARSY_HOST="${EMBARSY_HOST:-127.0.0.1}"
export EMBARSY_API_PORT="${EMBARSY_API_PORT:-8000}"
export EMBARSY_QDRANT_REST_PORT="${EMBARSY_QDRANT_REST_PORT:-6333}"
export EMBARSY_QDRANT_GRPC_PORT="${EMBARSY_QDRANT_GRPC_PORT:-6334}"
export EMBARSY_QDRANT_BIN="${EMBARSY_QDRANT_BIN:-${EMBARSY_BIN_DIR}/qdrant}"
export EMBARSY_QDRANT_STORAGE="${EMBARSY_QDRANT_STORAGE:-${EMBARSY_APP_SUPPORT}/qdrant/storage}"
export EMBARSY_QDRANT_CONFIG="${EMBARSY_QDRANT_CONFIG:-${EMBARSY_APP_SUPPORT}/qdrant/config.yaml}"
export OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://127.0.0.1:11434}"
export OLLAMA_HOST="${OLLAMA_HOST:-${OLLAMA_BASE_URL#http://}}"
export OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3-embedding}"
export OLLAMA_SOURCE_MODEL="${OLLAMA_SOURCE_MODEL:-hf.co/Qwen/Qwen3-Embedding-0.6B-GGUF:Q8_0}"
export OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:--1}"
export OLLAMA_MODELS="${OLLAMA_MODELS:-${EMBARSY_APP_SUPPORT}/ollama}"
export EMBARSY_OLLAMA_BIN="${EMBARSY_OLLAMA_BIN:-${EMBARSY_BIN_DIR}/ollama}"
export EMBARSY_API_BIN="${EMBARSY_API_BIN:-${EMBARSY_BIN_DIR}/embarsy-api}"
export EMBARSY_NODE_BIN="${EMBARSY_NODE_BIN:-${EMBARSY_BIN_DIR}/node}"
export EMBARSY_BRIDGE_DIR="${EMBARSY_BRIDGE_DIR:-${EMBARSY_BIN_DIR}/bridge}"

has_command() {
  command -v "$1" >/dev/null 2>&1
}

require_command() {
  if ! has_command "$1"; then
    echo "Missing required command: $1" >&2
    return 1
  fi
}

resolve_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$EMBARSY_HOME" "$path"
  fi
}

require_executable() {
  local path="$1" name="$2"
  if [[ ! -x "$path" ]]; then
    echo "Missing executable ${name}: ${path}" >&2
    echo "Put the native binary at this path or set the corresponding EMBARSY_*_BIN variable." >&2
    return 1
  fi
}

ensure_native_dirs() {
  mkdir -p \
    "${EMBARSY_RUN_DIR}" \
    "${EMBARSY_LOG_DIR}" \
    "${EMBARSY_QDRANT_STORAGE}" \
    "$(dirname "${EMBARSY_QDRANT_CONFIG}")" \
    "${OLLAMA_MODELS}"
}

http_ok() {
  local url="$1"
  curl -fsS --max-time 3 "$url" >/dev/null 2>&1
}

pid_alive() {
  local pid_file="$1"
  [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" >/dev/null 2>&1
}

EMBARSY_QDRANT_BIN="$(resolve_path "${EMBARSY_QDRANT_BIN}")"
EMBARSY_OLLAMA_BIN="$(resolve_path "${EMBARSY_OLLAMA_BIN}")"
EMBARSY_API_BIN="$(resolve_path "${EMBARSY_API_BIN}")"
EMBARSY_NODE_BIN="$(resolve_path "${EMBARSY_NODE_BIN}")"
EMBARSY_BRIDGE_DIR="$(resolve_path "${EMBARSY_BRIDGE_DIR}")"

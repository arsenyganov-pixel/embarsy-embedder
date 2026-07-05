#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

target="${1:-all}"

write_qdrant_config() {
  ensure_native_dirs
  cat > "${EMBARSY_QDRANT_CONFIG}" <<EOF
service:
  host: ${EMBARSY_HOST}
  http_port: ${EMBARSY_QDRANT_REST_PORT}
  grpc_port: ${EMBARSY_QDRANT_GRPC_PORT}
storage:
  storage_path: ${EMBARSY_QDRANT_STORAGE}
EOF
}

wait_for_url() {
  local name="$1" url="$2" pid_file="$3"
  for _ in {1..60}; do
    if http_ok "$url"; then
      echo "${name} is ready: ${url}"
      return 0
    fi
    if [[ -n "$pid_file" && ! -f "$pid_file" ]]; then
      echo "${name} pid file disappeared before readiness: ${pid_file}" >&2
      return 1
    fi
    if [[ -n "$pid_file" && ! pid_alive "$pid_file" ]]; then
      echo "${name} process exited before readiness." >&2
      return 1
    fi
    sleep 0.5
  done
  echo "${name} did not become ready: ${url}" >&2
  return 1
}

case "$target" in
  qdrant)
    require_executable "${EMBARSY_QDRANT_BIN}" "Qdrant"
    write_qdrant_config
    if http_ok "http://${EMBARSY_HOST}:${EMBARSY_QDRANT_REST_PORT}/readyz"; then
      echo "Qdrant is already ready."
      exit 0
    fi
    echo "Starting Qdrant on ${EMBARSY_HOST}:${EMBARSY_QDRANT_REST_PORT}..."
    QDRANT__SERVICE__API_KEY="${QDRANT_API_KEY:-}" \
      nohup "${EMBARSY_QDRANT_BIN}" --config-path "${EMBARSY_QDRANT_CONFIG}" \
      > "${EMBARSY_LOG_DIR}/qdrant.log" 2>&1 &
    echo $! > "${EMBARSY_RUN_DIR}/qdrant.pid"
    wait_for_url "Qdrant" "http://${EMBARSY_HOST}:${EMBARSY_QDRANT_REST_PORT}/readyz" "${EMBARSY_RUN_DIR}/qdrant.pid"
    ;;
  ollama)
    require_executable "${EMBARSY_OLLAMA_BIN}" "Ollama"
    ensure_native_dirs
    if ! http_ok "${OLLAMA_BASE_URL%/}/api/tags"; then
      OLLAMA_MODELS="${OLLAMA_MODELS}" \
        OLLAMA_HOST="${OLLAMA_HOST}" \
        nohup "${EMBARSY_OLLAMA_BIN}" serve > "${EMBARSY_LOG_DIR}/ollama.log" 2>&1 &
      echo $! > "${EMBARSY_RUN_DIR}/ollama.pid"
    fi
    wait_for_url "Ollama" "${OLLAMA_BASE_URL%/}/api/tags" "${EMBARSY_RUN_DIR}/ollama.pid"
    ;;
  api)
    "${SCRIPT_DIR}/start-api.sh"
    ;;
  all)
    "$0" qdrant
    "$0" ollama
    "${SCRIPT_DIR}/prepare-model.sh"
    "$0" api
    ;;
  *)
    echo "Usage: $0 [all|qdrant|ollama|api]" >&2
    exit 2
    ;;
esac

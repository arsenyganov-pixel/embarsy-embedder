#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

target="${1:-all}"

stop_pid_file() {
  local pid_file="$1" name="$2"
  if pid_alive "$pid_file"; then
    echo "Stopping ${name} pid $(cat "$pid_file")..."
    kill "$(cat "$pid_file")" || true
    rm -f "$pid_file"
  else
    echo "${name} is not running from Embarsy pid file."
  fi
}

case "$target" in
  qdrant)
    stop_pid_file "${EMBARSY_RUN_DIR}/qdrant.pid" "Qdrant"
    ;;
  ollama)
    stop_pid_file "${EMBARSY_RUN_DIR}/ollama.pid" "Ollama"
    ;;
  api)
    stop_pid_file "${EMBARSY_RUN_DIR}/api.pid" "Embarsy API"
    ;;
  all)
    "$0" api
    "$0" qdrant
    "$0" ollama
    ;;
  *)
    echo "Usage: $0 [all|qdrant|ollama|api]" >&2
    exit 2
    ;;
esac

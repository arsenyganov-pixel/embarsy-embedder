#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if pid_alive "${EMBARSY_RUN_DIR}/api.pid"; then
  echo "Embarsy API is already running on pid $(cat "${EMBARSY_RUN_DIR}/api.pid")."
  exit 0
fi

if [[ -x "${EMBARSY_API_BIN}" ]]; then
  echo "Starting Embarsy API binary on ${EMBARSY_HOST}:${EMBARSY_API_PORT}..."
  OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE}" \
    nohup "${EMBARSY_API_BIN}" \
      > "${EMBARSY_LOG_DIR}/api.log" 2>&1 &
  echo $! > "${EMBARSY_RUN_DIR}/api.pid"
else
  echo "Embarsy API binary is not available at ${EMBARSY_API_BIN}; starting source API for development."
  if [[ ! -x "${EMBARSY_HOME}/.venv/bin/uvicorn" ]]; then
  python3 -m venv "${EMBARSY_HOME}/.venv"
  "${EMBARSY_HOME}/.venv/bin/python" -m pip install --upgrade pip
  "${EMBARSY_HOME}/.venv/bin/python" -m pip install -r "${EMBARSY_HOME}/requirements.txt"
  fi

  echo "Starting Embarsy API source server on ${EMBARSY_HOST}:${EMBARSY_API_PORT}..."
  (
    cd "${EMBARSY_HOME}"
    PYTHONPATH="${EMBARSY_HOME}/src" \
      OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE}" \
      nohup "${EMBARSY_HOME}/.venv/bin/uvicorn" embarsy_api.main:app \
        --host "${EMBARSY_HOST}" \
        --port "${EMBARSY_API_PORT}" \
        > "${EMBARSY_LOG_DIR}/api.log" 2>&1 &
    echo $! > "${EMBARSY_RUN_DIR}/api.pid"
  )
fi

api_url="http://${EMBARSY_HOST}:${EMBARSY_API_PORT}/health"
for _ in {1..40}; do
  if http_ok "$api_url"; then
    echo "Embarsy API is ready: ${api_url}"
    exit 0
  fi

  if ! pid_alive "${EMBARSY_RUN_DIR}/api.pid"; then
    echo "Embarsy API process exited before becoming ready." >&2
    tail -n 80 "${EMBARSY_LOG_DIR}/api.log" >&2 || true
    exit 1
  fi

  sleep 0.5
done

echo "Embarsy API did not become ready in time: ${api_url}" >&2
tail -n 80 "${EMBARSY_LOG_DIR}/api.log" >&2 || true
exit 1

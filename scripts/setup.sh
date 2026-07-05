#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

create_env() {
  if [[ -f "${EMBARSY_HOME}/.env" ]]; then
    return
  fi
  local qdrant_key api_key
  qdrant_key="$(openssl rand -hex 32)"
  api_key="$(openssl rand -hex 24)"
  cp "${EMBARSY_HOME}/.env.example" "${EMBARSY_HOME}/.env"
  python3 - <<PY
from pathlib import Path
path = Path("${EMBARSY_HOME}/.env")
text = path.read_text()
text = text.replace("QDRANT_API_KEY=change-me-generate-with-setup", "QDRANT_API_KEY=${qdrant_key}")
text = text.replace("EMBARSY_API_KEY=", "EMBARSY_API_KEY=${api_key}")
path.write_text(text)
PY
  echo "Created ${EMBARSY_HOME}/.env with generated local API keys."
}

create_venv() {
  python3 -m venv "${EMBARSY_HOME}/.venv"
  "${EMBARSY_HOME}/.venv/bin/python" -m pip install --upgrade pip
  "${EMBARSY_HOME}/.venv/bin/python" -m pip install -r "${EMBARSY_HOME}/requirements.txt"
}

validate_native_binaries() {
  require_executable "${EMBARSY_QDRANT_BIN}" "Qdrant"
  require_executable "${EMBARSY_OLLAMA_BIN}" "Ollama"
}

create_env
# Reload generated env.
set -a
# shellcheck disable=SC1091
source "${EMBARSY_HOME}/.env"
set +a
ensure_native_dirs
validate_native_binaries
"${SCRIPT_DIR}/validate-bundled-binaries.sh"
create_venv
"${SCRIPT_DIR}/prepare-model.sh"
"${SCRIPT_DIR}/start.sh" qdrant
"${SCRIPT_DIR}/start-api.sh"
"${SCRIPT_DIR}/health.sh"

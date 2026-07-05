#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ ! -x "${EMBARSY_HOME}/.venv/bin/pyinstaller" ]]; then
  python3 -m venv "${EMBARSY_HOME}/.venv"
  "${EMBARSY_HOME}/.venv/bin/python" -m pip install --upgrade pip
  "${EMBARSY_HOME}/.venv/bin/python" -m pip install -r "${EMBARSY_HOME}/requirements-dev.txt"
fi

(
  cd "${EMBARSY_HOME}"
  "${EMBARSY_HOME}/.venv/bin/pyinstaller" --clean --noconfirm embarsy-api.spec
)

mkdir -p "${EMBARSY_BIN_DIR}"
cp "${EMBARSY_HOME}/dist/embarsy-api" "${EMBARSY_BIN_DIR}/embarsy-api"
chmod +x "${EMBARSY_BIN_DIR}/embarsy-api"

# Re-sign ad-hoc: PyInstaller's own onefile signature is rejected at runtime on Apple Silicon
# ("SIGKILL: Code Signature Invalid" / Taskgated) even though `codesign --verify` passes on disk.
# A clean re-sign fixes it; the app-level deep sign later re-signs it again inside the bundle.
codesign --remove-signature "${EMBARSY_BIN_DIR}/embarsy-api" 2>/dev/null || true
codesign --force --sign - --timestamp=none "${EMBARSY_BIN_DIR}/embarsy-api"

echo "Built Embarsy API binary: ${EMBARSY_BIN_DIR}/embarsy-api"

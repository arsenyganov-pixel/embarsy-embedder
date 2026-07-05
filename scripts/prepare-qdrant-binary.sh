#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/native-binaries.sh
source "${SCRIPT_DIR}/lib/native-binaries.sh"

if [[ -n "${EMBARSY_QDRANT_SOURCE_BIN}" ]]; then
  copy_binary "${EMBARSY_QDRANT_SOURCE_BIN}" "${EMBARSY_QDRANT_BIN}" "Qdrant"
elif [[ -n "${EMBARSY_QDRANT_SOURCE_DIR}" ]]; then
  if ! command -v cargo >/dev/null 2>&1; then
    echo "cargo is required to build Qdrant from EMBARSY_QDRANT_SOURCE_DIR." >&2
    exit 1
  fi
  (
    cd "${EMBARSY_QDRANT_SOURCE_DIR}"
    cargo build --release --bin qdrant
  )
  copy_binary "${EMBARSY_QDRANT_SOURCE_DIR}/target/release/qdrant" "${EMBARSY_QDRANT_BIN}" "Qdrant"
else
  echo "Qdrant source was not provided." >&2
  echo "Set EMBARSY_QDRANT_SOURCE_BIN or EMBARSY_QDRANT_SOURCE_DIR in config/native-binaries.env." >&2
  exit 1
fi

actual_version="$(${EMBARSY_QDRANT_BIN} --version || true)"
if ! version_contains "${actual_version}" "${QDRANT_VERSION}"; then
  echo "Qdrant version mismatch. Expected '${QDRANT_VERSION}', got: ${actual_version}" >&2
  exit 1
fi

echo "Qdrant version OK: ${actual_version}"


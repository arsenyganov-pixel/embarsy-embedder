#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_executable "${EMBARSY_API_BIN}" "Embarsy API"

output="$(${EMBARSY_API_BIN} --print-config)"

EMBARSY_API_SMOKE_OUTPUT="$output" python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["EMBARSY_API_SMOKE_OUTPUT"])
assert payload["app"] == "embarsy_api.main:app", payload
assert payload["host"], payload
assert int(payload["port"]) > 0, payload
print("Embarsy API binary smoke OK:", payload)
PY

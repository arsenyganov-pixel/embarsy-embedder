#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

source_iconset="${EMBARSY_HOME}/Embarsy-icons/AppIcon/Embarsy.iconset"
output_icns="${EMBARSY_HOME}/Embarsy-icons/AppIcon/Embarsy.icns"
work_iconset="${EMBARSY_HOME}/build/icons/Embarsy.iconset"

if ! command -v iconutil >/dev/null 2>&1; then
  echo "Missing iconutil. Install Xcode Command Line Tools." >&2
  exit 1
fi

rm -rf "${work_iconset}"
mkdir -p "${work_iconset}"

for file in "${source_iconset}"/*.png; do
  name="$(basename "$file")"
  normalized="${name/-2x/@2x}"
  cp "$file" "${work_iconset}/${normalized}"
done

iconutil -c icns "${work_iconset}" -o "${output_icns}"
echo "Prepared AppIcon: ${output_icns}"

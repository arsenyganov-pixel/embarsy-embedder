#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

app_version="0.1.1"
dmg="${EMBARSY_HOME}/build/Embarsy-${app_version}-arm64.dmg"
profile="${EMBARSY_NOTARY_PROFILE:-embarsy-notary}"
identity="${EMBARSY_CODESIGN_IDENTITY:-}"
sign_dmg=true

usage() {
  cat <<'EOF'
Usage: scripts/notarize-dmg.sh [options]

Signs the built DMG with Developer ID, submits it to Apple's notary service, waits
for the result, then staples the ticket so Gatekeeper approves it offline.

Prerequisites:
  * A "Developer ID Application" certificate installed in the login keychain.
  * A stored notary credential profile, e.g.:
      xcrun notarytool store-credentials embarsy-notary \
        --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-pw"

Options:
  --dmg PATH               DMG to notarize (default: build/Embarsy-<ver>-arm64.dmg).
  --keychain-profile NAME  notarytool credential profile (default: $EMBARSY_NOTARY_PROFILE or embarsy-notary).
  --identity ID            Developer ID Application identity (default: $EMBARSY_CODESIGN_IDENTITY).
  --no-sign-dmg            Do not re-sign the DMG container before submitting.
  -h, --help               Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dmg)              dmg="$2"; shift ;;
    --keychain-profile) profile="$2"; shift ;;
    --identity)         identity="$2"; shift ;;
    --no-sign-dmg)      sign_dmg=false ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ ! -f "${dmg}" ]]; then
  echo "DMG not found: ${dmg}" >&2
  echo "Build it first: EMBARSY_CODESIGN_IDENTITY=\"Developer ID Application: ... (TEAMID)\" scripts/package-dmg.sh" >&2
  exit 1
fi

if [[ -z "${identity}" || "${identity}" == "-" ]]; then
  echo "A Developer ID identity is required to sign the DMG." >&2
  echo "Set EMBARSY_CODESIGN_IDENTITY or pass --identity \"Developer ID Application: ... (TEAMID)\"." >&2
  exit 1
fi

require_command xcrun
require_command codesign

echo "Notarizing ${dmg}"
echo "  identity: ${identity}"
echo "  profile:  ${profile}"

# 1) Sign the DMG container itself (the app inside was already signed at package time).
if [[ "${sign_dmg}" == true ]]; then
  echo "Signing DMG container..."
  codesign --force --sign "${identity}" --timestamp "${dmg}"
fi

# 2) Submit to the notary service and block until Apple returns a verdict.
echo "Submitting to the notary service (this can take a few minutes)..."
if ! xcrun notarytool submit "${dmg}" --keychain-profile "${profile}" --wait; then
  echo "Notarization failed. Inspect the log with:" >&2
  echo "  xcrun notarytool history --keychain-profile ${profile}" >&2
  echo "  xcrun notarytool log <submission-id> --keychain-profile ${profile}" >&2
  exit 1
fi

# 3) Staple the ticket so first launch works even offline.
echo "Stapling ticket..."
xcrun stapler staple "${dmg}"
xcrun stapler validate "${dmg}"

# 4) Final Gatekeeper assessment of the DMG.
echo "Gatekeeper assessment:"
spctl -a -t open --context context:primary-signature -vv "${dmg}" || true

echo "Notarized + stapled: ${dmg}"

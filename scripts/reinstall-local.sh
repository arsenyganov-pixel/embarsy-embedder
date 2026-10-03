#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Install a freshly built Embarsy.app over the running one — correctly.
#
# Replacing the bundle on disk is NOT enough and fails silently: macOS leaves the running
# app process on the old executable, and the stack it spawned (API, Qdrant, Ollama) keeps
# holding its ports. The relaunched app then adopts those already-listening ports and
# serves the OLD API, so nothing appears to change. Worse, the "Update" affordance cannot
# help, because the version it compares against is baked into the old executable that is
# still running. So: stop the services, quit the app, swap the bundle, start again.

app_name="Embarsy"
install_dir="${EMBARSY_INSTALL_DIR:-/Applications}"
source_app="${EMBARSY_HOME}/build/${app_name}.app"
relaunch=true
build_app=false

usage() {
  cat <<'EOF'
Usage: scripts/reinstall-local.sh [options]

Stops the running Embarsy stack, quits the app, installs build/Embarsy.app over the
installed copy, and relaunches it.

Options:
  --build             Package build/Embarsy.app first (reuses the existing API binary).
  --no-relaunch       Install but do not start the app again.
  --install-dir PATH  Where the app lives (default: EMBARSY_INSTALL_DIR or /Applications).
  -h, --help          Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) build_app=true ;;
    --no-relaunch) relaunch=false ;;
    --install-dir)
      [[ $# -ge 2 ]] || { echo "Missing value for --install-dir" >&2; exit 2; }
      install_dir="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

target_app="${install_dir}/${app_name}.app"

if [[ "${build_app}" == true ]]; then
  echo "==> Packaging ${app_name}.app"
  "${SCRIPT_DIR}/package-macos-app.sh" --skip-binary-validation
fi

if [[ ! -d "${source_app}" ]]; then
  echo "No packaged app at ${source_app}" >&2
  echo "Run scripts/package-macos-app.sh (or pass --build) first." >&2
  exit 1
fi

# Terminate whatever is LISTENING on the managed ports, whoever started it: after an app
# relaunch the services belong to a previous app instance, so matching on our own PID files
# would miss exactly the processes that cause the stale-version trap.
stop_port() {
  local port="$1" label="$2" pids
  pids="$(/usr/sbin/lsof -nP -tiTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true)"
  [[ -n "${pids}" ]] || return 0
  echo "    stopping ${label} on :${port} (pid $(echo "${pids}" | tr '\n' ' '))"
  # shellcheck disable=SC2086
  kill ${pids} 2>/dev/null || true
  for _ in $(seq 1 20); do
    pids="$(/usr/sbin/lsof -nP -tiTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true)"
    [[ -n "${pids}" ]] || return 0
    sleep 0.5
  done
  echo "    ${label} did not exit on TERM; sending KILL"
  # shellcheck disable=SC2086
  kill -9 ${pids} 2>/dev/null || true
}

echo "==> Stopping the stack"
stop_port "${EMBARSY_API_PORT}" "Embarsy API"
stop_port "${EMBARSY_QDRANT_REST_PORT}" "Qdrant"
stop_port "${OLLAMA_HOST##*:}" "Ollama"

echo "==> Quitting ${app_name}"
osascript -e "tell application \"${app_name}\" to quit" 2>/dev/null || true
for _ in $(seq 1 20); do
  pgrep -x "${app_name}" >/dev/null 2>&1 || break
  sleep 0.5
done
if pgrep -x "${app_name}" >/dev/null 2>&1; then
  echo "    still running after quit; terminating"
  pkill -x "${app_name}" 2>/dev/null || true
  sleep 1
fi

echo "==> Installing to ${target_app}"
mkdir -p "${install_dir}"
rm -rf "${target_app}"
ditto --noextattr --norsrc "${source_app}" "${target_app}"
xattr -cr "${target_app}" 2>/dev/null || true

installed_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${target_app}/Contents/Info.plist")"
installed_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${target_app}/Contents/Info.plist")"
echo "    installed ${installed_version} (build ${installed_build})"

if [[ "${relaunch}" != true ]]; then
  echo "Done. Start ${app_name} yourself, then press Start All."
  exit 0
fi

echo "==> Launching ${app_name}"
open -a "${target_app}"

# The app starts its own services; wait for the API and then prove the RUNNING process is
# the one we just installed, since that is the exact failure this script exists to prevent.
echo "==> Waiting for the API"
for _ in $(seq 1 60); do
  http_ok "http://${EMBARSY_HOST}:${EMBARSY_API_PORT}/health" && break
  sleep 1
done

if ! http_ok "http://${EMBARSY_HOST}:${EMBARSY_API_PORT}/health"; then
  echo "API did not come up. Open ${app_name} and press Start All, then re-check." >&2
  exit 1
fi

running_version="$(curl -fsS --max-time 5 "http://${EMBARSY_HOST}:${EMBARSY_API_PORT}/health" \
  | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')"
echo "    API reports ${running_version}"

bundled_api="${target_app}/Contents/Resources/embarsy-api"
bundled_version="$("${bundled_api}" --version 2>/dev/null | awk '{print $NF}')"

if [[ "${running_version}" != "${bundled_version}" ]]; then
  echo "MISMATCH: the API answering on :${EMBARSY_API_PORT} is ${running_version}, but the installed app bundles ${bundled_version}." >&2
  echo "A previous process is still serving. Re-run this script, or stop it by hand." >&2
  exit 1
fi

echo "Reinstalled ${app_name} ${installed_version} — running API ${running_version} matches the bundle."

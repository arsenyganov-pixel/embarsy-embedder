#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

configuration="release"
dry_run=false
allow_missing_binaries=false
sign_app=true
build_api_binary=false
skip_binary_validation=false
install_app=false
install_dir="${EMBARSY_INSTALL_DIR:-/Users/$(id -un)/Applications}"
codesign_identity="${EMBARSY_CODESIGN_IDENTITY:--}"

usage() {
  cat <<'EOF'
Usage: scripts/package-macos-app.sh [options]

Builds Embarsy.app from the SwiftPM native app skeleton, copies bundled resources,
and ad-hoc signs embedded binaries plus the .app bundle.

Options:
  --debug                    Build Swift app in debug configuration.
  --dry-run                  Print packaging plan without writing the .app bundle.
  --allow-missing-binaries   Package even if bin/qdrant, bin/ollama or bin/embarsy-api are absent.
  --build-api-binary         Build bin/embarsy-api with PyInstaller before packaging.
  --skip-binary-validation   Skip version/smoke validation before packaging.
  --install                  Copy the packaged app to EMBARSY_INSTALL_DIR or ~/Applications.
  --install-dir PATH         Copy target for --install (default: EMBARSY_INSTALL_DIR or ~/Applications).
  --no-sign                  Skip ad-hoc codesign.
  -h, --help                 Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)
      configuration="debug"
      ;;
    --dry-run)
      dry_run=true
      ;;
    --allow-missing-binaries)
      allow_missing_binaries=true
      ;;
    --build-api-binary)
      build_api_binary=true
      ;;
    --skip-binary-validation)
      skip_binary_validation=true
      ;;
    --install)
      install_app=true
      ;;
    --install-dir)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --install-dir" >&2
        exit 2
      fi
      install_app=true
      install_dir="$2"
      shift
      ;;
    --no-sign)
      sign_app=false
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

app_name="Embarsy"
app_version="0.2.1"
bundle_version="${EMBARSY_BUNDLE_VERSION:-$(date -u +%Y%m%d%H%M)}"
native_dir="${EMBARSY_HOME}/native/EmbarsyApp"
bundle_dir="${EMBARSY_HOME}/build/${app_name}.app"
contents_dir="${bundle_dir}/Contents"
macos_dir="${contents_dir}/MacOS"
resources_dir="${contents_dir}/Resources"
swift_config_arg="-c"
swift_product_path="${native_dir}/.build/${configuration}/EmbarsyApp"
icon_path="${EMBARSY_HOME}/Embarsy-icons/AppIcon/Embarsy.icns"

binary_sources=(
  "${EMBARSY_QDRANT_BIN}:qdrant"
  "${EMBARSY_OLLAMA_BIN}:ollama"
  "${EMBARSY_API_BIN}:embarsy-api"
)

ollama_runner_source="${OLLAMA_LLAMA_SERVER_BIN:-}"
if [[ -z "${ollama_runner_source}" ]]; then
  ollama_runner_candidates=(
    "$(dirname "${EMBARSY_OLLAMA_BIN}")/lib/ollama/llama-server"
    "/opt/homebrew/opt/ollama/libexec/lib/ollama/llama-server"
    "/opt/homebrew/Cellar/ollama/0.30.11/libexec/lib/ollama/llama-server"
    "/usr/local/opt/ollama/libexec/lib/ollama/llama-server"
  )
  for candidate in "${ollama_runner_candidates[@]}"; do
    if [[ -x "${candidate}" ]]; then
      ollama_runner_source="${candidate}"
      break
    fi
  done
fi

echo "Packaging ${app_name}.app"
echo "  configuration: ${configuration}"
echo "  bundle: ${bundle_dir}"
echo "  dry_run: ${dry_run}"
echo "  build_api_binary: ${build_api_binary}"
echo "  skip_binary_validation: ${skip_binary_validation}"
echo "  bundle_version: ${bundle_version}"
echo "  install_app: ${install_app}"
echo "  install_dir: ${install_dir}"

if [[ "${build_api_binary}" == true && "${dry_run}" != true ]]; then
  "${SCRIPT_DIR}/build-api-binary.sh"
fi

missing=()
for entry in "${binary_sources[@]}"; do
  source_path="${entry%%:*}"
  target_name="${entry##*:}"
  if [[ ! -x "${source_path}" ]]; then
    missing+=("${target_name}: ${source_path}")
  fi
done

if [[ ! -x "${ollama_runner_source}" ]]; then
  missing+=("llama-server: set OLLAMA_LLAMA_SERVER_BIN or install Ollama with lib/ollama/llama-server")
fi

if [[ ${#missing[@]} -gt 0 && "${allow_missing_binaries}" != true ]]; then
  printf 'Missing required bundled binaries:\n' >&2
  printf '  %s\n' "${missing[@]}" >&2
  echo "Build them or rerun with --allow-missing-binaries for UI-only packaging." >&2
  exit 1
fi

if [[ "${skip_binary_validation}" != true ]]; then
  if [[ "${allow_missing_binaries}" == true ]]; then
    "${SCRIPT_DIR}/validate-bundled-binaries.sh" --allow-missing
  else
    "${SCRIPT_DIR}/validate-bundled-binaries.sh"
  fi
fi

if [[ "${dry_run}" == true ]]; then
  echo "Dry run plan:"
  echo "  swift build ${swift_config_arg} ${configuration} --product EmbarsyApp"
  if [[ "${build_api_binary}" == true ]]; then
    echo "  build API binary via scripts/build-api-binary.sh"
  fi
  echo "  prepare icon ${icon_path}"
  echo "  create ${bundle_dir}"
  echo "  copy executable ${swift_product_path} -> ${macos_dir}/${app_name}"
  for entry in "${binary_sources[@]}"; do
    echo "  copy resource ${entry%%:*} -> ${resources_dir}/${entry##*:}"
  done
  echo "  copy Ollama runner ${ollama_runner_source} -> ${resources_dir}/lib/ollama/llama-server"
  echo "  write Info.plist"
  echo "  ad-hoc sign: ${sign_app}"
  echo "  codesign identity: ${codesign_identity}"
  if [[ "${install_app}" == true ]]; then
    echo "  install ${bundle_dir} -> ${install_dir}/${app_name}.app"
  fi
  exit 0
fi

(
  cd "${native_dir}"
  swift build "${swift_config_arg}" "${configuration}" --product EmbarsyApp
)

"${SCRIPT_DIR}/prepare-icons.sh"

rm -rf "${bundle_dir}"
mkdir -p "${macos_dir}" "${resources_dir}"

cp "${swift_product_path}" "${macos_dir}/${app_name}"
chmod +x "${macos_dir}/${app_name}"
cp "${icon_path}" "${resources_dir}/Embarsy.icns"
# The status-bar / brand mark is now drawn natively (Sources/EmbarsyMark.swift),
# so the EmbarsyIndex_* toolbar PNGs no longer need to be bundled.

for entry in "${binary_sources[@]}"; do
  source_path="${entry%%:*}"
  target_name="${entry##*:}"
  if [[ -x "${source_path}" ]]; then
    cp "${source_path}" "${resources_dir}/${target_name}"
    chmod +x "${resources_dir}/${target_name}"
  else
    echo "Skipping missing optional binary: ${target_name} (${source_path})"
  fi
done

if [[ -x "${ollama_runner_source}" ]]; then
  mkdir -p "${resources_dir}/lib/ollama"
  cp "${ollama_runner_source}" "${resources_dir}/lib/ollama/llama-server"
  chmod +x "${resources_dir}/lib/ollama/llama-server"
else
  echo "Skipping missing Ollama runner: llama-server (${ollama_runner_source})"
fi

cat > "${contents_dir}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${app_name}</string>
  <key>CFBundleIconFile</key>
  <string>Embarsy.icns</string>
  <key>CFBundleIdentifier</key>
  <string>ru.embarsy.local</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${app_name}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${app_version}</string>
  <key>CFBundleVersion</key>
  <string>${bundle_version}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSMinimumSystemVersionByArchitecture</key>
  <dict>
    <key>arm64</key>
    <string>13.0</string>
  </dict>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

xattr -cr "${bundle_dir}" 2>/dev/null || true

if [[ "${sign_app}" == true ]]; then
  if [[ "${codesign_identity}" == "-" ]]; then
    echo "Warning: signing ${app_name}.app ad-hoc because EMBARSY_CODESIGN_IDENTITY is not set."
    echo "Warning: apps copied from DMG may be marked rejected by Gatekeeper and show a prohibited overlay until signed with Developer ID and notarized."
    while IFS= read -r -d '' executable; do
      codesign --force --sign - --timestamp=none "$executable"
    done < <(find "${contents_dir}" -type f -perm -111 -print0)
    codesign --force --deep --sign - --timestamp=none "${bundle_dir}"
  else
    # Developer ID: sign inside-out with the hardened runtime + a secure timestamp so the
    # app can be notarized. Nested helper binaries get entitlements that let them load their
    # own bundled libraries; the outer bundle is sealed LAST and WITHOUT --deep so the nested
    # signatures (and their entitlements) are preserved rather than clobbered.
    echo "Signing ${app_name}.app with Developer ID: ${codesign_identity}"
    helper_entitlements="${SCRIPT_DIR}/entitlements/helper.entitlements"
    while IFS= read -r -d '' executable; do
      [[ "${executable}" == "${macos_dir}/${app_name}" ]] && continue   # main exe sealed with the bundle below
      codesign --force --options runtime --timestamp \
        --entitlements "${helper_entitlements}" \
        --sign "${codesign_identity}" "$executable"
    done < <(find "${contents_dir}" -type f -perm -111 -print0)
    codesign --force --options runtime --timestamp \
      --sign "${codesign_identity}" "${bundle_dir}"
  fi
  codesign --verify --deep --strict "${bundle_dir}"
fi

if [[ "${install_app}" == true ]]; then
  mkdir -p "${install_dir}"
  rm -rf "${install_dir}/${app_name}.app"
  ditto --noextattr --norsrc "${bundle_dir}" "${install_dir}/${app_name}.app"
  xattr -cr "${install_dir}/${app_name}.app" 2>/dev/null || true
  echo "Installed ${install_dir}/${app_name}.app"
  echo "Installed build: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${install_dir}/${app_name}.app/Contents/Info.plist")"
fi

echo "Packaged ${bundle_dir}"

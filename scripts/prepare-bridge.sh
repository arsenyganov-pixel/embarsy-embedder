#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Stage the editor bridge for bundling: compiled JS plus its RUNTIME dependencies only.
#
# The public registry is named explicitly. The build machine's default may be a corporate
# mirror that does not carry public packages (and is unreachable off-VPN) — a release must not
# depend on which network the person packaging it happens to be on.

source_dir="${EMBARSY_HOME}/tools/embarsy-qdrant-mcp"
registry="${EMBARSY_NPM_REGISTRY:-https://registry.npmjs.org/}"

[[ -d "${source_dir}" ]] || { echo "Bridge source not found: ${source_dir}" >&2; exit 1; }

echo "Building bridge from ${source_dir}"
(
  cd "${source_dir}"
  npm install --silent --no-audit --no-fund --registry "${registry}"
  npm run build
)

version="$(node -p "require('${source_dir}/package.json').version")"

# Bundled to ONE file per entry point rather than copied with node_modules: the MCP SDK
# pulls in HTTP transports and OAuth machinery this stdio server never touches, which is
# 23 MB and 92 packages of bundle weight — and of supply-chain surface — for code that
# never runs. Tree-shaken, the same server is well under a megabyte.
rm -rf "${EMBARSY_BRIDGE_DIR}"
mkdir -p "${EMBARSY_BRIDGE_DIR}"
for entry in mcp index; do
  npx --prefix "${source_dir}" esbuild "${source_dir}/dist/bin/${entry}.js" \
    --bundle --platform=node --format=esm --target=node20 \
    --define:process.env.EMBARSY_BRIDGE_VERSION="\"${version}\"" \
    --outfile="${EMBARSY_BRIDGE_DIR}/${entry}.js" --log-level=warning
done

# Read by the app to show which bridge it carries — written from the same package.json the
# bundle was built from, so it can never disagree with the code it describes.
printf "%s\n" "${version}" > "${EMBARSY_BRIDGE_DIR}/VERSION"

staged_size="$(du -sh "${EMBARSY_BRIDGE_DIR}" | cut -f1)"
echo "Bridge ${version} staged at ${EMBARSY_BRIDGE_DIR} (${staged_size})"

# Prove the staged copy actually runs under the bundled Node before it is packaged — a
# missing runtime dependency is otherwise only discovered by a user whose editor silently
# fails to start the server.
if [[ -x "${EMBARSY_NODE_BIN}" ]]; then
  if "${EMBARSY_NODE_BIN}" "${EMBARSY_BRIDGE_DIR}/mcp.js" --help >/dev/null 2>&1; then
    echo "Smoke check OK: bundled Node runs the staged bridge"
  else
    echo "Staged bridge failed to run under ${EMBARSY_NODE_BIN}" >&2
    exit 1
  fi
else
  echo "Note: bundled Node not prepared yet — run scripts/prepare-node-binary.sh to smoke-check."
fi

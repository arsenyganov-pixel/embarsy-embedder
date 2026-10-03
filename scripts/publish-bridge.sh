#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Publish tools/embarsy-qdrant-mcp to the public npm registry.
#
# Every check here exists because it has already cost an evening once:
#   - the machine's default registry is a corporate mirror, so `npm login`/`whoami`/`view`
#     must each be told the public registry explicitly or they silently talk to the wrong
#     host (and `npm publish` then reports a 404 that actually means "not authenticated");
#   - `dist/` is what ships, so it is rebuilt here rather than trusted;
#   - a version already on the registry can never be republished, so that is checked
#     BEFORE anything else happens.
# Publishing is irreversible, so the final step asks — pass --yes to skip the prompt.

registry="https://registry.npmjs.org/"
package_dir="${EMBARSY_HOME}/tools/embarsy-qdrant-mcp"
assume_yes=false

usage() {
  cat <<'EOF'
Usage: scripts/publish-bridge.sh [--yes]

Verifies auth, rebuilds dist/, shows what would ship, then publishes
embarsy-qdrant-mcp to https://registry.npmjs.org/.

Options:
  --yes       Do not ask for confirmation before publishing.
  -h, --help  Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) assume_yes=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

require_command npm
cd "${package_dir}"

name="$(node -p 'require("./package.json").name')"
version="$(node -p 'require("./package.json").version')"
echo "==> ${name}@${version}"
echo "    registry: ${registry}"

echo "==> Checking authentication"
if ! who="$(npm whoami --registry "${registry}" 2>/dev/null)"; then
  echo "Not logged in to ${registry}." >&2
  echo "Run this first (the --registry flag matters: your default registry is a mirror):" >&2
  echo "  npm login --registry ${registry}" >&2
  exit 1
fi
echo "    logged in as ${who}"

echo "==> Checking the version is free"
published="$(npm view "${name}@${version}" version --registry "${registry}" 2>/dev/null || true)"
if [[ -n "${published}" ]]; then
  echo "${name}@${version} is already published and can never be replaced." >&2
  echo "Bump the version in ${package_dir}/package.json first." >&2
  exit 1
fi
latest="$(npm view "${name}" version --registry "${registry}" 2>/dev/null || echo "none")"
echo "    latest on the registry: ${latest} -> publishing ${version}"

echo "==> Rebuilding dist/"
npm run build

echo "==> Contents that would ship"
npm publish --dry-run --registry "${registry}"

if [[ "${assume_yes}" != true ]]; then
  echo
  read -r -p "Publish ${name}@${version} to ${registry}? [y/N] " answer
  case "${answer}" in
    y|Y|yes|YES) ;;
    *) echo "Aborted; nothing was published."; exit 0 ;;
  esac
fi

echo "==> Publishing"
npm publish --registry "${registry}"

echo "==> Verifying"
for _ in $(seq 1 10); do
  [[ "$(npm view "${name}" version --registry "${registry}" 2>/dev/null || true)" == "${version}" ]] && break
  sleep 2
done
echo "    registry now serves $(npm view "${name}" version --registry "${registry}")"

cat <<EOF

Published ${name}@${version}.

Update it locally with:
  npm install -g ${name}@latest --registry ${registry}

Then, in each indexed project, run \`embarsy-index\` once so the project name and folder
are written into the existing collection (no re-embedding — unchanged files are skipped).

nvm note: a global install lands under the ACTIVE node version. If \`npm ls -g ${name}\`
looks empty afterwards, check \`which embarsy-mcp\` — an older node version may still be
holding the copy that is actually on your PATH.
EOF

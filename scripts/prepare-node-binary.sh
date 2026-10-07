#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/native-binaries.sh
source "${SCRIPT_DIR}/lib/native-binaries.sh"

# Fetch the Node runtime that ships inside Embarsy.app so the editor bridge never depends on
# the user's machine. Every failure we spent days on — the corporate npm mirror, a stale npm
# cache, a package installed under one nvm version while another is active, the minimal PATH
# a GUI app passes to the servers it spawns — comes from relying on a Node that someone else
# installed. A pinned copy inside the bundle has none of those moving parts.
#
# Downloaded from the official nodejs.org tarball and verified against the SHASUMS256 file
# published beside it, rather than copied from whatever happens to be on the build machine.

node_version="${NODE_VERSION:?NODE_VERSION must be set in config/native-binaries.env}"
arch="arm64"
tarball="node-v${node_version}-darwin-${arch}.tar.gz"
base_url="https://nodejs.org/dist/v${node_version}"
work_dir="${EMBARSY_HOME}/build/node-download"

if [[ -x "${EMBARSY_NODE_BIN}" ]]; then
  existing="$("${EMBARSY_NODE_BIN}" --version 2>/dev/null || true)"
  if [[ "${existing}" == "v${node_version}" ]]; then
    echo "Node already prepared: ${existing} (${EMBARSY_NODE_BIN})"
    exit 0
  fi
  echo "Replacing bundled Node ${existing:-unknown} with v${node_version}"
fi

mkdir -p "${work_dir}"
(
  cd "${work_dir}"
  echo "Downloading ${tarball}"
  curl -fsSL -o "${tarball}" "${base_url}/${tarball}"
  curl -fsSL -o SHASUMS256.txt "${base_url}/SHASUMS256.txt"

  # Verify before unpacking: an archive that fails its published checksum is never opened.
  if ! grep " ${tarball}\$" SHASUMS256.txt | shasum -a 256 -c - >/dev/null 2>&1; then
    echo "Checksum verification FAILED for ${tarball}" >&2
    exit 1
  fi
  echo "Checksum OK"

  rm -rf "node-v${node_version}-darwin-${arch}"
  tar -xzf "${tarball}"
)

mkdir -p "${EMBARSY_BIN_DIR}"
copy_binary "${work_dir}/node-v${node_version}-darwin-${arch}/bin/node" "${EMBARSY_NODE_BIN}" "Node"

actual_version="$("${EMBARSY_NODE_BIN}" --version || true)"
if [[ "${actual_version}" != "v${node_version}" ]]; then
  echo "Node version mismatch. Expected 'v${node_version}', got: ${actual_version}" >&2
  exit 1
fi

echo "Node version OK: ${actual_version}"

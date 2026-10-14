#!/usr/bin/env bash
set -euo pipefail

# Puts the pinned Ollama into bin/: the official release archive (checked against its SHA-256),
# reduced to what Embarsy runs — `ollama` and the `llama-server` it starts, arm64 only. The
# archive's other files are Intel CPU variants, the MLX engine (Embarsy's models are GGUF and
# run on llama.cpp) and a quantize tool; both binaries carry their libraries inside.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/native-binaries.sh
source "${SCRIPT_DIR}/lib/native-binaries.sh"

: "${OLLAMA_VERSION:?OLLAMA_VERSION is not set in config/native-binaries.env}"
: "${OLLAMA_DARWIN_SHA256:?OLLAMA_DARWIN_SHA256 is not set in config/native-binaries.env}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
archive="${work}/ollama-darwin.tgz"
url="https://github.com/ollama/ollama/releases/download/v${OLLAMA_VERSION}/ollama-darwin.tgz"

echo "Downloading Ollama ${OLLAMA_VERSION}: ${url}"
curl -fsSL -o "${archive}" "${url}"
echo "${OLLAMA_DARWIN_SHA256}  ${archive}" | shasum -a 256 -c -

mkdir -p "${work}/x"
tar -xzf "${archive}" -C "${work}/x"
mkdir -p "$(dirname "${EMBARSY_OLLAMA_BIN}")"
for name in ollama llama-server; do
  lipo "${work}/x/${name}" -thin arm64 -output "$(dirname "${EMBARSY_OLLAMA_BIN}")/${name}"
  chmod +x "$(dirname "${EMBARSY_OLLAMA_BIN}")/${name}"
done

actual_version="$(${EMBARSY_OLLAMA_BIN} --version 2>&1 || true)"
if ! version_contains "${actual_version}" "${OLLAMA_VERSION}"; then
  echo "Ollama version mismatch. Expected '${OLLAMA_VERSION}', got: ${actual_version}" >&2
  exit 1
fi
echo "Ollama version OK: ${actual_version}"

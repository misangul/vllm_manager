#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${MINIO_MC_BIN_DIR:-${ROOT_DIR}/.bin}"
MC_TARGET="${MINIO_MC_PATH:-${BIN_DIR}/minio-mc}"

is_minio_client() {
  local candidate="$1"
  if [ ! -x "$candidate" ]; then
    return 1
  fi

  local version_output
  version_output="$("$candidate" --version 2>&1 || true)"
  case "$version_output" in
    *minio-mc*|*MinIO*|*RELEASE.*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

if is_minio_client "$MC_TARGET"; then
  echo "$MC_TARGET"
  exit 0
fi

mkdir -p "$BIN_DIR"

arch="$(uname -m)"
case "$arch" in
  x86_64|amd64)
    mc_asset="linux-amd64/mc"
    ;;
  aarch64|arm64)
    mc_asset="linux-arm64/mc"
    ;;
  *)
    echo "Unsupported architecture for auto-install: $arch" >&2
    echo "Set MC_BIN manually to an installed MinIO client path." >&2
    exit 1
    ;;
esac

download_url="https://dl.min.io/client/mc/release/${mc_asset}"
tmp_path="${MC_TARGET}.tmp"

echo "Installing MinIO client to ${MC_TARGET}..." >&2
curl -fsSL "$download_url" -o "$tmp_path"
chmod +x "$tmp_path"
mv "$tmp_path" "$MC_TARGET"

if ! is_minio_client "$MC_TARGET"; then
  echo "Downloaded binary is not a valid MinIO client: $MC_TARGET" >&2
  exit 1
fi

echo "$MC_TARGET"

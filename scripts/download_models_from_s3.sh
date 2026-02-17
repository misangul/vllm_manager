#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing env file: $ENV_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

MC_BIN="${MC_BIN:-$("${ROOT_DIR}/scripts/ensure_minio_mc.sh")}"

: "${MINIO_URL:?MINIO_URL is required in .env}"
: "${MINIO_ACCESS_KEY:?MINIO_ACCESS_KEY is required in .env}"
: "${MINIO_SECRET_KEY:?MINIO_SECRET_KEY is required in .env}"
: "${MINIO_BUCKET:?MINIO_BUCKET is required in .env}"
: "${CHEM_S3_PREFIX:?CHEM_S3_PREFIX is required in .env}"
: "${GEMMA_S3_PREFIX:?GEMMA_S3_PREFIX is required in .env}"

HF_CACHE_DIR="${HF_CACHE_DIR:-$HOME/models}"
CHEM_LOCAL_DIR="${CHEM_LOCAL_DIR:-${HF_CACHE_DIR}/chemdfm}"
GEMMA_LOCAL_DIR="${GEMMA_LOCAL_DIR:-${HF_CACHE_DIR}/gemma}"

mkdir -p "$CHEM_LOCAL_DIR" "$GEMMA_LOCAL_DIR"

MC_ALIAS="${MC_ALIAS:-modelstore}"

echo "Configuring mc alias '${MC_ALIAS}'..."
"$MC_BIN" alias set "$MC_ALIAS" "$MINIO_URL" "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" >/dev/null

echo "Syncing chemdfm model from s3..."
"$MC_BIN" mirror --overwrite \
  "${MC_ALIAS}/${MINIO_BUCKET}/${CHEM_S3_PREFIX}" \
  "${CHEM_LOCAL_DIR}"

echo "Syncing gemma model from s3..."
"$MC_BIN" mirror --overwrite \
  "${MC_ALIAS}/${MINIO_BUCKET}/${GEMMA_S3_PREFIX}" \
  "${GEMMA_LOCAL_DIR}"

echo "Model download completed."
echo "ChemDFM local path: ${CHEM_LOCAL_DIR}"
echo "Gemma local path:   ${GEMMA_LOCAL_DIR}"

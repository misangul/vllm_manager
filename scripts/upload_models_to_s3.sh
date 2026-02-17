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

if [ $# -lt 2 ]; then
  echo "Usage: $0 <LOCAL_MODEL_DIR> <MODEL_KEY>" >&2
  echo "MODEL_KEY: chemdfm | gemma" >&2
  exit 1
fi

LOCAL_MODEL_DIR="$1"
MODEL_KEY="$2"

if [ ! -d "$LOCAL_MODEL_DIR" ]; then
  echo "Local model directory not found: $LOCAL_MODEL_DIR" >&2
  exit 1
fi

MC_BIN="${MC_BIN:-$("${ROOT_DIR}/scripts/ensure_minio_mc.sh")}"

: "${MINIO_URL:?MINIO_URL is required in .env}"
: "${MINIO_ACCESS_KEY:?MINIO_ACCESS_KEY is required in .env}"
: "${MINIO_SECRET_KEY:?MINIO_SECRET_KEY is required in .env}"
: "${MINIO_BUCKET:?MINIO_BUCKET is required in .env}"

case "$MODEL_KEY" in
  chemdfm)
    MODEL_PREFIX="${CHEM_S3_PREFIX:?CHEM_S3_PREFIX is required in .env}"
    ;;
  gemma)
    MODEL_PREFIX="${GEMMA_S3_PREFIX:?GEMMA_S3_PREFIX is required in .env}"
    ;;
  *)
    echo "Unsupported MODEL_KEY: $MODEL_KEY" >&2
    exit 1
    ;;
esac

MC_ALIAS="${MC_ALIAS:-modelstore}"

echo "Configuring mc alias '${MC_ALIAS}'..."
"$MC_BIN" alias set "$MC_ALIAS" "$MINIO_URL" "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" >/dev/null

TARGET_PATH="${MC_ALIAS}/${MINIO_BUCKET}/${MODEL_PREFIX}"
echo "Uploading '${LOCAL_MODEL_DIR}' -> '${TARGET_PATH}'..."
shopt -s dotglob nullglob
for item in "${LOCAL_MODEL_DIR}"/*; do
  name="$(basename "$item")"
  source_path="$item"
  if [ -L "$item" ]; then
    source_path="$(readlink -f "$item")"
  fi

  if [ -d "$source_path" ]; then
    "$MC_BIN" mirror --overwrite "$source_path" "${TARGET_PATH}/${name}"
  else
    "$MC_BIN" cp "$source_path" "${TARGET_PATH}/${name}"
  fi
done

echo "Upload completed for model key '${MODEL_KEY}'."

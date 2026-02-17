#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing env file: $ENV_FILE" >&2
  echo "Create it from .env.example first." >&2
  exit 1
fi

MC_BIN="${MC_BIN:-$("${ROOT_DIR}/scripts/ensure_minio_mc.sh")}"
export MC_BIN

bash "${ROOT_DIR}/scripts/download_models_from_s3.sh"

docker compose -f "${ROOT_DIR}/docker-compose.yml" up -d --build

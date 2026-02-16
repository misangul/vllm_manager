#!/usr/bin/env bash
set -euo pipefail

# Shared defaults
GPU_DEVICE="${GPU_DEVICE:-0}"
HF_CACHE_DIR="${HF_CACHE_DIR:-$HOME/models}"
VLLM_DOCKER_IMAGE="${VLLM_DOCKER_IMAGE:-vllm/vllm-openai:latest}"
SHM_SIZE="${VLLM_SHM_SIZE:-2g}"
MEMLOCK_ULIMIT="${VLLM_MEMLOCK_ULIMIT:--1}"
STACK_ULIMIT="${VLLM_STACK_ULIMIT:-67108864}"
HF_TOKEN="${HF_TOKEN:-}"

# ChemDFM defaults
CHEM_CONTAINER_NAME="${CHEM_CONTAINER_NAME:-chemdfm-vllm-managed}"
CHEM_MODEL_ID="${CHEM_MODEL_ID:-OpenDFM/ChemDFM-R-14B}"
CHEM_HOST_PORT="${CHEM_HOST_PORT:-8011}"
CHEM_MAX_MODEL_LEN="${CHEM_MAX_MODEL_LEN:-4096}"
CHEM_GPU_MEMORY_UTILIZATION="${CHEM_GPU_MEMORY_UTILIZATION:-0.50}"
CHEM_EXTRA_ARGS="${CHEM_EXTRA_ARGS:-}"

# Gemma defaults tuned for A100 profile
GEMMA_CONTAINER_NAME="${GEMMA_CONTAINER_NAME:-gemma-vllm-managed}"
GEMMA_MODEL_ID="${GEMMA_MODEL_ID:-RedHatAI/gemma-3-27b-it-quantized.w8a8}"
GEMMA_HOST_PORT="${GEMMA_HOST_PORT:-8012}"
GEMMA_MAX_MODEL_LEN="${GEMMA_MAX_MODEL_LEN:-1024}"
GEMMA_GPU_MEMORY_UTILIZATION="${GEMMA_GPU_MEMORY_UTILIZATION:-0.50}"
GEMMA_EXTRA_ARGS="${GEMMA_EXTRA_ARGS:-}"

DEFAULT_ACTIVE_MODEL="${DEFAULT_ACTIVE_MODEL:-gemma}" # chemdfm|gemma
CLEAN_START="${CLEAN_START:-1}" # 1 removes old containers first
CONTROL_TIMEOUT_SECONDS="${CONTROL_TIMEOUT_SECONDS:-60}"
HEALTH_RETRIES="${HEALTH_RETRIES:-480}"
HEALTH_SLEEP_SECONDS="${HEALTH_SLEEP_SECONDS:-2}"

mkdir -p "$HF_CACHE_DIR"

run_container() {
  local name="$1"
  local port="$2"
  local model_id="$3"
  local max_len="$4"
  local gpu_mem="$5"
  local extra_args="$6"

  if [ "$CLEAN_START" = "1" ]; then
    docker rm -f "$name" >/dev/null 2>&1 || true
  fi

  if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
    if ! docker ps --format '{{.Names}}' | grep -qx "$name"; then
      docker start "$name" >/dev/null
    fi
    return 0
  fi

  # shellcheck disable=SC2086
  docker run -d \
    --name "$name" \
    --restart unless-stopped \
    --gpus "device=${GPU_DEVICE}" \
    -p "${port}:8000" \
    --shm-size "$SHM_SIZE" \
    --ulimit "memlock=${MEMLOCK_ULIMIT}" \
    --ulimit "stack=${STACK_ULIMIT}" \
    -e "VLLM_SERVER_DEV_MODE=1" \
    -e "HF_TOKEN=${HF_TOKEN}" \
    -v "${HF_CACHE_DIR}:/root/.cache/huggingface" \
    "$VLLM_DOCKER_IMAGE" \
    "$model_id" \
    --dtype auto \
    --trust-remote-code \
    --enable-sleep-mode \
    --gpu-memory-utilization "$gpu_mem" \
    --max-model-len "$max_len" \
    $extra_args >/dev/null
}

wait_health() {
  local port="$1"
  local name="$2"
  local attempt=0
  while [ "$attempt" -lt "$HEALTH_RETRIES" ]; do
    if curl -fsS --max-time 2 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      echo "$name is healthy on :$port"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep "$HEALTH_SLEEP_SECONDS"
  done
  echo "Timed out waiting for $name health on port $port" >&2
  docker logs --tail 120 "$name" >&2 || true
  exit 1
}

sleep_model() {
  local port="$1"
  curl -fsS --max-time "$CONTROL_TIMEOUT_SECONDS" -X POST "http://127.0.0.1:${port}/sleep?level=1" >/dev/null
}

wake_model() {
  local port="$1"
  curl -fsS --max-time "$CONTROL_TIMEOUT_SECONDS" -X POST "http://127.0.0.1:${port}/wake_up" >/dev/null
}

echo "Starting vLLM pair on GPU ${GPU_DEVICE}..."
run_container "$CHEM_CONTAINER_NAME" "$CHEM_HOST_PORT" "$CHEM_MODEL_ID" "$CHEM_MAX_MODEL_LEN" "$CHEM_GPU_MEMORY_UTILIZATION" "$CHEM_EXTRA_ARGS"
wait_health "$CHEM_HOST_PORT" "$CHEM_CONTAINER_NAME"

# Sleep ChemDFM before loading Gemma so both can coexist on one GPU.
sleep_model "$CHEM_HOST_PORT"

run_container "$GEMMA_CONTAINER_NAME" "$GEMMA_HOST_PORT" "$GEMMA_MODEL_ID" "$GEMMA_MAX_MODEL_LEN" "$GEMMA_GPU_MEMORY_UTILIZATION" "$GEMMA_EXTRA_ARGS"
wait_health "$GEMMA_HOST_PORT" "$GEMMA_CONTAINER_NAME"

if [ "$DEFAULT_ACTIVE_MODEL" = "gemma" ]; then
  active_name="$GEMMA_MODEL_ID"
else
  # Gemma is awake after startup, so sleep it first to free VRAM.
  sleep_model "$GEMMA_HOST_PORT"
  wake_model "$CHEM_HOST_PORT"
  active_name="$CHEM_MODEL_ID"
fi

echo
echo "vLLM pair is ready."
echo "Active model: $active_name"
echo "ChemDFM endpoint: http://127.0.0.1:${CHEM_HOST_PORT}"
echo "Gemma endpoint:   http://127.0.0.1:${GEMMA_HOST_PORT}"
echo "Use /sleep, /wake_up, /is_sleeping endpoints only on trusted network."

# vLLM Model Manager

Standalone FastAPI manager that controls two local vLLM containers and exposes a stable endpoint for inference.

## Managed models

- `chemdfm` -> `OpenDFM/ChemDFM-R-14B`
- `gemma` -> `RedHatAI/gemma-3-27b-it-quantized.w8a8`

By default:

- manager: `http://127.0.0.1:8010`
- chemdfm vLLM: `http://127.0.0.1:8011`
- gemma vLLM: `http://127.0.0.1:8012`

## Containerized deployment (Docker Compose)

Use this for CI/CD-friendly deployment.

```bash
cd /home/m.isangulov@innopolis.ru/vllm_manager
cp .env.example .env
# edit .env and set MinIO credentials
./start_compose_with_s3.sh
```

Services started:

- `manager` (`:8010`)
- `chemdfm-vllm` (`:8011`)
- `gemma-vllm` (`:8012`)
- `bootstrap` (one-shot init helper)

Startup behavior on single GPU:

- `chemdfm-vllm` starts first.
- `bootstrap` waits until ChemDFM is healthy, then puts it to sleep.
- `gemma-vllm` starts after bootstrap succeeds.
- manager default active model is `gemma`.
- both vLLM instances load models from local paths mounted from `${HF_CACHE_DIR}`.

This makes `./start_compose_with_s3.sh` reach a stable state without manual sleep/wake calls.

Compose mode runs manager in a container and routes with internal DNS:

- `CHEM_BASE_URL=http://chemdfm-vllm:8000`
- `GEMMA_BASE_URL=http://gemma-vllm:8000`

In this mode, manager uses `MANAGE_DOCKER=false` (Compose controls container lifecycle).
Default memory profile uses a high-utilization Gemma profile on A100 80GB:

- `CHEM_GPU_MEMORY_UTILIZATION=0.50`
- `GEMMA_GPU_MEMORY_UTILIZATION=0.90`
- `CHEM_MAX_MODEL_LEN=4096`
- `GEMMA_MAX_MODEL_LEN=4096`
- `MAX_COMPLETION_TOKENS=1600` (manager-side cap; requests above this are clipped)

### Compose operations

```bash
docker compose ps
docker compose logs -f bootstrap
docker compose logs -f manager
docker compose logs -f chemdfm-vllm
docker compose logs -f gemma-vllm
docker compose down
```

### Healthcheck gate (recommended)

Run the end-to-end gate after `docker compose up` to verify:

- manager health is up,
- chat works on active model,
- switch to ChemDFM works and chat succeeds,
- switch back to Gemma works and chat succeeds.

```bash
cd /home/m.isangulov@innopolis.ru/vllm_manager
./healthcheck_gate.sh
```

Optional overrides:

```bash
MANAGER_URL="http://127.0.0.1:8010" \
WAIT_TIMEOUT_SECONDS=1200 \
./healthcheck_gate.sh
```

### Minimal launch flow

```bash
cd /home/m.isangulov@innopolis.ru/vllm_manager
cp .env.example .env
# set MinIO credentials and S3 prefixes in .env
./start_compose_with_s3.sh
./healthcheck_gate.sh
```

### Deployment checklist (new server)

```bash
cd /path/to/vllm_manager
cp .env.example .env
# set MINIO_URL, MINIO_ACCESS_KEY, MINIO_SECRET_KEY, MINIO_BUCKET, and S3 prefixes
./start_compose_with_s3.sh
```

Notes:

- `start_compose_with_s3.sh` auto-installs MinIO client to `vllm_manager/.bin/minio-mc` when missing.
- If your environment forbids downloading binaries at runtime, preinstall MinIO client and set `MC_BIN=/absolute/path/to/minio-mc`.

### Upload models to S3 (manual, one-time per update)

Models are not baked into Docker images. Upload model folders to your MinIO/S3 bucket:

```bash
cd /home/m.isangulov@innopolis.ru/vllm_manager
cp .env.example .env
# configure MINIO_* and *_S3_PREFIX in .env

bash scripts/upload_models_to_s3.sh /path/to/chemdfm_model chemdfm
bash scripts/upload_models_to_s3.sh /path/to/gemma_model gemma
```

### Download models from S3 (pre-start step)

```bash
cd /home/m.isangulov@innopolis.ru/vllm_manager
bash scripts/download_models_from_s3.sh
```

## 1) Install dependencies

Install `uv` once (if needed):

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

Then sync project dependencies:

```bash
cd /home/m.isangulov@innopolis.ru/vllm_manager
uv sync
```

MinIO client is auto-installed by the scripts into `vllm_manager/.bin/minio-mc` if missing.
You can still override with `MC_BIN=/absolute/path/to/minio-mc`.

## 2) Start both vLLM containers (sleep-mode enabled)

```bash
cd /home/m.isangulov@innopolis.ru
./vllm_manager/scripts/download_models_from_s3.sh
./vllm_manager/start_vllm_pair.sh
```

Useful env overrides:

```bash
# Example: override local paths and keep Gemma active
CHEM_MODEL_PATH="/root/.cache/huggingface/chemdfm" \
GEMMA_MODEL_PATH="/root/.cache/huggingface/gemma" \
DEFAULT_ACTIVE_MODEL=gemma \
./vllm_manager/start_vllm_pair.sh
```

## 3) Start manager API

```bash
cd /home/m.isangulov@innopolis.ru
uv run uvicorn \
  vllm_manager.app:app \
  --host 0.0.0.0 \
  --port 8010
```

## 4) Check status and active model

```bash
curl -sS http://127.0.0.1:8010/health
curl -sS http://127.0.0.1:8010/active-model
curl -sS http://127.0.0.1:8010/status
```

`/status` includes per-model `configured_max_model_len` and manager `max_completion_tokens`.

## 5) Switch model

```bash
# Switch to Gemma
curl -sS -X POST http://127.0.0.1:8010/switch-model \
  -H 'Content-Type: application/json' \
  -d '{"model_name":"gemma"}'

# Switch back to ChemDFM
curl -sS -X POST http://127.0.0.1:8010/switch-model \
  -H 'Content-Type: application/json' \
  -d '{"model_name":"chemdfm"}'
```

## 6) Use stable inference endpoint

Always call manager endpoint; it routes to the currently active backend model.

```bash
curl -sS http://127.0.0.1:8010/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "ignored-by-manager",
    "messages": [{"role":"user","content":"Reply with one short sentence."}],
    "max_tokens": 64,
    "temperature": 0.2
  }'
```

## Stop / cleanup

```bash
docker rm -f chemdfm-vllm-managed gemma-vllm-managed
```

For Compose:

```bash
cd /home/m.isangulov@innopolis.ru/vllm_manager
docker compose down
```

## Notes

- Sleep-mode endpoints (`/sleep`, `/wake_up`) are dev endpoints. Keep vLLM bound to trusted network only.
- You need enough CPU RAM for offloaded model weights.
- If switch fails due memory pressure, lower model KV cache usage with smaller `*_MAX_MODEL_LEN` and lower `*_GPU_MEMORY_UTILIZATION`.

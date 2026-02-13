# vLLM Model Manager

Standalone FastAPI manager that controls two local vLLM containers and exposes a stable endpoint for inference.

## Managed models

- `chemdfm` -> `OpenDFM/ChemDFM-R-14B`
- `gemma` -> `google/gemma-3-27b-it` (override with quantized model ID via env)

By default:

- manager: `http://127.0.0.1:8010`
- chemdfm vLLM: `http://127.0.0.1:8011`
- gemma vLLM: `http://127.0.0.1:8012`

## Containerized deployment (Docker Compose)

Use this for CI/CD-friendly deployment.

```bash
cd /home/m.isangulov@innopolis.ru/vllm_manager
cp .env.example .env
# edit .env and set HF_TOKEN
docker compose up -d --build
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

This makes plain `docker compose up -d --build` reach a stable state without manual sleep/wake calls.

Compose mode runs manager in a container and routes with internal DNS:

- `CHEM_BASE_URL=http://chemdfm-vllm:8000`
- `GEMMA_BASE_URL=http://gemma-vllm:8000`

In this mode, manager uses `MANAGE_DOCKER=false` (Compose controls container lifecycle).

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
# set HF_TOKEN in .env
docker compose up -d --build
./healthcheck_gate.sh
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

## 2) Start both vLLM containers (sleep-mode enabled)

```bash
cd /home/m.isangulov@innopolis.ru
HF_TOKEN="your_hf_token" ./vllm_manager/start_vllm_pair.sh
```

Useful env overrides:

```bash
# Example: set quantized Gemma checkpoint and keep Gemma active
HF_TOKEN="your_hf_token" \
GEMMA_MODEL_ID="your-org/gemma-3-27b-int8" \
GEMMA_EXTRA_ARGS="--quantization bitsandbytes --load-format bitsandbytes" \
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

## 5) Switch model

```bash
# Switch to Gemma
curl -sS -X POST http://127.0.0.1:8010/switch-model \
  -H 'Content-Type: application/json' \
  -d '{"model_name":"google/gemma-3-27b-it"}'

# Switch back to ChemDFM
curl -sS -X POST http://127.0.0.1:8010/switch-model \
  -H 'Content-Type: application/json' \
  -d '{"model_name":"OpenDFM/ChemDFM-R-14B"}'
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

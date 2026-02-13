#!/usr/bin/env bash
set -euo pipefail

MANAGER_URL="${MANAGER_URL:-http://127.0.0.1:8010}"
CHEM_MODEL_ID="${CHEM_MODEL_ID:-OpenDFM/ChemDFM-R-14B}"
GEMMA_MODEL_ID="${GEMMA_MODEL_ID:-google/gemma-3-27b-it}"
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-900}"
POLL_SECONDS="${POLL_SECONDS:-3}"

deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))

log() {
  echo "[gate] $*"
}

wait_http_200() {
  local url="$1"
  local name="$2"
  while (( SECONDS < deadline )); do
    local code
    code="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 4 "$url" || true)"
    if [[ "$code" == "200" ]]; then
      log "$name is healthy ($url)"
      return 0
    fi
    sleep "$POLL_SECONDS"
  done
  log "timeout waiting for $name health at $url"
  return 1
}

wait_active_backend_ready() {
  while (( SECONDS < deadline )); do
    local response
    response="$(curl -sS --max-time 4 "$MANAGER_URL/status" || true)"
    if [[ -z "$response" ]]; then
      sleep "$POLL_SECONDS"
      continue
    fi
    if STATUS_JSON="$response" python3 - <<'PY'
import json
import os
import sys

obj = json.loads(os.environ["STATUS_JSON"])
active_key = obj.get("active_model_key")
models = obj.get("models") or {}
active = models.get(active_key) or {}
healthy = active.get("healthy")
if healthy is True:
    print(f"[gate] active backend healthy: key={active_key} model={active.get('model_id')}")
    sys.exit(0)
sys.exit(1)
PY
    then
      return 0
    fi
    sleep "$POLL_SECONDS"
  done
  log "timeout waiting for active backend health"
  return 1
}

chat_smoke() {
  local label="$1"
  log "chat smoke test: $label"
  local response
  response="$(curl -sS --fail \
    -H "Content-Type: application/json" \
    -d '{"model":"ignored-by-manager","messages":[{"role":"user","content":"Reply with two words only."}],"max_tokens":10,"temperature":0.1}' \
    "$MANAGER_URL/v1/chat/completions")"

  RESPONSE_JSON="$response" python3 - <<'PY'
import json
import os

obj = json.loads(os.environ["RESPONSE_JSON"])
model = obj.get("model")
choices = obj.get("choices") or []
if not choices:
    raise SystemExit("missing choices in chat response")
message = (choices[0].get("message") or {}).get("content", "").strip()
if not message:
    raise SystemExit("empty assistant response")
print(f"[gate] chat ok model={model} content={message[:80]}")
PY
}

switch_model() {
  local model_name="$1"
  log "switching to: $model_name"
  local response
  response="$(curl -sS --fail \
    -X POST "$MANAGER_URL/switch-model" \
    -H "Content-Type: application/json" \
    -d "{\"model_name\":\"$model_name\"}")"

  RESPONSE_JSON="$response" python3 - <<'PY'
import json
import os

obj = json.loads(os.environ["RESPONSE_JSON"])
status = obj.get("status")
if status not in {"switched", "already_active"}:
    raise SystemExit(f"unexpected switch status: {status!r}")
print(f"[gate] switch ok status={status} active={obj.get('active_model_id')}")
PY
}

assert_active_model() {
  local expected_model_id="$1"
  local response
  response="$(curl -sS --fail "$MANAGER_URL/active-model")"

  RESPONSE_JSON="$response" EXPECTED_MODEL="$expected_model_id" python3 - <<'PY'
import json
import os

obj = json.loads(os.environ["RESPONSE_JSON"])
expected = os.environ["EXPECTED_MODEL"]
actual = obj.get("active_model_id")
if actual != expected:
    raise SystemExit(f"active model mismatch: expected={expected!r}, got={actual!r}")
print(f"[gate] active model verified: {actual}")
PY
}

log "starting healthcheck gate against $MANAGER_URL"
wait_http_200 "$MANAGER_URL/health" "manager"
wait_http_200 "$MANAGER_URL/status" "manager status"
wait_active_backend_ready

chat_smoke "initial active"

switch_model "$CHEM_MODEL_ID"
assert_active_model "$CHEM_MODEL_ID"
chat_smoke "after switching to ChemDFM"

switch_model "$GEMMA_MODEL_ID"
assert_active_model "$GEMMA_MODEL_ID"
chat_smoke "after switching to Gemma"

log "healthcheck gate passed"

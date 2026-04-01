from __future__ import annotations

import asyncio
import time
from typing import Any, Dict, Optional

import httpx
from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from .config import Settings
from .orchestrator import ContainerStatus, ensure_container_running, inspect_container
from .vllm_client import VLLMClient


class SwitchModelRequest(BaseModel):
    model_name: str


class ManagerState:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.active_model_key = settings.active_model_key
        self.lock = asyncio.Lock()
        control_timeout = float(settings.control_timeout_seconds)
        self.vllm_client = VLLMClient(timeout_seconds=control_timeout)

    @property
    def active_model(self):
        return self.settings.models[self.active_model_key]


settings = Settings.from_env()
state = ManagerState(settings)
app = FastAPI(title="vLLM model manager", version="1.0.0")


def _container_status_payload(status: ContainerStatus) -> Dict[str, Any]:
    return {
        "name": status.name,
        "exists": status.exists,
        "running": status.running,
        "status": status.status,
        "exit_code": status.exit_code,
    }


async def _model_runtime_status(model_key: str) -> Dict[str, Any]:
    model = settings.models[model_key]
    if settings.manage_docker:
        container_status = inspect_container(model.container_name)
        should_probe = container_status.running
    else:
        # In compose mode manager does not own Docker lifecycle.
        container_status = ContainerStatus(
            name=model.container_name,
            exists=True,
            running=True,
            status="external",
            exit_code=None,
        )
        should_probe = True

    health = await state.vllm_client.health(model.base_url) if should_probe else False
    sleeping = await state.vllm_client.is_sleeping(model.base_url) if health else None
    return {
        "key": model.key,
        "model_id": model.model_id,
        "base_url": model.base_url,
        "configured_max_model_len": model.max_model_len,
        "container": _container_status_payload(container_status),
        "healthy": health,
        "sleeping": sleeping,
    }


async def _prepare_headers(authorization: Optional[str]) -> Dict[str, str]:
    headers = {"Content-Type": "application/json"}
    if authorization:
        headers["Authorization"] = authorization
    return headers


@app.get("/health")
async def health() -> Dict[str, str]:
    return {"status": "ok"}


@app.get("/active-model")
async def active_model() -> Dict[str, Any]:
    active = state.active_model
    return {
        "active_model_key": state.active_model_key,
        "active_model_id": active.model_id,
        "active_base_url": active.base_url,
        "available_models": {
            key: model.model_id for key, model in settings.models.items()
        },
    }


@app.get("/status")
async def manager_status() -> Dict[str, Any]:
    chem = await _model_runtime_status("chemdfm")
    gemma = await _model_runtime_status("gemma")
    return {
        "active_model_key": state.active_model_key,
        "manager_limits": {
            "max_completion_tokens": settings.max_completion_tokens,
        },
        "models": {
            "chemdfm": chem,
            "gemma": gemma,
        },
    }


@app.post("/switch-model")
async def switch_model(request: SwitchModelRequest) -> Dict[str, Any]:
    try:
        target_key = settings.resolve_key(request.model_name)
    except KeyError as err:
        raise HTTPException(status_code=400, detail=str(err)) from err

    async with state.lock:
        previous_key = state.active_model_key
        if previous_key == target_key:
            active = settings.models[target_key]
            return {
                "status": "noop",
                "active_model_key": target_key,
                "active_model_id": active.model_id,
                "message": "Requested model is already active.",
            }

        previous_model = settings.models[previous_key]
        target_model = settings.models[target_key]
        start = time.monotonic()
        previous_healthy = False

        try:
            if settings.manage_docker:
                ensure_container_running(settings, previous_model)
                ensure_container_running(settings, target_model)
            previous_healthy = await state.vllm_client.health(previous_model.base_url)
            if previous_healthy:
                await state.vllm_client.sleep(previous_model.base_url, level=1)
            await state.vllm_client.wake_up(target_model.base_url)
            await state.vllm_client.list_models(target_model.base_url)
        except Exception as err:
            rollback_error = None
            if previous_healthy:
                try:
                    await state.vllm_client.wake_up(previous_model.base_url)
                except Exception as rb_err:  # pragma: no cover - best effort rollback
                    rollback_error = str(rb_err)

            error_message = str(err) or repr(err)

            detail = {
                "message": "Model switch failed.",
                "requested_model_key": target_key,
                "requested_model_id": target_model.model_id,
                "active_model_key": previous_key,
                "active_model_id": previous_model.model_id,
                "error": error_message,
                "rollback_error": rollback_error,
            }
            raise HTTPException(status_code=500, detail=detail) from err

        state.active_model_key = target_key
        elapsed = round(time.monotonic() - start, 3)
        return {
            "status": "switched",
            "from_model_key": previous_key,
            "from_model_id": previous_model.model_id,
            "active_model_key": target_key,
            "active_model_id": target_model.model_id,
            "switch_time_seconds": elapsed,
        }


@app.post("/v1/chat/completions")
async def proxy_chat_completions(
    payload: Dict[str, Any],
    authorization: Optional[str] = Header(default=None),
) -> JSONResponse:
    active = state.active_model
    # Keep manager endpoint stable: always target currently active backend model.
    payload = dict(payload)
    payload["model"] = active.model_id
    if settings.max_completion_tokens is not None:
        max_tokens_limit = settings.max_completion_tokens
        requested_max_tokens = payload.get("max_tokens")
        if requested_max_tokens is None:
            payload["max_tokens"] = max_tokens_limit
        else:
            try:
                requested_max_tokens = int(requested_max_tokens)
            except (TypeError, ValueError) as err:
                raise HTTPException(
                    status_code=400,
                    detail="max_tokens must be an integer when MAX_COMPLETION_TOKENS is enabled",
                ) from err
            if requested_max_tokens <= 0:
                raise HTTPException(status_code=400, detail="max_tokens must be positive")
            payload["max_tokens"] = min(requested_max_tokens, max_tokens_limit)
    headers = await _prepare_headers(authorization)
    try:
        response = await state.vllm_client.proxy_json_post(
            active.base_url, "/v1/chat/completions", payload, headers=headers
        )
    except httpx.HTTPError as err:
        raise HTTPException(status_code=502, detail=f"Proxy error: {err}") from err

    try:
        body = response.json()
    except Exception:
        body = {"raw": response.text}
    return JSONResponse(status_code=response.status_code, content=body)


@app.get("/v1/models")
async def proxy_models() -> JSONResponse:
    active = state.active_model
    try:
        payload = await state.vllm_client.list_models(active.base_url)
    except Exception as err:
        raise HTTPException(status_code=502, detail=f"Proxy error: {err}") from err
    return JSONResponse(status_code=200, content=payload)

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Dict


@dataclass(frozen=True)
class ManagedModel:
    key: str
    model_id: str
    container_name: str
    host_port: int
    base_url_override: str
    max_model_len: int
    gpu_memory_utilization: float
    extra_args: str = ""

    @property
    def base_url(self) -> str:
        if self.base_url_override:
            return self.base_url_override
        return f"http://127.0.0.1:{self.host_port}"


@dataclass(frozen=True)
class Settings:
    manager_host: str
    manager_port: int
    active_model_key: str
    docker_image: str
    gpu_device: str
    hf_cache_dir: str
    shm_size: str
    memlock_ulimit: str
    stack_ulimit: str
    hf_token: str
    control_timeout_seconds: int
    manage_docker: bool
    models: Dict[str, ManagedModel]

    @classmethod
    def from_env(cls) -> "Settings":
        chem_model = ManagedModel(
            key="chemdfm",
            model_id=os.getenv("CHEM_MODEL_ID", "OpenDFM/ChemDFM-R-14B"),
            container_name=os.getenv("CHEM_CONTAINER_NAME", "chemdfm-vllm-managed"),
            host_port=int(os.getenv("CHEM_HOST_PORT", "8011")),
            base_url_override=os.getenv("CHEM_BASE_URL", ""),
            max_model_len=int(os.getenv("CHEM_MAX_MODEL_LEN", "4096")),
            gpu_memory_utilization=float(os.getenv("CHEM_GPU_MEMORY_UTILIZATION", "0.50")),
            extra_args=os.getenv("CHEM_EXTRA_ARGS", ""),
        )
        gemma_model = ManagedModel(
            key="gemma",
            model_id=os.getenv("GEMMA_MODEL_ID", "RedHatAI/gemma-3-27b-it-quantized.w8a8"),
            container_name=os.getenv("GEMMA_CONTAINER_NAME", "gemma-vllm-managed"),
            host_port=int(os.getenv("GEMMA_HOST_PORT", "8012")),
            base_url_override=os.getenv("GEMMA_BASE_URL", ""),
            max_model_len=int(os.getenv("GEMMA_MAX_MODEL_LEN", "1024")),
            gpu_memory_utilization=float(os.getenv("GEMMA_GPU_MEMORY_UTILIZATION", "0.50")),
            extra_args=os.getenv("GEMMA_EXTRA_ARGS", ""),
        )
        models = {
            chem_model.key: chem_model,
            gemma_model.key: gemma_model,
        }
        active = os.getenv("ACTIVE_MODEL_KEY", gemma_model.key).strip().lower()
        if active not in models:
            active = chem_model.key

        hf_cache_dir = os.getenv("HF_CACHE_DIR", str(Path.home() / "models"))
        return cls(
            manager_host=os.getenv("MANAGER_HOST", "0.0.0.0"),
            manager_port=int(os.getenv("MANAGER_PORT", "8010")),
            active_model_key=active,
            docker_image=os.getenv("VLLM_DOCKER_IMAGE", "vllm/vllm-openai:latest"),
            gpu_device=os.getenv("GPU_DEVICE", "0"),
            hf_cache_dir=hf_cache_dir,
            shm_size=os.getenv("VLLM_SHM_SIZE", "2g"),
            memlock_ulimit=os.getenv("VLLM_MEMLOCK_ULIMIT", "-1"),
            stack_ulimit=os.getenv("VLLM_STACK_ULIMIT", "67108864"),
            hf_token=os.getenv("HF_TOKEN", ""),
            control_timeout_seconds=int(os.getenv("CONTROL_TIMEOUT_SECONDS", "300")),
            manage_docker=os.getenv("MANAGE_DOCKER", "true").lower() in ("1", "true", "yes"),
            models=models,
        )

    def resolve_key(self, requested_model: str) -> str:
        normalized = requested_model.strip().lower()
        aliases = {
            "chemdfm": "chemdfm",
            self.models["chemdfm"].model_id.lower(): "chemdfm",
            "gemma": "gemma",
            "gemma-3-27b-it": "gemma",
            "gemma-3-27b-it-awq-int4": "gemma",
            self.models["gemma"].model_id.lower(): "gemma",
        }
        if normalized not in aliases:
            raise KeyError(
                f"Unsupported model '{requested_model}'. "
                f"Allowed: {self.models['chemdfm'].model_id}, {self.models['gemma'].model_id}"
            )
        return aliases[normalized]

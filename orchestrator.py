from __future__ import annotations

import json
import shlex
import subprocess
from dataclasses import dataclass
from typing import Optional

from .config import ManagedModel, Settings


class DockerError(RuntimeError):
    pass


@dataclass
class ContainerStatus:
    name: str
    exists: bool
    running: bool
    status: str
    exit_code: Optional[int] = None


def _run_docker(args: list[str]) -> str:
    cmd = ["docker", *args]
    try:
        proc = subprocess.run(cmd, check=False, capture_output=True, text=True)
    except FileNotFoundError as err:
        raise DockerError("docker CLI not found in runtime") from err
    if proc.returncode != 0:
        raise DockerError(proc.stderr.strip() or proc.stdout.strip() or "docker command failed")
    return proc.stdout.strip()


def inspect_container(name: str) -> ContainerStatus:
    try:
        out = _run_docker(
            [
                "inspect",
                name,
                "--format",
                "{{json .State}}",
            ]
        )
    except DockerError:
        return ContainerStatus(name=name, exists=False, running=False, status="missing")
    state = json.loads(out)
    return ContainerStatus(
        name=name,
        exists=True,
        running=bool(state.get("Running")),
        status=state.get("Status", "unknown"),
        exit_code=state.get("ExitCode"),
    )


def ensure_container_running(settings: Settings, model: ManagedModel) -> ContainerStatus:
    status = inspect_container(model.container_name)
    if status.running:
        return status
    if status.exists and not status.running:
        _run_docker(["start", model.container_name])
        return inspect_container(model.container_name)
    _run_docker(build_run_args(settings, model))
    return inspect_container(model.container_name)


def build_run_args(settings: Settings, model: ManagedModel) -> list[str]:
    args: list[str] = [
        "run",
        "-d",
        "--name",
        model.container_name,
        "--restart",
        "unless-stopped",
        "--gpus",
        f"device={settings.gpu_device}",
        "-p",
        f"{model.host_port}:8000",
        "--shm-size",
        settings.shm_size,
        "--ulimit",
        f"memlock={settings.memlock_ulimit}",
        "--ulimit",
        f"stack={settings.stack_ulimit}",
        "-e",
        "VLLM_SERVER_DEV_MODE=1",
        "-e",
        f"HF_TOKEN={settings.hf_token}",
        "-v",
        f"{settings.hf_cache_dir}:/root/.cache/huggingface",
        settings.docker_image,
        model.model_id,
        "--dtype",
        "auto",
        "--trust-remote-code",
        "--enable-sleep-mode",
        "--gpu-memory-utilization",
        str(model.gpu_memory_utilization),
        "--max-model-len",
        str(model.max_model_len),
    ]
    if model.extra_args:
        args.extend(shlex.split(model.extra_args))
    return args

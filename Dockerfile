FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

RUN pip install --no-cache-dir uv

COPY vllm_manager/pyproject.toml /app/pyproject.toml
COPY vllm_manager/uv.lock /app/uv.lock
RUN uv sync --frozen --no-dev --no-install-project

COPY vllm_manager /app/vllm_manager

EXPOSE 8010

CMD ["uv", "run", "--no-sync", "uvicorn", "vllm_manager.app:app", "--host", "0.0.0.0", "--port", "8010"]

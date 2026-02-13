from __future__ import annotations

from typing import Any, Dict, Optional

import httpx


class VLLMClient:
    def __init__(self, timeout_seconds: float = 30.0):
        self.timeout = httpx.Timeout(timeout_seconds)

    async def _request(
        self,
        method: str,
        url: str,
        *,
        params: Optional[Dict[str, Any]] = None,
        json_body: Optional[Dict[str, Any]] = None,
        headers: Optional[Dict[str, str]] = None,
    ) -> httpx.Response:
        async with httpx.AsyncClient(timeout=self.timeout) as client:
            response = await client.request(
                method=method,
                url=url,
                params=params,
                json=json_body,
                headers=headers,
            )
            return response

    async def health(self, base_url: str) -> bool:
        try:
            response = await self._request("GET", f"{base_url}/health")
            return response.status_code == 200
        except Exception:
            return False

    async def list_models(self, base_url: str) -> Dict[str, Any]:
        response = await self._request("GET", f"{base_url}/v1/models")
        response.raise_for_status()
        return response.json()

    async def is_sleeping(self, base_url: str) -> Optional[bool]:
        try:
            response = await self._request("GET", f"{base_url}/is_sleeping")
            if response.status_code != 200:
                return None
            payload = response.json()
            if isinstance(payload, dict):
                if "is_sleeping" in payload:
                    return bool(payload["is_sleeping"])
                if "sleeping" in payload:
                    return bool(payload["sleeping"])
            if isinstance(payload, bool):
                return payload
            return None
        except Exception:
            return None

    async def sleep(self, base_url: str, level: int = 1) -> None:
        response = await self._request("POST", f"{base_url}/sleep", params={"level": level})
        response.raise_for_status()

    async def wake_up(self, base_url: str) -> None:
        response = await self._request("POST", f"{base_url}/wake_up")
        response.raise_for_status()

    async def proxy_json_post(
        self,
        base_url: str,
        path: str,
        payload: Dict[str, Any],
        headers: Optional[Dict[str, str]] = None,
    ) -> httpx.Response:
        url = f"{base_url}{path}"
        return await self._request("POST", url, json_body=payload, headers=headers)

from __future__ import annotations

# Thin async REST client for the local DefenseClaw inspection service.
# DefenseClaw returns a verdict like {"action":"allow"|"block","would_block":bool,
# "severity":...,"reason":...}. This client only transports; the evaluator maps the
# verdict to an Agent Control decision and owns the fail-closed policy.
import json
from dataclasses import dataclass, field
from typing import Any

try:
    import httpx

    HTTPX_AVAILABLE = True
except ImportError:
    httpx = None  # type: ignore
    HTTPX_AVAILABLE = False


# route -> (path, body-builder). We only ever receive the selector-sliced payload, so
# the general case sends it as {content}; the tool routes reuse the same content.
def _content_body(content: str) -> dict[str, Any]:
    return {"content": content}


ROUTES: dict[str, str] = {
    "request": "/api/v1/inspect/request",
    "response": "/api/v1/inspect/response",
    "tool": "/api/v1/inspect/tool",
    "tool-response": "/api/v1/inspect/tool-response",
}


@dataclass
class DefenseClawClient:
    base_url: str
    token: str = field(repr=False, default="")
    timeout_s: float = 8.0
    _client: Any = field(default=None, repr=False, compare=False)

    def _get_client(self) -> Any:
        if not HTTPX_AVAILABLE:  # pragma: no cover
            raise RuntimeError("httpx not installed; cannot call DefenseClaw")
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(timeout=self.timeout_s)
        return self._client

    async def inspect(self, route: str, content: str) -> dict[str, Any]:
        path = ROUTES.get(route, ROUTES["request"])
        url = self.base_url.rstrip("/") + path
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json",
            "X-DefenseClaw-Client": "agent-control-evaluator",
        }
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        # tool routes expect a tool-shaped body; we don't have the tool name in an
        # evaluator (only the sliced payload), so send content under both keys.
        body: dict[str, Any]
        if route in ("tool", "tool-response"):
            body = {"tool": "unknown", "args": content, "output": content}
        else:
            body = _content_body(content)
        resp = await self._get_client().post(url, json=body, headers=headers)
        resp.raise_for_status()
        try:
            return resp.json()
        except json.JSONDecodeError:
            return {"action": "allow", "reason": "non-JSON response treated as allow"}

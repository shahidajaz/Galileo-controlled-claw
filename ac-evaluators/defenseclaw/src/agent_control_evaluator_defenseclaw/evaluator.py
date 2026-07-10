from __future__ import annotations

import hashlib
import json
import os
import time
from importlib.metadata import PackageNotFoundError, version
from typing import Any

from agent_control_evaluators import Evaluator, EvaluatorMetadata, register_evaluator
from agent_control_models import EvaluatorResult

from .client import HTTPX_AVAILABLE, DefenseClawClient
from .config import DefenseClawConfig


def _pkg_version() -> str:
    try:
        return version("agent-control-evaluator-defenseclaw")
    except PackageNotFoundError:
        return "0.0.0.dev"


def _stringify(data: Any) -> str:
    if data is None:
        return ""
    if isinstance(data, str):
        return data
    if isinstance(data, (int, float, bool)):
        return str(data)
    try:
        return json.dumps(data, ensure_ascii=False, sort_keys=True, default=str)
    except TypeError:
        return str(data)


@register_evaluator
class DefenseClawEvaluator(Evaluator[DefenseClawConfig]):
    """DefenseClaw evaluator: sends the step payload to the local DefenseClaw inspection
    service and maps its verdict to a match. A DefenseClaw "block" -> matched=True (the
    control's action decides deny/steer). Fails CLOSED: any error/timeout -> matched
    when on_error='deny'. Plugs into the same Agent Control seam as the Cisco evaluator.
    """

    metadata = EvaluatorMetadata(
        name="defenseclaw",
        version=_pkg_version(),
        description="DefenseClaw local inspection (fail-closed) integration",
        requires_api_key=False,
        timeout_ms=8000,
    )

    config_model = DefenseClawConfig

    # process-wide verdict cache: key -> (expires_monotonic, matched, message)
    _cache: dict[str, tuple[float, bool, str]] = {}

    @classmethod
    def is_available(cls) -> bool:
        return HTTPX_AVAILABLE

    def _fail(self, reason: str) -> EvaluatorResult:
        # fail-closed: treat as a match so the control's deny/steer fires
        matched = self.config.on_error == "deny"
        return EvaluatorResult(
            matched=matched,
            confidence=1.0 if matched else 0.0,
            message=f"DefenseClaw unavailable ({reason}); "
            + ("fail-closed -> blocked" if matched else "fail-open -> allowed"),
        )

    async def evaluate(self, data: Any) -> EvaluatorResult:
        content = _stringify(data)
        cfg = self.config

        # cache lookup
        key = ""
        if cfg.cache_ttl_s > 0:
            key = hashlib.sha256(f"{cfg.route}\x00{content}".encode()).hexdigest()
            hit = self._cache.get(key)
            if hit and hit[0] > time.monotonic():
                return EvaluatorResult(matched=hit[1], confidence=1.0, message=hit[2])

        token = os.getenv(cfg.token_env, "")
        client = DefenseClawClient(base_url=cfg.base_url, token=token, timeout_s=cfg.timeout_ms / 1000.0)
        try:
            verdict = await client.inspect(cfg.route, content)
        except Exception as e:  # transport error, timeout, non-2xx
            return self._fail(type(e).__name__)

        action = str(verdict.get("action", "allow")).lower()
        blocked = action == "block" or bool(verdict.get("would_block"))
        reason = str(verdict.get("reason") or verdict.get("severity") or "flagged by DefenseClaw")
        result = EvaluatorResult(
            matched=blocked,
            confidence=1.0 if blocked else 0.0,
            message=reason if blocked else "DefenseClaw: allowed",
        )
        if key:
            # cache allows longer than blocks (allow is the common, stable case)
            ttl = cfg.cache_ttl_s if not blocked else min(cfg.cache_ttl_s, 60)
            self._cache[key] = (time.monotonic() + ttl, blocked, result.message)
        return result

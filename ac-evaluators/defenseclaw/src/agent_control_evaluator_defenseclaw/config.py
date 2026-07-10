from __future__ import annotations

from typing import Literal

from agent_control_evaluators import EvaluatorConfig
from pydantic import Field


class DefenseClawConfig(EvaluatorConfig):
    """Configuration for the DefenseClaw evaluator.

    DefenseClaw is a LOCAL LLM-based inspection service (private, on-box). Unlike the
    Cisco reference (which ships fail-OPEN), this evaluator defaults to fail-CLOSED:
    if the inspector is unreachable or times out, the step is treated as a match so
    the control's deny/steer fires.

    Attributes:
        base_url: DefenseClaw inspect API base (reachable from the AC server container).
        route: which inspect endpoint to use. "request"/"response" send {content};
               "tool"/"tool-response" send tool-shaped bodies. Default "request" works
               with any selector-sliced payload (we only get the sliced data, not the
               whole step, so content inspection is the general case).
        token_env: env var holding the DefenseClaw bearer token (never inline the token
                   in a control body - control configs are readable via the API).
        timeout_ms: hard budget for the (slow, local) scan. On overrun -> on_error.
        on_error: "deny" = fail-CLOSED (recommended), "allow" = fail-open.
        cache_ttl_s: cache identical verdicts this long (agent loops repeat payloads);
                     0 disables the cache.
    """

    base_url: str = "http://host.docker.internal:18970"
    route: Literal["request", "response", "tool", "tool-response"] = "request"
    token_env: str = "DEFENSECLAW_TOKEN"
    timeout_ms: int = Field(default=8_000, ge=1)
    on_error: Literal["allow", "deny"] = "deny"
    cache_ttl_s: int = Field(default=300, ge=0)

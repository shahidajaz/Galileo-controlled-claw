"""DefenseClaw evaluator for Agent Control.

Registers a `defenseclaw` evaluator (same seam as the Cisco AI Defense evaluator) that
calls the local DefenseClaw inspection service and fails CLOSED.
"""
from .config import DefenseClawConfig
from .evaluator import DefenseClawEvaluator

__all__ = ["DefenseClawConfig", "DefenseClawEvaluator"]

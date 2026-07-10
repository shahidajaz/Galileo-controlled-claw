# Overlay on the upstream Agent Control server image: add OUR DefenseClaw evaluator so it
# registers via the `agent_control.evaluators` entry point, exactly like the shipped Cisco
# and Galileo contrib evaluators. The base is the stock agent-control server built from git
# (tag openclaw-ac-base:<ver>, produced once by fleet-up/apply); this layer just pip-installs
# the small package into that image's venv. No fork of Agent Control.
ARG BASE_IMAGE=openclaw-ac-base:8.2.0
FROM ${BASE_IMAGE}

COPY ac-evaluators/defenseclaw /opt/ac-evaluators/defenseclaw
# the base is a uv-managed venv (no pip); install with uv into that venv
RUN uv pip install --python /app/.venv/bin/python --no-deps /opt/ac-evaluators/defenseclaw \
 && /app/.venv/bin/python -c "import agent_control_evaluator_defenseclaw as m; print('installed defenseclaw evaluator', m.DefenseClawEvaluator.metadata.name)"

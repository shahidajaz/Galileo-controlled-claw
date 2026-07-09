#!/usr/bin/env bash
# Web control plane for the single governed OpenClaw agent.
#   ./bin/portal.sh            -> http://127.0.0.1:8891
# Tunnel from your Mac:  ssh -L 8891:127.0.0.1:8891 <box>
cd "$(dirname "$0")/.."
exec python3 bin/portal.py

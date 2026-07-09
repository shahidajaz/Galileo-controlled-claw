#!/usr/bin/env bash
# Manage local models for the bundled Ollama server (single-agent stack).
#   ./bin/models.sh list             # what's downloaded
#   ./bin/models.sh pull qwen2.5:1.5b
#   ./bin/models.sh rm   qwen2.5:1.5b
# GPU is used automatically when an NVIDIA GPU is present.
set -uo pipefail
cd "$(dirname "$0")/.."
CF=(-f compose.yml)
command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1 && CF+=(-f compose.gpu.yml)
UP(){ docker compose "${CF[@]}" --profile models up -d ollama >/dev/null 2>&1; }
case "${1:-list}" in
  list) UP; docker compose "${CF[@]}" --profile models exec -T ollama ollama list ;;
  pull) [ -n "${2:-}" ] || { echo "usage: models.sh pull <model>"; exit 1; }
        UP; docker compose "${CF[@]}" --profile models exec -T ollama ollama pull "$2" ;;
  rm)   [ -n "${2:-}" ] || { echo "usage: models.sh rm <model>"; exit 1; }
        docker compose "${CF[@]}" --profile models exec -T ollama ollama rm "$2" ;;
  *)    echo "usage: models.sh [list | pull <model> | rm <model>]" ;;
esac

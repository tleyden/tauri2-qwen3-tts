#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

MODEL_NAME="${MODEL_NAME:-Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit}"
SPEAKER="${SPEAKER:-Aiden}"
TEXT_FILE="${TEXT_FILE:-examples/podcast1.txt}"
OUTPUT_FILE="${OUTPUT_FILE:-.generated/podcast1.wav}"

scripts/run.sh \
  --model "$MODEL_NAME" \
  --speaker "$SPEAKER" \
  --text-file "$TEXT_FILE" \
  --output "$OUTPUT_FILE"

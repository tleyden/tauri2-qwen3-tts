#!/usr/bin/env bash
set -euo pipefail

MODEL_REPO="https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit"
MODEL_DIR=".models/Qwen3-TTS-12Hz-1.7B-Base-8bit"

cd "$(dirname "$0")/.."

if ! command -v git-lfs >/dev/null 2>&1 && ! git lfs version >/dev/null 2>&1; then
  cat >&2 <<'EOF'
git-lfs is required to download the Qwen3-TTS model.

Install it with:
  brew install git-lfs
  git lfs install
EOF
  exit 1
fi

mkdir -p "$(dirname "$MODEL_DIR")"

if [[ -d "$MODEL_DIR/.git" ]]; then
  echo "Model already exists at $MODEL_DIR"
  echo "To refresh it manually, run:"
  echo "  git -C '$MODEL_DIR' pull --ff-only"
  exit 0
fi

if [[ -e "$MODEL_DIR" ]]; then
  echo "Refusing to overwrite existing non-git path: $MODEL_DIR" >&2
  exit 1
fi

git lfs install
git clone "$MODEL_REPO" "$MODEL_DIR"

cat <<EOF

Model downloaded to:
  $MODEL_DIR

Run the baseline smoke test with:
  swift run Qwen3TTSPoc

Run the streaming smoke test with:
  swift run Qwen3TTSPoc --stream
EOF

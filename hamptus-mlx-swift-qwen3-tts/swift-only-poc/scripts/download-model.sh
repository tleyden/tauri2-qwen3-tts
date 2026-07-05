#!/usr/bin/env bash
set -euo pipefail

HF_BASE_URL="https://huggingface.co"
DEFAULT_MODEL_8BIT="mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"
DEFAULT_MODEL_4BIT="mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit"

cd "$(dirname "$0")/../../.."

model_from_input() {
  local input="$1"

  input="${input#https://huggingface.co/}"
  input="${input#http://huggingface.co/}"
  input="${input%/}"

  if [[ "$input" != */* ]]; then
    input="mlx-community/$input"
  fi

  printf '%s\n' "$input"
}

cat <<EOF
Choose a Qwen3-TTS model to download:

  1. $DEFAULT_MODEL_8BIT
     1.7B CustomVoice, named speakers + style/emotion instruct

  2. $DEFAULT_MODEL_4BIT
     1.7B CustomVoice, smaller 4-bit quantization

Or type a Hugging Face model name, such as:
  mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit

EOF

printf 'Model [1]: '
IFS= read -r MODEL_CHOICE

case "$MODEL_CHOICE" in
  "" | "1")
    MODEL_ID="$DEFAULT_MODEL_8BIT"
    ;;
  "2")
    MODEL_ID="$DEFAULT_MODEL_4BIT"
    ;;
  *)
    MODEL_ID="$(model_from_input "$MODEL_CHOICE")"
    ;;
esac

MODEL_REPO="$HF_BASE_URL/$MODEL_ID"
MODEL_DIR=".models/${MODEL_ID##*/}"

cat <<EOF

About to download:
  $MODEL_REPO

Destination:
  $MODEL_DIR

EOF

printf 'Download this model? [y/N] '
IFS= read -r CONFIRM_DOWNLOAD

case "$CONFIRM_DOWNLOAD" in
  y | Y | yes | YES)
    ;;
  *)
    echo "Download cancelled."
    exit 0
    ;;
esac

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
  cd hamptus-mlx-swift-qwen3-tts/swift-only-poc
  swift run Qwen3TTSPoc

Run the streaming smoke test with:
  cd hamptus-mlx-swift-qwen3-tts/swift-only-poc
  swift run Qwen3TTSPoc --stream
EOF

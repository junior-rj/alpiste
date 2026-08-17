#!/usr/bin/env bash
# Installs Alpiste's runtime and build dependencies: ffmpeg, whisper.cpp, xcodegen,
# and the medium model.
set -euo pipefail

MODEL_DIR="$HOME/Library/Application Support/Alpiste/models"
MODEL="$MODEL_DIR/ggml-medium.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin"

command -v brew >/dev/null || { echo "Homebrew is required: https://brew.sh"; exit 1; }

echo "==> Installing ffmpeg, whisper-cpp, and xcodegen"
brew install ffmpeg whisper-cpp xcodegen

if [ -f "$MODEL" ]; then
  echo "==> Model already present at $MODEL"
else
  echo "==> Downloading ggml-medium.bin (~1.5 GB, this takes a while)"
  mkdir -p "$MODEL_DIR"
  # Download to a temp name so an interrupted transfer can't look like a valid model.
  curl -fL --progress-bar "$MODEL_URL" -o "$MODEL.partial"
  mv "$MODEL.partial" "$MODEL"
  echo "==> Saved to $MODEL"
fi

mkdir -p "$HOME/.alpiste"
if [ ! -f "$HOME/.alpiste/.env" ]; then
  cat > "$HOME/.alpiste/.env" <<'EOF'
# Notes generation. Free tier: https://aistudio.google.com/apikey
GEMINI_API_KEY=
# Optional, defaults to gemini-flash-latest
# GEMINI_MODEL=

# Optional transcription fallback, only used when the local model is missing.
# GROQ_API_KEY=
# OPENAI_API_KEY=
EOF
  chmod 600 "$HOME/.alpiste/.env"
  echo "==> Created $HOME/.alpiste/.env, add your GEMINI_API_KEY to it"
fi

echo
echo "Done. Next: xcodegen && xcodebuild -scheme Alpiste -configuration Release build"

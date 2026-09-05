#!/usr/bin/env bash
# Installs Alpiste's runtime and build dependencies: ffmpeg, whisper.cpp, xcodegen,
# and the medium model.
set -euo pipefail

MODEL_DIR="$HOME/Library/Application Support/Alpiste/models"
MODEL="$MODEL_DIR/ggml-medium.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin"
# From whisper.cpp's models/README.md. A 1.5 GB download that whisper-cli then parses as
# raw tensors is worth checking before it is trusted.
MODEL_SHA1="fd9727b6e1217c2f614f9b698455c4ffd82463b4"

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
  echo "==> Verifying checksum"
  echo "$MODEL_SHA1  $MODEL.partial" | shasum -a 1 -c - \
    || { echo "Checksum mismatch, keeping $MODEL.partial for inspection"; exit 1; }
  mv "$MODEL.partial" "$MODEL"
  echo "==> Saved to $MODEL"
fi

mkdir -p "$HOME/.alpiste"
chmod 700 "$HOME/.alpiste"
if [ ! -f "$HOME/.alpiste/.env" ]; then
  # umask first: the file must never exist world-readable, not even between the write
  # and the chmod below.
  (umask 077; cat > "$HOME/.alpiste/.env" <<'EOF'
# Notes generation, first choice. Free tier: https://console.groq.com/keys
# Also transcribes when the local whisper model is missing.
GROQ_API_KEY=
# Optional, defaults to openai/gpt-oss-120b. Groq retires models often; the current
# list is at https://api.groq.com/openai/v1/models
# GROQ_MODEL=

# Notes generation, fallback when Groq fails. Free tier: https://aistudio.google.com/apikey
# Capped at 20 requests a day, which is why it is second, but its context window is far
# larger, so it is the one that can still handle a very long meeting.
# GEMINI_API_KEY=
# Optional, defaults to gemini-flash-latest
# GEMINI_MODEL=

# Optional transcription fallback, only used when the local model is missing. Groq is
# tried first when its key is set; OpenAI otherwise.
# OPENAI_API_KEY=
# GROQ_WHISPER_MODEL=       # defaults to whisper-large-v3-turbo
# OPENAI_WHISPER_MODEL=     # defaults to whisper-1

# Language whisper is pinned to, defaults to pt. Deliberately not "auto": whisper
# detects from the first 30 seconds alone and applies that guess to the whole file,
# which once turned a 45 minute Portuguese meeting into an English translation.
# WHISPER_LANGUAGE=pt
EOF
  )
  chmod 600 "$HOME/.alpiste/.env"
  echo "==> Created $HOME/.alpiste/.env, add your GROQ_API_KEY to it"
fi

echo
echo "Done. Next: xcodegen && xcodebuild -scheme Alpiste -configuration Release build"

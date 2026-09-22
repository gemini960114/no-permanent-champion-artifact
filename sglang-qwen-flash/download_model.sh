#!/usr/bin/env bash
# ==============================================================================
# 模型權重下載腳本: Qwen3.8-Flash-Next-FP8
# ==============================================================================
umask 077
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/config.env" ]; then
    chmod 600 "$SCRIPT_DIR/config.env" 2>/dev/null || true
    source "$SCRIPT_DIR/config.env"
fi

MODEL_TARGET="${1:-${MODEL_NAME:-Qwen/Qwen3.8-Flash-Next-FP8}}"
TARGET_DIR="${MODELS_DIR:-/path/to/work/models}/$(basename "$MODEL_TARGET")"
CACHE_DIR="${HF_CACHE_DIR:-/path/to/work/huggingface_cache}"

echo "=========================================================="
echo " 📥 開始下載模型權重: $MODEL_TARGET"
echo " 🔹 存放目錄: $TARGET_DIR"
echo " 🔹 快取目錄: $CACHE_DIR"
echo "=========================================================="

mkdir -p "$TARGET_DIR" "$CACHE_DIR"

export HF_TOKEN="${HF_TOKEN:-}"
export HF_HOME="$CACHE_DIR"

if command -v hf >/dev/null 2>&1; then
    hf download "$MODEL_TARGET" --local-dir "$TARGET_DIR"
elif command -v huggingface-cli >/dev/null 2>&1; then
    huggingface-cli download "$MODEL_TARGET" --local-dir "$TARGET_DIR" --local-dir-use-symlinks False
else
    echo "❌ 錯誤：未找到 hf 或 huggingface-cli 命令行工具！" >&2
    exit 1
fi

echo "✅ 模型下載完成: $TARGET_DIR"

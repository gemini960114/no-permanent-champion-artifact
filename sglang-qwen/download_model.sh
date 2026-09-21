#!/usr/bin/env bash
# ==============================================================================
# Qwen 模型下載腳本 (download_model.sh)
# 支援下載 Qwen/Qwen3.8-27B 或 Qwen/Qwen3.8-27B-FP8
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 載入 config.env
if [ -f "$SCRIPT_DIR/config.env" ]; then
    source "$SCRIPT_DIR/config.env"
fi

MODELS_ROOT="${MODELS_DIR:-/path/to/work/models}"
TOKEN="${HF_TOKEN:-}"

# 預設下載使用者指定的 Qwen/Qwen3.8-27B，亦可透過參數指定
MODEL_REPO="${1:-Qwen/Qwen3.8-27B}"
TARGET_DIR="$MODELS_ROOT/$(basename "$MODEL_REPO")"

TOKEN_ARG=()
if [ -n "$TOKEN" ]; then
    TOKEN_ARG=(--token "$TOKEN")
fi

echo "========================================================"
echo "🚀 開始下載 HuggingFace 模型: $MODEL_REPO"
echo "📁 存放路徑: $TARGET_DIR"
echo "========================================================"

mkdir -p "$TARGET_DIR"

uvx --from huggingface_hub hf download \
    "$MODEL_REPO" \
    --local-dir "$TARGET_DIR" \
    "${TOKEN_ARG[@]}"

echo ""
echo "✅ 模型下載完成！存放於: $TARGET_DIR"

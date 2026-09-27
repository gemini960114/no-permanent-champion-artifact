#!/usr/bin/env bash
# ==============================================================================
# 模型權重下載腳本: GLM-5.3-Flash（與 sglang-qwen-27b 共享，常規無需下載）
# ==============================================================================
umask 077
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/config.env" ]; then
    chmod 600 "$SCRIPT_DIR/config.env" 2>/dev/null || true
    source "$SCRIPT_DIR/config.env"
fi

# 權重與 sglang-qwen-27b 共享；MODEL_NAME 带 -vLLM 後綴（Gateway 隔離用），實際下載對象為 FALLBACK_MODEL_NAME
MODEL_TARGET="${1:-${FALLBACK_MODEL_NAME:-Qwen/GLM-5.3-Flash}}"
if [ -z "${1:-}" ] && [ -z "${FALLBACK_MODEL_NAME:-}" ]; then MODEL_TARGET="Qwen/GLM-5.3-Flash"; fi
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

TOKEN_ARG=()
if [ -n "${HF_TOKEN:-}" ]; then
    TOKEN_ARG=(--token "$HF_TOKEN")
fi

if command -v uvx >/dev/null 2>&1; then
    uvx --from huggingface_hub hf download "$MODEL_TARGET" --local-dir "$TARGET_DIR" "${TOKEN_ARG[@]}"
elif command -v hf >/dev/null 2>&1; then
    hf download "$MODEL_TARGET" --local-dir "$TARGET_DIR" "${TOKEN_ARG[@]}"
elif command -v huggingface-cli >/dev/null 2>&1; then
    huggingface-cli download "$MODEL_TARGET" --local-dir "$TARGET_DIR" --local-dir-use-symlinks False "${TOKEN_ARG[@]}"
else
    echo "❌ 錯誤：未找到 uvx, hf 或 huggingface-cli 命令行工具！" >&2
    exit 1
fi

echo "✅ 模型下載完成: $TARGET_DIR"

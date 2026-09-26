#!/usr/bin/env bash
# ==============================================================================
# vLLM Qwen3.8-Flash-Next 狀態檢查腳本 (check_service.sh)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ -f "$SCRIPT_DIR/config.env" ]; then
    source "$SCRIPT_DIR/config.env"
fi

PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REGISTRY_DIR="$PROJECT_ROOT/runtime/endpoints"

echo "=========================================================="
echo " 🔍 vLLM Qwen3.8-Flash-Next 狀態監控"
echo "=========================================================="

echo "▶ 1. 目前執行中的 Slurm Job (vllm_flash_next):"
squeue -u "$USER" --name="vllm_flash_next" -o "%.10i %.9P %.14j %.8u %.2t %.10M %.6D %R" || true
echo ""

echo "▶ 2. 活躍端點註冊狀態 (runtime/endpoints/vllm_flash_next_*.env):"
FOUND_EP=false
if [ -d "$REGISTRY_DIR" ]; then
    for f in "$REGISTRY_DIR"/vllm_flash_next_*.env; do
        if [ -f "$f" ]; then
            FOUND_EP=true
            echo "📄 端點檔案: $(basename "$f")"
            cat "$f" | sed 's/^/   /'
            echo "----------------------------------------------------------"
        fi
    done
fi

if [ "$FOUND_EP" = false ]; then
    echo "  (目前無已註冊之活躍端點)"
fi
echo ""

echo "▶ 3. 最新執行紀錄尾端 (logs/vllm-flash-next-*.err):"
LATEST_ERR=$(ls -t logs/vllm-flash-next-*.err 2>/dev/null | head -n 1 || true)
if [ -n "$LATEST_ERR" ] && [ -f "$LATEST_ERR" ]; then
    echo "📄 日誌檔案: $LATEST_ERR"
    tail -n 15 "$LATEST_ERR" | sed 's/^/   /'
else
    echo "  (尚無日誌檔案)"
fi
echo "=========================================================="

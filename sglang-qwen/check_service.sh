#!/usr/bin/env bash
# ==============================================================================
# SGLang 服務狀態檢查工具 (check_service.sh)
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=================================================================="
echo "📋 SGLang Qwen 服務狀態檢查"
echo "=================================================================="

echo -e "\n▶ 1. 檢查 SLURM 作業佇列 (squeue)："
squeue -u "$(whoami)" --name=sglang_qwen -o "%.10i %.9P %.18j %.8u %.2t %.10M %.6D %R" || true

if [ -f "$SCRIPT_DIR/config.env" ]; then
    source "$SCRIPT_DIR/config.env"
fi

if [ -f "$SCRIPT_DIR/endpoint.info" ]; then
    echo -e "\n▶ 2. 最近一次啟動資訊 (endpoint.info)："
    cat "$SCRIPT_DIR/endpoint.info"
    
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/endpoint.info"
    
    echo -e "\n▶ 3. 測試節點連線健康狀態 (${ENDPOINT}/v1/models)："
    AUTH_HEADER=()
    if [ -n "${SGLANG_API_KEY:-}" ]; then
        AUTH_HEADER=(-H "Authorization: Bearer ${SGLANG_API_KEY}")
    fi

    RESP=$(curl -s -m 5 "${AUTH_HEADER[@]}" "${ENDPOINT}/v1/models" || true)
    if [ -n "$RESP" ] && echo "$RESP" | grep -q '"object":'; then
        echo "✅ SGLang 服務正常運作中！"
        echo "$RESP" | python3 -m json.tool || echo "$RESP"
    else
        echo "⏳ 服務連線未回應或認證未通過，請檢查日誌或稍候重試..."
    fi
else
    echo -e "\n⚠️ 尚未產生 endpoint.info，作業可能正在排隊中。"
fi

LATEST_LOG=$(ls -t logs/sglang-*.out 2>/dev/null | head -n1 || true)
if [ -n "$LATEST_LOG" ]; then
    echo -e "\n▶ 4. 最新執行日誌末尾 (tail -n 15 $LATEST_LOG)："
    echo "------------------------------------------------------------------"
    tail -n 15 "$LATEST_LOG"
fi

echo "=================================================================="

#!/usr/bin/env bash
# ==============================================================================
# SGLang 服務狀態檢查工具 (check_service.sh)
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENDPOINTS_DIR="$PROJECT_ROOT/runtime/endpoints"
cd "$SCRIPT_DIR"

echo "=================================================================="
echo "📋 SGLang Qwen 服務狀態檢查"
echo "=================================================================="

echo -e "\n▶ 1. 檢查 SLURM 作業佇列 (squeue)："
squeue -u "$(whoami)" --name=sglang_qwen -o "%.10i %.9P %.18j %.8u %.2t %.10M %.6D %R" || true

if [ -f "$SCRIPT_DIR/config.env" ]; then
    source "$SCRIPT_DIR/config.env"
fi

AUTH_HEADER=()
if [ -n "${SGLANG_API_KEY:-}" ]; then
    AUTH_HEADER=(-H "Authorization: Bearer ${SGLANG_API_KEY}")
fi

echo -e "\n▶ 2. 檢查端點註冊庫 ($ENDPOINTS_DIR)："
FOUND_ENDPOINTS=0
if [ -d "$ENDPOINTS_DIR" ]; then
    for ep_file in "$ENDPOINTS_DIR"/*.env; do
        [ -e "$ep_file" ] || continue
        ((FOUND_ENDPOINTS++))
        echo "------------------------------------------------------------------"
        echo "📄 端點登錄檔 : $(basename "$ep_file")"
        cat "$ep_file"
        
        EP_URL=$(grep "^ENDPOINT=" "$ep_file" | cut -d'=' -f2 | tr -d '\r\n')
        EP_STATE=$(grep "^STATE=" "$ep_file" | cut -d'=' -f2 | tr -d '\r\n')
        EP_JOB=$(grep "^SLURM_JOB_ID=" "$ep_file" | cut -d'=' -f2 | tr -d '\r\n')

        echo -e "\n▶ 3. 測試端點連線健康狀態 (${EP_URL}/v1/models)："
        if [ -n "$EP_URL" ]; then
            RESP=$(curl -s -m 5 "${AUTH_HEADER[@]}" "${EP_URL}/v1/models" || true)
            if [ -n "$RESP" ] && echo "$RESP" | grep -q '"object":'; then
                echo "✅ SGLang 服務正常運作中！(Job: $EP_JOB, State: $EP_STATE)"
                echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"
            else
                echo "⏳ 服務連線未回應或仍在啟動中 (Job: $EP_JOB, State: $EP_STATE)..."
            fi
        fi
    done
fi

if [ "$FOUND_ENDPOINTS" -eq 0 ]; then
    echo "⚠️ 目前端點註冊庫無任何活躍端點，作業可能正在排隊中或已結束。"
fi

LATEST_LOG=$(ls -t logs/sglang-*.out 2>/dev/null | head -n1 || true)
if [ -n "$LATEST_LOG" ]; then
    echo -e "\n▶ 4. 最新執行日誌末尾 (tail -n 15 $LATEST_LOG)："
    echo "------------------------------------------------------------------"
    tail -n 15 "$LATEST_LOG"
fi

echo "=================================================================="

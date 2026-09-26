#!/usr/bin/env bash
# ==============================================================================
# 一鍵啟動指定地端模型引擎 → 等待就緒 → 啟動 Gateway (start_models.sh)
# 用法：./start_models.sh <引擎目錄名>...   可指定多個
#       ./start_models.sh --list           列出所有可用引擎
# 範例：./start_models.sh sglang-qwen-27b sglang-qwen-flash
# 流程：對每個指定引擎 (1) 已在運行 → 跳過 (2) 執行該目錄 submit_slurm.sh
#       送出 Slurm job → 等待 endpoint STATE=ready → 最後啟動 Gateway
#       (start_background.sh)。未指定的引擎不會被啟動，也不需任何排除設定。
# 注意：Gateway 會於「執行本腳本的節點」啟動——請於固定部署節點執行
#       (現為 login-2，隧道目標綁定此節點)。
# ==============================================================================
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "$DIR"

WAIT_TIMEOUT="${WAIT_TIMEOUT:-1200}"   # 每個引擎等待就緒上限 (秒)
POLL_INTERVAL="${POLL_INTERVAL:-15}"   # 輪詢間隔 (秒)

# ------------------------------------------------------------------------------
# 輔助函式
# ------------------------------------------------------------------------------
list_engines() {
    echo "可用引擎 (engines/ 下含 submit_slurm.sh 之子目錄)："
    local d
    for d in engines/*/; do
        [ -f "$d/submit_slurm.sh" ] || continue
        local real tag=""
        real=$(realpath "$d")
        tag=$(grep -m1 '^#SBATCH --job-name=' "$real"/*server.slurm 2>/dev/null | sed 's/.*=//')
        printf "  • %-24s (job-name: %s)\n" "$(basename "$d")" "${tag:-未知}"
    done
}

usage() {
    echo "用法：$0 <引擎目錄名>...    例：$0 sglang-qwen-27b sglang-qwen-flash"
    echo "      $0 --list            列出所有可用引擎"
    list_engines
    exit 1
}

# ------------------------------------------------------------------------------
# 參數解析
# ------------------------------------------------------------------------------
[ $# -ge 1 ] || usage
if [ "${1:-}" = "--list" ]; then list_engines; exit 0; fi

# 節點安全檢查：Gateway 記錄於其他節點時，本機無法停止它 (PID 為節點區域)
CURRENT_NODE="$(hostname -s)"
RECORDED_NODE="$(cat "$DIR/.litellm_node" 2>/dev/null || true)"
if [ -n "$RECORDED_NODE" ] && [ "$RECORDED_NODE" != "$CURRENT_NODE" ]; then
    echo "❌ 錯誤：Gateway 記錄於 ${RECORDED_NODE} 執行，本機為 ${CURRENT_NODE}。"
    echo "   PID 是節點區域的——請先 ssh ${RECORDED_NODE} 執行 ./stop.sh 後，"
    echo "   再於目標節點執行本腳本。"
    exit 1
fi

# ------------------------------------------------------------------------------
# 逐一處理指定引擎
# ------------------------------------------------------------------------------
declare -a PENDING_JOBS=()   # "JOB_ID:引擎名"
FAILED=0

for ENGINE in "$@"; do
    ENGINE_DIR="$DIR/engines/$ENGINE"
    if [ ! -d "$ENGINE_DIR" ] || [ ! -f "$ENGINE_DIR/submit_slurm.sh" ]; then
        echo "❌ 引擎不存在或缺少 submit_slurm.sh：engines/$ENGINE"
        FAILED=1
        continue
    fi

    # 冪等檢查：該引擎已有運行中的 Slurm job 則跳過
    JOB_NAME=$(grep -m1 '^#SBATCH --job-name=' "$ENGINE_DIR"/*server.slurm 2>/dev/null | sed 's/.*=//')
    if [ -n "$JOB_NAME" ] && squeue -h -u "$(id -un)" -n "$JOB_NAME" 2>/dev/null | grep -q .; then
        echo "⏭️  $ENGINE：已有運行中的 job (${JOB_NAME})，跳過派送"
        continue
    fi

    echo "🚀 $ENGINE：派送 Slurm job..."
    SUBMIT_OUT=$(cd "$ENGINE_DIR" && ./submit_slurm.sh 2>&1) || {
        echo "❌ $ENGINE：派送失敗"
        echo "$SUBMIT_OUT" | sed 's/^/    /'
        FAILED=1
        continue
    }
    JOB_ID=$(echo "$SUBMIT_OUT" | grep -oE 'Submitted batch job [0-9]+' | grep -oE '[0-9]+' | head -1)
    if [ -z "$JOB_ID" ]; then
        echo "❌ $ENGINE：無法解析 Job ID"
        echo "$SUBMIT_OUT" | sed 's/^/    /'
        FAILED=1
        continue
    fi
    echo "   ✅ 已派送 (Job ${JOB_ID})"
    PENDING_JOBS+=("${JOB_ID}:${ENGINE}")
done

# ------------------------------------------------------------------------------
# 等待所有新派送引擎就緒 (endpoint STATE=ready 或 job 提前結束則失敗)
# ------------------------------------------------------------------------------
for ENTRY in "${PENDING_JOBS[@]:-}"; do
    [ -z "$ENTRY" ] && continue
    JOB_ID="${ENTRY%%:*}"
    ENGINE="${ENTRY#*:}"
    echo "⏳ $ENGINE (Job ${JOB_ID})：等待就緒 (上限 ${WAIT_TIMEOUT} 秒)..."
    ELAPSED=0
    while [ "$ELAPSED" -lt "$WAIT_TIMEOUT" ]; do
        EP_FILE=$(ls "$DIR"/runtime/endpoints/*_"${JOB_ID}".env 2>/dev/null | head -1)
        if [ -n "$EP_FILE" ] && grep -q "^STATE=ready" "$EP_FILE" 2>/dev/null; then
            echo "   ✅ READY ($(grep '^NODE_HOSTNAME=' "$EP_FILE" | cut -d= -f2))"
            continue 2
        fi
        # job 已消失且無 ready 端點 → 引擎啟動失敗 (逾時 scancel / 崩潰)
        if [ -z "$EP_FILE" ] && ! squeue -h -j "$JOB_ID" 2>/dev/null | grep -q .; then
            echo "   ❌ Job ${JOB_ID} 已結束但未發布就緒端點 (詳見 engines/$ENGINE/logs/)"
            FAILED=1
            continue 2
        fi
        sleep "$POLL_INTERVAL"
        ELAPSED=$((ELAPSED + POLL_INTERVAL))
    done
    echo "   ❌ 等待逾時 (${WAIT_TIMEOUT} 秒)，引擎未就緒"
    FAILED=1
done

# ------------------------------------------------------------------------------
# 啟動 Gateway (start_background.sh 會自動納入所有 ready 引擎)
# ------------------------------------------------------------------------------
echo "──────────────────────────────────────────"
if [ "$FAILED" -ne 0 ]; then
    echo "⚠️  部分引擎啟動失敗，Gateway 仍將以現有 ready 引擎啟動 (fail-tolerant)"
fi
echo "▶ 啟動 Gateway (@${CURRENT_NODE})..."
exec "$DIR/start_background.sh"

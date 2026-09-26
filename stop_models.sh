#!/usr/bin/env bash
# ==============================================================================
# 一鍵停止模型引擎 Slurm job (stop_models.sh)
# 用法：./stop_models.sh                    停止「所有」引擎
#       ./stop_models.sh sglang-qwen-27b   停止指定引擎（可多個）
#       ./stop_models.sh --list            列出各引擎運行狀態（不執行停止）
# 範例：./stop_models.sh sglang-qwen-27b sglang-qwen-flash
# 行為：
#   ① 依各引擎 slurm 的 --job-name 向 squeue 找出該引擎全部實例（含多實例）
#      ——validate_* 煙霧 job 名稱不同，不會被誤停
#   ② scancel 後等待退場 trap 清理 endpoint 檔（最多 30 秒）
#   ③ Gateway 不動——停止引擎後建議重啟 Gateway 刷新路由（./start_background.sh）
#      或一併停止 Gateway（./stop.sh）
# ==============================================================================
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "$DIR"

CLEANUP_WAIT="${CLEANUP_WAIT:-30}"

# ------------------------------------------------------------------------------
# 引擎探索（與 start_models.sh 一致：engines/ 下含 submit_slurm.sh 之子目錄，realpath 去重）
# ------------------------------------------------------------------------------
declare -a ALL_ENGINES=()
declare -A SEEN=()
for d in engines/*/; do
    [ -f "$d/submit_slurm.sh" ] || continue
    real=$(realpath "$d")
    [ -n "${SEEN[$real]:-}" ] && continue
    SEEN[$real]=1
    ALL_ENGINES+=("$(basename "$real")")   # 以真體目錄名顯示（避免 symlink 名混淆）
done

engine_tag() {
    grep -m1 '^#SBATCH --job-name=' "engines/$1"/*server.slurm 2>/dev/null | sed 's/.*=//'
}

engine_jobs() {  # 列出該 job-name 之下全部運行中 job ID
    local tag="$1"
    [ -n "$tag" ] || return 0
    squeue -h -u "$(id -un)" -n "$tag" -o "%i" 2>/dev/null
}

list_status() {
    echo "各引擎運行狀態："
    local e tag jobs
    for e in "${ALL_ENGINES[@]:-}"; do
        [ -z "$e" ] && continue
        tag=$(engine_tag "$e"); jobs=$(engine_jobs "$tag")
        if [ -n "$jobs" ]; then
            echo "  🟢 $e (job: $(echo "$jobs" | tr '\n' ' '))"
        else
            echo "  ⚪ $e"
        fi
    done
}

# ------------------------------------------------------------------------------
# 參數解析
# ------------------------------------------------------------------------------
if [ "${1:-}" = "--list" ]; then list_status; exit 0; fi

TARGETS=()
if [ $# -eq 0 ]; then
    TARGETS=("${ALL_ENGINES[@]:-}")
    echo "🎯 未指定引擎——停止「所有」引擎"
else
    for a in "$@"; do
        if [ ! -d "engines/$a" ]; then
            echo "❌ 引擎不存在：engines/$a"
            list_status
            exit 1
        fi
        TARGETS+=("$a")
    done
fi

# ------------------------------------------------------------------------------
# 停止
# ------------------------------------------------------------------------------
STOPPED=0
for e in "${TARGETS[@]:-}"; do
    [ -z "$e" ] && continue
    tag=$(engine_tag "$e")
    jobs=$(engine_jobs "$tag")
    if [ -z "$jobs" ]; then
        echo "⚪ $e：無運行中的 job"
        continue
    fi
    for j in $jobs; do
        echo "🛑 $e：停止 Job ${j} (job-name: ${tag})"
        scancel "$j" && STOPPED=$((STOPPED+1))
    done
done

# ------------------------------------------------------------------------------
# 等待退場清理（endpoint 檔由引擎 trap 自行移除）
# ------------------------------------------------------------------------------
if [ "$STOPPED" -gt 0 ]; then
    echo "⏳ 等待退場清理（最多 ${CLEANUP_WAIT} 秒）..."
    ELAPSED=0
    while [ "$ELAPSED" -lt "$CLEANUP_WAIT" ]; do
        REMAIN=$(ls runtime/endpoints/*.env 2>/dev/null | wc -l)
        [ "$REMAIN" -eq 0 ] && break
        sleep 3; ELAPSED=$((ELAPSED + 3))
    done
fi

echo "──────────────────────────────────────────"
echo "📊 結果：已停止 ${STOPPED} 個 job"
list_status
echo ""
echo "ℹ️  Gateway 未變動——後續擇一："
echo "   • 重啟刷新路由（引擎已停的模型自路由移除）：./start_background.sh"
echo "   • 一併停止 Gateway：./stop.sh"

#!/usr/bin/env bash
# ==============================================================================
# SGLang SLURM 任務派送腳本 (submit_slurm.sh)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ -f "$SCRIPT_DIR/config.env" ]; then
    chmod 600 "$SCRIPT_DIR/config.env" 2>/dev/null || true
    source "$SCRIPT_DIR/config.env"
fi


PARTITION="${SLURM_PARTITION:-8gpus}"
ACCOUNT="${SLURM_ACCOUNT:-your-slurm-account}"
GPUS="${SLURM_GPUS:-1}"
CPUS="${SLURM_CPUS:-12}"
MEM="${SLURM_MEM:-120G}"
TIME="${SLURM_TIME:-24:00:00}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--partition)
            PARTITION="$2"
            shift 2
            ;;
        -a|--account)
            ACCOUNT="$2"
            shift 2
            ;;
        -g|--gpus)
            GPUS="$2"
            shift 2
            ;;
        -c|--cpus)
            CPUS="$2"
            shift 2
            ;;
        -m|--mem)
            MEM="$2"
            shift 2
            ;;
        -t|--time)
            TIME="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            if [[ "$1" != -* ]]; then
                PARTITION="$1"
                shift
            else
                echo "未知參數: $1"
                shift
            fi
            ;;
    esac
done

echo "=================================================================="
echo "🚀 準備派送 SGLang Qwen3.8-27B 服務至 SLURM"
echo "=================================================================="
echo "🔹 分割區 (Partition) : $PARTITION"
echo "🔹 計費專案 (Account) : $ACCOUNT"
echo "🔹 GPU 配置           : $GPUS Core H200 GPU (--gres=gpu:H200:$GPUS)"
echo "🔹 CPU / RAM          : $CPUS Cores / $MEM"
echo "🔹 執行時間上限       : $TIME"
echo "🔹 服務連接埠 (Port)  : ${PORT:-30000}"
echo "=================================================================="

SBATCH_ARGS=(
    --partition="$PARTITION"
    --account="$ACCOUNT"
    --gres="gpu:H200:$GPUS"
    --cpus-per-task="$CPUS"
    --mem="$MEM"
    --time="$TIME"
    --chdir="$SCRIPT_DIR"
)

if [ "$DRY_RUN" = true ]; then
    echo "[Dry-Run] 預覽 sbatch 提交指令："
    echo "sbatch ${SBATCH_ARGS[*]} sglang_server.slurm"
    exit 0
fi

JOB_OUTPUT=$(sbatch "${SBATCH_ARGS[@]}" sglang_server.slurm)
echo "✅ $JOB_OUTPUT"

JOB_ID=$(echo "$JOB_OUTPUT" | grep -o '[0-9]*' | tail -n1)
echo ""
echo "💡 提示："
echo "  • 查詢作業狀態 : squeue -j $JOB_ID"
echo "  • 即時查看日誌 : tail -f logs/sglang-sglang_qwen-${JOB_ID}.out"
echo "  • 檢查服務狀態 : ./check_service.sh"
echo "  • 取消/停止作業: scancel $JOB_ID"

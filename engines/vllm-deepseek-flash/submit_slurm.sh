#!/usr/bin/env bash
# ==============================================================================
# vLLM DeepSeek-V4.1-Flash SLURM 任務派送腳本 (submit_slurm.sh)
# ==============================================================================
umask 077
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
mkdir -p -m 700 "$SCRIPT_DIR/logs"
chmod 700 "$SCRIPT_DIR/logs" 2>/dev/null || true

if [ -f "$SCRIPT_DIR/config.env" ]; then
    chmod 600 "$SCRIPT_DIR/config.env" 2>/dev/null || true
    source "$SCRIPT_DIR/config.env"
fi

PARTITION="${SLURM_PARTITION:-8gpus}"
ACCOUNT="${SLURM_ACCOUNT:-your-slurm-account}"
GPUS="${SLURM_GPUS:-2}"
CPUS="${SLURM_CPUS:-24}"
MEM="${SLURM_MEM:-180G}"
TIME="${SLURM_TIME:-24:00:00}"
NODELIST=""
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
        -w|--nodelist)
            NODELIST="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            echo "用法: $0 [選項]"
            echo "選項:"
            echo "  -p, --partition <PARTITION>  指定 SLURM 分區 (預設: $PARTITION)"
            echo "  -a, --account <ACCOUNT>      指定計畫代號 (預設: $ACCOUNT)"
            echo "  -g, --gpus <NUM>             指定 GPU 數量 (預設: $GPUS)"
            echo "  -c, --cpus <NUM>             指定 CPU 核心數 (預設: $CPUS)"
            echo "  -m, --mem <SIZE>             指定記憶體大小 (預設: $MEM)"
            echo "  -t, --time <DURATION>        指定執行時間 (預設: $TIME)"
            echo "  -w, --nodelist <NODE>        指定執行節點 (例如 node-A)"
            echo "  --dry-run                    僅印出 sbatch 指令，不實際提交"
            exit 0
            ;;
        *)
            echo "❌ 未知選項: $1" >&2
            exit 1
            ;;
    esac
done

SBATCH_ARGS=(
    "--account=${ACCOUNT}"
    "--partition=${PARTITION}"
    "--gres=gpu:H200:${GPUS}"
    "--cpus-per-task=${CPUS}"
    "--mem=${MEM}"
    "--time=${TIME}"
)

if [ -n "$NODELIST" ]; then
    SBATCH_ARGS+=("--nodelist=${NODELIST}")
fi

echo "=========================================================="
echo " 🚀 準備派送 vLLM DeepSeek-V4.1-Flash 作業到 SLURM"
echo "=========================================================="
echo " 🔹 計畫代號 (Account)   : $ACCOUNT"
echo " 🔹 分區名稱 (Partition) : $PARTITION"
echo " 🔹 GPU 資源 (GPUs)      : ${GPUS}x H200 GPU (TP=2)"
echo " 🔹 CPU 核心 (CPUs)      : $CPUS"
echo " 🔹 記憶體   (Memory)    : $MEM"
echo " 🔹 最大時限 (Time)      : $TIME"
[ -n "$NODELIST" ] && echo " 🔹 指定節點 (Node)      : $NODELIST"
echo "=========================================================="

if [ "$DRY_RUN" = true ]; then
    echo "🔍 [Dry Run] 預計執行指令:"
    echo "sbatch ${SBATCH_ARGS[*]} vllm_server.slurm"
    exit 0
fi

JOB_OUTPUT=$(sbatch "${SBATCH_ARGS[@]}" vllm_server.slurm)
echo "✅ $JOB_OUTPUT"

JOB_ID=$(echo "$JOB_OUTPUT" | grep -oE '[0-9]+' | head -n 1)
echo "=========================================================="
echo " 🎉 任務派送成功！Job ID: $JOB_ID"
echo " 💡 可執行 ./check_service.sh 監控啟動狀態"
echo "=========================================================="

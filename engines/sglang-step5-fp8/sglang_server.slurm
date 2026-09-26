#!/bin/bash
# ==============================================================================
# SLURM 核心派送腳本: SGLang Step-5-Preview-FP8 on 8x H200 GPU (TP=8, EP=8)
# ==============================================================================
#SBATCH --job-name=sglang_step5_fp8
#SBATCH --partition=8gpus
#SBATCH --account=your-slurm-account
#SBATCH --nodes=1
#SBATCH --gres=gpu:H200:8
#SBATCH --cpus-per-task=96
#SBATCH --mem=480G
#SBATCH --time=24:00:00
#SBATCH --output=logs/sglang-flash-%x-%j.out
#SBATCH --error=logs/sglang-flash-%x-%j.err

umask 077
set -eo pipefail

# 1. 確保工作目錄
WORK_DIR="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
if [[ "$WORK_DIR" == *"/var/spool/slurmd"* ]] || [ ! -w "$WORK_DIR" ]; then
    WORK_DIR="/path/to/work/github/litellm-proxy/engines/sglang-step5-fp8"
fi
cd "$WORK_DIR"
mkdir -p -m 700 logs
chmod 700 logs 2>/dev/null || true

# 載入設定檔
if [ -f "$WORK_DIR/config.env" ]; then
    chmod 600 "$WORK_DIR/config.env" 2>/dev/null || true
    source "$WORK_DIR/config.env"
fi

# 2. 載入 Singularity 環境
SINGULARITY_BIN=""
for cmd in /usr/bin/singularity /usr/bin/apptainer singularity apptainer; do
    if command -v "$cmd" >/dev/null 2>&1; then
        SINGULARITY_BIN="$(command -v "$cmd")"
        break
    fi
done

if [ -z "$SINGULARITY_BIN" ]; then
    export PATH="/work/envstack/apps/singularity/4.3.7/bin:$PATH"
    SINGULARITY_BIN="$(command -v singularity || true)"
fi

if [ -z "$SINGULARITY_BIN" ]; then
    echo "❌ 錯誤：計算節點上找不到 singularity 執行檔！" >&2
    exit 1
fi

SIF_FILE="${SIF_PATH:-/path/to/work/containers/sglang_latest.sif}"
if [ ! -f "$SIF_FILE" ]; then
    echo "❌ 錯誤：找不到容器映像檔 $SIF_FILE" >&2
    exit 1
fi

# 3. 檢查與解析模型權重路徑
MODEL_DIR="${MODELS_DIR:-/path/to/work/models}"
MODEL_TARGET="${MODEL_NAME:-Qwen/Qwen3.8-Flash-Next-FP8}"
RESOLVED_MODEL_PATH=""

if [ -d "$MODEL_DIR/$(basename "$MODEL_TARGET")" ]; then
    RESOLVED_MODEL_PATH="$MODEL_DIR/$(basename "$MODEL_TARGET")"
elif [ -d "$MODEL_DIR/$MODEL_TARGET" ]; then
    RESOLVED_MODEL_PATH="$MODEL_DIR/$MODEL_TARGET"
elif [ -n "${FALLBACK_MODEL_NAME:-}" ] && [ -d "$MODEL_DIR/$(basename "$FALLBACK_MODEL_NAME")" ]; then
    RESOLVED_MODEL_PATH="$MODEL_DIR/$(basename "$FALLBACK_MODEL_NAME")"
else
    RESOLVED_MODEL_PATH="$MODEL_TARGET"
fi

# 4. 取得計算節點網路與端點註冊目錄
NODE_HOSTNAME=$(hostname -s)
NODE_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1 || echo "127.0.0.1")
PROJECT_ROOT="$(cd "$WORK_DIR/../.." && pwd)"
REGISTRY_DIR="$PROJECT_ROOT/runtime/endpoints"
PORT_LOCKS_DIR="$PROJECT_ROOT/runtime/port-locks"
mkdir -p -m 700 "$REGISTRY_DIR" "$PORT_LOCKS_DIR"
chmod 700 "$REGISTRY_DIR" "$PORT_LOCKS_DIR" 2>/dev/null || true

ENDPOINT_REGISTRY_FILE="$REGISTRY_DIR/sglang_flash_${SLURM_JOB_ID:-manual}.env"
ENGINE_NAME="sglang_step5_fp8"

# 5. 載入通用生命週期函式庫 (優先使用頂層 lib/lifecycle.sh)
LIB_LIFECYCLE="${PROJECT_ROOT}/lib/lifecycle.sh"
if [ ! -f "$LIB_LIFECYCLE" ]; then
    LIB_LIFECYCLE="$WORK_DIR/../../lib/lifecycle.sh"
fi
source "$LIB_LIFECYCLE"

# 6. 動態可用 Port 偵測與搶佔
PORT_BASE="${PORT:-34000}"
CURRENT_PORT_LOCK=""
find_available_port "$PORT_BASE" 100

# 7. 設定退場安全陷阱
trap cleanup_endpoint TERM INT EXIT

echo "=================================================================="
echo "🚀 SGLang Step-5-Preview-FP8 服務正在啟動"
echo "=================================================================="
echo "🔹 Job ID       : ${SLURM_JOB_ID:-N/A}"
echo "🔹 執行節點     : $NODE_HOSTNAME ($NODE_IP)"
echo "🔹 GPU 資源     : 8x H200 GPU (TP=8)"
echo "🔹 模型路徑     : $RESOLVED_MODEL_PATH"
echo "🔹 容器映像檔   : $SIF_FILE"
echo "🔹 服務端點     : http://${NODE_HOSTNAME}:${PORT} (內網 IP: http://${NODE_IP}:${PORT})"
echo "🔹 Port Lock    : $CURRENT_PORT_LOCK"
echo "🔹 開始時間     : $(date)"
echo "=================================================================="

publish_endpoint "starting"

# 背景非同步自檢健康檢查 (逾時 HEALTH_TIMEOUT 秒，預設 600，未就緒則主動終止釋放 GPU)
(
    AUTH_HEADER=()
    if [ -n "${SGLANG_API_KEY:-}" ]; then
        AUTH_HEADER=(-H "Authorization: Bearer ${SGLANG_API_KEY}")
    fi
    HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-600}"
    TMP_BODY=$(mktemp)
    trap 'rm -f "$TMP_BODY"' EXIT
    for i in $(seq 1 $(( HEALTH_TIMEOUT / 2 ))); do
        sleep 2
        HTTP_CODE=$(curl -sS -m 4 -o "$TMP_BODY" -w "%{http_code}" "${AUTH_HEADER[@]}" "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null || echo "000")
        if validate_health_response "$HTTP_CODE" "$TMP_BODY"; then
            echo "✅ [Job ${SLURM_JOB_ID:-N/A}] SGLang Step-5 健康自檢通過 (Port $PORT HTTP 200/JSON 合規)，發布狀態為 ready"
            publish_endpoint "ready"
            rm -f "$TMP_BODY"
            exit 0
        fi
    done
    rm -f "$TMP_BODY"
    echo "❌ [Job ${SLURM_JOB_ID:-N/A}] SGLang Step-5 自檢逾時 (Port $PORT，逾時 ${HEALTH_TIMEOUT} 秒)，主動終止服務釋放 GPU 資源" >&2
    # SERVER_PID 於本子殼啟動後才設定，子殼內拿不到；$$ 在子殼內即為主 shell 之 PID，
    # 對其送 TERM 可靠觸發 cleanup_endpoint trap (清理端點檔與 Port 鎖)
    if [ -n "${SLURM_JOB_ID:-}" ]; then
        scancel "${SLURM_JOB_ID}" 2>/dev/null || kill -TERM "$$" 2>/dev/null || true
    else
        kill -TERM "$$" 2>/dev/null || true
    fi
    exit 1
) &
HEALTH_PID=$!

# 啟動 SGLang Serve
# 注意：Step-5 為 Sparse GQA Transformer MoE（非 hybrid Mamba）——不使用 linear-attn 系列
# 參數；MTP 投機解碼（image 內含 step3p5_mtp.py）俟官方參數確認後再實驗開啟
CMD=(
  "$SINGULARITY_BIN" exec
  --nv
  --bind /work:/work
  "$SIF_FILE"
  /opt/sglang/bin/sglang serve
    --trust-remote-code
    --model-path "$RESOLVED_MODEL_PATH"
    --tp "${TP:-8}"
    --ep "${EP:-8}"
    --mem-fraction-static "${MEM_FRACTION:-0.90}"
    --chunked-prefill-size "${CHUNKED_PREFILL_SIZE:-8192}"
    --context-length "${CONTEXT_LENGTH:-262144}"
    --reasoning-parser "${REASONING_PARSER:-step3p5}"
    --host "${HOST:-0.0.0.0}"
    --port "$PORT"
)

if [ -n "${SGLANG_API_KEY:-}" ]; then
    CMD+=(--api-key "$SGLANG_API_KEY")
fi

# 併發上限：投機解碼 (NEXTN) 開啟時 sglang 預設會自動降為 48，
# 設定 MAX_RUNNING_REQUESTS 可明確覆蓋（記憶體允許的前提下提高總吞吐）
if [ -n "${MAX_RUNNING_REQUESTS:-}" ]; then
    CMD+=(--max-running-requests "$MAX_RUNNING_REQUESTS")
fi

# 顯示啟動指令時遮罩 --api-key 值，避免金鑰寫入 Slurm log
DISPLAY_CMD="${CMD[*]}"
echo "🔹 執行啟動指令: ${DISPLAY_CMD//--api-key */--api-key <masked>}"
"${CMD[@]}" &
SERVER_PID=$!

wait "$SERVER_PID"
cleanup_endpoint

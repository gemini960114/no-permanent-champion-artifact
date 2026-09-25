#!/bin/bash
# ==============================================================================
# SLURM 核心派送腳本: SGLang Qwen3.8-27B on 1x H200 GPU
# ==============================================================================
#SBATCH --job-name=sglang_qwen
#SBATCH --partition=8gpus
#SBATCH --account=your-slurm-account
#SBATCH --nodes=1
#SBATCH --gres=gpu:H200:1
#SBATCH --cpus-per-task=12
#SBATCH --mem=120G
#SBATCH --time=24:00:00
#SBATCH --output=logs/sglang-%x-%j.out
#SBATCH --error=logs/sglang-%x-%j.err

umask 077
set -eo pipefail

# 1. 確保工作目錄 (SLURM 計算節點上 BASH_SOURCE 會指向 /var/spool/slurmd，故優先採用 SLURM_SUBMIT_DIR)
WORK_DIR="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
if [[ "$WORK_DIR" == *"/var/spool/slurmd"* ]] || [ ! -w "$WORK_DIR" ]; then
    WORK_DIR="/path/to/work/github/litellm-proxy/engines/sglang-qwen-27b"
fi
cd "$WORK_DIR"
mkdir -p -m 700 logs
chmod 700 logs 2>/dev/null || true

# 載入設定檔
if [ -f "$WORK_DIR/config.env" ]; then
    chmod 600 "$WORK_DIR/config.env" 2>/dev/null || true
    source "$WORK_DIR/config.env"
fi


# 2. 載入 Singularity 環境 (優先使用宿主機 /usr/bin/singularity 或 apptainer，具備完整的 NVIDIA Driver 580 / CUDA 13 掛載支援)
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
    echo "❌ 錯誤：計算節點上找不到 singularity 執行檔！"
    exit 1
fi
echo "🔹 Singularity 執行檔: $SINGULARITY_BIN"

SIF_FILE="${SIF_PATH:-/path/to/work/containers/sglang_latest.sif}"
if [ ! -f "$SIF_FILE" ]; then
    echo "❌ 錯誤：找不到容器映像檔 $SIF_FILE"
    exit 1
fi

# 3. 搜尋模型路徑 (優先尋找已下載的本地路徑，若無則依 HF 庫名)
RESOLVED_MODEL_PATH=""
CANDIDATES=(
    "${MODELS_DIR:-/path/to/work/models}/Qwen3.8-27B-FP8"
    "${MODELS_DIR:-/path/to/work/models}/Qwen3.8-27B"
    "${MODELS_DIR:-/path/to/work/models}/$(basename "${MODEL_NAME:-Qwen/Qwen3.8-27B-FP8}")"
)

for c in "${CANDIDATES[@]}"; do
    if [ -d "$c" ]; then
        RESOLVED_MODEL_PATH="$c"
        break
    fi
done

if [ -z "$RESOLVED_MODEL_PATH" ]; then
    RESOLVED_MODEL_PATH="${MODEL_NAME:-Qwen/Qwen3.8-27B-FP8}"
fi

NODE_HOSTNAME="$(hostname)"
NODE_IP="$(hostname -I | awk '{print $1}')"

# ------------------------------------------------------------------------------
# 端點登錄檔 (Endpoint Registry) 與 Port 原子鎖目錄
# ------------------------------------------------------------------------------
PROJECT_ROOT="$(cd "$WORK_DIR/../.." && pwd)"
REGISTRY_DIR="$PROJECT_ROOT/runtime/endpoints"
PORT_LOCKS_DIR="$PROJECT_ROOT/runtime/port-locks"
mkdir -p -m 700 "$REGISTRY_DIR" "$PORT_LOCKS_DIR" 2>/dev/null || true
chmod 700 "$REGISTRY_DIR" "$PORT_LOCKS_DIR" 2>/dev/null || true

ENDPOINT_REGISTRY_FILE="$REGISTRY_DIR/sglang_qwen_${SLURM_JOB_ID:-manual}.env"
CURRENT_PORT_LOCK=""
HEALTH_PID=""
SERVER_PID=""

# ------------------------------------------------------------------------------
# 載入生命週期共用函式庫 (Port 原子鎖、兩階段發布、退場清理與健康驗證)
# 注意：在 SLURM 計算節點上 BASH_SOURCE[0] 指向 /var/spool/slurmd，故必須使用 $WORK_DIR
# ------------------------------------------------------------------------------
LIB_LIFECYCLE="${SGLANG_LIFECYCLE_LIB:-$WORK_DIR/lib/lifecycle.sh}"
if [ -f "$LIB_LIFECYCLE" ]; then
    # shellcheck source=/dev/null
    source "$LIB_LIFECYCLE"
else
    echo "❌ 錯誤：找不到生命週期共用函式庫 $LIB_LIFECYCLE" >&2
    exit 1
fi

BASE_PORT="${PORT:-30000}"
PORT=""
find_available_port "$BASE_PORT"
if [ -z "${PORT:-}" ] || [ -z "${CURRENT_PORT_LOCK:-}" ]; then
    echo "❌ 錯誤：無法成功鎖定可用 Port！" >&2
    exit 1
fi

trap cleanup_endpoint TERM INT EXIT

echo "=================================================================="
echo "🚀 SGLang Qwen3.8-27B 服務正在啟動"
echo "=================================================================="
echo "🔹 Job ID       : ${SLURM_JOB_ID:-N/A}"
echo "🔹 執行節點     : $NODE_HOSTNAME ($NODE_IP)"
echo "🔹 GPU 資源     : 1x H200 GPU (${SLURM_JOB_GPUS:-0})"
echo "🔹 模型路徑     : $RESOLVED_MODEL_PATH"
echo "🔹 容器映像檔   : $SIF_FILE"
echo "🔹 服務端點     : http://${NODE_HOSTNAME}:${PORT} (內網 IP: http://${NODE_IP}:${PORT})"
echo "🔹 Port Lock    : $CURRENT_PORT_LOCK"
echo "🔹 開始時間     : $(date)"
echo "=================================================================="

# 1. 初始發布狀態為 starting (此狀態下合成器嚴格忽略，不上線)
publish_endpoint "starting"

# 2. 背景非同步自檢健康檢查：嚴格要求 HTTP 200 與合法 JSON 回應才標記 ready；
#    逾時 (HEALTH_TIMEOUT 秒，預設 600) 未就緒則主動終止服務釋放 GPU 資源
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
            echo "✅ [Job ${SLURM_JOB_ID:-N/A}] SGLang 健康自檢通過 (Port $PORT 回應 HTTP 200 且 JSON 合法)，發布狀態正式為 ready"
            publish_endpoint "ready"
            rm -f "$TMP_BODY"
            exit 0
        fi
    done
    rm -f "$TMP_BODY"
    echo "❌ [Job ${SLURM_JOB_ID:-N/A}] SGLang 健康自檢逾時未就緒 (Port $PORT，逾時 ${HEALTH_TIMEOUT} 秒)，主動終止服務釋放 GPU 資源" >&2
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

# 4. 透過 Singularity 啟動 SGLang Serve
CMD=(
  "$SINGULARITY_BIN" exec
  --nv
  --bind /work:/work
  "$SIF_FILE"
  /opt/sglang/bin/sglang serve
    --trust-remote-code
    --model-path "$RESOLVED_MODEL_PATH"
    --kv-cache-dtype "${KV_CACHE_DTYPE:-fp8_e4m3}"
    --mem-fraction-static "${MEM_FRACTION:-0.85}"
    --attention-backend "${ATTENTION_BACKEND:-flashinfer}"
    --chunked-prefill-size "${CHUNKED_PREFILL_SIZE:-32768}"
    --max-prefill-tokens "${MAX_PREFILL_TOKENS:-32768}"
    --reasoning-parser "${REASONING_PARSER:-qwen3}"
    --tool-call-parser "${TOOL_CALL_PARSER:-qwen3_coder}"
    --mamba-full-memory-ratio "${MAMBA_FULL_MEMORY_RATIO:-4.59}"
    --host "${HOST:-0.0.0.0}"
    --port "$PORT"
    --mamba-radix-cache-strategy "${MAMBA_RADIX_CACHE_STRATEGY:-extra_buffer}"
    --mamba-ssm-dtype "${MAMBA_SSM_DTYPE:-float32}"
)

if [ -n "${SGLANG_API_KEY:-}" ]; then
  echo "🔒 SGLang API Key 鑑權保護已啟用"
  export SINGULARITYENV_SGLANG_API_KEY="$SGLANG_API_KEY"
  export SGLANG_API_KEY="$SGLANG_API_KEY"
  CMD+=(--api-key "$SGLANG_API_KEY")
fi

# 置於背景並由 Bash 監聽信號以確保 trap 於 scancel 時能可靠執行
"${CMD[@]}" &
SERVER_PID=$!
wait "$SERVER_PID"



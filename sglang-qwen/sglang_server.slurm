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
    WORK_DIR="/path/to/work/github/litellm-proxy/sglang-qwen"
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
PROJECT_ROOT="$(cd "$WORK_DIR/.." && pwd)"
REGISTRY_DIR="$PROJECT_ROOT/runtime/endpoints"
PORT_LOCKS_DIR="$PROJECT_ROOT/runtime/port-locks"
mkdir -p -m 700 "$REGISTRY_DIR" "$PORT_LOCKS_DIR" 2>/dev/null || true
chmod 700 "$REGISTRY_DIR" "$PORT_LOCKS_DIR" 2>/dev/null || true

ENDPOINT_REGISTRY_FILE="$REGISTRY_DIR/sglang_qwen_${SLURM_JOB_ID:-manual}.env"
CURRENT_PORT_LOCK=""

# ------------------------------------------------------------------------------
# 動態可用 Port 偵測：以 POSIX 原生原子操作 (mkdir) 徹底消除 Race Condition
# ------------------------------------------------------------------------------
find_available_port() {
    local candidate="${1:-30000}"
    local max_attempts=100
    local attempt=0
    while [ "$attempt" -lt "$max_attempts" ]; do
        local lock_dir="$PORT_LOCKS_DIR/${NODE_HOSTNAME}-${candidate}"

        # 1. 嘗試原子搶佔 Port 鎖目錄 (mkdir 為系統呼叫層級的原子操作)
        if mkdir -m 700 "$lock_dir" 2>/dev/null; then
            # 搶鎖成功！進一步檢驗實體 Socket 是否確無被其他孤兒程序佔用
            if python3 -c "
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    s.bind(('0.0.0.0', int(sys.argv[1])))
    s.close()
    sys.exit(0)
except OSError:
    sys.exit(1)
" "$candidate" 2>/dev/null; then
                # 實體 Socket 與原子鎖均確認就緒，記錄擁有者資訊
                echo "${SLURM_JOB_ID:-manual}" > "$lock_dir/job_id"
                date -u +"%Y-%m-%dT%H:%M:%SZ" > "$lock_dir/created_at"
                CURRENT_PORT_LOCK="$lock_dir"
                echo "$candidate"
                return 0
            else
                # 實體被佔用，撤銷此鎖
                rm -rf "$lock_dir" 2>/dev/null || true
            fi
        fi

        echo "⚠️ Port $candidate 在節點 $NODE_HOSTNAME 上已被預約或佔用，嘗試下一個 Port $((candidate + 1))..." >&2
        ((candidate++))
        ((attempt++))
    done
    echo "❌ 錯誤：找不到可用 Port (嘗試至 $candidate)" >&2
    return 1
}

BASE_PORT="${PORT:-30000}"
ACTUAL_PORT=$(find_available_port "$BASE_PORT")
PORT="$ACTUAL_PORT"

publish_endpoint() {
    local state="${1:-ready}"
    local tmp_file="$REGISTRY_DIR/sglang_qwen_${SLURM_JOB_ID:-manual}.env.tmp.$$"
    cat > "$tmp_file" <<EOF
MODEL_NAME=Qwen3.8-27B
MODEL_ALIAS=qwen3.8
RESOLVED_MODEL_PATH=${RESOLVED_MODEL_PATH}
NODE_HOSTNAME=${NODE_HOSTNAME}
NODE_IP=${NODE_IP}
PORT=${PORT}
ENDPOINT=http://${NODE_HOSTNAME}:${PORT}
API_BASE=http://${NODE_HOSTNAME}:${PORT}/v1
SLURM_JOB_ID=${SLURM_JOB_ID:-N/A}
STATE=${state}
UPDATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
    mv -f "$tmp_file" "$ENDPOINT_REGISTRY_FILE"
    chmod 600 "$ENDPOINT_REGISTRY_FILE" 2>/dev/null || true
}

cleanup_endpoint() {
    echo "🛑 SGLang 服務正在停止 (Job: ${SLURM_JOB_ID:-N/A})..."
    if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill -TERM "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    if [ -f "$ENDPOINT_REGISTRY_FILE" ]; then
        rm -f "$ENDPOINT_REGISTRY_FILE" 2>/dev/null || true
    fi
    if [ -n "${CURRENT_PORT_LOCK:-}" ] && [ -d "$CURRENT_PORT_LOCK" ]; then
        rm -rf "$CURRENT_PORT_LOCK" 2>/dev/null || true
    fi
}
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
echo "🔹 開始時間     : $(date)"
echo "=================================================================="

# 1. 初始發布狀態為 starting (此狀態下合成器嚴格忽略，不上線)
publish_endpoint "starting"

# 2. 輸出節點資訊至檔案 (保留向後相容性)
cat > "$WORK_DIR/endpoint.info" <<EOF
JOB_ID=${SLURM_JOB_ID:-N/A}
NODE=${NODE_HOSTNAME}
IP=${NODE_IP}
PORT=${PORT}
ENDPOINT=http://${NODE_HOSTNAME}:${PORT}
ENDPOINT_IP=http://${NODE_IP}:${PORT}
API_KEY_PROTECTED=$([ -n "${SGLANG_API_KEY:-}" ] && echo "true" || echo "false")
START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
EOF

# 3. 背景非同步自檢健康檢查：嚴格要求 HTTP 200 與合法 JSON 回應才標記 ready
(
    AUTH_HEADER=()
    if [ -n "${SGLANG_API_KEY:-}" ]; then
        AUTH_HEADER=(-H "Authorization: Bearer ${SGLANG_API_KEY}")
    fi
    for i in $(seq 1 180); do
        sleep 2
        HTTP_CODE=$(curl -s -m 4 -w "%{http_code}" -o /dev/null "${AUTH_HEADER[@]}" "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" = "200" ]; then
            echo "✅ [Job ${SLURM_JOB_ID:-N/A}] SGLang 健康自檢通過 (Port $PORT 回應 HTTP 200)，發布狀態正式為 ready"
            publish_endpoint "ready"
            exit 0
        fi
    done
    echo "❌ [Job ${SLURM_JOB_ID:-N/A}] SGLang 健康自檢逾時未就緒 (Port $PORT)" >&2
) &

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



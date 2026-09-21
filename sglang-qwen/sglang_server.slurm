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
PORT="${PORT:-30000}"

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

# 輸出節點資訊至檔案，方便 Gateway / LiteLLM 讀取
cat > "$WORK_DIR/endpoint.info" <<EOF
JOB_ID=${SLURM_JOB_ID}
NODE=${NODE_HOSTNAME}
IP=${NODE_IP}
PORT=${PORT}
ENDPOINT=http://${NODE_HOSTNAME}:${PORT}
ENDPOINT_IP=http://${NODE_IP}:${PORT}
API_KEY_PROTECTED=$([ -n "${SGLANG_API_KEY:-}" ] && echo "true" || echo "false")
START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
EOF

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

"${CMD[@]}"



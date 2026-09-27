#!/bin/bash
# ==============================================================================
# SLURM 核心派送腳本: vLLM GLM-5.3-Flash on 8x H200 GPU (TEP8)
# ==============================================================================
#SBATCH --job-name=vllm_glm53_flash
#SBATCH --partition=8gpus
#SBATCH --account=your-slurm-account
#SBATCH --nodes=1
#SBATCH --gres=gpu:H200:8
#SBATCH --cpus-per-task=96
#SBATCH --mem=480G
#SBATCH --time=24:00:00
#SBATCH --output=logs/vllm-glm53-flash-%x-%j.out
#SBATCH --error=logs/vllm-glm53-flash-%x-%j.err

umask 077
set -eo pipefail

# 1. 確保工作目錄
WORK_DIR="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
if [[ "$WORK_DIR" == *"/var/spool/slurmd"* ]] || [ ! -w "$WORK_DIR" ]; then
    WORK_DIR="/path/to/work/github/litellm-proxy/engines/vllm-glm53-flash"
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

SIF_FILE="${SIF_PATH:-/path/to/work/containers/vllm_latest.sif}"
if [ ! -f "$SIF_FILE" ]; then
    echo "⚠️ 提醒：容器映像檔 $SIF_FILE 尚未就緒，若使用 Docker/Apptainer 請確認映像檔路徑" >&2
fi

# 3. 檢查與解析模型權重路徑（CANDIDATES 陣列——與 validate_engine.sh 檢查邏輯一致）
RESOLVED_MODEL_PATH=""
CANDIDATES=(
    "${MODELS_DIR:-/path/to/work/models}/$(basename "${MODEL_NAME:-zai-org/GLM-5.3-Flash-vLLM}")"
    "${MODELS_DIR:-/path/to/work/models}/${MODEL_NAME:-zai-org/GLM-5.3-Flash-vLLM}"
    "${MODELS_DIR:-/path/to/work/models}/$(basename "${FALLBACK_MODEL_NAME:-zai-org/GLM-5.3-Flash}")"
)

for c in "${CANDIDATES[@]}"; do
    if [ -d "$c" ]; then
        RESOLVED_MODEL_PATH="$c"
        break
    fi
done

if [ -z "$RESOLVED_MODEL_PATH" ]; then
    RESOLVED_MODEL_PATH="${MODEL_NAME:-zai-org/GLM-5.3-Flash-vLLM}"
fi

# 4. 取得計算節點網路與端點註冊目錄
NODE_HOSTNAME=$(hostname -s)
NODE_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1 || echo "127.0.0.1")
PROJECT_ROOT="$(cd "$WORK_DIR/../.." && pwd)"
REGISTRY_DIR="$PROJECT_ROOT/runtime/endpoints"
PORT_LOCKS_DIR="$PROJECT_ROOT/runtime/port-locks"
mkdir -p -m 700 "$REGISTRY_DIR" "$PORT_LOCKS_DIR"
chmod 700 "$REGISTRY_DIR" "$PORT_LOCKS_DIR" 2>/dev/null || true

ENDPOINT_REGISTRY_FILE="$REGISTRY_DIR/vllm_glm53_flash_${SLURM_JOB_ID:-manual}.env"
ENGINE_NAME="vllm_glm53_flash"

# 5. 載入通用生命週期函式庫
LIB_LIFECYCLE="${PROJECT_ROOT}/lib/lifecycle.sh"
if [ ! -f "$LIB_LIFECYCLE" ]; then
    LIB_LIFECYCLE="$WORK_DIR/../../lib/lifecycle.sh"
fi
source "$LIB_LIFECYCLE"

# 6. 動態可用 Port 偵測與搶佔
PORT_BASE="${PORT:-33000}"
CURRENT_PORT_LOCK=""
find_available_port "$PORT_BASE" 100

# 7. 設定退場安全陷阱
trap cleanup_endpoint TERM INT EXIT

echo "=================================================================="
echo "🚀 vLLM GLM-5.3-Flash 服務正在啟動"
echo "=================================================================="
echo "🔹 Job ID       : ${SLURM_JOB_ID:-N/A}"
echo "🔹 執行節點     : $NODE_HOSTNAME ($NODE_IP)"
echo "🔹 GPU 資源     : 4x H200 GPU (TEP4)"
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
    if [ -n "${VLLM_GLM_API_KEY:-}" ]; then
        AUTH_HEADER=(-H "Authorization: Bearer ${VLLM_GLM_API_KEY}")
    fi
    HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-600}"
    TMP_BODY=$(mktemp)
    trap 'rm -f "$TMP_BODY"' EXIT
    for i in $(seq 1 $(( HEALTH_TIMEOUT / 2 ))); do
        sleep 2
        HTTP_CODE=$(curl -sS -m 4 -o "$TMP_BODY" -w "%{http_code}" "${AUTH_HEADER[@]}" "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null || echo "000")
        if validate_health_response "$HTTP_CODE" "$TMP_BODY"; then
            echo "✅ [Job ${SLURM_JOB_ID:-N/A}] vLLM 健康自檢通過 (Port $PORT HTTP 200/JSON 合規)，發布狀態為 ready"
            publish_endpoint "ready"
            rm -f "$TMP_BODY"
            exit 0
        fi
    done
    rm -f "$TMP_BODY"
    echo "❌ [Job ${SLURM_JOB_ID:-N/A}] vLLM 自檢逾時 (Port $PORT，逾時 ${HEALTH_TIMEOUT} 秒)，主動終止服務釋放 GPU 資源" >&2
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

# 啟動 vLLM Serve 指令（參數依官方 Recipe：recipes.vllm.ai/zai-org/GLM-5.3-Flash
# 之 TP＋EP 擴展配置；⚠️ Hopper 不支援此模型 FP8 KV → 不設 --kv-cache-dtype，用 BF16 KV）
CMD=(
  "$SINGULARITY_BIN" exec
  --nv
  --bind /work:/work
  "$SIF_FILE"
  vllm serve "$RESOLVED_MODEL_PATH"
    --host "${HOST:-0.0.0.0}"
    --port "$PORT"
    --tensor-parallel-size "${TENSOR_PARALLEL_SIZE:-8}"
    --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION:-0.85}"
    --max-num-seqs "${MAX_NUM_SEQS:-128}"
    --reasoning-parser "${REASONING_PARSER:-glm47}"
    --tool-call-parser "${TOOL_CALL_PARSER:-glm47}"
    --enable-auto-tool-choice
)

# 可選參數：變數有設定時才附加旗標，避免傳入空字串導致 vLLM 啟動失敗
# DeepGEMM 繞道：Hopper 上 vLLM 內部 TRT-LLM deep_gemm 曾出現 cubin 斷言失敗
# （!cubin.empty() || isPathValid(path_)），VLLM_USE_DEEP_GEMM=0 改走 CUTLASS 路徑
# （與官方 Flash-Next Recipe 於 Blackwell 的同款處理模式）
if [ "${VLLM_USE_DEEP_GEMM:-}" = "0" ]; then
  export SINGULARITYENV_VLLM_USE_DEEP_GEMM=0
fi
# deep_gemm JIT 快取落地（根因修復）：容器內 HOME=/root 唯讀 → JIT cubin 寫不進
# 預設快取（$VLLM_CACHE_ROOT/deep_gemm）→ cubin.empty() 斷言。指到 /work 可寫路徑。
if [ -n "${VLLM_CACHE_DIR:-}" ]; then
  mkdir -p "$VLLM_CACHE_DIR" 2>/dev/null || true
  export SINGULARITYENV_VLLM_CACHE_ROOT="$VLLM_CACHE_DIR"
  export SINGULARITYENV_DG_JIT_CACHE_DIR="$VLLM_CACHE_DIR/deep_gemm"
  export SINGULARITYENV_TILELANG_CACHE_DIR="$VLLM_CACHE_DIR/tilelang"
fi
# 專家平行（Recipe：TP/EP/TEP 皆可擴展；A/B 對稱採 TEP8）
if [ "${ENABLE_EXPERT_PARALLEL:-}" = "true" ]; then
  CMD+=(--enable-expert-parallel)
fi
# 關閉 FlashInfer autotune（實測 H200 曾於 autotune 階段掛死 31 分鐘；
# 官方 Flash-Next Recipe 於 H200 亦採 --no-enable-flashinfer-autotune）
if [ "${ENABLE_FLASHINFER_AUTOTUNE:-}" = "false" ]; then
  CMD+=(--no-enable-flashinfer-autotune)
fi
# 投機解碼（官方 MTP5：內建 draft head；R2 壓測用）
if [ -n "${SPECULATIVE_CONFIG:-}" ]; then
  CMD+=(--speculative-config "$SPECULATIVE_CONFIG")
fi

if [ -n "${VLLM_GLM_API_KEY:-}" ]; then
  CMD+=(--api-key "$VLLM_GLM_API_KEY")
fi
# 投機解碼（官方 MTP：內建 draft head；R2 壓測用）
if [ -n "${SPECULATIVE_CONFIG:-}" ]; then
  CMD+=(--speculative-config "$SPECULATIVE_CONFIG")
fi

if [ -n "${VLLM_GLM_API_KEY:-}" ]; then
  CMD+=(--api-key "$VLLM_GLM_API_KEY")
fi

# 顯示啟動指令時遮罩 --api-key 值，避免金鑰寫入 Slurm log
DISPLAY_CMD="${CMD[*]}"
echo "🔹 執行啟動指令: ${DISPLAY_CMD//--api-key */--api-key <masked>}"
"${CMD[@]}" &
SERVER_PID=$!

wait "$SERVER_PID"
cleanup_endpoint

#!/usr/bin/env bash
# ==============================================================================
# vLLM Qwen3.8-Flash-Next 推論容器映像檔拉取腳本 (pull_image.sh)
# ==============================================================================
umask 077
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/config.env" ]; then
    chmod 600 "$SCRIPT_DIR/config.env" 2>/dev/null || true
    source "$SCRIPT_DIR/config.env"
fi

CONTAINERS_DIR="/path/to/work/containers"
TARGET_SIF="${SIF_PATH:-${CONTAINERS_DIR}/vllm_latest.sif}"
CACHE_DIR="${CONTAINERS_DIR}/apptainer_cache"
TMP_DIR="${CONTAINERS_DIR}/apptainer_tmp"

# 1. 建立快取目錄 (防止 home 目錄空間爆滿)
mkdir -p "$CACHE_DIR" "$TMP_DIR"
export APPTAINER_CACHEDIR="$CACHE_DIR"
export APPTAINER_TMPDIR="$TMP_DIR"
export SINGULARITY_CACHEDIR="$CACHE_DIR"
export SINGULARITY_TMPDIR="$TMP_DIR"

# 2. 解析可用之容器拉取工具
PULL_BIN=""
for cmd in /usr/bin/apptainer /usr/bin/singularity apptainer singularity; do
    if command -v "$cmd" >/dev/null 2>&1; then
        PULL_BIN="$(command -v "$cmd")"
        break
    fi
done

if [ -z "$PULL_BIN" ]; then
    echo "❌ 錯誤：找不到 apptainer 或 singularity 執行檔！" >&2
    exit 1
fi

# 預設採用 nightly 版本以支援 Qwen3.8-Flash-Next 最新 MLA Sparse 與 Engram 特性
DOCKER_IMAGE="${1:-docker://vllm/vllm-openai:nightly}"

echo "=========================================================="
echo " 🚀 開始拉取並建構 vLLM 推論容器 (Qwen3.8-Flash-Next)"
echo " 🔹 工具路徑: $PULL_BIN"
echo " 🔹 來源映像: $DOCKER_IMAGE"
echo " 🔹 輸出目標: $TARGET_SIF"
echo " 🔹 快取路徑: $CACHE_DIR"
echo " 💡 轉換時間約需 10~15 分鐘，請耐心等候..."
echo "=========================================================="

"$PULL_BIN" pull -F "$TARGET_SIF" "$DOCKER_IMAGE"

echo ""
echo "✅ 容器拉取與轉換完成: $TARGET_SIF"
echo "💡 可執行 ./submit_slurm.sh 啟動 vLLM Qwen3.8-Flash-Next 服務"

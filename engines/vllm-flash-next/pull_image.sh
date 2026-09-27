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
# ==== Image 版本政策 C：版本化檔名輸出，永不覆蓋既有 SIF ====
# 用法：./pull_image.sh <版本標籤> [docker-image-uri] [--force]
#   輸出檔名 = <框架>_<版本標籤>.sif（例：vllm_0.29.2.sif）
#   已存在的 SIF 一律拒絕覆蓋（--force 才允許）——舊版永遠留磁碟 standby
#   切換引擎：改 config.env 的 SIF_PATH → ./validate_engine.sh → 更新 KNOWN_GOOD.md
FORCE_OVERWRITE=false
VERSION_TAG=""
DOCKER_URI=""
for arg in "$@"; do
    case "$arg" in
        --force) FORCE_OVERWRITE=true ;;
        *) if [ -z "$VERSION_TAG" ]; then VERSION_TAG="$arg"; else DOCKER_URI="$arg"; fi ;;
    esac
done
if [ -z "$VERSION_TAG" ] || [ "$VERSION_TAG" = "latest" ] || [ "$VERSION_TAG" = "nightly" ]; then
    echo "❌ 請指定具體版本標籤（浮動標籤無法回溯，是版本政策 C 禁止的覆蓋風險源）：" >&2
    echo "   用法：$0 <版本標籤> [docker-image-uri]   例：$0 0.29.2" >&2
    exit 1
fi
TARGET_SIF="${CONTAINERS_DIR}/vllm_${VERSION_TAG}.sif"
if [ -f "$TARGET_SIF" ] && [ "$FORCE_OVERWRITE" != true ]; then
    echo "❌ $TARGET_SIF 已存在——版本政策 C 不覆蓋（舊版 standby）。" >&2
    echo "   換一個版本標籤，或確認重抓必要性後加 --force。" >&2
    exit 1
fi
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
DOCKER_IMAGE="${DOCKER_URI:-docker://vllm/vllm-openai:nightly}"

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

echo ""
echo "📋 版本政策 C：切換步驟（引擎不會自動改用新 SIF）"
echo "   ① engines/<引擎>/config.env 改 SIF_PATH=${CONTAINERS_DIR}/vllm_${VERSION_TAG}.sif"
echo "   ② ./validate_engine.sh <引擎>（煙霧驗證，最終裁決）"
echo "   ③ 更新 engines/KNOWN_GOOD.md 登記實測版本；舊 SIF 保留 standby"

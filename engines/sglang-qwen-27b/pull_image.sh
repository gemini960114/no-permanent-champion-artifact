#!/usr/bin/env bash
# ==============================================================================
# SGLang Qwen3.8-27B 推論容器映像檔拉取腳本 (pull_image.sh)
# ==============================================================================
umask 077
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/config.env" ]; then
    chmod 600 "$SCRIPT_DIR/config.env" 2>/dev/null || true
    source "$SCRIPT_DIR/config.env"
fi

CONTAINERS_DIR="/path/to/work/containers"
# ==== Image 版本政策 C：版本化檔名輸出，預設不覆蓋既有 SIF ====
# 用法：./pull_image.sh <版本標籤> [docker-image-uri] [--force]
#   來源映像：第 2 個參數，未給則用 config.env 的 CONTAINER_IMAGE；兩者皆無則拒絕（不再預設下載 nightly/latest）
#   輸出檔名 = <框架>_<版本標籤>.sif（例：sglang_0.29.2.sif）
#   已存在的 SIF 預設拒絕覆蓋（--force 才允許，並重寫 manifest）——舊版預設留磁碟 standby
#   切換引擎：改 config.env 的 SIF_PATH → ./validate_engine.sh → 更新 KNOWN_GOOD.md
FORCE_OVERWRITE=false
VERSION_TAG=""
DOCKER_URI=""
POS_COUNT=0   # 以位置計數，不以變數是否為空判斷——空字串參數也佔一個位置
for arg in "$@"; do
    case "$arg" in
        --force) FORCE_OVERWRITE=true ;;
        *) POS_COUNT=$((POS_COUNT + 1))
           case "$POS_COUNT" in
               1) VERSION_TAG="$arg" ;;
               2) DOCKER_URI="$arg" ;;   # 空字串＝改用 config.env 的 CONTAINER_IMAGE
               *) echo "❌ 多餘的參數：'$arg'（最多兩個：版本標籤、來源映像）" >&2
                  echo "   用法：$0 <版本標籤> [docker-image-uri] [--force]" >&2
                  exit 1 ;;
           esac ;;
    esac
done
if [ -z "$VERSION_TAG" ] || [ "$VERSION_TAG" = "latest" ] || [ "$VERSION_TAG" = "nightly" ]; then
    echo "❌ 請指定具體版本標籤（浮動標籤無法回溯，是版本政策 C 禁止的覆蓋風險源）：" >&2
    echo "   用法：$0 <版本標籤> <docker-image-uri>" >&2
    exit 1
fi
TARGET_SIF="${CONTAINERS_DIR}/sglang_${VERSION_TAG}.sif"
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

# 來源映像必須明確指定（第 2 個參數，或 config.env 的 CONTAINER_IMAGE），且不得為浮動標籤：
# 檔名上的版本標籤只是名稱，SIF 的實際內容由來源決定；預設下載 nightly/latest 會讓同名 SIF 內容無法追溯。
DOCKER_IMAGE="${DOCKER_URI:-${CONTAINER_IMAGE:-}}"
if [ -z "$DOCKER_IMAGE" ]; then
    echo "❌ 請明確指定來源映像（第 2 個參數，或 config.env 的 CONTAINER_IMAGE）：" >&2
    echo "   用法：$0 <版本標籤> <docker-image-uri>   例：$0 <版本> docker://<repo>:<固定版本標籤>" >&2
    exit 1
fi
IMAGE_REF="${DOCKER_IMAGE#*://}"
IMAGE_LAST="${IMAGE_REF##*/}"
if [[ "$IMAGE_REF" == *@* ]]; then
    # digest 釘選：必須是 @sha256: 後接 64 位十六進位
    if ! [[ "$IMAGE_REF" =~ @sha256:[0-9a-f]{64}$ ]]; then
        echo "❌ digest 格式錯誤（$DOCKER_IMAGE）：須為 @sha256:<64 位小寫十六進位>。" >&2
        exit 1
    fi
else
    IMAGE_TAG="${IMAGE_LAST#*:}"
    if [[ "$IMAGE_LAST" != *:* ]] || [ -z "$IMAGE_TAG" ] || [ "$IMAGE_TAG" = "latest" ] || [ "$IMAGE_TAG" = "nightly" ]; then
        echo "❌ 來源映像須帶固定版本標籤（$DOCKER_IMAGE）：無標籤、空標籤或 latest/nightly 日後可能指向不同內容。" >&2
        echo "   請改用固定版本標籤，或以 @sha256:<digest> 指定。" >&2
        exit 1
    fi
fi

echo "=========================================================="
echo " 🚀 開始拉取並建構 SGLang 推論容器 (Qwen3.8-27B)"
echo " 🔹 工具路徑: $PULL_BIN"
echo " 🔹 來源映像: $DOCKER_IMAGE"
echo " 🔹 輸出目標: $TARGET_SIF"
echo " 🔹 快取路徑: $CACHE_DIR"
echo " 💡 轉換時間約需 10~15 分鐘，請耐心等候..."
echo "=========================================================="

# 記錄來源與內容雜湊：版本標籤只是檔名，這份 manifest 才能回溯 SIF 的實際內容
MANIFEST="${TARGET_SIF}.manifest"
rm -f "$MANIFEST"   # --force 重抓時，舊 manifest 不可留著冒充新內容

"$PULL_BIN" pull -F "$TARGET_SIF" "$DOCKER_IMAGE"

# 先各自取值並檢查，再寫暫存檔、更名：任一步失敗都不留下空欄位的 manifest
manifest_fail() {
    rm -f "${MANIFEST}.tmp" 2>/dev/null || true   # 清不掉也不可蓋過真正的錯誤訊息
    echo "❌ $1——SIF 已拉取但 manifest 未寫入，請修正後重跑（加 --force）：$TARGET_SIF" >&2
    exit 1
}
PULLED_AT="$(date -Is)" || manifest_fail "無法取得時間"
[ -n "$PULLED_AT" ] || manifest_fail "取得的時間為空"
SIF_SHA256="$(sha256sum "$TARGET_SIF" | awk '{print $1}')" || manifest_fail "無法計算 SHA-256"
[[ "$SIF_SHA256" =~ ^[0-9a-f]{64}$ ]] || manifest_fail "SHA-256 格式異常（$SIF_SHA256）"
# 單一 printf 一次寫完：多個 echo 的區塊只回傳最後一個狀態，前面寫入失敗會被掩蓋
printf '%s\n' \
    "source=$DOCKER_IMAGE" \
    "version_tag=$VERSION_TAG" \
    "pulled_at=$PULLED_AT" \
    "sif_sha256=$SIF_SHA256" \
    > "${MANIFEST}.tmp" || manifest_fail "無法寫入 manifest"
mv -f "${MANIFEST}.tmp" "$MANIFEST" || manifest_fail "無法更名 manifest"
echo "🧾 來源與 SHA-256 已記錄：$MANIFEST"

echo ""
echo "✅ 容器拉取與轉換完成: $TARGET_SIF"
echo "💡 可執行 ./submit_slurm.sh 啟動 SGLang Qwen3.8-27B 服務"

echo ""
echo "📋 版本政策 C：切換步驟（引擎不會自動改用新 SIF）"
echo "   ① engines/<引擎>/config.env 改 SIF_PATH=${CONTAINERS_DIR}/sglang_${VERSION_TAG}.sif"
echo "   ② ./validate_engine.sh <引擎>（煙霧驗證，最終裁決）"
echo "   ③ 更新 engines/KNOWN_GOOD.md 登記實測版本；舊 SIF 保留 standby"

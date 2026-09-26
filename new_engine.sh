#!/usr/bin/env bash
# ==============================================================================
# 從原型引擎 scaffold 新引擎目錄 (new_engine.sh)
# 用法：./new_engine.sh <新引擎名> [--from <原型目錄名>]
#       ./new_engine.sh --list-archetypes
# 範例：./new_engine.sh my-model --from sglang-qwen-flash
# 做了什麼：
#   ① 複製原型目錄（排除 logs/、pull.log 等本地執行產物；保留 config.env 金鑰與參數）
#   ② 改寫 slurm 的 --job-name 與 ENGINE_NAME（避免與原型共用端點命名空間/埠鎖）
#   ③ 印出後續步驟清單（改 config → 下載權重 → 拉 image → 驗證 → 上線）
# ==============================================================================
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ENGINE_ROOT="$DIR/engines"

ARCHETYPES=(
    "sglang-qwen-27b:小模型單卡 (TP1，支援多實例負載平衡)"
    "sglang-qwen-flash:大模型 TP4+EP4+NEXTN 投機解碼 (hybrid Mamba)"
    "vllm-qwen27b:vLLM 官方 Recipe 參數 (TP1，SGLang vs vLLM A/B 對照組)"
    "vllm-flash-next:vLLM TEP4 官方 Recipe MoE 配方 (A/B 第二戰冠軍 7,886 tok/s)"
)

list_archetypes() {
    echo "可用原型 (新引擎的起點，配方細節見 engines/KNOWN_GOOD.md)："
    local a
    for a in "${ARCHETYPES[@]}"; do
        printf "  • %-24s %s\n" "${a%%:*}" "${a#*:}"
    done
}

usage() {
    echo "用法：$0 <新引擎名> --from <原型目錄名>"
    echo "      $0 --list-archetypes"
    list_archetypes
    exit 1
}

# ------------------------------------------------------------------------------
# 參數解析
# ------------------------------------------------------------------------------
[ $# -ge 1 ] || usage
if [ "${1:-}" = "--list-archetypes" ]; then list_archetypes; exit 0; fi

NEW_NAME="${1:-}"
FROM="${3:-}"
[ $# -eq 3 ] && [ "${2:-}" = "--from" ] || usage

# 名稱驗證：小寫字母/數字/連字號，且不得已存在
if ! echo "$NEW_NAME" | grep -qE '^[a-z0-9][a-z0-9-]*$'; then
    echo "❌ 引擎名稱僅接受小寫字母、數字與連字號（例：my-model）：$NEW_NAME"
    exit 1
fi
if [ ! -d "$ENGINE_ROOT/$FROM" ] || [ ! -f "$ENGINE_ROOT/$FROM/submit_slurm.sh" ]; then
    echo "❌ 原型不存在或缺少 submit_slurm.sh：engines/$FROM"
    list_archetypes
    exit 1
fi
if [ -e "$ENGINE_ROOT/$NEW_NAME" ]; then
    echo "❌ 目標已存在：engines/$NEW_NAME"
    exit 1
fi

NEW_TAG=$(echo "$NEW_NAME" | tr '-' '_')
TARGET="$ENGINE_ROOT/$NEW_NAME"

# ------------------------------------------------------------------------------
# 複製與身分改寫
# ------------------------------------------------------------------------------
echo "🧬 Scaffold：engines/$FROM → engines/$NEW_NAME"
cp -a "$ENGINE_ROOT/$FROM" "$TARGET"

# 移除本地執行產物（log、pull 產物；config.env 保留——金鑰與參數可沿用）
rm -rf "$TARGET/logs" "$TARGET"/*.log

# 改寫 slurm 身分：--job-name 與 ENGINE_NAME（避免與原型撞端點命名空間）
SLURM_FILES=$(ls "$TARGET"/*server.slurm 2>/dev/null)
for f in $SLURM_FILES; do
    sed -i "s/^#SBATCH --job-name=.*/#SBATCH --job-name=${NEW_TAG}/" "$f"
    if grep -q '^ENGINE_NAME=' "$f"; then
        sed -i "s/^ENGINE_NAME=.*/ENGINE_NAME=\"${NEW_TAG}\"/" "$f"
    else
        # 原型未宣告 ENGINE_NAME（如 27b 用 lifecycle 預設值）→ 插入宣告避免沿用原型命名空間
        LAST_SBATCH=$(grep -n '^#SBATCH' "$f" | tail -1 | cut -d: -f1)
        [ -n "$LAST_SBATCH" ] && sed -i "$((LAST_SBATCH + 1))i ENGINE_NAME=\"${NEW_TAG}\"" "$f"
    fi
done

echo "✅ 已建立 engines/$NEW_NAME（job-name / ENGINE_NAME → ${NEW_TAG}）"
echo ""
echo "──────────────────────────────────────────"
echo "📋 後續步驟："
echo "  ① 編輯 engines/$NEW_NAME/config.env"
echo "     - MODEL_NAME / MODEL_ALIAS（新模型 HF 識別名）"
echo "     - SIF_PATH（指向正確版本 image，版本選擇見 engines/KNOWN_GOOD.md）"
echo "     - 確認金鑰（沿用或換新）與埠位/硬體參數"
echo "  ② 下載權重：cd engines/$NEW_NAME && ./download_model.sh"
echo "  ③ 拉取 image：./pull_image.sh（建議改用版本釘選的 docker tag）"
echo "  ④ 驗證：cd $DIR && ./validate_engine.sh $NEW_NAME"
echo "  ⑤ 上線：./start_models.sh $NEW_NAME"
echo "  ⑥ 更新 engines/KNOWN_GOOD.md 登記實測版本與參數"

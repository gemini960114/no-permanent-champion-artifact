#!/usr/bin/env bash
# ==============================================================================
# 引擎支援實測 (check_engine_support.sh) — model-onboarding skill 附屬工具
# 用法：check_engine_support.sh <架構關鍵字>   例：check_engine_support.sh step
# 檢查：① 三個現有 image 的原生模型檔 ② SGLang reasoning-parser 合法選項
# 注意：模型檔存在＝必要非充分條件（仍需 registry 註冊，最終以煙霧測試為準）
# ==============================================================================
set -u

KEYWORD="${1:-}"
if [ -z "$KEYWORD" ]; then
    echo "用法：$0 <架構關鍵字>   例：$0 step"
    exit 1
fi

CONTAINERS=/path/to/work/containers

echo "════ ① 原生模型檔支援（grep -i '$KEYWORD'）════"
for sif in sglang_latest sglang_flash_latest; do
    echo "── $sif (SGLang)："
    if [ -f "$CONTAINERS/$sif.sif" ]; then
        VER=$(timeout 60 apptainer exec "$CONTAINERS/$sif.sif" python3 -c "import sglang; print(sglang.__version__)" 2>/dev/null || echo "?")
        MATCHES=$(timeout 60 apptainer exec "$CONTAINERS/$sif.sif" \
            bash -c "ls /sgl-workspace/sglang/python/sglang/srt/models/ 2>/dev/null | grep -i '$KEYWORD'" 2>/dev/null)
        echo "   版本: SGLang $VER"
        if [ -n "$MATCHES" ]; then echo "$MATCHES" | sed 's/^/   ✅ /'; else echo "   ❌ 無匹配"; fi
    else
        echo "   ⚠️ image 不存在"
    fi
done
echo "── vllm_latest (vLLM)："
if [ -f "$CONTAINERS/vllm_latest.sif" ]; then
    VER=$(timeout 60 apptainer exec "$CONTAINERS/vllm_latest.sif" python3 -c "import vllm; print(vllm.__version__)" 2>/dev/null || echo "?")
    MATCHES=$(timeout 60 apptainer exec "$CONTAINERS/vllm_latest.sif" \
        bash -c "ls /usr/local/lib/python3.12/dist-packages/vllm/model_executor/models/ /usr/local/lib/python3.12/dist-packages/vllm/models/ 2>/dev/null | grep -i '$KEYWORD'" 2>/dev/null)
    echo "   版本: vLLM $VER"
    if [ -n "$MATCHES" ]; then echo "$MATCHES" | sed 's/^/   ✅ /'; else echo "   ❌ 無匹配"; fi
else
    echo "   ⚠️ image 不存在"
fi

echo ""
echo "════ ② SGLang reasoning-parser 合法選項（DetectorMap）════"
if [ -f "$CONTAINERS/sglang_flash_latest.sif" ]; then
    timeout 60 apptainer exec "$CONTAINERS/sglang_flash_latest.sif" bash -c \
        "sed -n '/DetectorMap/,/}/p' /sgl-workspace/sglang/python/sglang/srt/parser/reasoning_parser.py 2>/dev/null | grep -oE '\"[a-z0-9_]+\"' | tr -d '\"'" 2>/dev/null | tr '\n' ' '
    echo ""
    echo "⚠️ model card 指定的 parser 值若不在上列清單，啟動會直接失敗——改用架構名對應值"
fi

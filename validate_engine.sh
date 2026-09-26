#!/usr/bin/env bash
# ==============================================================================
# 引擎驗證：靜態檢查 + 煙霧啟動 (validate_engine.sh)
# 用法：./validate_engine.sh <引擎目錄名> [--stage 0|1|all] [--fresh]
#   Stage 0（靜態，不耗 GPU）：config 必填齊、權重在、image 在、slurm 語法、名稱無衝突
#   Stage 1（煙霧，短時 job）：
#     - 引擎已在運行 → 直接對現有實例測試（不耗額外 GPU）
#     - 否則派送 --time 限制的短時 job → 等 STATE=ready → 直連引擎測
#       /v1/models + 一筆小 chat → 自動 scancel 收工
#   --fresh：強制派送新的煙霧 job（即使引擎已在運行；用於參數調整後重新驗證）
# ==============================================================================
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "$DIR"

SMOKE_WALLTIME="${SMOKE_WALLTIME:-30}"        # 煙霧 job 牆鐘上限 (分鐘)
VALIDATE_TIMEOUT="${VALIDATE_TIMEOUT:-1800}"  # 等待就緒上限 (秒)
POLL_INTERVAL="${POLL_INTERVAL:-15}"

STAGE="all"
FRESH=0
ENGINE="${1:-}"
shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --stage) STAGE="${2:-}"; shift 2 ;;
        --fresh) FRESH=1; shift ;;
        *) echo "❌ 未知參數：$1"; exit 1 ;;
    esac
done

if [ -z "$ENGINE" ] || [ ! -d "engines/$ENGINE" ]; then
    echo "用法：$0 <引擎目錄名> [--stage 0|1|all] [--fresh]"
    echo "可用引擎：$(ls -d engines/*/ 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
    exit 1
fi

EDIR="$DIR/engines/$ENGINE"
CFG="$EDIR/config.env"
PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

# 載入引擎設定（金鑰不顯示）
if [ -f "$CFG" ]; then
    set -a; source "$CFG"; set +a
fi

echo "=========================================================="
echo " 🔍 引擎驗證：$ENGINE"

# ==============================================================================
# Stage 0：靜態檢查
# ==============================================================================
if [ "$STAGE" = "0" ] || [ "$STAGE" = "all" ]; then
    echo "── Stage 0：靜態檢查（不耗 GPU）"
    [ -f "$CFG" ] && ok "config.env 存在" || { bad "config.env 不存在（cp config.env.example config.env 後填寫）"; echo "=========================================================="; exit 1; }

    [ -n "${MODEL_NAME:-}" ] && ok "MODEL_NAME = ${MODEL_NAME}" || bad "MODEL_NAME 未設定"

    SLURM_FILE=$(ls "$EDIR"/*server.slurm 2>/dev/null | head -1)

    # 權重：沿用引擎 slurm 自己的候選路徑解析（CANDIDATES 陣列），
    # 無 CANDIDATES 時退回「原名 → 去 -FP8 後綴 → RESOLVED_MODEL_PATH」
    WEIGHTS=""
    if [ -n "$SLURM_FILE" ]; then
        CAND_BLOCK=$(sed -n '/^CANDIDATES=(/,/^)/p' "$SLURM_FILE" 2>/dev/null)
        if [ -n "$CAND_BLOCK" ]; then
            eval "$CAND_BLOCK"
            for c in ${CANDIDATES[@]:-}; do
                [ -d "$c" ] && WEIGHTS="$c" && break
            done
        fi
    fi
    if [ -z "$WEIGHTS" ]; then
        BASE_NAME=$(basename "${MODEL_NAME:-unknown}")
        for c in "${MODELS_DIR:-/path/to/work/models}/$BASE_NAME" \
                 "${MODELS_DIR:-/path/to/work/models}/${BASE_NAME%-FP8}" \
                 "${RESOLVED_MODEL_PATH:-}"; do
            [ -n "$c" ] && [ -d "$c" ] && WEIGHTS="$c" && break
        done
    fi
    if [ -n "$WEIGHTS" ] && [ -f "$WEIGHTS/config.json" ]; then
        ok "權重就位：$WEIGHTS ($(du -sh "$WEIGHTS" 2>/dev/null | cut -f1))"
    else
        bad "權重未就位（候選路徑皆無 config.json；執行 engines/$ENGINE/download_model.sh）"
    fi

    # image
    if [ -n "${SIF_PATH:-}" ] && [ -f "$SIF_PATH" ]; then
        ok "image 就位：$SIF_PATH ($(du -h "$SIF_PATH" 2>/dev/null | cut -f1))"
    else
        bad "SIF_PATH 未設定或檔案不存在：${SIF_PATH:-（未設定）}（執行 pull_image.sh）"
    fi

    # 金鑰（不顯示值）
    KEYVAR="${API_KEY_ENV:-SGLANG_API_KEY}"
    KEY_VAL="${!KEYVAR:-}"
    [ -n "$KEY_VAL" ] && ok "引擎金鑰已設定 (\$${KEYVAR})" || bad "引擎金鑰未設定：\$$KEYVAR"

    # slurm 語法
    if [ -n "$SLURM_FILE" ] && bash -n "$SLURM_FILE" 2>/dev/null; then
        ok "slurm 腳本語法正確 ($(basename "$SLURM_FILE"))"
    else
        bad "slurm 腳本不存在或語法錯誤"
    fi

    # 名稱衝突：job-name 若已被「其他引擎」使用 → 端點命名空間可能撞名
    THIS_TAG=$(grep -m1 '^#SBATCH --job-name=' "$SLURM_FILE" 2>/dev/null | sed 's/.*=//')
    for other in engines/*/; do
        [ "$(basename "$other")" = "$ENGINE" ] && continue
        OTHER_REAL=$(realpath "$other"); THIS_REAL=$(realpath "$EDIR")
        [ "$OTHER_REAL" = "$THIS_REAL" ] && continue   # symlink 判定為同一引擎
        OTHER_TAG=$(grep -m1 '^#SBATCH --job-name=' "$OTHER_REAL"/*server.slurm 2>/dev/null | sed 's/.*=//')
        if [ -n "$THIS_TAG" ] && [ "$THIS_TAG" = "$OTHER_TAG" ]; then
            bad "job-name「${THIS_TAG}」與 engines/$(basename "$other") 重複（冪等偵測會互相誤判）"
        fi
    done
    [ $FAIL -eq 0 ] && ok "無 job-name 衝突"
fi

# ==============================================================================
# Stage 1：煙霧測試
# ==============================================================================
if [ "$STAGE" = "1" ] || [ "$STAGE" = "all" ]; then
    [ $FAIL -gt 0 ] && { echo "── 跳過 Stage 1（Stage 0 有失敗項）"; echo "=========================================================="; exit 1; }
    echo "── Stage 1：煙霧測試"

    ENDPOINT=""
    VALIDATE_JOB=""

    # 找現有運行實例（endpoint 檔之 ENGINE_DIR 欄位比對）
    find_running_endpoint() {
        local f
        for f in runtime/endpoints/*.env; do
            [ -f "$f" ] || continue
            grep -q "^ENGINE_DIR=$EDIR$" "$f" 2>/dev/null || continue
            grep -q "^STATE=ready" "$f" 2>/dev/null || continue
            echo "$f"; return 0
        done
        return 1
    }

    if [ "$FRESH" -eq 0 ] && EP=$(find_running_endpoint); then
        ENDPOINT="$EP"
        echo "  ℹ️  引擎已在運行，直接測試現有實例（--fresh 可強制新 job）"
    else
        # 派送短時煙霧 job（⚠️ 必須 cd 進引擎目錄——slurm 的 #SBATCH --output
        # 與 runtime 登記路徑為相對路徑，從 repo root 提交會解析到錯誤位置）
        SLURM_FILE=$(ls "$EDIR"/*server.slurm 2>/dev/null | head -1)
        TAG=$(grep -m1 '^#SBATCH --job-name=' "$SLURM_FILE" | sed 's/.*=//')
        echo "  🚀 派送煙霧 job（牆鐘上限 ${SMOKE_WALLTIME} 分鐘）..."
        SUBMIT_OUT=$(cd "$EDIR" && sbatch --time="$SMOKE_WALLTIME" --job-name="validate_${TAG}" "$SLURM_FILE" 2>&1) || {
            bad "sbatch 失敗：$SUBMIT_OUT"; echo "=========================================================="; exit 1;
        }
        VALIDATE_JOB=$(echo "$SUBMIT_OUT" | grep -oE '[0-9]+' | head -1)
        echo "     Job ${VALIDATE_JOB}"

        echo "  ⏳ 等待就緒（上限 ${VALIDATE_TIMEOUT} 秒）..."
        ELAPSED=0
        while [ "$ELAPSED" -lt "$VALIDATE_TIMEOUT" ]; do
            EP_FILE=$(ls runtime/endpoints/*_"${VALIDATE_JOB}".env 2>/dev/null | head -1)
            if [ -n "$EP_FILE" ] && grep -q "^STATE=ready" "$EP_FILE" 2>/dev/null; then
                ENDPOINT="$EP_FILE"; break
            fi
            if [ -z "$EP_FILE" ] && ! squeue -h -j "$VALIDATE_JOB" 2>/dev/null | grep -q .; then
                bad "Job ${VALIDATE_JOB} 已結束但未就緒（查 engines/$ENGINE/logs/）"
                break
            fi
            sleep "$POLL_INTERVAL"; ELAPSED=$((ELAPSED + POLL_INTERVAL))
        done
        [ -z "$ENDPOINT" ] && [ $FAIL -eq 0 ] && bad "等待就緒逾時"
    fi

    if [ -n "$ENDPOINT" ]; then
        # 解析端點（直連引擎，不經 Gateway）
        EP_IP=$(grep '^NODE_IP=' "$ENDPOINT" | cut -d= -f2)
        EP_PORT=$(grep '^PORT=' "$ENDPOINT" | cut -d= -f2)
        KEYVAR="${API_KEY_ENV:-SGLANG_API_KEY}"
        KEY_VAL="${!KEYVAR:-}"
        BASE="http://${EP_IP}:${EP_PORT}"

        CODE=$(curl -s -o /tmp/validate_models.json -w "%{http_code}" -m 15 \
            -H "Authorization: Bearer ${KEY_VAL}" "$BASE/v1/models" 2>/dev/null || echo 000)
        if [ "$CODE" = "200" ]; then
            N_MODELS=$(python3 -c "import json; print(len(json.load(open('/tmp/validate_models.json')).get('data',[])))" 2>/dev/null || echo "?")
            ok "/v1/models → 200（${N_MODELS} 個模型）"
        else
            bad "/v1/models → HTTP $CODE"
        fi

        # chat 測試模型名：以 /v1/models 實際服務名為準（vLLM 嚴格把關服務名=權重路徑，
        # SGLang 雖寬鬆但統一探測可相容兩框架；探測失敗才退回 MODEL_NAME）
        SMOKE_MODEL=$(python3 -c "import json; d=json.load(open('/tmp/validate_models.json')).get('data',[]); print(d[0]['id'] if d else '')" 2>/dev/null || echo "")
        SMOKE_MODEL="${SMOKE_MODEL:-$MODEL_NAME}"

        CHAT_CODE=$(curl -s -o /tmp/validate_chat.json -w "%{http_code}" -m 120 \
            -H "Authorization: Bearer ${KEY_VAL}" -H "Content-Type: application/json" \
            -d "{\"model\": \"${SMOKE_MODEL}\", \"messages\": [{\"role\": \"user\", \"content\": \"回覆OK即可\"}], \"max_tokens\": 64}" \
            "$BASE/v1/chat/completions" 2>/dev/null || echo 000)
        if [ "$CHAT_CODE" = "200" ]; then
            REPLY=$(python3 -c "import json; print(json.load(open('/tmp/validate_chat.json'))['choices'][0]['message']['content'].strip()[:40])" 2>/dev/null || echo "?")
            ok "chat 端到端 → 200（回覆：${REPLY}）"
        else
            bad "chat 端到端 → HTTP $CHAT_CODE"
        fi
    fi

    # 煙霧 job 收工（現有實例不動）
    if [ -n "$VALIDATE_JOB" ]; then
        scancel "$VALIDATE_JOB" 2>/dev/null && echo "  🧹 已回收煙霧 job ${VALIDATE_JOB}（牆鐘 ${SMOKE_WALLTIME} 分鐘為後備）"
    fi
fi

echo "=========================================================="
if [ $FAIL -eq 0 ]; then
    echo " 🎉 驗證通過（${PASS} 項）——可正式上線：./start_models.sh $ENGINE"
    exit 0
else
    echo " ⚠️  驗證失敗（${FAIL} 項失敗 / ${PASS} 項通過）"
    exit 1
fi

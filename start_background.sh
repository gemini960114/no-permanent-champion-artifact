#!/usr/bin/env bash
# ==============================================================================
# 背景啟動 LiteLLM → 等待就緒 → 健康檢查 → curl 實測模型 (start_background.sh)
# 用法：./start_background.sh              以模型清單第一個模型實測
#       ./start_background.sh GLM-5.2      指定實測模型
# 服務以 setsid 脫離終端機執行，關閉終端機不會中止；日誌寫入 litellm.log。
# ==============================================================================
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "$DIR"

TEST_MODEL="${1:-}"
WAIT_SECS=180

if [ -f "$DIR/.env" ]; then
    set -a
    source "$DIR/.env"
    set +a
fi
PORT="${PORT:-54921}"
KEY="${LITELLM_MASTER_KEY:-}"
NODE="$(hostname -s)"

# 與 start.sh 相同的監聽位址解析
case "${HOST:-internal}" in
    0.0.0.0|127.*|localhost) TARGET_IP=127.0.0.1 ;;
    internal) TARGET_IP=$(getent ahostsv4 "$NODE" | awk 'NR==1 {print $1}') ;;
    *) TARGET_IP="$HOST" ;;
esac
BASE_URL="http://${TARGET_IP}:${PORT}"

# 1. 背景啟動 (start.sh 會先自動停止舊實例)
OLD_PID=$(cat "$DIR/.litellm.pid" 2>/dev/null || echo "")
echo "▶ [1/3] 背景啟動 LiteLLM (${NODE} → ${BASE_URL})"
touch "$DIR/litellm.log" && chmod 600 "$DIR/litellm.log"
LOG_START=$(wc -l < "$DIR/litellm.log")
setsid nohup "$DIR/start.sh" >> "$DIR/litellm.log" 2>&1 < /dev/null & disown

# 等待「新 PID 出現、行程存活、存活探測 200」；舊實例在重啟空檔仍可能回應，故必須比對 PID
READY=false
for ((i = 1; i <= WAIT_SECS; i++)); do
    PID=$(cat "$DIR/.litellm.pid" 2>/dev/null || echo "")
    if [ -n "$PID" ] && [ "$PID" != "$OLD_PID" ] && kill -0 "$PID" 2>/dev/null; then
        if [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' "${BASE_URL}/health/liveliness" 2>/dev/null)" = 200 ]; then
            READY=true
            break
        fi
    fi
    # start.sh 若已提前失敗結束 (例如設定錯誤)，不必等到逾時
    if [ "$i" -gt 5 ] && ! pgrep -u "$(whoami)" -f "$DIR/start.sh|litellm --config" > /dev/null; then
        break
    fi
    sleep 1
done

if [ "$READY" != true ]; then
    echo "❌ LiteLLM 未能在 ${WAIT_SECS} 秒內就緒，本次啟動日誌："
    tail -n +"$((LOG_START + 1))" "$DIR/litellm.log" | tail -20
    exit 1
fi
echo "✅ 已就緒 (PID ${PID}，耗時 ${i} 秒)"

# 2. 健康檢查
echo
echo "▶ [2/3] 健康檢查"
if ! "$DIR/healthcheck.sh" --quick; then
    echo "❌ 健康檢查未通過，略過模型實測"
    exit 1
fi

# 3. curl 實測模型
echo
if [ -z "$TEST_MODEL" ]; then
    TEST_MODEL=$(curl -s -m 10 -H "Authorization: Bearer ${KEY}" "${BASE_URL}/v1/models" \
        | python3 -c 'import sys, json; print(json.load(sys.stdin)["data"][0]["id"])' 2>/dev/null || true)
fi
if [ -z "$TEST_MODEL" ]; then
    echo "❌ 取不到可用模型，無法實測"
    exit 1
fi

echo "▶ [3/3] curl 實測模型：${TEST_MODEL}"
RESP=$(mktemp)
CODE=$(curl -s -m 120 -o "$RESP" -w '%{http_code}' "${BASE_URL}/v1/chat/completions" \
    -H "Authorization: Bearer ${KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"model\": \"${TEST_MODEL}\", \"messages\": [{\"role\": \"user\", \"content\": \"你好，請用一句話自我介紹。\"}], \"max_tokens\": 80}")
REPLY=$(python3 -c 'import sys, json; print(json.load(open(sys.argv[1]))["choices"][0]["message"]["content"].strip()[:200])' "$RESP" 2>/dev/null || true)

if [ "$CODE" = 200 ] && [ -n "$REPLY" ]; then
    echo "✅ HTTP 200，模型回覆："
    echo "   🤖 ${REPLY}"
    rm -f "$RESP"
else
    echo "❌ HTTP ${CODE}，回應內容："
    head -c 400 "$RESP"
    echo
    rm -f "$RESP"
    exit 1
fi

echo
echo "=========================================================="
echo " 🎉 LiteLLM 已在背景運行並通過實測"
echo " 🔹 即時日誌 : tail -f ${DIR}/litellm.log"
echo " 🔹 停止服務 : ${DIR}/stop.sh"
echo "=========================================================="

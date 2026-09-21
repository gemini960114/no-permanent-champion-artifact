#!/usr/bin/env bash
# ==============================================================================
# LiteLLM Gateway 全功能健全性驗證腳本 (test.sh)
# 特色：嚴格驗證 HTTP 狀態碼與回應格式，杜絕假性成功
# ==============================================================================
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "$DIR"

if [ -f "$DIR/.env" ]; then
    set -a
    source "$DIR/.env"
    set +a
fi

PORT="${PORT:-54821}"
BASE_URL="http://127.0.0.1:${PORT}"
KEY="${LITELLM_MASTER_KEY:-}"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

echo "=========================================================="
echo " 🧪 開始測試 LiteLLM Gateway (${BASE_URL})"
echo "=========================================================="

if [ -z "$KEY" ]; then
    echo "❌ 錯誤：.env 中未找到 LITELLM_MASTER_KEY！"
    exit 1
fi

# 測試輔助函式
# 用法: run_test "標題" "is_mandatory (true/false)" <curl args...>
run_test() {
    local title="$1"
    local mandatory="$2"
    shift 2

    ((TOTAL_TESTS++))
    echo -e "\n▶ 測試 $TOTAL_TESTS: $title"
    
    local tmp_out
    tmp_out=$(mktemp)
    local http_code
    
    http_code=$(curl -s -m 30 -w "%{http_code}" -o "$tmp_out" "$@") || {
        echo "❌ 網路連線逾時或連線中斷 (HTTP $http_code)"
        rm -f "$tmp_out"
        if [ "$mandatory" = true ]; then
            ((FAILED_TESTS++))
        fi
        return 1
    }

    local content
    content=$(cat "$tmp_out")
    rm -f "$tmp_out"

    # 檢查 HTTP 狀態碼是否為 200
    if [ "$http_code" -ne 200 ]; then
        echo "❌ 失敗 (HTTP $http_code)"
        echo "  回應內容: $content"
        if [ "$mandatory" = true ]; then
            ((FAILED_TESTS++))
        fi
        return 1
    fi

    # 檢查是否有 error 欄位
    if echo "$content" | grep -q '"error":'; then
        echo "❌ 失敗 (回應含 error 訊息)"
        echo "  回應內容: $content"
        if [ "$mandatory" = true ]; then
            ((FAILED_TESTS++))
        fi
        return 1
    fi

    echo "✅ 通過 (HTTP 200)"
    # 簡短印出前兩行預覽
    if echo "$content" | grep -q '"choices"'; then
        local reply
        reply=$(echo "$content" | python3 -c 'import sys, json; data=json.load(sys.stdin); print(data["choices"][0]["message"]["content"].strip()[:100])' 2>/dev/null || true)
        if [ -n "$reply" ]; then
            echo "  🤖 模型回覆: \"$reply...\""
        fi
    fi
    ((PASSED_TESTS++))
    return 0
}

# 1. 服務健康檢查
run_test "Gateway 健康檢查 (/health)" true \
  -H "Authorization: Bearer ${KEY}" \
  -X GET "${BASE_URL}/health"


# 2. 可用模型清單
run_test "查詢可用模型清單 (/v1/models)" true \
  -H "Authorization: Bearer ${KEY}" \
  -X GET "${BASE_URL}/v1/models"

# 3. SGLang Qwen3.8-27B 本地推論
run_test "Qwen3.8-27B 本地推論 (SGLang on H200)" true \
  -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${KEY}" \
  -d '{
    "model": "Qwen3.8-27B",
    "messages": [{"role": "user", "content": "你好，請用一句話介紹你自己。"}],
    "max_tokens": 50
  }'

# 4. SGLang Qwen3.8 短別名測試
run_test "qwen3.8 別名推論" true \
  -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${KEY}" \
  -d '{
    "model": "qwen3.8",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 30
  }'

# 5. 虛擬用戶模型權限隔離測試 (Bob 僅能存取 GLM-5.2，存取 Qwen3.8 應為 HTTP 403)
((TOTAL_TESTS++))
echo -e "\n▶ 測試 $TOTAL_TESTS: 虛擬金鑰權限隔離 (未授權模型應攔截 403)"
BOB_KEY=$(python3 -c 'import json; d=json.load(open("api_keys.json")); print([k for k,v in d.items() if v.get("user_id")=="Bob"][0])' 2>/dev/null || echo "")
if [ -n "$BOB_KEY" ]; then
    TMP_FILE=$(mktemp)
    HTTP_CODE=$(curl -s -m 15 -w "%{http_code}" -o "$TMP_FILE" \
      -X POST "${BASE_URL}/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${BOB_KEY}" \
      -d '{
        "model": "Qwen3.8-27B",
        "messages": [{"role": "user", "content": "hi"}],
        "max_tokens": 20
      }')
    rm -f "$TMP_FILE"
    if [ "$HTTP_CODE" -eq 403 ]; then
        echo "✅ 通過 (成功攔截，HTTP 403 Forbidden)"
        ((PASSED_TESTS++))
    else
        echo "❌ 失敗 (預期 403，實際為 HTTP $HTTP_CODE)"
        ((FAILED_TESTS++))
    fi
else
    echo "⚠️  跳過 (api_keys.json 未找到 Bob 之 Key)"
fi

# 6. 國網 GenAI Portal 外部模型 (標記為可選測試，不中斷回傳碼)
echo -e "\n----------------------------------------------------------"
echo "🌐 外部國網 Portal 遠端模型測試 (可選項目，視國網配額與網路狀態而定)："
echo "----------------------------------------------------------"
run_test "外部 GLM-5.2 推論" false \
  -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${KEY}" \
  -d '{
    "model": "GLM-5.2",
    "messages": [{"role": "user", "content": "hi"}],
    "max_tokens": 20
  }' || true

run_test "外部 Kimi-K3 推論" false \
  -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${KEY}" \
  -d '{
    "model": "Kimi-K3",
    "messages": [{"role": "user", "content": "hi"}],
    "max_tokens": 20
  }' || true

echo -e "\n=========================================================="
echo " 📊 測試結果總結"
echo "=========================================================="
echo "  總執行項目 : $TOTAL_TESTS"
echo "  成功通過   : $PASSED_TESTS"
echo "  核心失敗   : $FAILED_TESTS"
echo "=========================================================="

if [ "$FAILED_TESTS" -gt 0 ]; then
    echo "❌ 測試未完全通過！請檢視上述失敗項目。"
    exit 1
else
    echo "🎉 所有必要核心項目均已成功通過！"
    exit 0
fi

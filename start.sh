#!/usr/bin/env bash
umask 077
set -e


DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

cd "$DIR"

# 確保日誌檔具備 600 權限 (防範呼叫端外部重導向未帶 umask 077)
if [ -f "$DIR/litellm.log" ]; then
    chmod 600 "$DIR/litellm.log" 2>/dev/null || true
fi

PID_FILE="$DIR/.litellm.pid"


# 1. 載入虛擬環境
if [ -d "$DIR/.venv" ]; then
    source "$DIR/.venv/bin/activate"
fi

# 2. 載入環境變數
if [ -f "$DIR/.env" ]; then
    set -a
    source "$DIR/.env"
    set +a
fi

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-54821}"

# 3. 檢查是否已有正在運行的實例
if [ -f "$PID_FILE" ]; then
    EXISTING_PID=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
        echo "⚠️  LiteLLM Proxy 已在運行中 (PID: $EXISTING_PID, Port: $PORT)"
        echo "   若需重啟，請先執行 ./stop.sh"
        exit 1
    else
        rm -f "$PID_FILE"
    fi
fi

# 4. 動態合成最新 Runtime 設定檔 (嚴格 Fail-Closed，禁止沿用失敗之舊設定)
CONFIG_TO_USE="$DIR/config.yaml"
if [ -f "$DIR/scripts/generate_runtime_config.py" ]; then
    echo "🔹 執行端點探測與 Runtime 設定生成..."
    if python3 "$DIR/scripts/generate_runtime_config.py"; then
        if [ -f "$DIR/config.runtime.yaml" ]; then
            CONFIG_TO_USE="$DIR/config.runtime.yaml"
        fi
    else
        echo "❌ 錯誤：Runtime 設定檔生成失敗，終止啟動以策安全！" >&2
        exit 1
    fi
fi

# 若 SGLang API Key 尚未由 .env 載入，自 sglang-qwen/config.env 同步
if [ -z "${SGLANG_API_KEY:-}" ] && [ -f "$DIR/sglang-qwen/config.env" ]; then
    DETECTED_SGLANG_KEY=$(grep "^SGLANG_API_KEY=" "$DIR/sglang-qwen/config.env" | cut -d'=' -f2 | tr -d '\r\n')
    if [ -n "$DETECTED_SGLANG_KEY" ]; then
        export SGLANG_API_KEY="$DETECTED_SGLANG_KEY"
        echo "🔹 動態載入 SGLang 金鑰 : [已配置]"
    fi
fi

echo "=========================================================="
echo " 🚀 正在啟動 LiteLLM Proxy (${HOST}:${PORT})"
echo " 🔹 設定檔   : ${CONFIG_TO_USE}"
echo " 🔹 PID 檔案 : ${PID_FILE}"
echo "=========================================================="

# 記錄目前 PID (exec 保留原 PID)
echo "$$" > "$PID_FILE"

exec litellm --config "$CONFIG_TO_USE" --host "$HOST" --port "$PORT"

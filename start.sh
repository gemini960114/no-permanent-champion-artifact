#!/usr/bin/env bash
umask 077
set -e


DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

cd "$DIR"

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

# 4. 自動偵測 SGLang 動態節點端點 (若存在 endpoint.info)
if [ -f "$DIR/sglang-qwen/endpoint.info" ]; then
    DETECTED_ENDPOINT=$(grep "^ENDPOINT=" "$DIR/sglang-qwen/endpoint.info" | cut -d'=' -f2 | tr -d '\r\n')
    if [ -n "$DETECTED_ENDPOINT" ]; then
        export SGLANG_API_BASE="${DETECTED_ENDPOINT}/v1"
        echo "🔹 動態載入 SGLang 端點 : $SGLANG_API_BASE"
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
echo " 🔹 設定檔   : ${DIR}/config.yaml"
echo " 🔹 PID 檔案 : ${PID_FILE}"
echo "=========================================================="

# 記錄目前 PID (exec 保留原 PID)
echo "$$" > "$PID_FILE"

exec litellm --config "$DIR/config.yaml" --host "$HOST" --port "$PORT"

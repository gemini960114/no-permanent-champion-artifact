#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PID_FILE="$DIR/.litellm.pid"

if [ -f "$DIR/.env" ]; then
    set -a
    source "$DIR/.env"
    set +a
fi

PORT="${PORT:-54821}"
CURRENT_USER="$(whoami)"

echo "=========================================================="
echo " 🛑 準備停止 LiteLLM Proxy (Port: $PORT)"
echo "=========================================================="

STOPPED=false

# 方法 1: 優先透過 .litellm.pid 停止
if [ -f "$PID_FILE" ]; then
    TARGET_PID=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$TARGET_PID" ] && kill -0 "$TARGET_PID" 2>/dev/null; then
        echo "🔹 依據 PID 檔案停止 LiteLLM (PID: $TARGET_PID)..."
        kill -TERM "$TARGET_PID" 2>/dev/null || true
        for _ in {1..10}; do
            if ! kill -0 "$TARGET_PID" 2>/dev/null; then
                break
            fi
            sleep 0.5
        done
        if kill -0 "$TARGET_PID" 2>/dev/null; then
            echo "⚠️  進程未能在時限內關閉，發送強制終止 (SIGKILL)..."
            kill -9 "$TARGET_PID" 2>/dev/null || true
        fi
        STOPPED=true
    fi
    rm -f "$PID_FILE" "$DIR/.litellm_node"
fi

# 方法 2: 安全後備 (僅搜尋當前使用者名下的 litellm 程序)
MATCHED_PIDS=$(pgrep -u "$CURRENT_USER" -f "litellm.*--port.*$PORT" 2>/dev/null || true)
if [ -n "$MATCHED_PIDS" ]; then
    for PID in $MATCHED_PIDS; do
        echo "🔹 停止當前使用者名下殘存的 LiteLLM 進程 (PID: $PID)..."
        kill -TERM "$PID" 2>/dev/null || true
        # 與方法 1 相同之優雅終止：最多等待 5 秒再送 SIGKILL
        for _ in {1..10}; do
            if ! kill -0 "$PID" 2>/dev/null; then
                break
            fi
            sleep 0.5
        done
        if kill -0 "$PID" 2>/dev/null; then
            echo "⚠️  進程未能在時限內關閉，發送強制終止 (SIGKILL)..."
            kill -9 "$PID" 2>/dev/null || true
        fi
        STOPPED=true
    done
fi

if [ "$STOPPED" = true ]; then
    echo "✅ LiteLLM Proxy 已成功停止。"
else
    echo "ℹ️  未發現屬於當前使用者的 LiteLLM Proxy 執行實例。"
fi
echo "=========================================================="

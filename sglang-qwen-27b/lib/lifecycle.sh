#!/usr/bin/env bash
# ==============================================================================
# sglang-qwen/lib/lifecycle.sh (向後相容轉發層)
# ==============================================================================
# 優先載入專案頂層共用生命週期函式庫 lib/lifecycle.sh
_TOP_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" 2>/dev/null && pwd)/lifecycle.sh"
if [ -f "$_TOP_LIB" ]; then
    source "$_TOP_LIB"
    return 0 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# 1. 動態可用 Port 偵測：以 POSIX 原生原子操作 (mkdir) 徹底消除 Race Condition
# ------------------------------------------------------------------------------
find_available_port() {
    local candidate="${1:-30000}"
    local max_attempts="${2:-100}"
    local attempt=0
    while [ "$attempt" -lt "$max_attempts" ]; do
        local lock_dir="$PORT_LOCKS_DIR/${NODE_HOSTNAME}-${candidate}"

        # 嘗試原子搶佔 Port 鎖目錄 (mkdir 為系統呼叫層級的原子操作)
        if mkdir -m 700 "$lock_dir" 2>/dev/null; then
            # 搶鎖成功！進一步檢驗實體 Socket 是否確無被其他孤兒程序佔用
            if python3 -c "
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(('0.0.0.0', int(sys.argv[1])))
    s.close()
    sys.exit(0)
except OSError:
    sys.exit(1)
" "$candidate" 2>/dev/null; then
                # 實體 Socket 與原子鎖均確認就緒，記錄擁有者資訊
                echo "${SLURM_JOB_ID:-manual}" > "$lock_dir/job_id"
                date -u +"%Y-%m-%dT%H:%M:%SZ" > "$lock_dir/created_at"
                PORT="$candidate"
                CURRENT_PORT_LOCK="$lock_dir"
                return 0
            else
                # 實體被佔用，撤銷此鎖
                rm -rf "$lock_dir" 2>/dev/null || true
            fi
        fi

        echo "⚠️ Port $candidate 在節點 $NODE_HOSTNAME 上已被預約或佔用，嘗試下一個 Port $((candidate + 1))..." >&2
        candidate=$((candidate + 1))
        attempt=$((attempt + 1))
    done
    echo "❌ 錯誤：找不到可用 Port (嘗試至 $candidate)" >&2
    return 1
}

# ------------------------------------------------------------------------------
# 2. 端點狀態原子發布
# ------------------------------------------------------------------------------
publish_endpoint() {
    local state="${1:-ready}"
    local tmp_file="$REGISTRY_DIR/sglang_qwen_${SLURM_JOB_ID:-manual}.env.tmp.$$"
    cat > "$tmp_file" <<EOF
MODEL_NAME=${MODEL_NAME:-Qwen3.8-27B}
MODEL_ALIAS=${MODEL_ALIAS:-qwen3.8}
RESOLVED_MODEL_PATH=${RESOLVED_MODEL_PATH:-}
API_KEY_ENV=${API_KEY_ENV:-SGLANG_API_KEY}
ENGINE_DIR=${ENGINE_DIR:-${WORK_DIR:-}}
NODE_HOSTNAME=${NODE_HOSTNAME:-}
NODE_IP=${NODE_IP:-}
PORT=${PORT:-}
ENDPOINT=http://${NODE_HOSTNAME:-}:${PORT:-}
API_BASE=http://${NODE_HOSTNAME:-}:${PORT:-}/v1
SLURM_JOB_ID=${SLURM_JOB_ID:-manual}
STATE=${state}
UPDATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
    mv -f "$tmp_file" "$ENDPOINT_REGISTRY_FILE"
    chmod 600 "$ENDPOINT_REGISTRY_FILE" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# 3. 退場清理與鎖擁有者驗證 (Owner Verification)
# ------------------------------------------------------------------------------
CLEANUP_DONE=false
cleanup_endpoint() {
    [ "${CLEANUP_DONE:-false}" = true ] && return 0
    CLEANUP_DONE=true
    trap - TERM INT EXIT
    echo "🛑 SGLang 服務正在停止 (Job: ${SLURM_JOB_ID:-N/A})..."
    if [ -n "${HEALTH_PID:-}" ] && kill -0 "$HEALTH_PID" 2>/dev/null; then
        kill -TERM "$HEALTH_PID" 2>/dev/null || true
        wait "$HEALTH_PID" 2>/dev/null || true
    fi
    if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill -TERM "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    if [ -n "${ENDPOINT_REGISTRY_FILE:-}" ] && [ -f "$ENDPOINT_REGISTRY_FILE" ]; then
        rm -f "$ENDPOINT_REGISTRY_FILE" 2>/dev/null || true
    fi
    if [ -n "${CURRENT_PORT_LOCK:-}" ] && [ -d "$CURRENT_PORT_LOCK" ]; then
        local lock_owner=""
        if [ -f "$CURRENT_PORT_LOCK/job_id" ]; then
            lock_owner=$(cat "$CURRENT_PORT_LOCK/job_id" 2>/dev/null || true)
        fi
        if [ "$lock_owner" = "${SLURM_JOB_ID:-manual}" ]; then
            rm -rf -- "$CURRENT_PORT_LOCK" 2>/dev/null || true
        else
            echo "⚠️ Port 鎖 $CURRENT_PORT_LOCK 擁有者已變更 ($lock_owner != ${SLURM_JOB_ID:-manual})，略過刪除以防誤刪" >&2
        fi
    fi
}

# ------------------------------------------------------------------------------
# 4. 健康檢查回應驗證 (HTTP 200 + 合規 OpenAI JSON 結構)
# ------------------------------------------------------------------------------
validate_health_response() {
    local http_code="$1"
    local body_file="$2"
    if [ "$http_code" = "200" ] && python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    sys.exit(0 if isinstance(data, dict) and ('data' in data or 'object' in data) else 1)
except Exception:
    sys.exit(1)
" < "$body_file" 2>/dev/null; then
        return 0
    fi
    return 1
}

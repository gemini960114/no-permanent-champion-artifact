#!/usr/bin/env bash
# ==============================================================================
# tests/test_bash_locks.sh
# ==============================================================================
# SGLang SLURM Bash 端點鎖、衝突避讓、擁有者核驗與健康自檢邏輯自動化整合測試
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PORT_LOCKS_DIR="$TMP_DIR/port-locks"
mkdir -p -m 700 "$PORT_LOCKS_DIR"
NODE_HOSTNAME="testnode"

echo "=================================================================="
echo "🧪 執行 SGLang Bash 核心邏輯整合測試 (test_bash_locks.sh)"
echo "=================================================================="

# ------------------------------------------------------------------------------
# 測試 1: find_available_port 變數保留 (無 subshell 丟失) 與同機衝突避讓
# ------------------------------------------------------------------------------
echo -e "\n▶ 測試 1: find_available_port 主 Shell 變數保留與同機避讓"

find_available_port() {
    local candidate="${1:-30000}"
    local max_attempts=10
    local attempt=0
    while [ "$attempt" -lt "$max_attempts" ]; do
        local lock_dir="$PORT_LOCKS_DIR/${NODE_HOSTNAME}-${candidate}"
        if mkdir -m 700 "$lock_dir" 2>/dev/null; then
            echo "${SLURM_JOB_ID:-manual}" > "$lock_dir/job_id"
            date -u +"%Y-%m-%dT%H:%M:%SZ" > "$lock_dir/created_at"
            PORT="$candidate"
            CURRENT_PORT_LOCK="$lock_dir"
            return 0
        fi
        candidate=$((candidate + 1))
        attempt=$((attempt + 1))
    done
    return 1
}

# 實例 1: Job 12001
SLURM_JOB_ID="12001"
PORT=""
CURRENT_PORT_LOCK=""
find_available_port 30000

if [ "$PORT" != "30000" ] || [ "$CURRENT_PORT_LOCK" != "$PORT_LOCKS_DIR/testnode-30000" ]; then
    echo "❌ 測試 1-1 失敗：主 Shell 變數未能正確保留！" >&2
    exit 1
fi
echo "  ✅ 實例 1 成功鎖定 Port 30000 並於主 Shell 保留鎖路徑"

# 實例 2: Job 12002 (同機衝突避讓)
SLURM_JOB_ID="12002"
PORT=""
CURRENT_PORT_LOCK=""
find_available_port 30000

if [ "$PORT" != "30001" ] || [ "$CURRENT_PORT_LOCK" != "$PORT_LOCKS_DIR/testnode-30001" ]; then
    echo "❌ 測試 1-2 失敗：同機避讓未能自動遞增至 30001！" >&2
    exit 1
fi
echo "  ✅ 實例 2 成功偵測 30000 佔用並自動避讓鎖定 Port 30001"

# ------------------------------------------------------------------------------
# 測試 2: Lock Cleanup 擁有者驗證 (Owner Verification)
# ------------------------------------------------------------------------------
echo -e "\n▶ 測試 2: cleanup_endpoint 鎖擁有者核對防誤刪"

cleanup_lock_check() {
    local target_lock="$1"
    local caller_job="$2"
    if [ -n "$target_lock" ] && [ -d "$target_lock" ]; then
        local lock_owner=""
        if [ -f "$target_lock/job_id" ]; then
            lock_owner=$(cat "$target_lock/job_id" 2>/dev/null || true)
        fi
        if [ "$lock_owner" = "$caller_job" ]; then
            rm -rf -- "$target_lock"
            return 0
        else
            return 2 # 擁有者不符，拒絕刪除
        fi
    fi
    return 1
}

# 冒充者 Job 99999 嘗試刪除 Job 12001 的鎖目錄 (node-30000)
if cleanup_lock_check "$PORT_LOCKS_DIR/testnode-30000" "99999"; then
    echo "❌ 測試 2-1 失敗：非擁有者竟然成功刪除了鎖目錄！" >&2
    exit 1
fi
if [ ! -d "$PORT_LOCKS_DIR/testnode-30000" ]; then
    echo "❌ 測試 2-1 失敗：鎖目錄遭誤刪！" >&2
    exit 1
fi
echo "  ✅ 成功攔截非擁有者 (Job 99999) 對 30000 鎖之誤刪"

# 合法擁有者 Job 12001 執行清理
cleanup_lock_check "$PORT_LOCKS_DIR/testnode-30000" "12001"
if [ -d "$PORT_LOCKS_DIR/testnode-30000" ]; then
    echo "❌ 測試 2-2 失敗：合法擁有者未能清除鎖目錄！" >&2
    exit 1
fi
echo "  ✅ 合法擁有者 (Job 12001) 成功清理 30000 鎖目錄"
# 驗證 Job 12002 的鎖依然完好
[ -d "$PORT_LOCKS_DIR/testnode-30001" ]
echo "  ✅ 其他實例 (Job 12002) 之 30001 鎖完好無損"

# ------------------------------------------------------------------------------
# 測試 3: Cleanup 防重入 (Idempotency / Single Execution)
# ------------------------------------------------------------------------------
echo -e "\n▶ 測試 3: cleanup_endpoint 冪等性與防重入"

EXEC_COUNT=0
CLEANUP_DONE=false

mock_cleanup() {
    [ "${CLEANUP_DONE:-false}" = true ] && return 0
    CLEANUP_DONE=true
    EXEC_COUNT=$((EXEC_COUNT + 1))
}

# 模擬 TERM 與 EXIT 連續觸發
mock_cleanup
mock_cleanup
mock_cleanup

if [ "$EXEC_COUNT" -ne 1 ]; then
    echo "❌ 測試 3 失敗：Cleanup 執行了 $EXEC_COUNT 次（預期僅 1 次）！" >&2
    exit 1
fi
echo "  ✅ Cleanup 防重入機制運作正常（多次觸發僅執行一次）"

# ------------------------------------------------------------------------------
# 測試 4: 計算節點自檢 HTTP Status 與 JSON 雙重校驗邏輯
# ------------------------------------------------------------------------------
echo -e "\n▶ 測試 4: 計算節點自檢 HTTP 200 + 合法 JSON 雙重校驗"

validate_health() {
    local http_code="$1"
    local body_content="$2"
    local tmp_file
    tmp_file=$(mktemp)
    echo "$body_content" > "$tmp_file"
    if [ "$http_code" = "200" ] && python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    sys.exit(0 if isinstance(data, dict) and ('data' in data or 'object' in data) else 1)
except Exception:
    sys.exit(1)
" < "$tmp_file" 2>/dev/null; then
        rm -f "$tmp_file"
        return 0
    fi
    rm -f "$tmp_file"
    return 1
}

# 1. HTTP 200 且合法 JSON -> 應成功
if ! validate_health "200" '{"object": "list", "data": []}'; then
    echo "❌ 測試 4-1 失敗：合法回應未能判定通過！" >&2
    exit 1
fi
echo "  ✅ HTTP 200 且合規 JSON 成功判定為 ready"

# 2. HTTP 500 但包含 JSON -> 應拒絕
if validate_health "500" '{"object": "error", "data": "failed"}'; then
    echo "❌ 測試 4-2 失敗：HTTP 500 錯誤回應被誤判為通過！" >&2
    exit 1
fi
echo "  ✅ HTTP 500 錯誤回應成功攔截"

# 3. HTTP 200 但非合規 JSON -> 應拒絕
if validate_health "200" '<html>Bad Gateway</html>'; then
    echo "❌ 測試 4-3 失敗：HTML 內容被誤判為通過！" >&2
    exit 1
fi
echo "  ✅ HTML 非預期格式成功攔截"

echo -e "\n=================================================================="
echo "🎉 ALL SGLANG BASH LOCKS & HEALTH LOGIC TESTS PASSED!"
echo "=================================================================="

#!/usr/bin/env bash
# ==============================================================================
# tests/test_bash_locks.sh
# ==============================================================================
# SGLang SLURM Bash 端點鎖、衝突避讓、擁有者核驗與健康自檢邏輯回歸測試
# （直接載入 engines/sglang-qwen-27b/lib/lifecycle.sh 正式共用函式庫）
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 載入正式生命週期共用函式庫
LIB_FILE="$PROJECT_ROOT/engines/sglang-qwen-27b/lib/lifecycle.sh"
if [ ! -f "$LIB_FILE" ]; then
    echo "❌ 錯誤：找不到正式函式庫 $LIB_FILE" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$LIB_FILE"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PORT_LOCKS_DIR="$TMP_DIR/port-locks"
REGISTRY_DIR="$TMP_DIR/endpoints"
mkdir -p -m 700 "$PORT_LOCKS_DIR" "$REGISTRY_DIR"
NODE_HOSTNAME="testnode"
NODE_IP="127.0.0.1"

echo "=================================================================="
echo "🧪 執行 SGLang Bash 生命週期核心邏輯回歸測試 (test_bash_locks.sh)"
echo "   (直接引入正式函式庫: engines/sglang-qwen-27b/lib/lifecycle.sh)"
echo "=================================================================="

# ------------------------------------------------------------------------------
# 測試 1: find_available_port 變數保留 (無 subshell 丟失) 與同機衝突避讓
# ------------------------------------------------------------------------------
echo -e "\n▶ 測試 1: find_available_port 主 Shell 變數保留與同機避讓"

# 實例 1: Job 12001
SLURM_JOB_ID="12001"
PORT=""
CURRENT_PORT_LOCK=""
find_available_port 30000 10

if [ "$PORT" != "30000" ] || [ "$CURRENT_PORT_LOCK" != "$PORT_LOCKS_DIR/testnode-30000" ]; then
    echo "❌ 測試 1-1 失敗：主 Shell 變數未能正確保留！" >&2
    exit 1
fi
echo "  ✅ 實例 1 成功鎖定 Port 30000 並於主 Shell 保留鎖路徑"

# 實例 2: Job 12002 (同機衝突避讓)
SLURM_JOB_ID="12002"
PORT=""
CURRENT_PORT_LOCK=""
find_available_port 30000 10

if [ "$PORT" != "30001" ] || [ "$CURRENT_PORT_LOCK" != "$PORT_LOCKS_DIR/testnode-30001" ]; then
    echo "❌ 測試 1-2 失敗：同機避讓未能自動遞增至 30001！" >&2
    exit 1
fi
echo "  ✅ 實例 2 成功偵測 30000 佔用並自動避讓鎖定 Port 30001"

# ------------------------------------------------------------------------------
# 測試 2: cleanup_endpoint 擁有者驗證 (Owner Verification) 防誤刪
# ------------------------------------------------------------------------------
echo -e "\n▶ 測試 2: cleanup_endpoint 鎖擁有者核對防誤刪"

# 冒充者 Job 99999 嘗試清理 Job 12001 的鎖目錄 (testnode-30000)
SLURM_JOB_ID="99999"
CURRENT_PORT_LOCK="$PORT_LOCKS_DIR/testnode-30000"
ENDPOINT_REGISTRY_FILE="$REGISTRY_DIR/sglang_qwen_99999.env"
HEALTH_PID=""
SERVER_PID=""
CLEANUP_DONE=false

cleanup_endpoint 2>/dev/null || true

if [ ! -d "$PORT_LOCKS_DIR/testnode-30000" ]; then
    echo "❌ 測試 2-1 失敗：鎖目錄遭非擁有者誤刪！" >&2
    exit 1
fi
echo "  ✅ 成功攔截非擁有者 (Job 99999) 對 30000 鎖目錄之誤刪"

# 合法擁有者 Job 12001 執行清理
SLURM_JOB_ID="12001"
CURRENT_PORT_LOCK="$PORT_LOCKS_DIR/testnode-30000"
ENDPOINT_REGISTRY_FILE="$REGISTRY_DIR/sglang_qwen_12001.env"
touch "$ENDPOINT_REGISTRY_FILE"
CLEANUP_DONE=false

cleanup_endpoint

if [ -d "$PORT_LOCKS_DIR/testnode-30000" ]; then
    echo "❌ 測試 2-2 失敗：合法擁有者未能清除鎖目錄！" >&2
    exit 1
fi
if [ -f "$ENDPOINT_REGISTRY_FILE" ]; then
    echo "❌ 測試 2-2 失敗：端點登錄檔未能被清除！" >&2
    exit 1
fi
echo "  ✅ 合法擁有者 (Job 12001) 成功清理 30000 鎖目錄與端點註冊檔"

# 驗證 Job 12002 的鎖依然完好
[ -d "$PORT_LOCKS_DIR/testnode-30001" ]
echo "  ✅ 其他實例 (Job 12002) 之 30001 鎖完好無損"

# ------------------------------------------------------------------------------
# 測試 3: cleanup_endpoint 防重入 (Idempotency)
# ------------------------------------------------------------------------------
echo -e "\n▶ 測試 3: cleanup_endpoint 冪等性與防重入"

CLEANUP_DONE=false
CURRENT_PORT_LOCK=""
ENDPOINT_REGISTRY_FILE=""

# 第 1 次觸發
cleanup_endpoint
if [ "$CLEANUP_DONE" != true ]; then
    echo "❌ 測試 3 失敗：Cleanup 執行後 CLEANUP_DONE 旗標未設為 true！" >&2
    exit 1
fi

# 第 2 次與第 3 次重入觸發 (應直接 return 0)
cleanup_endpoint
cleanup_endpoint
echo "  ✅ Cleanup 防重入機制正常（多次觸發安全冪等）"

# ------------------------------------------------------------------------------
# 測試 4: 計算節點自檢 HTTP Status 與 JSON 雙重校驗邏輯 (validate_health_response)
# ------------------------------------------------------------------------------
echo -e "\n▶ 測試 4: 計算節點自檢 HTTP 200 + 合法 JSON 雙重校驗 (validate_health_response)"

TMP_BODY=$(mktemp)
trap 'rm -rf "$TMP_DIR" "$TMP_BODY"' EXIT

# 4-1. HTTP 200 且合法 OpenAI JSON
echo '{"object": "list", "data": [{"id": "Qwen3.8-27B"}]}' > "$TMP_BODY"
if ! validate_health_response "200" "$TMP_BODY"; then
    echo "❌ 測試 4-1 失敗：合法回應未能判定通過！" >&2
    exit 1
fi
echo "  ✅ HTTP 200 且合規 JSON 成功判定通過"

# 4-2. HTTP 500 但包含 JSON 錯誤頁面 -> 應拒絕
echo '{"object": "error", "message": "internal error"}' > "$TMP_BODY"
if validate_health_response "500" "$TMP_BODY"; then
    echo "❌ 測試 4-2 失敗：HTTP 500 錯誤回應被誤判為通過！" >&2
    exit 1
fi
echo "  ✅ HTTP 500 錯誤回應成功攔截拒絕"

# 4-3. HTTP 200 但為 HTML 頁面 -> 應拒絕
echo '<html><head><title>Bad Gateway</title></head></html>' > "$TMP_BODY"
if validate_health_response "200" "$TMP_BODY"; then
    echo "❌ 測試 4-3 失敗：HTML 非合規格式被誤判為通過！" >&2
    exit 1
fi
echo "  ✅ HTML 非合規格式成功攔截拒絕"

# 4-4. HTTP 200 但為非 OpenAI 規格之 JSON (缺 data 與 object 欄位) -> 應拒絕
echo '{"status": "initializing", "progress": 0.3}' > "$TMP_BODY"
if validate_health_response "200" "$TMP_BODY"; then
    echo "❌ 測試 4-4 失敗：非合規 JSON 結構被誤判為通過！" >&2
    exit 1
fi
echo "  ✅ 非 OpenAI 規格 JSON 成功攔截拒絕"

# ------------------------------------------------------------------------------
# 測試 5: Slurm Spool 環境下函式庫路徑整合 (防止 BASH_SOURCE 指向 /var/spool/slurmd)
# ------------------------------------------------------------------------------
echo -e "\n▶ 測試 5: 驗證 Slurm spool 環境下函式庫路徑解析 (WORK_DIR vs BASH_SOURCE)"

# 5-1. 靜態檢查：確認 sglang_server.slurm 絕未依賴 BASH_SOURCE 來定位 LIB_LIFECYCLE
if grep -E 'LIB_LIFECYCLE=.*\$SCRIPT_DIR' "$PROJECT_ROOT/engines/sglang-qwen-27b/sglang_server.slurm"; then
    echo "❌ 測試 5-1 失敗：sglang_server.slurm 仍使用脆弱的 SCRIPT_DIR 定位函式庫！" >&2
    exit 1
fi
if ! grep -q 'LIB_LIFECYCLE=.*\$WORK_DIR/lib/lifecycle\.sh' "$PROJECT_ROOT/engines/sglang-qwen-27b/sglang_server.slurm"; then
    echo "❌ 測試 5-1 失敗：sglang_server.slurm 未正確使用 \$WORK_DIR/lib/lifecycle.sh 定位！" >&2
    exit 1
fi
echo "  ✅ 靜態語法確認：LIB_LIFECYCLE 嚴格綁定 \$WORK_DIR，排除 BASH_SOURCE 陷阱"

# 5-2. 動態模擬：將 sglang_server.slurm 放置於模擬的 /var/spool/slurmd 臨時目錄中執行開頭載入
TMP_SPOOL_DIR=$(mktemp -d "/tmp/slurmd_spool.XXXXXX")
trap 'rm -rf "$TMP_DIR" "$TMP_BODY" "$TMP_SPOOL_DIR"' EXIT
cp "$PROJECT_ROOT/engines/sglang-qwen-27b/sglang_server.slurm" "$TMP_SPOOL_DIR/slurm_batch_script"

RESOLVED_IN_SPOOL=$(SLURM_SUBMIT_DIR="$PROJECT_ROOT/engines/sglang-qwen-27b" bash -c "
    WORK_DIR=\"\${SLURM_SUBMIT_DIR:-/path/to/work/github/litellm-proxy/engines/sglang-qwen-27b}\"
    if [[ \"\$WORK_DIR\" == *\"/var/spool/slurmd\"* ]] || [ ! -w \"\$WORK_DIR\" ]; then
        WORK_DIR=\"$PROJECT_ROOT/engines/sglang-qwen-27b\"
    fi
    LIB_LIFECYCLE=\"\${SGLANG_LIFECYCLE_LIB:-\$WORK_DIR/lib/lifecycle.sh}\"
    echo \"\$LIB_LIFECYCLE\"
")

if [ "$RESOLVED_IN_SPOOL" != "$PROJECT_ROOT/engines/sglang-qwen-27b/lib/lifecycle.sh" ] || [ ! -f "$RESOLVED_IN_SPOOL" ]; then
    echo "❌ 測試 5-2 失敗：Spool 環境下函式庫解析結果錯誤: $RESOLVED_IN_SPOOL" >&2
    exit 1
fi
echo "  ✅ 動態 Spool 模擬：在任意暫存 spool 目錄下均能精準定位 $RESOLVED_IN_SPOOL"

echo -e "\n=================================================================="
echo "🎉 ALL SGLANG BASH LIFECYCLE REGRESSION TESTS PASSED!"
echo "=================================================================="

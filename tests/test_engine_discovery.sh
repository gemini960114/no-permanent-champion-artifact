#!/usr/bin/env bash
# ==============================================================================
# tests/test_engine_discovery.sh
# ==============================================================================
# 驗證引擎發現規則於 generate_runtime_config.py 與 start.sh 兩處一致：
# 1. engines/ 下「含 config.env 或 config.env.example 之子目錄」才視為引擎
# 2. 無設定檔之子目錄 (如 _template/) 不被掃入
# 3. symlink 以 realpath 去重
# 4. 掃描範圍僅限 engines/ (專案根目錄的 config.env 不會被誤掃)
# 5. 環境變數既有值優先，不被引擎 config.env 覆蓋
# 測試金鑰一律使用假值 (非真實秘密)。
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

# ------------------------------------------------------------------------------
# 建立假引擎樹：
#   engines/alpha/config.env        → TEST_API_KEY=fake-alpha
#   engines/beta/config.env.example → (僅範本；視為引擎但不提供金鑰)
#   engines/_template/              → 空目錄 (不視為引擎)
#   engines/alpha-link → alpha      → symlink (應去重)
#   ./config.env (根目錄)           → TEST_API_KEY=fake-root-level (不應被掃入)
# ------------------------------------------------------------------------------
mkdir -p "$TMP_ROOT/engines/alpha" "$TMP_ROOT/engines/beta" "$TMP_ROOT/engines/_template"
printf 'TEST_API_KEY=fake-alpha\n' > "$TMP_ROOT/engines/alpha/config.env"
printf '# example only\n' > "$TMP_ROOT/engines/beta/config.env.example"
ln -s "$TMP_ROOT/engines/alpha" "$TMP_ROOT/engines/alpha-link"
printf 'TEST_API_KEY=fake-root-level\n' > "$TMP_ROOT/config.env"
# 端點檔引用 TEST_API_KEY → loader 會將其納入查找清單
mkdir -p "$TMP_ROOT/runtime/endpoints"
printf 'API_KEY_ENV=TEST_API_KEY\nSTATE=ready\n' > "$TMP_ROOT/runtime/endpoints/fake_engine_1.env"

echo "=================================================================="
echo "🧪 引擎發現規則一致性測試 (python get_engine_dirs vs start.sh loader)"
echo "=================================================================="

# ------------------------------------------------------------------------------
# 測試 1: Python 端 get_engine_dirs —— 引擎辨識與 symlink 去重
# ------------------------------------------------------------------------------
PY_DIRS=$(python3 -c "
import sys, os
sys.path.insert(0, '$PROJECT_ROOT/scripts')
import generate_runtime_config as grc
grc.PROJECT_ROOT = '$TMP_ROOT'
print(' '.join(sorted(os.path.basename(d) for d in grc.get_engine_dirs())))
")

if [ "$PY_DIRS" != "alpha beta" ]; then
    echo "❌ 測試 1 失敗：python get_engine_dirs 結果異常: [$PY_DIRS] (預期: alpha beta)" >&2
    exit 1
fi
echo "  ✅ python get_engine_dirs: alpha + beta 入列、_template 排除、alpha-link 去重"

# ------------------------------------------------------------------------------
# 測試 2: start.sh 端 load_engine_api_keys —— 掃描範圍僅限 engines/
# ------------------------------------------------------------------------------
sed -n '/^load_engine_api_keys() {$/,/^}$/p' "$PROJECT_ROOT/start.sh" > "$TMP_ROOT/func.sh"
if [ ! -s "$TMP_ROOT/func.sh" ]; then
    echo "❌ 測試 2 失敗：無法自 start.sh 擷取 load_engine_api_keys 函式" >&2
    exit 1
fi

LOADER_RESULT=$(bash -c '
set -u
DIR="'"$TMP_ROOT"'"
source "'"$TMP_ROOT"'/func.sh"
unset TEST_API_KEY
load_engine_api_keys > /dev/null
echo "${TEST_API_KEY:-none}"
')

if [ "$LOADER_RESULT" != "fake-alpha" ]; then
    echo "❌ 測試 2 失敗：start.sh loader 載入結果異常: [$LOADER_RESULT] (預期: fake-alpha；若為 fake-root-level 代表掃描範圍未限 engines/)" >&2
    exit 1
fi
echo "  ✅ start.sh loader: 自 engines/alpha 載入金鑰，根目錄 config.env 未被誤掃"

# ------------------------------------------------------------------------------
# 測試 3: 環境變數既有值優先 (不被引擎 config.env 覆蓋)
# ------------------------------------------------------------------------------
PRIORITY_RESULT=$(bash -c '
set -u
DIR="'"$TMP_ROOT"'"
source "'"$TMP_ROOT"'/func.sh"
TEST_API_KEY="fake-preset-value"
export TEST_API_KEY
load_engine_api_keys > /dev/null
echo "${TEST_API_KEY:-none}"
')

if [ "$PRIORITY_RESULT" != "fake-preset-value" ]; then
    echo "❌ 測試 3 失敗：環境變數既有值遭到引擎 config.env 覆蓋: [$PRIORITY_RESULT]" >&2
    exit 1
fi
echo "  ✅ 環境變數既有值優先，未被引擎 config.env 覆蓋"

# ------------------------------------------------------------------------------
# 測試 4: 只含 config.env.example 之引擎目錄不會產生金鑰汙染
# ------------------------------------------------------------------------------
EXAMPLE_CHECK=$(bash -c '
set -u
DIR="'"$TMP_ROOT"'"
source "'"$TMP_ROOT"'/func.sh"
unset TEST_API_KEY
load_engine_api_keys > /dev/null
if [ -n "${TEST_API_KEY:-}" ]; then echo "SET"; else echo "EMPTY"; fi
')
# alpha 已提供金鑰，故此處應為 SET；另驗證 beta (僅 example) 不會被視為金鑰來源：
# 將 alpha 移除後重新載入，僅剩 beta 時不得載入任何金鑰
mv "$TMP_ROOT/engines/alpha/config.env" "$TMP_ROOT/engines/alpha/config.env.bak"
BETA_RESULT=$(bash -c '
set -u
DIR="'"$TMP_ROOT"'"
source "'"$TMP_ROOT"'/func.sh"
unset TEST_API_KEY
load_engine_api_keys > /dev/null
if [ -n "${TEST_API_KEY:-}" ]; then echo "SET"; else echo "EMPTY"; fi
')
mv "$TMP_ROOT/engines/alpha/config.env.bak" "$TMP_ROOT/engines/alpha/config.env"

if [ "$BETA_RESULT" != "EMPTY" ]; then
    echo "❌ 測試 4 失敗：只含 config.env.example 之目錄不應提供金鑰" >&2
    exit 1
fi
echo "  ✅ 僅含 config.env.example 之引擎目錄不提供金鑰 (辨識為引擎但無金鑰來源)"

echo "=================================================================="
echo "🎉 ALL ENGINE DISCOVERY CONSISTENCY TESTS PASSED!"
echo "=================================================================="

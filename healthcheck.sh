#!/usr/bin/env bash
# ==============================================================================
# LiteLLM Gateway 健康檢查 (healthcheck.sh)
# 用法：./healthcheck.sh           完整檢查 (含各模型上游健康探測，約 10~60 秒)
#       ./healthcheck.sh --quick   略過模型上游探測 (數秒內完成)
# 須在 LiteLLM 執行節點上執行；不做推論、不消耗 token。任一核心項目失敗則回傳碼 1。
# ==============================================================================
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "$DIR"

QUICK=false
[ "${1:-}" = "--quick" ] && QUICK=true

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
OOD_PREFIX="/node/${NODE}/${PORT}"

FAILED=0
WARNED=0
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; ((WARNED++)); }
fail() { echo "❌ $*"; ((FAILED++)); }

# http_code <curl args...>：只回傳 HTTP 狀態碼 (連線失敗為 000)
http_code() {
    curl -s -m 10 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || true
}

echo "=========================================================="
echo " 🩺 LiteLLM Gateway 健康檢查 (${NODE} → ${BASE_URL})"
echo "    $(date '+%F %T')"
echo "=========================================================="

# 1. 設定
if [ -z "$KEY" ]; then
    fail ".env 中未找到 LITELLM_MASTER_KEY，無法進行驗證類檢查"
    exit 1
fi
if [ -z "$TARGET_IP" ]; then
    fail "無法解析 ${NODE} 的內網 IP (HOST=${HOST:-internal})"
    exit 1
fi

# 2. 行程
RECORDED_NODE=$(cat "$DIR/.litellm_node" 2>/dev/null || echo "")
PID=$(cat "$DIR/.litellm.pid" 2>/dev/null || echo "")
if [ -n "$RECORDED_NODE" ] && [ "$RECORDED_NODE" != "$NODE" ]; then
    fail "LiteLLM 記錄在 ${RECORDED_NODE} 執行，請到該節點執行本腳本"
    exit 1
fi
if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    ok "行程存活 (PID ${PID}，已運行 $(ps -o etime= -p "$PID" | tr -d ' '))"
else
    fail "行程不存在 (PID 檔: ${PID:-無})，請執行 ./start.sh"
fi

# 2.5 外部 VM 反向隧道資訊（若曾以 ~/start-litellm-tunnel.sh 啟動）
TUNNEL_INFO="$HOME/.litellm-tunnel.info"
if [ -f "$TUNNEL_INFO" ]; then
    T_NODE=$(sed -n 's/^node=//p' "$TUNNEL_INFO" 2>/dev/null)
    T_PID=$(sed -n 's/^autossh_pid=//p' "$TUNNEL_INFO" 2>/dev/null)
    if [ -n "$T_NODE" ]; then
        echo "ℹ️  反向隧道運行於 ${T_NODE} (autossh PID: ${T_PID:-未知})；停止：ssh ${T_NODE} 後執行 ~/stop-litellm-tunnel.sh"
    fi
fi

# 3. 監聽位址 (不應綁公網)
LISTEN=$(ss -ltnH "sport = :${PORT}" 2>/dev/null | awk '{print $4}' | sort -u | tr '\n' ' ')
if [ -z "$LISTEN" ]; then
    fail "埠 ${PORT} 無人監聽"
elif echo "$LISTEN" | grep -qE '^(0\.0\.0\.0|\*|\[::\]):| (0\.0\.0\.0|\*|\[::\]):'; then
    warn "監聽 ${LISTEN}— 會一併綁到公網 IP，建議 .env 設 HOST=internal"
else
    ok "監聽位址 ${LISTEN}"
fi

# 4. 存活探測
CODE=$(http_code "${BASE_URL}/health/liveliness")
[ "$CODE" = 200 ] && ok "存活探測 /health/liveliness (HTTP 200)" || fail "存活探測 /health/liveliness (HTTP ${CODE})"

# 5. 鑑權與模型清單
MODELS_JSON=$(curl -s -m 10 -H "Authorization: Bearer ${KEY}" "${BASE_URL}/v1/models" 2>/dev/null || true)
MODELS=$(echo "$MODELS_JSON" | python3 -c 'import sys,json; print(" ".join(m["id"] for m in json.load(sys.stdin)["data"]))' 2>/dev/null || true)
if [ -n "$MODELS" ]; then
    ok "模型清單 ($(echo "$MODELS" | wc -w) 個)：${MODELS}"
else
    fail "無法取得模型清單 /v1/models"
fi
CODE=$(http_code "${BASE_URL}/v1/models")
[ "$CODE" = 401 ] && ok "未帶金鑰被拒 (HTTP 401)" || fail "未帶金鑰應回 401，實際 HTTP ${CODE}"

# 6. OOD /node/ 反向代理
if [ "${ENABLE_OOD_PROXY:-false}" = "true" ]; then
    CODE=$(http_code -H "Authorization: Bearer ${KEY}" "${BASE_URL}${OOD_PREFIX}/v1/models")
    [ "$CODE" = 200 ] && ok "OOD 前綴路徑 ${OOD_PREFIX}/v1/models (HTTP 200)" || fail "OOD 前綴路徑 ${OOD_PREFIX}/v1/models (HTTP ${CODE})"

    PUBLIC="https://${OOD_SERVER:-nano4.nchc.org.tw}${OOD_PREFIX}/health/liveliness"
    CODE=$(http_code -k "$PUBLIC")
    case "$CODE" in
        302) ok "OOD 入口正常且受 SSO 保護 (未登入 → 302)" ;;
        000) warn "連不到 OOD 入口 ${OOD_SERVER:-nano4.nchc.org.tw}" ;;
        *)   warn "OOD 入口未登入回 HTTP ${CODE} (預期 302)" ;;
    esac

    CERT_END=$(echo | timeout 10 openssl s_client -connect "${OOD_SERVER:-nano4.nchc.org.tw}:443" -servername "${OOD_SERVER:-nano4.nchc.org.tw}" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -n "$CERT_END" ]; then
        if [ "$(date -d "$CERT_END" +%s 2>/dev/null || echo 0)" -lt "$(date +%s)" ]; then
            warn "OOD 入口 TLS 憑證已過期 (${CERT_END})，客戶端需 -k / verify=False"
        else
            ok "OOD 入口 TLS 憑證有效至 ${CERT_END}"
        fi
    fi
else
    echo "ℹ️  OOD 代理未啟用 (ENABLE_OOD_PROXY=false)，略過"
fi

# 7. 各模型上游健康 (LiteLLM /health 會對每個部署發出探測請求)
if [ "$QUICK" = false ]; then
    HEALTH_JSON=$(curl -s -m 90 -H "Authorization: Bearer ${KEY}" "${BASE_URL}/health" 2>/dev/null || true)
    HEALTH_REPORT=$(echo "$HEALTH_JSON" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for e in d.get("healthy_endpoints", []):
    print("OK", e.get("model", "?"), e.get("api_base", ""))
for e in d.get("unhealthy_endpoints", []):
    err = str(e.get("error", "")).splitlines()[0][:120] if e.get("error") else ""
    print("BAD", e.get("model", "?"), err)
' 2>/dev/null || true)
    if [ -z "$HEALTH_REPORT" ]; then
        fail "上游健康探測 /health 無回應或格式錯誤"
    else
        while read -r status model rest; do
            if [ "$status" = OK ]; then
                ok "上游 ${model#openai/} 健康"
            else
                fail "上游 ${model#openai/} 異常：${rest}"
            fi
        done <<< "$HEALTH_REPORT"
    fi
else
    echo "ℹ️  --quick 模式，略過上游模型探測"
fi

# 8. 叢集內自建推論端點 (runtime/endpoints)
if compgen -G "$DIR/runtime/endpoints/*.env" > /dev/null; then
    READY=$(grep -l '^STATE=ready' "$DIR"/runtime/endpoints/*.env 2>/dev/null | wc -l)
    TOTAL=$(ls "$DIR"/runtime/endpoints/*.env | wc -l)
    ok "自建推論端點：${READY}/${TOTAL} 個 ready"
else
    echo "ℹ️  目前無自建推論端點 (SGLang/vLLM 作業未執行)"
fi

# 9. 本次啟動後的日誌錯誤 (排除 401/403 鑑權拒絕，那是正常防護，本腳本第 5 項也會產生一筆)
LOG="$DIR/litellm.log"
PROC_OUT=$(readlink "/proc/${PID:-0}/fd/1" 2>/dev/null || echo "")
if [ -n "$PROC_OUT" ] && [ "$PROC_OUT" != "$LOG" ]; then
    echo "ℹ️  LiteLLM 輸出到 ${PROC_OUT} (前景啟動)，未寫入 litellm.log，略過日誌檢查"
    echo "    關閉該終端機會一併停止服務；背景啟動：setsid nohup ./start.sh >> litellm.log 2>&1 < /dev/null & disown"
elif [ -f "$LOG" ]; then
    START_LINE=$(grep -n '正在啟動 LiteLLM' "$LOG" | tail -1 | cut -d: -f1)
    ERRS=$(tail -n +"${START_LINE:-1}" "$LOG" | grep -E 'ERROR|Traceback' | grep -vcE 'Exception occured - 40[13]' || true)
    if [ "$ERRS" -eq 0 ]; then
        ok "litellm.log 本次啟動後無異常錯誤"
    else
        warn "litellm.log 本次啟動後有 ${ERRS} 筆錯誤，請檢視：tail -n +${START_LINE:-1} litellm.log | grep -E 'ERROR|Traceback'"
    fi
fi

echo "=========================================================="
if [ "$FAILED" -eq 0 ]; then
    echo " 🎉 健康檢查通過 (警告 ${WARNED} 項)"
    [ "${ENABLE_OOD_PROXY:-false}" = "true" ] && echo " 🔹 OOD 代理 : https://${OOD_SERVER:-nano4.nchc.org.tw}${OOD_PREFIX}/v1"
    echo "=========================================================="
    exit 0
else
    echo " ❌ 健康檢查失敗 ${FAILED} 項 (警告 ${WARNED} 項)"
    echo "=========================================================="
    exit 1
fi

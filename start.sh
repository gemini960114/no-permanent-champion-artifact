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

HOST="${HOST:-internal}"
PORT="${PORT:-54821}"
NODE="$(hostname -s)"

# HOST=internal：綁定本機主機名解析到的叢集內網 IP (例 login-4 → LOGIN_4_IP)，
# 不綁公網 IP；SSH -L <節點>:<埠> 與 OOD /node/<節點>/ 皆以同一主機名解析，換節點也對得上。
if [ "$HOST" = "internal" ]; then
    HOST=$(getent ahostsv4 "$NODE" | awk 'NR==1 {print $1}')
    if [ -z "$HOST" ] || [[ "$HOST" == 127.* ]]; then
        echo "❌ 錯誤：無法解析 ${NODE} 的內網 IP (getent 結果: '${HOST}')，請在 .env 明確指定 HOST=<內網 IP>" >&2
        exit 1
    fi
fi

# Open OnDemand /node/ 反向代理 (與 SSH Tunnel 並存)
# OOD 會把完整路徑 /node/<主機>/<埠>/... 原封轉給後端，SERVER_ROOT_PATHS 讓 LiteLLM
# 同時接受「帶前綴 (OOD)」與「不帶前綴 (SSH Tunnel)」兩種請求。
OOD_URL=""
if [ "${ENABLE_OOD_PROXY:-false}" = "true" ]; then
    if [[ "$HOST" == 127.* ]] || [ "$HOST" = "localhost" ]; then
        echo "❌ 錯誤：ENABLE_OOD_PROXY=true 需要 HOST=internal（OOD 代理從 login-1/login-2 跨機連入），目前 HOST=${HOST}" >&2
        exit 1
    fi
    export SERVER_ROOT_PATHS="/node/${NODE}/${PORT}"
    OOD_URL="https://${OOD_SERVER:-nano4.nchc.org.tw}${SERVER_ROOT_PATHS}/v1"
else
    unset SERVER_ROOT_PATHS
fi

# 3. 檢查是否已有正在運行的實例 (支援冪等自動重啟)
if [ -f "$PID_FILE" ]; then
    EXISTING_PID=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
        echo "🔄 偵測到現有 LiteLLM Proxy 實例 (PID: $EXISTING_PID)，自動執行優雅重啟以套用最新端點..."
        "$DIR/stop.sh" || true
        sleep 1
    else
        rm -f "$PID_FILE"
    fi
fi

# 4. 載入各引擎鑑權金鑰 (供 Runtime 設定生成探測與 litellm 執行期 os.environ/XXX 解析使用)
#    .env 既有值優先；未設定者自各引擎目錄 config.env 自動收集 (sglang-* / vllm-*，symlink 去重)
load_engine_api_keys() {
    local key_var cfg val ep_file d real
    # 收集端點檔實際引用之 API_KEY_ENV 變數名稱 (另固定納入 SGLANG_API_KEY / VLLM_API_KEY)
    local key_vars="SGLANG_API_KEY VLLM_API_KEY"
    for ep_file in "$DIR"/runtime/endpoints/*.env; do
        [ -e "$ep_file" ] || continue
        key_var=$(grep -m1 '^API_KEY_ENV=' "$ep_file" | cut -d'=' -f2 | tr -d '\r\n')
        if [ -n "$key_var" ] && [[ " $key_vars " != *" $key_var "* ]]; then
            key_vars="$key_vars $key_var"
        fi
    done
    # 收集引擎目錄 (engines/ 下含 config.env 或 config.env.example 之子目錄才視為引擎，
    # 與 generate_runtime_config.py 的 get_engine_dirs() 判定規則一致；readlink -f 對 symlink 去重)
    local engine_dirs=() seen=""
    for d in "$DIR"/engines/*; do
        [ -d "$d" ] || continue
        if [ ! -f "$d/config.env" ] && [ ! -f "$d/config.env.example" ]; then
            continue
        fi
        real=$(readlink -f "$d" 2>/dev/null || echo "$d")
        [[ " $seen " == *" $real "* ]] && continue
        seen="$seen $real"
        engine_dirs+=("$d")
    done
    # 依序查找：環境變數 (含 .env 載入值) 已有者優先，其次各引擎 config.env
    # (僅輸出變數名稱與配置狀態，絕不印出金鑰值)
    for key_var in $key_vars; do
        if [ -n "${!key_var:-}" ]; then
            continue
        fi
        for d in "${engine_dirs[@]}"; do
            cfg="$d/config.env"
            [ -f "$cfg" ] || continue
            val=$(grep -m1 "^${key_var}=" "$cfg" | cut -d'=' -f2- | tr -d '\r\n')
            # 去除成對包覆之引號 (注意：雙引號內必須寫 \'，裸 ' 會被視為空 pattern 而無法去除)
            val="${val#\"}"
            val="${val%\"}"
            val="${val#\'}"
            val="${val%\'}"
            if [ -n "$val" ]; then
                export "$key_var=$val"
                echo "🔹 動態載入 ${key_var} : [已配置]"
                break
            fi
        done
    done
    return 0
}
load_engine_api_keys

# 5. 動態合成最新 Runtime 設定檔 (嚴格 Fail-Closed，禁止沿用失敗之舊設定)
#    generator 回傳碼：0 = 全部成功；2 = 部分成功 (Slurm UNKNOWN 端點略過)；
#    僅 2 允許帶警告繼續啟動，其餘非 0 一律中止
CONFIG_TO_USE="$DIR/config.yaml"
if [ -f "$DIR/scripts/generate_runtime_config.py" ]; then
    echo "🔹 執行端點探測與 Runtime 設定生成..."
    GEN_RC=0
    python3 "$DIR/scripts/generate_runtime_config.py" || GEN_RC=$?
    if [ "$GEN_RC" -eq 0 ] || [ "$GEN_RC" -eq 2 ]; then
        if [ -f "$DIR/config.runtime.yaml" ]; then
            CONFIG_TO_USE="$DIR/config.runtime.yaml"
        fi
        if [ "$GEN_RC" -eq 2 ]; then
            echo "⚠️  警告：Runtime 設定生成僅部分成功 (Slurm 狀態查詢異常，已略過狀態未知之端點)，以現有可用端點繼續啟動！" >&2
        fi
    else
        echo "❌ 錯誤：Runtime 設定檔生成失敗，終止啟動以策安全！" >&2
        exit 1
    fi
fi

echo "=========================================================="
echo " 🚀 正在啟動 LiteLLM Proxy (${HOST}:${PORT})"
echo " 🔹 執行節點 : ${NODE}"
echo " 🔹 設定檔   : ${CONFIG_TO_USE}"
echo " 🔹 PID 檔案 : ${PID_FILE}"
echo " 🔹 SSH 通道 : ssh -L 127.0.0.1:4000:${NODE}:${PORT} → http://127.0.0.1:4000/v1"
if [ -n "$OOD_URL" ]; then
    echo " 🔹 OOD 代理 : ${OOD_URL}（需附 OnDemand 登入 Cookie）"
fi
echo "=========================================================="

# 記錄目前 PID 與執行節點 (exec 保留原 PID)
echo "$$" > "$PID_FILE"
echo "$NODE" > "$DIR/.litellm_node"

exec litellm --config "$CONFIG_TO_USE" --host "$HOST" --port "$PORT"

#!/usr/bin/env bash
# ==============================================================================
# LiteLLM Proxy 一鍵安裝與環境初始化腳本 (install.sh)
# 適用環境：HPC Linux 環境 (支援 uv 或原生 python3 venv)
# ==============================================================================

umask 077
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

cd "$DIR"

echo "=========================================================="
echo " 開始部署 LiteLLM Proxy 虛擬環境與相依套件..."
echo " 專案目錄: $DIR"
echo "=========================================================="

# 1. 檢查並建立虛擬環境 (.venv)
if command -v uv >/dev/null 2>&1; then
    echo "▶ 偵測到 uv 工具，使用 'uv venv' 建立虛擬環境..."
    if [ ! -d ".venv" ]; then
        uv venv
    else
        echo "  (.venv 已存在，跳過建立)"
    fi
    echo "▶ 依據 requirements.txt 安裝相依套件 (鎖定 litellm[proxy]==1.102.0)..."
    uv pip install -r requirements.txt
else
    echo "▶ 未偵測到 uv，使用原生 'python3 -m venv' 建立虛擬環境..."
    if [ ! -d ".venv" ]; then
        python3 -m venv .venv
    else
        echo "  (.venv 已存在，跳過建立)"
    fi
    echo "▶ 升級 pip 並安裝相依套件..."
    .venv/bin/python -m pip install -U pip
    .venv/bin/pip install -r requirements.txt
fi

# 2. 初始化 .env 設定檔 (若不存在則自動建立)
if [ ! -f ".env" ]; then
    echo "▶ 初始化 .env 環境變數檔..."
    NEW_MASTER_KEY=$(.venv/bin/python -c "import secrets; print('sk-litellm-'+secrets.token_urlsafe(32))")
    NEW_SGLANG_KEY=$(.venv/bin/python -c "import secrets; print('sk-sglang-'+secrets.token_urlsafe(24))")
    cat > .env <<EOF
# 監聽主機 (預設 127.0.0.1 避免被區網其他用戶掃描)
HOST=127.0.0.1
PORT=54821

# LiteLLM Master Key (擁有最高管理權限)
LITELLM_MASTER_KEY=${NEW_MASTER_KEY}

# 國網 GenAI Portal API Key (請填入您的國網 API Key)
NCHC_GENAI_API_KEY=${NCHC_GENAI_API_KEY:-your_nchc_genai_api_key}

# HPC 內部 SGLang Qwen 端點與鑑權金鑰 (可由 start.sh 自動自 endpoint.info 載入)
SGLANG_API_BASE=http://node-H:30000/v1
SGLANG_API_KEY=${NEW_SGLANG_KEY}
EOF
    chmod 600 .env
    echo "  .env 已建立，並設定權限為 600 (僅自己可讀寫)。"
else
    chmod 600 .env
fi

if [ -f "sglang-qwen/config.env" ]; then
    chmod 600 sglang-qwen/config.env
fi


# 3. 確保輔助腳本具備執行權限 (含 sglang-qwen 子模組)
chmod +x start.sh stop.sh test.sh key_tool.py install.sh 2>/dev/null || true
if [ -d "sglang-qwen" ]; then
    chmod +x sglang-qwen/*.sh 2>/dev/null || true
fi

# 4. 驗證 Gateway 安裝
echo "▶ 驗證 Gateway 安裝版本..."
VERSION_INFO=$(.venv/bin/python -c "import importlib.metadata; print('LiteLLM version: ' + importlib.metadata.version('litellm'))" 2>/dev/null || true)
echo "  $VERSION_INFO"


# 5. 檢查 sglang-qwen 推論容器環境 (純 Singularity 零安裝架構)
echo "▶ 檢查 sglang-qwen 推論環境..."
SIF_FILE="/path/to/work/containers/sglang_latest.sif"
if [ -f "$SIF_FILE" ]; then
    echo "  ✅ 找到 SGLang 容器映像檔: $SIF_FILE"
else
    echo "  ⚠️ 未找到 SGLang 容器映像檔 ($SIF_FILE)，若需使用本機推論請確認容器路徑。"
fi
if command -v /usr/bin/singularity >/dev/null 2>&1 || command -v singularity >/dev/null 2>&1; then
    echo "  ✅ 系統 Singularity/Apptainer 執行檔就緒 (sglang-qwen 為零安裝容器化，無需 pip 安裝套件)。"
fi

echo "=========================================================="
echo " 🎉 安裝已全部完成！"
echo " [Gateway 網關管理]"
echo " • 啟動網關: ./start.sh 或 (umask 077; nohup ./start.sh > litellm.log 2>&1 &)"


echo " • 測試服務: ./test.sh"
echo " • 管理金鑰: ./key_tool.py generate --name 'User' --models all"
echo " • 停止服務: ./stop.sh"
echo ""
echo " [sglang-qwen 內部推論服務 (純 Singularity 零安裝)]"
echo " • 下載權重: cd sglang-qwen && ./download_model.sh Qwen/Qwen3.8-27B"
echo " • 派送服務: cd sglang-qwen && ./submit_slurm.sh"
echo " • 檢查狀態: cd sglang-qwen && ./check_service.sh"
echo "=========================================================="

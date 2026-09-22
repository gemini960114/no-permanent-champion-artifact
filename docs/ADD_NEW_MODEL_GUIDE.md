# 5 分鐘新增模型與推論引擎指南 (Plug-and-Play Model Guide)

本指南說明如何在 LiteLLM Gateway 叢集中，以**標準化、隨插即用（Plug-and-Play）**的方式新增任何 LLM 模型或推論後端（例如 SGLang、vLLM、TGI、TensorRT-LLM 等）。

---

## 1. 架構核心概念

LiteLLM Gateway 採用**全自動動態端點註冊與健康探測機制**：
```
[ 各模型專屬目錄 (sglang-*/vllm-*) ]
              │
              ▼ (Slurm Batch Job)
       lib/lifecycle.sh (共用生命週期管理)
       ├── 1. 原子目錄鎖競搶可用 Port (runtime/port_locks/)
       ├── 2. 階段一註冊 (state=starting)
       ├── 3. 啟動 SGLang / vLLM 服務
       └── 4. 階段二探測與註冊 (HTTP 200 + JSON 驗證, state=ready)
              │
              ▼ (寫入 runtime/endpoints/job_<ID>.env)
   scripts/generate_runtime_config.py (自動偵測)
              │
              ▼
    LiteLLM Proxy 動態路由與負載平衡 (Port 4000)
```

**新增模型只需要建立一個目錄，無需修改核心代理程式碼！**

---

## 2. 目錄命名規範

目錄請依循 `<推論引擎>-<模型名稱與規格>/` 命名規範：

| 目錄範例 | 推論引擎 | 模型 | 預設 Port 區間 |
| :--- | :--- | :--- | :--- |
| `sglang-qwen-27b/` | SGLang | Qwen/Qwen3.8-27B-FP8 | 30000+ |
| `sglang-qwen-flash/` | SGLang | Qwen/Qwen3.8-Flash-Next-FP8 | 32000+ |
| `vllm-deepseek-flash/`| vLLM | deepseek-ai/DeepSeek-V4.1-Flash | 33000+ |
| `vllm-llama-70b/` (自訂) | vLLM | meta-llama/Llama-3.3-70B-Instruct | 34000+ |

---

## 3. 目錄必要檔案結構

每個模型目錄應包含以下檔案（可直接複製現有目錄作為模板）：

```bash
<engine>-<model>/
├── config.env.example       # 設定檔範本（包含模型路徑、TP、參數、Port 等）
├── config.env               # 本地實際設定檔（不納入 Git）
├── <engine>_server.slurm    # Slurm 批次啟動腳本（呼叫 lib/lifecycle.sh）
├── submit_slurm.sh          # 便捷送出作業腳本
├── check_service.sh         # 本地健康檢測與狀態檢查腳本
├── download_model.sh        # HuggingFace 模型下載腳本
└── README.md                # 該模型專屬維運與參數說明
```

---

## 4. 快速新增步驟 (5 步驟完成)

### 步驟 1：複製現有目錄作為模板

若要新增 SGLang 模型：
```bash
cp -r sglang-qwen-flash vllm-new-model  # 或複製 sglang-qwen-flash
cd vllm-new-model
```

### 步驟 2：編輯 `config.env.example` 與 `config.env`

設定模型名稱、路徑、GPU 需求與基礎 Port：
```bash
# 核心模型識別
MODEL_NAME="My-New-Model"
MODEL_ALIAS="my-model,my-model-fast"
MODEL_DIR="/path/to/work/models/My-New-Model"
HF_MODEL_NAME="org/My-New-Model"

# Slurm 叢集設定
SLURM_PARTITION="normal"
GPUS_PER_NODE=4
CPUS_PER_TASK=32
MEM="120G"

# 推論引擎設定
BASE_PORT=34000
API_KEY_ENV="SGLANG_API_KEY"   # 或 VLLM_API_KEY，若無可填 dummy
```

### 步驟 3：在 Slurm 腳本中載入 `lib/lifecycle.sh`

在 `<engine>_server.slurm` 中，只需以下 4 個標準生命週期呼叫：

```bash
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/lib/lifecycle.sh"

# 1. 註冊 EXIT 清理程序
trap 'cleanup_endpoint_and_lock "${LOCKED_PORT:-}" "${LIFECYCLE_ENV_FILE:-}" "$JOB_ID"' EXIT

# 2. 自動尋找可用連接埠並鎖定
PORT=$(acquire_dynamic_port "$BASE_PORT" 50 "$JOB_ID" "$NODE_HOSTNAME")
LOCKED_PORT="$PORT"
export PORT

# 3. 階段一：註冊 starting 狀態
ENDPOINT_ENV_FILE=$(register_endpoint_starting "$JOB_ID" "$NODE_HOSTNAME" "$PORT" \
    "$MODEL_NAME" "$MODEL_ALIAS" "$MODEL_DIR" "$API_KEY_ENV")
LIFECYCLE_ENV_FILE="$ENDPOINT_ENV_FILE"

# 4. 啟動背景推論引擎 (例如 sglang serve 或 vllm serve)
sglang serve --model-path "$MODEL_DIR" --port "$PORT" ... &
ENGINE_PID=$!

# 5. 階段二：等待探測並升級為 ready 狀態
API_BASE="http://${NODE_HOSTNAME}:${PORT}/v1"
wait_and_register_endpoint "$ENDPOINT_ENV_FILE" "$API_BASE" "$API_KEY" 600 "$ENGINE_PID"

# 6. 等待行程結束
wait "$ENGINE_PID"
```

### 步驟 4：下載模型權重並送出 Slurm 作業

```bash
bash download_model.sh
bash submit_slurm.sh
```

### 步驟 5：驗證 LiteLLM Gateway 自動掛載

作業啟動並通過健康檢查後：
1. 檢視端點狀態：
   ```bash
   cat runtime/endpoints/job_<ID>.env
   # 應顯示 STATE="ready"
   ```
2. LiteLLM 透過 `generate_runtime_config.py` 自動讀取新端點：
   ```bash
   python3 scripts/generate_runtime_config.py
   ```
3. 透過 LiteLLM 代理端點測試新模型：
   ```bash
   curl -s http://127.0.0.1:4000/v1/models \
     -H "Authorization: Bearer sk-litellm-master-key" | jq .
   ```
   您自訂的模型名稱 `My-New-Model` 與 `my-model` 將自動出現在清單中！

---

## 5. Port 鎖與清理機制保障 (Fail-Closed)

- **原子目錄鎖**：`mkdir runtime/port_locks/<NODE>-<PORT>` 具備 POSIX 原子性，保證跨節點多作業不發生 Port 衝突。
- **所有權檢查**：清理程序只會刪除本 Job 建立的鎖與端點檔案，絕不誤刪其他運行中 Job。
- **孤兒鎖自動回收**：若節點意外斷電或 Slurm `scancel -f`，逾時 10 分鐘且確定本機/遠端 Port 未佔用時，系統會自動回收無主孤兒鎖。

---

## 6. 範例目錄對照

- **SGLang 範例**：參考 [sglang-qwen-27b/](file:///path/to/work/github/litellm-proxy/sglang-qwen-27b) 或 [sglang-qwen-flash/](file:///path/to/work/github/litellm-proxy/sglang-qwen-flash)
- **vLLM 範例**：參考 [vllm-deepseek-flash/](file:///path/to/work/github/litellm-proxy/vllm-deepseek-flash)
- **共用生命週期程式庫**：參考 [lib/lifecycle.sh](file:///path/to/work/github/litellm-proxy/lib/lifecycle.sh)

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
               ▼ (寫入 runtime/endpoints/${ENGINE_NAME}_${SLURM_JOB_ID:-manual}.env)
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

# 健康自檢逾時 (秒)：超過仍未就緒將自動 scancel 釋放 GPU (權重載入慢的模型請調大，如 1800)
HEALTH_TIMEOUT=600
```

> 🔑 **`API_KEY_ENV` 金鑰解析規則**：Gateway 端（`start.sh` 的端點探測與 LiteLLM 執行期 `os.environ/XXX` 解析）依「環境變數（含專案根目錄 `.env`）→ 該引擎目錄的 `config.env`」順序查找 `API_KEY_ENV` 指名的變數，找不到**不會**退回其他引擎的金鑰。
> 由於環境變數優先且同名變數僅對應一個值，**多個引擎若要使用不同金鑰，請各自採用不同的變數名稱**（例如 `MYMODEL_API_KEY`）並同步設定 `API_KEY_ENV`。
> 端點檔會自動寫入 `ENGINE_DIR` 供合成器回溯源頭；legacy 檔案缺少此欄位時，合成器會掃描各引擎目錄（`sglang-*` / `vllm-*`）並對 symlink 去重。

### 步驟 3：以 `vllm_server.slurm` 為範本修改 Slurm 腳本

**請勿從空白腳本重寫**。直接複製最新的 [`vllm-deepseek-flash/vllm_server.slurm`](../vllm-deepseek-flash/vllm_server.slurm) 再修改——它已內建 `ENGINE_DIR` 寫入、`${SLURM_JOB_ID:-manual}` fallback、`HEALTH_TIMEOUT` 逾時自動退場與選用參數條件傳入，照抄才不會與函式庫實作脫節：

```bash
cp vllm-deepseek-flash/vllm_server.slurm mymodel_server.slurm
```

需要修改的位置只有以下幾處（其餘照抄）：

| 修改處 | 範本中的值 | 說明 |
| :--- | :--- | :--- |
| `#SBATCH --job-name=` | `vllm_deepseek` | Slurm 作業名稱（同時用於 log 檔名） |
| `WORK_DIR` fallback 路徑 | `/work/.../vllm-deepseek-flash` | Slurm spool 環境下 `BASH_SOURCE` 指向 `/var/spool/slurmd`，需絕對路徑 fallback |
| `ENGINE_NAME` | `vllm_deepseek` | 端點檔前綴：`runtime/endpoints/${ENGINE_NAME}_${SLURM_JOB_ID:-manual}.env` |
| `ENDPOINT_REGISTRY_FILE` | `vllm_deepseek_${SLURM_JOB_ID:-manual}.env` | 與 `ENGINE_NAME` 保持一致 |
| `API_KEY_ENV`（於 `config.env`） | `VLLM_API_KEY` | 引擎鑑權金鑰的變數名（解析規則見步驟 2） |
| `CMD=( ... )` 啟動指令 | `vllm serve "$RESOLVED_MODEL_PATH" ...` | 換成新引擎的啟動指令；選用參數比照 `--api-key` 的條件附加寫法，變數為空時勿傳旗標 |

腳本中的生命週期接點全部來自 [`lib/lifecycle.sh`](../lib/lifecycle.sh)（**不需自行實作**，以下函式與變數名稱皆可在現有腳本中 grep 到）：

```bash
# 1. 載入共用函式庫 (計算節點上 BASH_SOURCE 指向 /var/spool/slurmd，須以 WORK_DIR/PROJECT_ROOT 定位)
source "$LIB_LIFECYCLE"

# 2. 原子搶佔可用 Port (必須於主 Shell 直接呼叫，避免 subshell 變數丟失)
find_available_port "$PORT_BASE" 100

# 3. 註冊退場清理 trap (冪等防重入 + Port 鎖擁有者核驗)
trap cleanup_endpoint TERM INT EXIT

# 4. 兩階段發布：先 starting，背景健康自檢通過後再 ready
publish_endpoint "starting"
publish_endpoint "ready"

# 5. 健康自檢：HTTP 200 + OpenAI 相容 JSON 雙重校驗
validate_health_response "$HTTP_CODE" "$TMP_BODY"
```

> ⚠️ 背景健康自檢逾時（`HEALTH_TIMEOUT` 秒）後會 `scancel` 自身作業（非 Slurm 環境對主 shell 送 TERM）釋放 GPU，並透過 `cleanup_endpoint` trap 清理端點檔與 Port 鎖——這段邏輯已內建於範本，修改啟動指令時**不要更動**。

### 步驟 4：下載模型權重並送出 Slurm 作業

```bash
bash download_model.sh
bash submit_slurm.sh
```

### 步驟 5：驗證 LiteLLM Gateway 自動掛載

作業啟動並通過健康檢查後：
1. 檢視端點狀態（檔名依 `ENGINE_NAME` 命名）：
   ```bash
   cat runtime/endpoints/vllm_deepseek_<JOB_ID>.env
   # 應顯示 STATE=ready
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

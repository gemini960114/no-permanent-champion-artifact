# SGLang Qwen3.8-27B on H200 (1x GPU) 部署與維運手冊

本目錄整合了從 `/path/to/work/models/opentwbench` 提取並最佳化的高性能推論引擎架構，專門用於在 NCHC H200 超算叢集上，以 **單卡 GPU (1 Core H200)** 搭配 **純 Singularity 容器映像檔 (`sglang_latest.sif`)** 部署 `Qwen/Qwen3.8-27B` 深度思考推理大模型服務。

---

## 目錄檔案結構

| 檔案名稱 | 類型 | 說明 |
| :--- | :--- | :--- |
| [`config.env`](file:///path/to/work/github/litellm-proxy/sglang-qwen/config.env) | 配置設定 | 集中管理所有 SLURM 資源配額、容器路徑、模型名稱與 SGLang 核心推論參數 |
| [`download_model.sh`](file:///path/to/work/github/litellm-proxy/sglang-qwen/download_model.sh) | 下載工具 | 透過 `uvx --from huggingface_hub` 高速下載 HuggingFace 模型權重至 `/path/to/work/models` |
| [`submit_slurm.sh`](file:///path/to/work/github/litellm-proxy/sglang-qwen/submit_slurm.sh) | 派送腳本 | 支援 `--dry-run` 與自訂參數，安全設定 `--chdir` 派送作業至 SLURM |
| [`sglang_server.slurm`](file:///path/to/work/github/litellm-proxy/sglang-qwen/sglang_server.slurm) | SLURM 核心 | 申請 1 顆 H200 GPU、綁定系統 Singularity 容器執行 `sglang serve` 的批次腳本 |
| [`check_service.sh`](file:///path/to/work/github/litellm-proxy/sglang-qwen/check_service.sh) | 檢查工具 | 即時查詢 SLURM 佇列、檢查 `endpoint.info`、測試 `/v1/models` 並檢視最新日誌 |
| `endpoint.info` | 動態輸出 | 服務啟動時自動記錄目前分配到的計算節點 Hostname、內網 IP 與 Port |
| `logs/` | 日誌目錄 | 存放 SLURM 標準輸出 (`.out`) 與 SGLang 運行日誌 (`.err`) |

---

## 依賴與安裝說明（Zero-Installation 零安裝架構）

> [!IMPORTANT]
> **本推論模組採用「純 Singularity 容器化」架構，宿主機零安裝、零環境污染！**
> 
> * **❌ 不需要建立 Python 虛擬環境 (`.venv`)**
> * **❌ 不需要 `pip install` 任何 PyTorch、SGLang 或 HuggingFace 套件**
> * **❌ 不需要手動編譯 FlashInfer 或 Triton CUDA 算子**
> 
> **核心理由**：所有重度深度學習環境（Python 3.12、SGLang 核心、PyTorch 2.13.0+cu130、FlashInfer、Triton GDN 算子、Mamba 快取模組等）均已預先打包封裝於唯讀容器映像檔：
> 📁 `/path/to/work/containers/sglang_latest.sif` (12GB)
> 
> 宿主機（Host）只需要使用系統內建的 `/usr/bin/singularity`（Apptainer 1.4.3）執行 SLURM 批次任務，即可直接開箱運行。下載模型部分亦採用隨選即跑的 `uvx` 工具，完全無需在宿主機全域環境安裝套件。

---

## 完整工作流指南 (Step-by-Step Guide)

### 步驟 1：下載模型權重

本專案使用 `uvx` 自動調用 `huggingface-cli` 進行多執行緒高速下載，並自動設定 Hugging Face Token：

```bash
cd /path/to/work/github/litellm-proxy/sglang-qwen

# 下載 Qwen/Qwen3.8-27B (約 52GB，18 個 safetensors 分塊)
./download_model.sh Qwen/Qwen3.8-27B
```
> 模型將儲存於 `/path/to/work/models/Qwen3.8-27B`。若目錄已存在且檔案齊全，腳本會自動驗證並略過。

---

### 步驟 2：提交 SLURM 1 GPU 作業

預設使用 `8gpus` 分割區，分配 1 顆 H200 GPU (143GB 顯存)、12 核心 CPU 與 120GB 主記憶體：

```bash
# 預覽提交指令 (Dry-run)
./submit_slurm.sh --dry-run

# 正式提交
./submit_slurm.sh
```

若欲指定其他分割區或帳號：
```bash
./submit_slurm.sh -p dev -a your-slurm-account
```

---

### 步驟 3：監控服務與啟動進度

SGLang 啟動時會歷經兩個階段：
1. **權重載入**（約 15~20 秒）：將 52GB 模型載入 H200 顯存，並劃分 Mamba State Cache (54GB) 與 FP8 KV Cache。
2. **CUDA Graph 暖機編譯**（約 3~5 分鐘）：針對 32k prefill 進行 106 種 token 區間的預熱捕獲（進度條顯示 `Capturing num tokens...`）。

透過檢查工具監控：
```bash
./check_service.sh
```
或即時觀看日誌：
```bash
# 查看最新啟動的作業日誌（請依實際 Job ID 替換）
tail -f logs/sglang-sglang_qwen-*.err
```

當看到以下訊息時，代表 SGLang 服務已完全就緒：
```text
INFO:     Application startup complete.
INFO:     Uvicorn running on http://0.0.0.0:30000 (Press CTRL+C to quit)
```

---

### 步驟 4：整合至 LiteLLM Proxy Gateway

當服務就緒後，`./check_service.sh` 會顯示分配到的節點名稱（例如 `node-H`）。

在根目錄的 [`config.yaml`](file:///path/to/work/github/litellm-proxy/config.yaml) 中加入以下設定：

```yaml
  # ==========================================
  # HPC 內部 SGLang 服務 (Qwen3.8-27B on H200)
  # ==========================================
  - model_name: Qwen3.8-27B
    litellm_params:
      model: openai//path/to/work/models/Qwen3.8-27B
      api_base: http://node-H:30000/v1
      api_key: dummy

  - model_name: qwen3.8
    litellm_params:
      model: openai//path/to/work/models/Qwen3.8-27B
      api_base: http://node-H:30000/v1
      api_key: dummy
```

重啟或啟動 LiteLLM Gateway：
```bash
cd /path/to/work/github/litellm-proxy
./stop.sh && ./start.sh > litellm.log 2>&1 &
```

---

### 步驟 5：外部筆電連線與 API 呼叫

在個人筆電（透過 SSH Tunnel 映射 `127.0.0.1:4000` 至 HPC Gateway）即可調用：

#### 🔹 Windows PowerShell 測試：
```powershell
$res = Invoke-RestMethod -Uri "http://127.0.0.1:4000/v1/chat/completions" `
  -Method Post `
  -Headers @{Authorization="Bearer <YOUR_LITELLM_MASTER_KEY>"} `
  -ContentType "application/json; charset=utf-8" `
  -Body '{"model": "Qwen3.8-27B", "messages": [{"role": "user", "content": "你好，請自我介紹！"}], "max_tokens": 150}'

# 檢視模型回答內文
$res.choices[0].message.content

# 檢視 Qwen 的深度思考歷程 (Reasoning Process)
$res.choices[0].message.reasoning_content
```

#### 🔹 Linux / macOS cURL 測試：
```bash
curl -X POST "http://127.0.0.1:4000/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <YOUR_LITELLM_MASTER_KEY>" \
  -d '{
    "model": "Qwen3.8-27B",
    "messages": [{"role": "user", "content": "你好，請自我介紹！"}],
    "max_tokens": 150
  }'
```

---

## 核心參數配置說明 (`config.env`)

所有運算資源與推論參數均在 [`config.env`](file:///path/to/work/github/litellm-proxy/sglang-qwen/config.env) 集中維護：

| 參數名稱 | 建議值 | 說明 |
| :--- | :--- | :--- |
| `SLURM_ACCOUNT` | `your-slurm-account` | SLURM 計費專案帳號 |
| `SLURM_PARTITION` | `8gpus` | SLURM 分割區名稱（亦可填 `dev` 進行快速測試） |
| `SLURM_GPUS` | `1` | 申請 GPU 數量（`--gres=gpu:H200:1`） |
| `SLURM_CPUS` | `12` | 搭配之 CPU 核心數 |
| `SLURM_MEM` | `120G` | 搭配之主記憶體容量 |
| `SIF_PATH` | `/path/to/work/containers/sglang_latest.sif` | Singularity SIF 容器映像檔路徑 |
| `PORT` | `30000` | SGLang API 監聽連接埠 |
| `KV_CACHE_DTYPE` | `fp8_e4m3` | KV Cache 採用 FP8 格式以節省顯存並加大並發能力 |
| `MEM_FRACTION` | `0.85` | 靜態佔用 GPU 顯存比例（H200 約劃分 122GB） |
| `ATTENTION_BACKEND` | `flashinfer` | 注意力算子後端加速 |
| `CHUNKED_PREFILL_SIZE` | `32768` | 啟用分塊 Prefill，最大支援 32k tokens |
| `MAX_PREFILL_TOKENS` | `32768` | 單次最大 Prefill Token 上限 |
| `REASONING_PARSER` | `qwen3` | 自動啟用 Qwen3 深度思考推理輸出解析 |
| `TOOL_CALL_PARSER` | `qwen3_coder` | 支援 Function / Tool Calling 語法解析 |
| `MAMBA_FULL_MEMORY_RATIO` | `4.59` | 專用 Mamba 狀態空間快取記憶體倍率 |
| `MAMBA_RADIX_CACHE_STRATEGY` | `extra_buffer` | Mamba Radix Cache 快取策略 |
| `MAMBA_SSM_DTYPE` | `float32` | Mamba SSM 運算精確度 |
| `SGLANG_API_KEY` | *(隨機字串)* | SGLang 後端安全鑑權金鑰，防止 HPC 內網未授權直連 |


---

## 關鍵技術踩坑與最佳實踐 (Troubleshooting)

1. **容器映像檔純淨性**：
   * `/path/to/work/containers/sglang_latest.sif` 為純原裝映像檔，**完全不需要在裡面額外安裝任何套件**。內部已自建 Python 3.12、SGLang、FlashInfer、Triton 與 Mamba 算子。
2. **Singularity 驅動相容性**：
   * 計算節點上必須優先使用宿主機的 `/usr/bin/singularity`（Apptainer 1.4.3），不可隨意引用 `/work/envstack/...` 的舊版執行檔，以確保完整相容 **NVIDIA Driver 580.65 / CUDA 13.0**。
3. **工作目錄權限 (`mkdir logs: Permission denied`)**：
   * 提交 SLURM 任務時必須帶有 `--chdir`，否則計算節點會預設執行於 `/var/spool/slurmd/` 導致無寫入權限。
4. **容器內執行檔路徑**：
   * SGLang 位於 `/opt/sglang/bin/sglang`，在 Singularity 執行時需以絕對路徑調用。

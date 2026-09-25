# LiteLLM & SGLang H200 地端高併發壓力測試指引 (Client-Side Benchmarks)

本目錄提供一套**在外部客戶端（地端測試 VM 或筆電）**透過 SSH Tunnel 穿透至國網 HPC 叢集，對 LiteLLM Gateway 及後端 SGLang H200 叢集進行高併發壓力測試的完整工具與說明。

---

## 🏗️ 網路與通道架構圖

國網入口 `nano4.nchc.org.tw` 具有輪詢負載平衡機制，外部連線會隨機分派至 5 台登入節點（`login-1` ~ `login-5`）。

```text
[外部測試 VM / 筆電]
  │
  │  (SSH Tunnel 通道)
  ▼
[nano4.nchc.org.tw] ──▶ 隨機分配登入節點 (如 login-1 ~ login-5)
                             │
                             │  (HPC 內部高速私網 INTERNAL_CIDR)
                             ▼
                    [LiteLLM 運行節點 (如 login-4:54821)]
                             │
                             │  (動態負載平衡 Simple-Shuffle)
                             ▼
                    [SGLang H200 算力叢集 (如 node-A:30000~30002)]
```

---

## 🚀 快速上手 4 步驟

### 步驟 1：確認 LiteLLM 目前跑在哪一台登入節點

LiteLLM 啟動腳本會自動將目前運行的節點名稱記錄於專案根目錄的 `.litellm_node`。
在 HPC 登入節點終端機執行：

```bash
cd /path/to/work/github/litellm-proxy
cat .litellm_node
```

> **輸出範例**：`login-4`（或 `login-3`、`login-1` 等）。
> 請記住這個節點代號，後續在外部建立 SSH Tunnel 時需使用。

---

### 步驟 2：在外部測試 VM 建立 SSH Tunnel 通道

打開**測試 VM 的終端機**，將本地端點 `127.0.0.1:4000` 透過 SSH 轉發至該執行節點：

```bash
# 請將 <TARGET_NODE> 換成步驟 1 查到的節點名稱 (例如 login-4)
ssh -N \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=6 \
  -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:4000:login-4:54921 \
  your-user@nano4.nchc.org.tw
```
*(輸入密碼與 OTP，保持此終端機視窗開啟)*

> 💡 **關鍵設計**：
> 由於我們在指令中明確指定了目標節點（如 `login-4:54821`），無論 `nano4.nchc.org.tw` 隨機把您的連線丟到哪一台登入節點（例如抽中 `login-1`），該節點都會透過內部私網將流量自動轉送至 `login-4`，**100% 穩定接通，徹底免除隨機抽籤連不上的問題**！

---

### 步驟 3：在測試 VM 配置環境 (使用 `uv`)

在測試 VM 上，利用 `uv` 快速建立虛擬環境並安裝依賴套件：

```bash
# 1. 進入壓測目錄或建立獨立工作區
cd benchmarks

# 2. 複製設定檔範本
cp .env.example .env

# 3. 建立並啟用 Python 虛擬環境
uv venv
source .venv/bin/activate

# 4. 安裝測試必要套件
uv pip install "httpx[http2]" rich tqdm python-dotenv
```

編輯 `.env` 確保 API Key 與端點正確：
```env
LITELLM_BASE_URL=http://127.0.0.1:4000
LITELLM_API_KEY=REDACTED_API_KEY
DEFAULT_CONCURRENCY=100
DEFAULT_TOTAL=300
DEFAULT_MAX_TOKENS=300
DEFAULT_TEMPERATURE=0.7
DEFAULT_TIMEOUT=120.0
```

---

### 步驟 4：執行壓力測試

#### 方案 A：常規驗證測試 (100 人並發，300 筆請求)
```bash
uv run python stress_test.py -c 100 -n 300
```

#### 方案 B：500 人超高併發長文本極限測試 (儲存 JSON 成果)
```bash
uv run python stress_test.py -c 500 -n 1000 --max-tokens 500 --output-json result_500c_500t.json
```

#### 方案 C：離線模擬模式 (驗證程式邏輯與報表輸出)
```bash
uv run python stress_test.py --mock -c 50 -n 100
```

---

## 📊 實測基準報告 (Performance Baseline)

以下為本專案在 3 實例 SGLang Qwen3.8-27B on H200 叢集架構下，所完成的 **500 人超高併發、max_tokens: 500** 深度壓力測試紀錄：

### 🎯 測試配置摘要
* **並發規模 (Concurrency)**：500 人同時在線
* **總測試請求數 (Total Requests)**：1,000 筆真實技術問答 Prompt
* **單次上限 (Max Tokens)**：`max_tokens = 500`
* **負載模型**：`Qwen3.8-27B` 與 `qwen3.8` 均勻輪流負載（各 500 筆）

### 📈 測試成果指標

| 指標項目 (Metric) | 測試數據 (Value) | 說明與工程解讀 |
| :--- | :--- | :--- |
| **並發規模 (Concurrency)** | **500 人** | 模擬 500 位用戶同時發起長文本推論 |
| **總測試請求數** | **1,000 筆** | 累計產出超過 41.3 萬 Token |
| **成功次數 (Success Count)** | **997 筆 (99.7%)** | 極限負載下依然維持 99.7% 極高可用性 |
| **失敗次數 (Failed Count)** | **3 筆 (0.3%)** | 瞬間高峰波段導致的遠端通道連線重置 |
| **總執行耗時 (Total Time)** | **58.38 秒** | 不到 1 分鐘消化完 1,000 筆長文本生成 |
| **整體請求吞吐 (QPS / RPS)** | **17.08 req/s** | 每秒完成 17 筆長回答請求 |
| **Token 生成吞吐 (TPS)** | **7,082.94 tokens/s 🚀** | **創下全場最高！每秒產出 7,080+ Token** |
| **總輸出 Token 數** | **413,516 tokens** | 完整涵蓋思維鏈與正文解答 |
| **單一請求平均實際 Token** | **414.8 tokens** | 模型完整展開思維鏈（Reasoning）與結論 |
| **平均延遲 (Avg Latency)** | **21.738 秒** | 包含 500 人併發排隊佇列與長文本 Decode |
| **中位數延遲 (P50)** | **22.609 秒** | 半數請求約 22 秒回傳 |
| **P90 延遲** | **30.070 秒** | 90% 請求在 30 秒內完成 |
| **P95 延遲** | **32.118 秒** | 95% 請求在 32 秒內完成 |
| **P99 延遲** | **36.404 秒** | 99% 請求於 36 秒內回傳 |
| **最長延遲 (Max Latency)** | **39.609 秒** | 最大排隊等待時間不超過 40 秒 |

### 🏷️ 個別模型負載分流成效

| 模型名稱 (Model) | 總請求數 | 成功數 | 失敗數 | 成功率 | 平均延遲 | P95 延遲 | 平均實際 Token |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **Qwen3.8-27B** | 500 | 500 | 0 | **100.0%** | 21.793s | 33.011s | 414.4 tokens |
| **qwen3.8 (短別名)** | 500 | 497 | 3 | **99.4%** | 21.683s | 31.800s | 415.2 tokens |

---

## 🔬 核心工程與架構洞察

1. **H200 硬體算力與頻寬完全釋放**：
   先前在 100 並發（300 tokens）時的 TPS 為 4,112 tokens/s；本次 500 並發（500 tokens）時，GPU 每個 Batch 中維持數百個序列同時進行 Decode，將 TPS 一舉衝高至 **7,082 tokens/s（提升 +72.2%）**，充分驗證了 H200 4.8 TB/s 高頻寬記憶體（HBM3e）在長序列大批處理時的巨大優勢。
2. **思維鏈充足容納**：
   實際平均輸出為 414.8 tokens（約佔上限 500 的 83%），證明 Qwen 3.8 能夠在此長度下完整走完思維鏈（`<think>...</think>`）並給出高質量結論，無被截斷問題。
3. **極度穩定的延遲上限**：
   在 500 人超高併發且單次輸出 400+ tokens 的極限考驗下，P99 延遲依然維持在 36.4 秒，最長延遲小於 40 秒，無任何顯存不足（OOM）或系統雪崩現象。

---

## ⚡ 1000 人極限壓測：Flash 引擎併發上限調優 (MAX_RUNNING_REQUESTS 48 vs 100)

以下為 **Qwen3.8-Flash（4×H200、NEXTN 投機解碼）單實例**，經外部 VM 反向隧道（`http://VM_PUBLIC_IP:4000`）注入 **1000 人同時併發、max_tokens=800、客戶端逾時 300 秒** 的對照實測。

### 🔧 為什麼要調 MAX_RUNNING_REQUESTS？

SGLang 開啟投機解碼（NEXTN）時會**自動把併發解碼上限降為 48**（log：`Max running requests is reset to 48 for speculative decoding`），但本引擎記憶體極為充裕（Mamba 狀態池 1,603 槽、KV cache 425 萬 tokens），48 遠低估硬體潛力。於 `engines/sglang-qwen-flash/config.env` 設定 `MAX_RUNNING_REQUESTS=100` 即可覆蓋（sglang_server.slurm 會條件附加 `--max-running-requests`）。

### 📈 對照成果

| 指標 | 上限 48（預設） | 上限 100（調優） | 變化 |
| :--- | :---: | :---: | :---: |
| 成功率 | **100%** (1000/1000) | **100%** (1000/1000) | 持平 |
| 總耗時 | 241.7 秒 | **188.4 秒** | **-22%** |
| 平均吞吐 (TPS) | 2,153 tok/s | **2,774 tok/s** | **+29%** |
| 峰值吞吐 (引擎 gen throughput) | 4,463 tok/s | **6,221 tok/s** | **+39%** |
| P50 延遲 | 127.3 秒 | **104.0 秒** | **-18%** |
| P95 延遲 | 235.2 秒 | **184.6 秒** | **-21%** |
| 最長延遲 | 241.5 秒 | **188.2 秒** | **-22%** |
| 引擎最大併行 | 48 | **100** | 參數生效 |
| 最大排隊請求數 | 452 | **403** | -11% |
| 總輸出 Token | 520,501 | 522,684 | 相當 |

### 🖥️ 基礎設施開銷（100 人併發峰值）

| 元件 | 峰值 CPU | 峰值記憶體 | 結論 |
| :--- | :---: | :---: | :--- |
| LiteLLM Gateway（HPC 登入節點） | 5.2% | 333 MB | 極輕量，絕非瓶頸 |
| 反向隧道 ssh（HPC 端） | 0.1% | 5 MB | 可忽略 |
| VM 端 sshd（全部） | 0.1% | ~75 MB | 可忽略 |

### 💡 工程解讀

1. **併發上限調高的收益不只吞吐**：最大排隊從 452 降至 403，請求等待時間縮短，**P50/P95/最長延遲全面下降 18~22%**——總耗時、吞吐、延遲三贏。
2. **投機解碼的批次退化被排隊削減抵銷**：併發 100 時單請求解碼速度略降（驗證成本隨 batch 增加），但佇列消化速度加快，端到端延遲反而改善。
3. **Gateway 與隧道完全不是瓶頸**：1000 人併發下 litellm 僅 5.2% CPU / 333MB，瓶頸完全在 GPU 引擎端——擴容應優先**多派引擎實例**（litellm 動態負載平衡自動分流）。
4. **客戶端逾時設定很重要**：本規格（800 tokens、高併發）下請求最長可達 190 秒，客戶端逾時需 ≥ 300 秒，否則會誤判為服務故障（引擎實際仍正常生成）。

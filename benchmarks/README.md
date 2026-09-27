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
                     [LiteLLM 運行節點 (如 login-2:54921)]
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

> **輸出範例**：`login-2`（或 `login-3`、`login-1` 等）。
> 請記住這個節點代號，後續在外部建立 SSH Tunnel 時需使用。

---

### 步驟 2：在外部測試 VM 建立 SSH Tunnel 通道

打開**測試 VM 的終端機**，將本地端點 `127.0.0.1:4000` 透過 SSH 轉發至該執行節點：

```bash
# 請將 <TARGET_NODE> 換成步驟 1 查到的節點名稱 (例如 login-2)
ssh -N \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=6 \
  -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:4000:login-2:54921 \
  your-user@nano4.nchc.org.tw
```
*(輸入密碼與 OTP，保持此終端機視窗開啟)*

> 💡 **關鍵設計**：
> 由於我們在指令中明確指定了目標節點（如 `login-2:54921`），無論 `nano4.nchc.org.tw` 隨機把您的連線丟到哪一台登入節點（例如抽中 `login-1`），該節點都會透過內部私網將流量自動轉送至 `login-2`，**100% 穩定接通，徹底免除隨機抽籤連不上的問題**！

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

編輯 `.env` 確保 API Key 與端點正確（金鑰請向管理員索取，或以 `key_tool.py generate` 發放）：
```env
LITELLM_BASE_URL=http://127.0.0.1:4000
LITELLM_API_KEY=your-litellm-api-key-here
DEFAULT_CONCURRENCY=100
DEFAULT_TOTAL=300
DEFAULT_MAX_TOKENS=300
DEFAULT_TEMPERATURE=0.7
DEFAULT_TIMEOUT=120.0
```

> ⚠️ **逾時設定提醒**：高併發 × 長文本（如 1000 人 × 800 tokens）實測單一請求最長延遲可達 **188 秒**，此規格請以 `--timeout 300`（或 `.env` 設 `DEFAULT_TIMEOUT=300`）執行，否則會將仍在正常生成的請求誤判為 ReadTimeout 失敗。

> 💡 **測試 Flash 引擎**：預設負載模型為 27B；測 Flash 時以環境變數覆蓋：
> ```bash
> BENCH_MODELS="Qwen3.8-Flash,qwen3.8-flash" uv run python stress_test.py -c 1000 -n 1000 --max-tokens 800 --timeout 300
> ```

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

### 🖥️ 基礎設施開銷（1000 人壓測期間峰值）

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

---

## 📁 歷史測試紀錄與原始數據 (`results/`)

各輪壓測的完整原始 JSON 統計收錄於 [`results/`](results/)：

| 檔案 | 測試情境 | 引擎 / 通道 | 關鍵結果 |
| :--- | :--- | :--- | :--- |
| `bench_result_500_users.json` | 500 人 × 300 tokens | Flash 單實例（併發上限 48）／VM 反向隧道 | 100% 成功、平均 1,478 tok/s、P95 91.4 秒 |
| `bench_result_1000_users_mrr48.json` | 1000 人 × 800 tokens | 同上 | 100% 成功、平均 2,153 tok/s、峰值 4,463 tok/s |
| `bench_result_1000_users_mrr100.json` | 1000 人 × 800 tokens | Flash 單實例（`MAX_RUNNING_REQUESTS=100`）／VM 反向隧道 | 100% 成功、平均 2,774 tok/s、峰值 6,221 tok/s |
| `bench_result_1000_users_mrr100_client_timeout120.json` | 同上但客戶端逾時 120 秒 | 同上 | **56.2% 成功**——失敗全為 ReadTimeout，作為「逾時設定不足」的對照紀錄 |

> 測試日期：2026-09-25。當時部署：Gateway @ `login-4:54921`、引擎 Slurm Job @ `node-C`（4×H200）。

---

## 🔥 三引擎時代壓測（2026-09-26：GLM-5.3-Flash 上線＋調優＋混合負載）

背景：GLM-5.3-Flash（8×H200, TP8+EP8, EAGLE MTP）經 model-onboarding skill 上線後，
執行四段式測試（個別基線 → 調優 → 混合負載 → 瓶頸定位）。

### 📈 各輪結果總覽

| 測試 | 規模 | 成功率 | 平均 TPS | 峰值 TPS | P95 |
| :--- | :--- | :---: | :---: | :---: | :---: |
| GLM-5.3-Flash（cap 64） | 1000 人 × 800 tok | 95.7% | 2,324 | 6,077 | 286.6 秒 |
| **GLM-5.3-Flash（cap 128，調優後）** | 1000 人 × 800 tok | **100%** | **3,057** | **6,980** | 236.8 秒 |
| Qwen3.8-27B（單卡） | 500 人 × 500 tok | **100%** | 2,584 | 3,276 | 77.3 秒 |
| 三模型混合（經隧道，sshd fd 修復前） | 1500 人 × 500 tok | 91.8% | 8,251 | — | 70.4 秒 |
| **三模型混合（旁路直連）** | 1500 人 × 500 tok | **100%** | 8,156 | — | 77.6 秒 |
| **三模型混合（經隧道，sshd fd 修復後）** | 1500 人 × 500 tok | **100%** 🏆 | **8,146** | — | 76.8 秒 |

> Qwen3.8-Flash 引擎沿用 2026-09-25 基線（1000×800：100%、峰值 6,221 tok/s），未重測。

### 💡 工程解讀

1. **GLM 調優與 flash 同劇本**：`MAX_RUNNING_REQUESTS` 64→128 後，成功率 95.7→100%、
   平均吞吐 +31%（2,324→3,057）、峰值 6,980 tok/s（全場最高）。8×H200 上限還沒摸到，
   生產值定 128（再往上尾延遲會快速增長）。
2. **單卡 27B 的性價比**：1×H200 撐 500 人 100% 成功、P95 僅 77 秒——輕量模型
   單卡部署完全堪用。
3. **混合負載的全景**：三引擎同時分流，Gateway 聚合 **~8,200 tok/s**、自身僅
   2.5% CPU／405MB——瓶頸完全不在 Gateway 與引擎。
4. **⚠️ 真正的瓶頸鏈（三個 fd 相關教訓＋一次歸因修正）**：
   - **VM 客戶端 `ulimit -n` 1024**：1500 併發時 fd 耗盡（`Errno 24`），成功數卡
     ~1020——`ulimit -n 65535` 解決。壓測前必查客戶端 fd 上限。
   - **隧道 sshd 的 fd soft limit 也是 1024**（`/proc/<sshd>/limits` 實查）——外部
     連線的第一線瓶頸。**修法正解是 `/etc/security/limits.conf`**（PAM 機制；
     只改 systemd override 只影響主監聽器，per-connection sshd 不吃）——
     修復後重測 1500 人經隧道 **100%**。詳見
     [`docs/EXTERNAL_VM_TUNNEL.md`](../docs/EXTERNAL_VM_TUNNEL.md) 3.5 節。
   - **歸因修正實錄**：初判「8% ReadError 是隧道單流天花板」為**誤判**——真兇是
     sshd fd。教訓：旁路測試只能證明「問題在 VM↔Gateway 之間」，不能細分 sshd fd
     vs 隧道流控；**修一層驗一層**才是硬道理。單流天花板在 1500 內尚未摸到。
   - 本輪完整診斷已技能化：[`.agents/skills/concurrency-troubleshooting/`](../.agents/skills/concurrency-troubleshooting/README.md)。
5. **建議的生產容量**（經隧道對外，sshd fd 修復後實證）：**~1500 併發、聚合 ~8,100 tok/s、100%**——
   現有使用者規模（數十至數百併發）有 10 倍以上餘裕；>1500 尚未實測。

### 📁 本輪原始數據

| 檔案 | 情境 |
| :--- | :--- |
| `bench_glm53_1000_users_cap64.json` / `_cap128.json` | GLM 調優前後對照 |
| `bench_27b_500_users.json` | 27B 單卡基線 |
| `bench_mixed_1500_users_via_tunnel.json` / `_bypass_tunnel.json` | 混合負載瓶頸定位對照 |
| `bench_mixed_1500_users_sshd_fd_fixed.json` | sshd fd 修復後驗證輪（經隧道 100%，歸因修正的證據） |

## ⚔️ SGLang vs vLLM 同模型 A/B 對決（2026-09-27）

**動機**：vLLM 引擎路徑自專案成立從未實測（舊 `vllm-deepseek-flash` 原型無憑無據已刪），
以本地既有 Qwen3.8-27B BF16 權重（52GB，零下載）建立 `engines/vllm-qwen27b` 對照組，
與 `sglang-qwen-27b` 進行**科學對決**。

### 🎯 對決條件（嚴格公平）

| 項目 | 設定 |
| :--- | :--- |
| 權重 | **同一份** `/path/to/work/models/Qwen3.8-27B`（BF16） |
| 硬體 | 各 1×H200（同節點同時段依序測） |
| 參數來源 | **雙方官方文件**：SGLang Cookbook（docs.sglang.io）vs vLLM Recipe（recipes.vllm.ai） |
| R1 併發 | SGLang cap 128（官方公式 `MAX_MAMBA_CACHE_SIZE=640`=128×5＋bf16 狀態）vs vLLM `--max-num-seqs 128` |
| 負載 | 500 人併發 × max_tokens 500，經正式隧道路徑（VM → Gateway → 引擎） |
| 工作量確認 | 兩輪總 tokens 207,832 vs 207,638（±0.1%＝同題同工作量） |

### 📈 R1 陽春版（無投機解碼，生產推薦配置）

| 指標 | SGLang 0.5.20 | vLLM 0.29.1rc1 | 勝負 |
| :--- | :--- | :--- | :--- |
| 成功率 | 100%（500/500） | 100%（500/500） | 平手 |
| 聚合吞吐 | **3,823 tok/s** | 3,597 tok/s | **SGLang +6.3%** |
| P95 延遲 | **51.8s** | 54.6s | SGLang 快 5.1% |
| 總時長 | 54.4s | 57.7s | SGLang 快 5.7% |

### 📈 R2 投機解碼全力版（同一顆 checkpoint 內建 MTP head）

| 指標 | SGLang EAGLE 3/1/4 | vLLM MTP×3 |
| :--- | :--- | :--- |
| 併發上限 | **48**（記憶體所限，見下） | 128（MTP 共享權重幾乎免費） |
| 聚合吞吐 | 2,306 tok/s（**-40%** vs 自身 R1） | 3,034 tok/s（**-16%** vs 自身 R1） |
| P95 延遲 | 87.2s | 64.4s |

### 💡 工程解讀

1. **R1：SGLang 以 ~6% 小勝**——同權重同硬體同併發下，SGLang 的 scheduler／kernel
   組合在 27B dense 混合架構上略佔優勢；但差距不大，兩框架都是一線水準。
2. **R2：雙雙變慢，物理定律勝出**——500 人高併發下 decode batch 已達算力飽和，
   投機解碼的 draft＋verify 是純開銷（acceptance 增益無法彌補）。**MTP/EAGLE 是
   低併發延遲武器，不是高併發吞吐武器**。與 flash 引擎 NEXTN（1000 人壓測效益
   為正）的差異在於該模型 MoE 結構解碼成本低、batch 空間大。
3. **框架實作差異實證**：SGLang EAGLE 需額外載入 draft 權重＋GDN 中間狀態快取
   （`intermediate_ssm_state_cache` 13.8GB）→ 記憶體預算擠壓併發至 48；
   vLLM MTP 直接用主模型 checkpoint 內建 head，共享權重、cap 128 不變。
   **混合線性注意力（GDN）模型的投機解碼記憶體代價，SGLang 遠高於 vLLM。**
4. **生產配置定案＝R1 陽春版**（兩引擎投機解碼參數已註解保留於 config.env，
   供未來低併發場景或單流延遲優化使用）。

### 📁 本輪原始數據

| 檔案 | 情境 |
| :--- | :--- |
| `bench_ab_sglang_27b_r1.json` / `bench_ab_vllm_27b_r1.json` | R1 陽春版對決 |
| `bench_ab_sglang_27b_r2_eagle.json` / `bench_ab_vllm_27b_r2_mtp.json` | R2 投機解碼對決 |

### 🔧 過程中修復的基礎設施問題（本輪除錯收穫）

- **`git rm` 不會刪除 gitignore 的檔案**：刪除 `vllm-deepseek-flash` 引擎後，
  `config.env`（金鑰檔）殘留成「殭屍引擎目錄」，仍被 `start.sh` 金鑰載入邏輯
  依字母序掃到（`vllm-deepseek` < `vllm-qwen27b`）→ **舊金鑰覆蓋新引擎金鑰**
  → generator 探測 401 → 端點被略過、路由缺席。教訓：**刪除引擎務必
  `git rm -r` 後再 `rm -rf` 目錄**（或 `git clean`），並重啟 gateway 驗證
  「活躍後端」數量。
- **generator 探測加強**：`is_endpoint_alive` 失敗後重試一次＋輸出失敗原因
  （HTTP status／例外），冷啟動首測逾時不再誤殺端點。
- **驗證器模型名相容**：`validate_engine.sh` 改以 `/v1/models` 實際服務名做
  chat 測試（vLLM 嚴格把關服務名＝權重路徑；SGLang 寬鬆放行——統一探測相容兩框架）。

## ⚔️ SGLang vs vLLM 同模型 A/B 對決・第二戰：Qwen3.8-Flash-Next（2026-09-27）

**動機**：27B 戰（SGLang 勝 6%）之後，於 qwen4_exp 新架構（GDN＋QSA＋51B N-gram
embedding＋512 專家 ultra-sparse MoE，180B 總參／6B 激活）上再戰——新增
`engines/vllm-flash-next`（TP4+EP4/TEP4、埠 37000），與 `sglang-qwen-flash`
共享本地 FP8 權重（173GB，零下載），參數全依官方 vLLM Recipe（H200 章節）。

### 🎯 對決條件

| 項目 | 設定 |
| :--- | :--- |
| 權重 | **同一份** `Qwen3.8-Flash-Next-FP8`（173GB） |
| 硬體 | 各 4×H200（TP4+EP4） |
| 併發 | **雙邊 cap 256**（vLLM Recipe 明訂 `--max-num-seqs 256`，低了會啟動錯誤；SGLang `MAX_RUNNING_REQUESTS=256` 對齊） |
| 負載 | 1000 人併發 × max_tokens 800（對齊 flash 生產基線），經正式隧道 |
| 工作量確認 | 各輪 516k~525k tokens（±0.8%＝同題同工作量） |

### 📈 結果（四宮格）

| 配置 | SGLang 0.5.20 | vLLM 0.29.1rc1 | 勝負 |
| :--- | :--- | :--- | :--- |
| R1 陽春（無投機） | 3,383 tok/s¹／P95 150.6s | **7,886 tok/s／P95 63.2s** | **vLLM 2.33×** |
| R2 投機解碼 | 3,925（NEXTN 3/1/4，**+16%**）² | 4,282（MTP×3，**-46%**） | vLLM +9% |
| **各自最佳** | 3,925（開 NEXTN） | **7,886（不開 MTP）** | **vLLM 2.01×** |

¹ SGLang R1 先以預設（PLE 卸載 CPU）測得 3,296 tok/s，改 `--no-ple-offload-embedding`
（51B N-gram embedding 留 GPU，對齊 vLLM 記憶體策略）後 3,383——**PLE 策略只值 2.6%**，
非差距主因。
² 兩輪成功率均 100%（1000/1000）。

### 💡 工程解讀

1. **與 27B 戰完全相反的結局**：27B（dense）SGLang 勝 6%；Flash-Next（ultra-sparse MoE）
   vLLM 勝 2.33×。**框架優勢隨架構翻轉**——qwen4_exp 是新架構，vLLM 的 triton MoE＋
   FP8 pipeline 成熟度明顯領先（我們的 vLLM image 0.29.1rc1 比 SGLang 0.5.20 對此架構
   更新）。
2. **投機解碼效應兩框架方向相反**（同一模型、同顆 MTP head）：
   - SGLang NEXTN **+16%**（MoE 6B 激活解碼便宜，draft 划算——與其生產調優經驗一致）
   - vLLM MTP **-46%**（與官方 Recipe 於 H100 的警告一致：acceptance ~36%、
     「do not enable by default」）
   - **同一顆 draft head，兩種框架實作，一個賺一個賠**——投機解碼的成敗在實作品質，
     不在模型本身。
3. **PLE（51B N-gram embedding）記憶體策略**：SGLang 預設卸載 CPU、vLLM 於 H200 放
   GPU——實測差異僅 2.6%，非主因。
4. **生產建議**：flash 產線若切至 vllm-flash-next（R1 陽春配置），吞吐可較現行
   SGLang 最佳配置（3,925）提升 **~2.0×**（7,886）——待決策。

### 📁 本輪原始數據

| 檔案 | 情境 |
| :--- | :--- |
| `bench_ab_sglang_flash_r1.json` | SGLang R1（PLE 卸載 CPU，預設） |
| `bench_ab_sglang_flash_r1b_ple_gpu.json` | SGLang R1（PLE 留 GPU，對齊 vLLM 策略） |
| `bench_ab_sglang_flash_r2.json` | SGLang R2（NEXTN 3/1/4） |
| `bench_ab_vllm_flash_r1.json` | vLLM R1（陽春，=其最佳配置） |
| `bench_ab_vllm_flash_r2.json` | vLLM R2（MTP×3） |

## ⚔️ SGLang vs vLLM 同模型 A/B 對決・第三戰：GLM-5.3-Flash（2026-09-27）

**動機**：GLM-5.3-Flash 的 vLLM Recipe 上線（原評估記錄「vLLM 無支援」已過時），
新增 `engines/vllm-glm53-flash`（TEP8、埠 38000、**專用 image `vllm_glm53-flash.sif`**
＝vLLM 官方認證 build，依版本政策 C 新檔名進場），與 `sglang-glm53-flash`
共享本地 FP8 權重（306GB，零下載）。

### 🎯 對決條件

| 項目 | 設定 |
| :--- | :--- |
| 權重 | **同一份** `GLM-5.3-Flash`（306GB 原生 FP8） |
| 硬體 | 各 8×H200（TP8+EP8 vs TEP8）；vLLM 用專用 image 0.28.1rc1.dev580（含預編譯 GLM kernel），SGLang 0.5.20 |
| 併發 | 雙邊 cap 128；⚠️ Hopper 不支援此模型 FP8 KV → vLLM 用 BF16 KV（Recipe 明載） |
| 負載 | 1000 人×800 tok，經正式隧道；工作量 732k~734k tokens（各輪一致 ✓） |

### 📈 結果（四宮格）

| 配置 | SGLang 0.5.20 | vLLM 0.28.1rc1（專用 build） | 勝負 |
| :--- | :--- | :--- | :--- |
| R1 陽春（無投機） | **3,669 tok/s**／P95 192.5s／100% | 2,857 tok/s／P95 251.0s／100% | **SGLang +28%** |
| R2 投機解碼 | 3,135（MTP EAGLE 5/1/6，**-15%**） | 2,066（MTP5，**-28%**，成功率僅 **85.6%** ReadTimeout） | SGLang +52% |
| **各自最佳** | **3,669**（不開 MTP） | 2,857（不開 MTP） | **SGLang +28%** |

### 💡 工程解讀

1. **三戰總結論：框架優勢由架構決定，沒有永久冠軍**——27B dense（qwen3_5）SGLang +6%、
   Flash-Next ultra-sparse MoE（qwen4_exp）vLLM +133%、GLM KDA＋sparse MLA（glm5_next）
   SGLang +28%。新模型上架前**必須雙框架實測**（model-onboarding skill Step 4 制度）。
2. **GLM 上雙框架的 MTP 都是淨損**（SGLang -15%、vLLM -28%＋可靠性崩壞 85.6%）——
   與 Flash-Next（SGLang NEXTN +16%）相反：GLM 18B 激活解碼較重，
   高併發算力飽和下 draft+verify 開銷蓋過增益。
3. **生產改進落地**：原 SGLang GLM 生產配置開 MTP（實測 3,057~3,135 tok/s）——
   **關閉後 3,669（+18%）**，已於本輪直接套用（config 註解保留 MTP 參數與決策依據）。
4. **專用 image 教訓**：通用 nightly（0.29.1rc1）跑 GLM 撞 TRT-LLM deep_gemm cubin
   斷言＋FlashInfer autotune 掛死 31 分鐘——官方專用 tag（`vllm/vllm-openai:glm53-flash`）
   一次解決。**疑難雜症先查官方專用 build**（Recipe 的 "use docker" 提示）。

### 🔧 過程修復

- **拉取失敗三連**：登入節點 NFS unlink 競態（"directory not empty"）→ 改用**計算節點
  slurm job 拉取**（dev 分區、本地 /tmp 暫存）一次成功——大型 image 拉取一律走計算節點。
- **FlashInfer autotune 掛死**：scancel 殘留的共享 autotune 快取＋autotune 本身掛住 →
  清快取＋`--no-enable-flashinfer-autotune`（Flash-Next Recipe 同款處理）。
- **JSON 引號三度犯**：config.env 的 `SPECULATIVE_CONFIG` 必須**單引號**包裹 JSON
  （bash source 會剝雙引號）——已全面修正三個 vLLM 引擎的 config 與 example。

### 📁 本輪原始數據

| 檔案 | 情境 |
| :--- | :--- |
| `bench_ab_sglang_glm53_r1.json` / `bench_ab_vllm_glm53_r1.json` | R1 陽春版對決 |
| `bench_ab_sglang_glm53_r2.json` / `bench_ab_vllm_glm53_r2.json` | R2 投機解碼對決（vLLM 85.6%） |

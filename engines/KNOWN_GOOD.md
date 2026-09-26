# 已驗證引擎配方登記表 (KNOWN_GOOD)

> **目的**：記錄每個引擎「驗證過的 image 版本 × 權重 × 啟動參數」組合。
> 新模型上線前先查此表找最接近的原型；image 版本更換後**必須重新驗證**並更新本表。
> **識別規則**：image 以「框架 + 版本號」識別（例：SGLang 0.5.20），不以 SIF 檔名
> （`*_latest.sif` 僅為檔名，實際版本以下表為準——檔名不改是為了避免中斷現行 config.env）。
> 完整操作手冊（每日開退場、驗證、疑難排解）見
> [docs/ENGINE_LIFECYCLE_GUIDE.md](../docs/ENGINE_LIFECYCLE_GUIDE.md)。

---

## 配方總覽

| 引擎目錄 | 模型 | 框架 / 實測版本 | image (SIF) | 權重大小 | 硬體 | 驗證狀態 |
| :--- | :--- | :--- | :--- | :---: | :---: | :--- |
| `sglang-qwen-27b` | Qwen/Qwen3.8-27B-FP8 | SGLang **0.5.19** | `sglang_latest.sif` | 52 GB | 1×H200 (TP1) | ✅ 運行中 (2026-09-26) |
| `sglang-qwen-flash` | Qwen/Qwen3.8-Flash-Next-FP8 | SGLang **0.5.20** | `sglang_flash_latest.sif` | 173 GB | 4×H200 (TP4+EP4) | ✅ 1000 人壓測通過 (2026-09-25) |
| `vllm-deepseek-flash` | deepseek-ai/DeepSeek-V4.1-Flash | vLLM **0.29.1rc1.dev452** | `vllm_latest.sif` | 763 GB (**未下載**) | 2×H200 (TP2) | ⚪ 未驗證（權重未下載） |
| `sglang-step5-fp8` | TypeSafeAI/Step-5-Preview-FP8 | SGLang **0.5.20**（原生 step3p5 支援） | `sglang_flash_latest.sif`（共用） | ~604 GB (**FP8 未釋出**) | 8×H200 (TP8+EP8) | 🟡 準備中（BF16 1.21TB 超出硬體已排除；FP8 釋出後即可上線） |
| `sglang-glm53-flash` | zai-org/GLM-5.3-Flash | SGLang **0.5.20**（原生 glm5_next 支援） | `sglang_flash_latest.sif`（共用） | 328.3 GB（原生 FP8） | 8×H200 (TP8+EP8) | ✅ 運行中；1000 人壓測 100%（峰值 6,980 tok/s，`MAX_RUNNING_REQUESTS=128`，2026-09-26，VLM 帶圖驗證通過） |

> `engines/sglang-qwen` → `sglang-qwen-27b` 的相容 symlink，非獨立引擎。

---

## 詳細配方

### 1. engines/sglang-qwen-27b（原型：小模型單卡）

| 項目 | 值 |
| :--- | :--- |
| image | `sglang_latest.sif`（docker `lmsysorg/sglang:latest`，SIF 轉檔 2026-09-05，內含 SGLang **0.5.19**） |
| 權重 | `/path/to/work/models/Qwen3.8-27B`（52 GB） |
| 平行 | TP=1（**支援同主機多實例**，埠 30000 起跳，LiteLLM 自動負載平衡） |
| `HEALTH_TIMEOUT` | 600 秒（權重載入約 2~3 分鐘） |
| 實績 | 早期 3 實例形態 500 人壓測 7,082 tok/s；2026-09-26 單實例經 `start_models.sh` 啟動驗證 |

### 2. engines/sglang-qwen-flash（原型：大模型 TP4+EP4+投機解碼）

| 項目 | 值 |
| :--- | :--- |
| image | `sglang_flash_latest.sif`（docker `lmsysorg/sglang:latest`，SIF 轉檔 2026-09-22，內含 SGLang **0.5.20**） |
| 權重 | `/path/to/work/models/Qwen3.8-Flash-Next-FP8`（173 GB，hybrid Mamba 架構） |
| 平行 | TP=4 + EP=4 |
| 投機解碼 | NEXTN（3 步預測、Eagle Top-K=1、4 draft tokens） |
| `MAX_RUNNING_REQUESTS` | **100**（不設時 sglang 因投機解碼自動降 48；記憶體額度：Mamba 狀態池 1,603 槽、KV cache 425 萬 tokens） |
| 其他 | chunked-prefill 8192、`HEALTH_TIMEOUT` 1800 秒（權重載入約 5~6 分鐘） |
| 實績 | 1000 人 × 800 tokens：100% 成功、峰值 6,221 tok/s、P95 185 秒（2026-09-25，詳 `benchmarks/README.md`） |

### 3. engines/vllm-deepseek-flash（原型：vLLM + CPU offload）

| 項目 | 值 |
| :--- | :--- |
| image | `vllm_latest.sif`（SIF 轉檔 2026-09-22，內含 vLLM **0.29.1rc1.dev452** 開發版） |
| 權重 | `deepseek-ai/DeepSeek-V4.1-Flash`（763 GB，**尚未下載**） |
| 平行 | TP=2 |
| 特色參數 | FlashInfer MLA Sparse、Engram CPU offload（`--attention-config`/`--engram-config` 有設定才附加） |
| `HEALTH_TIMEOUT` | 1800 秒（CPU offload 載入慢） |
| 狀態 | ⚪ 啟動邏輯僅單元測試覆蓋；下載權重後以 `validate_engine.sh` 完成驗證並更新本表 |

### 4. engines/sglang-step5-fp8（原型：大模型 TP8+EP8 MoE）🟡 準備中

| 項目 | 值 |
| :--- | :--- |
| image | `sglang_flash_latest.sif`（與 flash **共用**，SGLang 0.5.20，2026-09-26 實測已內建 `step3p5.py`／`step3p5_mtp.py` 原生支援） |
| 權重 | `Step-5-Preview-FP8`（~604 GB，**官方 FP8 尚未釋出**；BF16 版 1.21TB 超出 8×H200 與磁碟容量已排除） |
| 平行 | TP=8 + EP=8（單節點 8×H200 = 1,128GB，KV 餘 ~520GB） |
| 關鍵參數 | `--context-length 262144`（官方 1M 為理想值）、`--reasoning-parser step3p5`（⚠️ model card 寫 `stepfun`，實測 0.5.20 DetectorMap 無此選項）、`--trust-remote-code`、`--mem-fraction-static 0.90`、`MAX_RUNNING_REQUESTS=64`（初始，上線後調優） |
| 未實驗項 | MTP 投機解碼（image 已含 `step3p5_mtp.py`，俟官方參數確認） |
| `HEALTH_TIMEOUT` | 2400 秒（604GB 載入＋暖機） |
| 評估記錄 | 2026-09-26，流程見 [`.agents/skills/model-onboarding/README.md`](../.agents/skills/model-onboarding/README.md) |

---

## 新模型上線 SOP（搭配工具）

```bash
# ① 從最接近的原型 scaffold（原型選擇見上表）
./new_engine.sh my-model --from sglang-qwen-flash

# ② 編輯 engines/my-model/config.env（MODEL_NAME / SIF_PATH / 金鑰）

# ③ 下載權重與 image
cd engines/my-model && ./download_model.sh && ./pull_image.sh && cd ../..

# ④ 驗證（靜態檢查 → 煙霧啟動：開得起來、答一題、自動收工）
./validate_engine.sh my-model

# ⑤ 正式上線
./start_models.sh my-model
```

**選版原則**：新模型先讀 HF model card 的建議引擎版本（Qwen/DeepSeek 官方卡通常註明
「需 sglang ≥ x.y」）→ 挑**支援該架構的最低穩定版** → `pull_image.sh` 拉取 →
本表登記實測版本。避免依賴 `:latest` 浮動標籤而不記錄版本。

**驗證紀錄慣例**：image 更換或參數調整後，跑 `validate_engine.sh <引擎>` 一次，
將日期與結果更新至本表「驗證狀態」欄。

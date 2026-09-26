# SGLang Step-5-Preview-FP8 容器化推論部署 (8x H200 GPU)

> ## ⚠️ 狀態：準備中（等待官方 FP8 權重釋出）
> - **BF16 版不可行**：604B × 2B ≈ **1.21TB 權重**，超出單節點 8×H200（1,128GB）容量，
>   `/work` 磁碟剩餘（1.1TB）也放不下——已評估排除（2026-09-26，評估流程見
>   [`skills/model-onboarding/README.md`](../../skills/model-onboarding/README.md)）。
> - **FP8 版（~604GB）→ 8×H200 可行**：權重後仍餘 ~520GB 供 KV cache。
> - 官方釋出後流程：`cp config.env.example config.env`（已備妥）→ `./download_model.sh` →
>   回專案根目錄 `./validate_engine.sh sglang-step5-fp8` → `./start_models.sh sglang-step5-fp8`。

---

## 🚀 核心規格與技術特色

* **模型**：`Step-5-Preview`（StepFun）——600B 總參數 Sparse MoE、27B 激活（~4.5% sparsity）、
  92 層 narrow-deep Transformer、**Sparse GQA + block-wise token merging**、
  **多模態輸入**（文字／圖片／影片）、思維鏈 `reasoning_effort` 可調（low/medium/high/xhigh）。
* **平行架構**：Tensor Parallel (TP=8) 與 Expert Parallel (EP=8)，單節點 8×H200。
* **框架**：**SGLang 0.5.20**（與 `sglang-qwen-flash` 共用 `sglang_flash_latest.sif`——
  2026-09-26 實測該 image 已內建 `step3p5.py` 原生支援與 `step3p5_mtp.py`；
  我們的 vLLM 0.29.1rc1 image 無 step 系列支援，故不採 vLLM）。
* **推論解析**：`--reasoning-parser stepfun`（官方指定）。
* **全自動生命週期**：原生整合頂層 `lib/lifecycle.sh` 原子搶鎖、兩階段發布與退場安全清理。

## ⚙️ 關鍵啟動參數與理由

| 參數 | 值 | 理由 |
| :--- | :--- | :--- |
| `--tp 8 --ep 8` | 8×H200 | FP8 權重 604GB 需 8 卡容納 |
| `--context-length` | **262144**（256K） | 官方 1M 為理想值；KV cache 不允許，穩定後再調升 |
| `--mem-fraction-static` | 0.90 | 大權重情境提高靜態配置比例 |
| `--max-running-requests` | 64（初始） | 上線後依記憶體餘量實測調優（比照 flash 48→100 經驗） |
| `--trust-remote-code` | 必要 | step3p5 為新架構 |
| `--reasoning-parser` | **step3p5** | 思維鏈解析。⚠️ model card 寫 `stepfun`，但 2026-09-26 實測 SGLang 0.5.20 的 `ReasoningParser.DetectorMap` 無此選項（合法值為架構名 `step3p5`）——照抄官方指令會啟動失敗 |
| MTP 投機解碼 | ❌ 暫不開 | image 內含 `step3p5_mtp.py`，俟官方參數確認後實驗（`config.env.example` 第 7 節） |
| `HEALTH_TIMEOUT` | 2400 秒 | 604GB 權重載入＋CUDA Graph 暖機，較 flash 更保守 |

## 🛠️ 快速操作指引

```bash
# 1. 下載模型權重（⚠️ 官方 FP8 釋出後才可執行；repo 名以釋出公告為準）
./download_model.sh TypeSafeAI/Step-5-Preview-FP8

# 2. 驗證（靜態檢查 → 煙霧啟動）
cd /path/to/work/github/litellm-proxy
./validate_engine.sh sglang-step5-fp8

# 3. 正式上線
./start_models.sh sglang-step5-fp8

# 4. 停止
./stop_models.sh sglang-step5-fp8
```

> 💡 已驗證配方登記與選版原則見 [`engines/KNOWN_GOOD.md`](../KNOWN_GOOD.md)；
> 完整操作手冊見 [`docs/ENGINE_LIFECYCLE_GUIDE.md`](../../docs/ENGINE_LIFECYCLE_GUIDE.md)。

## 📊 硬體適配評估摘要（2026-09-26）

| 項目 | BF16 | FP8（本目錄目標） |
| :--- | :---: | :---: |
| 權重大小 | ~1.21 TB | ~604 GB |
| 4×H200（564GB） | ❌ | ❌ |
| 8×H200（1,128GB） | ❌（權重即超出） | ✅（KV 餘 ~520GB） |
| `/work` 磁碟（剩 1.1TB） | ❌ 放不下 | ✅ |

*官方建議配置：FP8 → 4×H100 80GB（320GB，需 offload）；我們採 8×H200 直上無需 offload。*

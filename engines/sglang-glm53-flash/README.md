# SGLang GLM-5.3-Flash 容器化推論部署 (8x H200 GPU)

> ## ✅ 評估結論（2026-09-26，model-onboarding skill 產出）：**可行，已備妥待下載**
> - **框架**：SGLang **0.5.20**（實測 image 內含 `glm5_next.py`＋`glm5_next_nextn.py`；
>   vLLM 0.29.1rc1 無 glm5 支援；官方要求 SGLang ≥0.5.20——與 flash 共用 image 即可）
> - **硬體**：**8×H200 TP8/EP8**（官方 cookbook 唯一 H200 配方，無 4-GPU 版）；
>   權重 328.3GB（原生 FP8）＋ 18B 激活（MoE），KV 餘量充裕
> - **解析器**（⚠️ 依 skill 鐵律實測，非照抄）：`--reasoning-parser auto`→`glm45` ✓、
>   `--tool-call-parser auto`→`glm47`（`glm47_moe_detector.py`）✓
> - **依賴套件實測**：tilelang 0.1.12 ✓、deep_gemm ✓、EAGLE 投機解碼 ✓
> - License：MIT；非 gated；支援 `reasoning_effort`（low/high/max）

---

## 🚀 核心規格

* **模型**：`zai-org/GLM-5.3-Flash`——320B 總參數／18B 激活 Sparse MoE、
  **原生多模態**（文字／圖片／影片）、hybrid sparse＋linear attention（DSA）、
  Manifold-Constrained Hyper-Connections (mHC)、原生 1M context。
* **配方**：[官方 cookbook](https://cookbook.sglang.io/autoregressive/GLM/GLM-5.3-Flash)
  H200 8-GPU **Low Latency**（EAGLE MTP 5-1-6）；改 High Throughput 策略＝註解掉
  `config.env` 的 `SPECULATIVE_*` 四行（官方另提供 DFlash2 投機解碼但 draft 模型 gated，暫不採）。

## ⚙️ 關鍵啟動參數與理由

| 參數 | 值 | 理由 |
| :--- | :--- | :--- |
| `--tp 8 --ep 8` | 8×H200 | 官方唯一 H200 配方（GSM8K 97% 驗證於此配置） |
| `--kv-cache-dtype bfloat16` | BF16 KV | Hopper 不支援 FP8 KV＋TRT-LLM DSA（官方明載） |
| `--dsa-prefill/decode-backend tilelang` | TileLang DSA | H200 建議配對（bf16-tilelang） |
| `--moe-runner-backend deep_gemm` | deep_gemm | 官方 MoE 後端 |
| `--speculative-algorithm EAGLE 5-1-6` | MTP 投機解碼 | 官方 Low Latency 配方（upstream 已將 NEXTN 併入 EAGLE） |
| `--mem-fraction-static 0.75` | 0.75 | 官方 Low Latency 值 |
| `MAX_RUNNING_REQUESTS` | 64（初始） | 上線後實測調優（比照 flash 48→100 經驗） |
| `HEALTH_TIMEOUT` | 2400 秒 | 328GB 權重載入＋DSA 編譯暖機 |
| context-length | 不設 | 官方配方不含此旗標（KV 池由 mem-fraction 決定） |

## 🛠️ 上線流程

```bash
# 1. 下載權重（328.3GB，hf download --local-dir 直落）
./download_model.sh zai-org/GLM-5.3-Flash

# 2. 驗證（靜態 → 煙霧；⚠️ VLM 模組：煙霧通過後必加一筆帶圖片請求，見 skill）
cd /path/to/work/github/litellm-proxy
./validate_engine.sh sglang-glm53-flash

# 3. 上線 / 停止
./start_models.sh sglang-glm53-flash
./stop_models.sh sglang-glm53-flash
```

> 💡 已驗證配方登記見 [`engines/KNOWN_GOOD.md`](../KNOWN_GOOD.md)；
> 評估流程見 [`.agents/skills/model-onboarding/`](../../.agents/skills/model-onboarding/README.md)；
> 完整操作手冊見 [`docs/ENGINE_LIFECYCLE_GUIDE.md`](../../docs/ENGINE_LIFECYCLE_GUIDE.md)。

## ⚠️ 注意事項

- **GPU 佔用**：本引擎 8×H200；與 flash（4）＋27b（1）同時運行需叢集 13 GPU 餘裕
- **共用 image**：與 flash 共用 `sglang_0.5.20.sif`——重建 image 會同時影響兩者
  （`pull_image.sh` 已加警告，重建後需雙引擎重驗）
- **多模態**：圖片／影片請求端到端未驗證（skill 規定煙霧測試需補帶圖請求）；
  影片功能需 image 內含 `torchcodec`（未驗證）

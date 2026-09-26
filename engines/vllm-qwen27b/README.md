# vLLM Qwen3.8-27B 引擎（SGLang vs vLLM A/B 對決用）

以 **vLLM** 框架服務 `Qwen3.8-27B`，與 [`sglang-qwen-27b`](../sglang-qwen-27b/) 進行**同模型 A/B 對決**：
同權重（本地 BF16 52GB 共享）、同 1×H200、同併發上限 128、同 500 人壓測。

## 設計依據（全部有憑有據）

| 來源 | 內容 |
| :--- | :--- |
| [官方 vLLM Recipe](https://recipes.vllm.ai/Qwen/Qwen3.8-27B) | kv fp8、`--reasoning-parser qwen3`（官方明言「實務上不可省」）、`--tool-call-parser qwen3_xml`、MTP 投機解碼 |
| [官方 Model Card](https://huggingface.co/Qwen/Qwen3.8-27B) | 架構 `Qwen3_5ForConditionalGeneration`（vLLM 0.17.0+ 原生支援）、262K context、thinking 預設開啟 |
| vLLM image 實測 | `vllm_latest.sif`（0.29.1rc1.dev452）registry 已映射 `Qwen3_5ForConditionalGeneration → qwen3_5.py` |

## 服務參數（R1 陽春版）

```bash
vllm serve /path/to/work/models/Qwen3.8-27B \
  --tensor-parallel-size 1 --max-model-len 262144 \
  --kv-cache-dtype fp8 --max-num-seqs 128 \
  --reasoning-parser qwen3 --tool-call-parser qwen3_xml --enable-auto-tool-choice
```

**R2 全力版**：config.env 取消註解 `SPECULATIVE_CONFIG={"method":"mtp","num_speculative_tokens":3}`
（官方 MTP：checkpoint 內建 draft head）。

## 與 SGLang 27B 的對等性

| 項目 | SGLang 27B | 本引擎 |
| :--- | :--- | :--- |
| 權重 | `/path/to/work/models/Qwen3.8-27B`（BF16） | **同一份** |
| GPU | 1×H200 | 1×H200 |
| 併發上限 | `MAX_MAMBA_CACHE_SIZE=640`（128×5 slots）→ cap 128 | `MAX_NUM_SEQS=128` |
| KV | fp8_e4m3 | fp8 |
| Gateway 模型名 | `Qwen/Qwen3.8-27B-FP8`＋別名 `qwen-27b` 等 | `Qwen/Qwen3.8-27B-vLLM`＋別名 `qwen-27b-vllm`（命名空間隔離） |

> **實績（2026-09-27 A/B 對決）**：3,597 tok/s／P95 54.6s／100%——以 6.3% 之差負於 SGLang 對照組（3,823 tok/s）；MTP 投機解碼高併發實測 **-16%**（算力飽和下 draft+verify 為純開銷，生產不建議）。完整戰報見 [`benchmarks/README.md`](../../benchmarks/README.md)。

## 操作

> 💡 **一鍵操作**（專案根目錄）：`./start_models.sh vllm-qwen27b`（派送→等就緒→自動重啟 Gateway）、
> `./validate_engine.sh vllm-qwen27b`（上線前兩階段驗證）、`./stop_models.sh vllm-qwen27b`（一鍵停止）。
> 完整流程見 [docs/ENGINE_LIFECYCLE_GUIDE.md](../../docs/ENGINE_LIFECYCLE_GUIDE.md)。

權重**無需下載**（與 sglang-qwen-27b 共享本地目錄）；`download_model.sh` 僅在需要重新取得權重時使用
（下載對象為真實 repo `Qwen/Qwen3.8-27B`）。

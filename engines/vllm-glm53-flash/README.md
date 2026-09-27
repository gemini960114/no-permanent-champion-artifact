# vLLM GLM-5.3-Flash 引擎（SGLang vs vLLM A/B 第三戰）

以 **vLLM** 服務 `GLM-5.3-Flash`（321B MoE／18B 激活，KDA 線性注意力＋NoPE sparse MLA、
原生 FP8、MTP），與 [`sglang-glm53-flash`](../sglang-glm53-flash/) 進行**同模型 A/B 對決**：
同權重（本地 FP8 306GB 共享）、同 8×H200 TEP8、同併發上限。

## 設計依據（全部有憑有據）

| 來源 | 內容 |
| :--- | :--- |
| [官方 vLLM Recipe](https://recipes.vllm.ai/zai-org/GLM-5.3-Flash) | TP/EP 擴展、`glm47` parser、MTP5、**Hopper 不支援 FP8 KV（用 BF16 KV）**、FlashInfer ≥0.6.17 |
| image 實測 | `vllm_0.29.1rc1.sif` registry 已映射 `Glm5NextForConditionalGeneration → vllm.models.glm5next`＋`Glm5NextMTP`；FlashInfer 0.6.18.post1 ✓ |

## 服務參數（R1 陽春版）

```bash
vllm serve /path/to/work/models/GLM-5.3-Flash \
  --tensor-parallel-size 8 --enable-expert-parallel \
  --gpu-memory-utilization 0.85 --max-num-seqs 128 \
  --reasoning-parser glm47 --tool-call-parser glm47 --enable-auto-tool-choice
```

**R2 全力版**：config.env 取消註解
`SPECULATIVE_CONFIG={"method":"mtp","num_speculative_tokens":5}`（官方 MTP5）。

## 與 SGLang glm53 的對等性

| 項目 | SGLang glm53 | 本引擎 |
| :--- | :--- | :--- |
| 權重 | `/path/to/work/models/GLM-5.3-Flash`（306GB FP8） | **同一份** |
| GPU | 8×H200 TP8+EP8 | 8×H200 TEP8 |
| Gateway 模型名 | `zai-org/GLM-5.3-Flash`＋別名 `glm5.3-flash` | `zai-org/GLM-5.3-Flash-vLLM`＋別名 `glm5.3-flash-vllm`（命名空間隔離） |

## 操作

> 💡 **一鍵操作**（專案根目錄）：`./start_models.sh vllm-glm53-flash`、
> `./validate_engine.sh vllm-glm53-flash`、`./stop_models.sh vllm-glm53-flash`。
> 完整流程見 [docs/ENGINE_LIFECYCLE_GUIDE.md](../../docs/ENGINE_LIFECYCLE_GUIDE.md)。

權重無需下載（與 SGLang 版共享）。`HEALTH_TIMEOUT=2400`（306GB 載入＋編譯）。

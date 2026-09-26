# vLLM Qwen3.8-Flash-Next 引擎（SGLang vs vLLM A/B 對決用）

以 **vLLM** 框架服務 `Qwen3.8-Flash-Next-FP8`（qwen4_exp 架構：GDN＋QSA＋Gated Residual
＋51B N-gram embedding＋512 專家 MoE），與 [`sglang-qwen-flash`](../sglang-qwen-flash/)
進行**同模型 A/B 對決**：同權重（本地 FP8 173GB 共享）、同 4×H200、同併發上限。

## 設計依據（全部有憑有據）

| 來源 | 內容 |
| :--- | :--- |
| [官方 vLLM Recipe](https://recipes.vllm.ai/Qwen/Qwen3.8-Flash-Next) | H200 章節：**TEP＋`--moe-backend triton`**（純 TP 與 FP8 128-寬量化塊不相容）、`--max-num-seqs 256`（低於此值會 mamba-cache 啟動錯誤）、prefix caching、關 flashinfer-autotune |
| [官方 Model Card](https://huggingface.co/Qwen/Qwen3.8-Flash-Next) | 架構 `qwen4_exp`（180B 總參／6B 激活）、thinking 預設開啟（` Müd` 標記）、262K context |
| vLLM image 實測 | `vllm_latest.sif`（0.29.1rc1.dev452）registry 已映射 `Qwen4ExpForConditionalGeneration → vllm.models.qwen4_exp`＋`Qwen4ExpMTP`（投機解碼） |

## 服務參數（R1 陽春版）

```bash
vllm serve /path/to/work/models/Qwen3.8-Flash-Next-FP8 \
  --tensor-parallel-size 4 --enable-expert-parallel --moe-backend triton \
  --gpu-memory-utilization 0.85 --max-num-seqs 256 --enable-prefix-caching \
  --no-enable-flashinfer-autotune \
  --reasoning-parser qwen3 --tool-call-parser qwen3_coder --enable-auto-tool-choice
```

**R2 全力版**：config.env 取消註解
`SPECULATIVE_CONFIG={"method":"mtp","num_speculative_tokens":3}`。
（⚠️ 官方 Recipe 於 4×H100 實測 MTP **全面變慢**：acceptance 僅 ~36%、吞吐 -8~36%——
R2 在 H200 驗證是否同樣結論。）

## 與 SGLang flash 的對等性

| 項目 | SGLang flash | 本引擎 |
| :--- | :--- | :--- |
| 權重 | `/path/to/work/models/Qwen3.8-Flash-Next-FP8`（173GB） | **同一份** |
| GPU | 4×H200 TP4+EP4 | 4×H200 TEP4 |
| Gateway 模型名 | `Qwen/Qwen3.8-Flash-Next-FP8`＋別名 `qwen3.8-flash` 等 | `Qwen/Qwen3.8-Flash-Next-vLLM`＋別名 `qwen-flash-vllm`（命名空間隔離） |

> **實績（2026-09-27 A/B 第二戰冠軍）**：1000 人×800 tok 壓測 **100%／7,886 tok/s／P95 63.2s**
> （R1 陽春配置即各自最佳）——勝 SGLang flash 最佳配置（NEXTN，3,925 tok/s）**2.01×**；
> MTP 投機解碼實測 **-46%**（與官方 Recipe H100 警告一致，不建議開啟）。
> 完整戰報見 [`benchmarks/README.md`](../../benchmarks/README.md)。

## 操作

> 💡 **一鍵操作**（專案根目錄）：`./start_models.sh vllm-flash-next`（派送→等就緒→自動重啟 Gateway）、
> `./validate_engine.sh vllm-flash-next`（上線前兩階段驗證）、`./stop_models.sh vllm-flash-next`（一鍵停止）。
> 完整流程見 [docs/ENGINE_LIFECYCLE_GUIDE.md](../../docs/ENGINE_LIFECYCLE_GUIDE.md)。

權重**無需下載**（與 sglang-qwen-flash 共享本地目錄）。`HEALTH_TIMEOUT=2400`（173GB 載入＋編譯）。

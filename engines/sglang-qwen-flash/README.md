# SGLang Qwen3.8-Flash-Next 容器化推論部署 (4x H200 GPU)

本目錄提供基於 **SGLang** 框架的高效推論部署方案，專門用於在 4 張 NVIDIA H200 GPU 上運行 `Qwen/Qwen3.8-Flash-Next-FP8`。

> **實績（2026-09-27 SGLang vs vLLM A/B 第二戰）**：各自最佳配置（NEXTN 3/1/4、cap 256）
> 1000 人×800 tok 壓測 100%／**3,925 tok/s**／P95 129.7s——敗 vLLM 對照組
> （[`engines/vllm-flash-next`](../vllm-flash-next/)，R1 陽春 7,886 tok/s）**2.01×**；
> NEXTN 投機解碼 +16%（MoE 解碼便宜，投機有效）。完整戰報見
> [`benchmarks/README.md`](../../benchmarks/README.md)。

---

## 🚀 核心規格與技術特色

* **平行架構**：Tensor Parallel (TP=4) 與 Expert Parallel (EP=4)。
* **推論加速**：
  * **Speculative Decoding**：採用 `NEXTN` 投機解碼演算法（3 步預測、Eagle Top-K=1、4 個 Draft Token）。
  * **線性注意力最佳化**：Prefill 與 Decode 均採用 FlashInfer，驗證採用 Triton。
  * **狀態空間模型 (SSM)**：Mamba SSM 採用 `bfloat16` 精度。
* **分塊預填充**：`chunked-prefill-size = 8192`。
* **全自動生命週期**：原生整合頂層 `lib/lifecycle.sh` 原子搶鎖、兩階段發布與退場安全清理。

---

## ⚡ 併發解碼上限 (MAX_RUNNING_REQUESTS)

SGLang 開啟 NEXTN 投機解碼時，會**自動把併發解碼上限降為 48**（log 訊息：`Max running requests is reset to 48 for speculative decoding`），但本引擎記憶體極為充裕（Mamba 狀態池 1,603 槽、KV cache 約 425 萬 tokens），48 遠低估硬體潛力。

於 `config.env` 設定即可覆蓋（`sglang_server.slurm` 會在變數有設定時條件附加 `--max-running-requests`）：

```env
MAX_RUNNING_REQUESTS=100
```

**實測效益**（1000 人 × 800 tokens 併發壓測，2026-09-25）：

| 指標 | 上限 48 | 上限 100 | 變化 |
| :--- | :---: | :---: | :---: |
| 峰值吞吐 | 4,463 tok/s | 6,221 tok/s | **+39%** |
| 總耗時 | 241.7 秒 | 188.4 秒 | **-22%** |
| P95 延遲 | 235.2 秒 | 184.6 秒 | **-21%** |
| 成功率 | 100% | 100% | 持平 |

完整對照與工程解讀見 [`benchmarks/README.md`](../../benchmarks/README.md)。**建議維持 100**：再往上投機解碼的批次退化會讓尾延遲快速增長，需要更高總吞吐時應優先多派引擎實例（LiteLLM 自動分流）。

---

## 🛠️ 快速操作指引

### 1. 下載模型權重
```bash
./download_model.sh Qwen/Qwen3.8-Flash-Next-FP8
```

### 2. 派送 Slurm 作業 (預設 4x H200 GPU)
```bash
./submit_slurm.sh
```

### 3. 監控啟動進度
```bash
./check_service.sh
```
待端點自檢通過並標記 `STATE=ready` 後，回到專案根目錄執行 `./start.sh`，LiteLLM 即可自動將 `Qwen3.8-Flash-Next-FP8` 與短別名 `qwen3.8-flash` 納入負載平衡！

> 💡 **一鍵替代方案**（專案根目錄）：`./start_models.sh sglang-qwen-flash`（派送→等就緒→自動啟動 Gateway）、`./validate_engine.sh sglang-qwen-flash`（上線前兩階段驗證）、`./stop_models.sh sglang-qwen-flash`（一鍵停止）。完整流程見 [docs/ENGINE_LIFECYCLE_GUIDE.md](../../docs/ENGINE_LIFECYCLE_GUIDE.md)。

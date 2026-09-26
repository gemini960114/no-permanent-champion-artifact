# vLLM DeepSeek-V4.1-Flash 容器化推論部署 (2x H200 GPU)

本目錄提供基於 **vLLM** 框架的高效推論部署方案，專門用於在 2 張 NVIDIA H200 GPU 上運行 `deepseek-ai/DeepSeek-V4.1-Flash`。

---

## 🚀 核心規格與技術特色

* **平行架構**：Tensor Parallel (TP=2)。
* **注意力機制與推論加速**：
  * **FlashInfer MLA Sparse**：`FLASHINFER_MLA_SPARSE_DSV41` 注意力後端，搭配 `mxfp4` 索引 KV Dtype 與 Sparse Logits。
  * **KV Cache 精度**：`fp8` 量化快取。
  * **Engram CPU Offload**：啟用 CPU 卸載支援。
* **Tokenizer 與 Parser**：
  * Tokenizer Mode: `deepseek_v41`。
  * Tool Call Parser: `deepseek_v41`（原生支援 `--enable-auto-tool-choice`）。
  * Reasoning Parser: `deepseek_v41`（深度思考思維鏈解析）。
  * 多模態編碼器：`--mm-encoder-tp-mode data`。
* **全自動生命週期**：原生整合專案頂層 `lib/lifecycle.sh` 原子搶鎖、兩階段發布與安全退場清理。

---

## 🛠️ 快速操作指引

### 1. 下載模型權重
```bash
./download_model.sh deepseek-ai/DeepSeek-V4.1-Flash
```

### 2. 派送 Slurm 作業 (預設 2x H200 GPU)
```bash
./submit_slurm.sh
```

### 3. 監控啟動進度
```bash
./check_service.sh
```
待端點自檢通過並標記 `STATE=ready` 後，回到專案根目錄執行 `./start.sh`，LiteLLM 即可自動將 `deepseek-ai/DeepSeek-V4.1-Flash` 與短別名 `deepseek-v4-flash` 納入負載平衡！

> 💡 **一鍵替代方案**（專案根目錄）：`./start_models.sh vllm-deepseek-flash`（派送→等就緒→自動啟動 Gateway）、`./validate_engine.sh vllm-deepseek-flash`（上線前兩階段驗證，權重下載完成後建議先跑一次）、`./stop_models.sh vllm-deepseek-flash`（一鍵停止）。完整流程見 [docs/ENGINE_LIFECYCLE_GUIDE.md](../../docs/ENGINE_LIFECYCLE_GUIDE.md)。

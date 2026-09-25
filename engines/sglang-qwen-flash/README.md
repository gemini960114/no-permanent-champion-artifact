# SGLang Qwen3.8-Flash-Next 容器化推論部署 (4x H200 GPU)

本目錄提供基於 **SGLang** 框架的高效推論部署方案，專門用於在 4 張 NVIDIA H200 GPU 上運行 `Qwen/Qwen3.8-Flash-Next-FP8`。

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

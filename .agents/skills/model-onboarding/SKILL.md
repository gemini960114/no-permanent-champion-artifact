---
name: model-onboarding
description: >-
  評估 Hugging Face 模型能否部署到 NCHC H200 參集：當使用者貼上 HF 模型 URL
  並要求評估可行性、選擇 vLLM 或 SGLang、docker image 版本、啟動參數，
  或要求比較模型／建成 engines/ 模組時使用。涵蓋引擎原生支援實測、
  硬體記憶體計算（4×/8×H200）、啟動參數草案；未經使用者明確同意
  絕不建立模組或下載權重。
---

# 模型上線評估 (Model Onboarding Review)

## 鐵律

1. **實測優先**：引擎支援與參數合法性用 `scripts/` 內的工具查證，**不猜、不盡信 model card**
   （實錄：Step-5 card 寫 `--reasoning-parser stepfun`，實測 SGLang 0.5.20 無此選項，正確值 `step3p5`）
2. **同意才動工**：使用者明確說「可以／做吧／建模」等，才建立 engines 模組或下載權重；
   徵求同意時揭露成本（磁碟、下載時間、驗證 GPU 時數）
3. **誠實的硬體結論**：只能是「✅ 直接上／🟡 等量化版／❌ 不可行（建議 API 接入）」三選一

## 工作流程

### Step 1：收集模型事實（抓 model card）
必查：總參數／激活參數（MoE?）、精度與檔案大小、架構（dense／MoE／hybrid mamba／
**VLM**）、context length、**是否 gated（HF 條款）**、官方部署指令（僅供參考）、License 限制。

### Step 2：實測引擎支援（跑腳本，別徒手）
```bash
# 於 repo 根目錄執行（或改用絕對路徑 /path/to/work/github/litellm-proxy/...）
.agents/skills/model-onboarding/scripts/check_engine_support.sh <架構關鍵字>
# 檢查三個現有 image (sglang 0.5.19/0.5.20, vllm 0.29.1rc1) 的模型檔
# ＋ reasoning-parser 合法選項 (DetectorMap)
```
- 模型檔存在＝必要非充分條件，最終以 Step 6 煙霧測試為準
- 無原生支援 → 查上游收錄版本，建議重拉 image 並版本釘選（避免 `latest`）
- **重拉共用 image 會影響共用該 image 的其他引擎**（重新驗證＋更新 KNOWN_GOOD）

### Step 3：硬體適配計算（跑腳本）
```bash
.agents/skills/model-onboarding/scripts/estimate_fit.py --params <總參數B> --precision <bf16|fp8|int4>
# 例：--params 604 --precision fp8 --active 27 --extra-gb 20（--extra-gb＝多模態視覺塔等額外顯存）
# 自動對照 4×H200 (564GB) / 8×H200 (1,128GB) / df 磁碟剩餘
```
人工再加計：TP8/EP8 通訊緩衝（5-10%）、KV cache 預留（≥20-30%，腳本已含 25% 保守值）。

### Step 4：輸出評估報告（必含）
- 框架建議（**附實測證據**：腳本輸出摘要）
- 記憶體計算表、image 版本
- 啟動參數草案：TP/EP、context-length 現實值（官方值通常是理想值）、
  reasoning-parser（**實測合法值**）、MAX_RUNNING_REQUESTS 初始 64、HEALTH_TIMEOUT
- 埠位分配（以各引擎 config.env 為準；現用：27b=30000、flash=32000、vllm=33000、step5=34000）
- **不部署替代方案**（官方 API）與成本預估（下載時間／磁碟／GPU 時數）

### Step 5：等待明確同意 ⚠️（見鐵律 2）

### Step 6：建成 engines 模組
```bash
./new_engine.sh <框架>-<模型>-<精度> --from <最接近原型>
# → 改 config.env(.example)：模型名/埠/TP/參數/金鑰沿用
# → 改 *server.slurm：GPU 數/CPU/mem/啟動參數（合法性已於 Step 2 驗證）
# → 寫引擎 README（規格、參數理由、硬體評估摘要、狀態）
# → ./download_model.sh → ./validate_engine.sh <名稱> → ./start_models.sh <名稱>
# → 更新 engines/KNOWN_GOOD.md ＋ 本 skill README.md 的評估記錄表
```
- 目錄命名：`sglang-<模型>-<精度>`；job-name 為底線版本
- **VLM 模組煙霧驗證必加一筆帶圖片的請求**（`validate_engine.sh` 只測文字，需手動補）：
  ```bash
  curl -s -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -d '{"model":"<MODEL_NAME>","messages":[{"role":"user","content":[
      {"type":"image_url","image_url":{"url":"https://huggingface.co/datasets/huggingface/documentation-images/resolve/main/p-blog/candy.JPG"}},
      {"type":"text","text":"圖片裡是什麼動物？"}]}],"max_tokens":64}' \
    "http://<引擎IP>:<PORT>/v1/chat/completions"
  ```
- `--trust-remote-code` 僅用於官方／可信任 repo（鏡像需核對出處）

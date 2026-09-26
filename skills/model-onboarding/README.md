# Skill：模型上線評估 (Model Onboarding Review)

> **這是給 AI 助手的技能指令**——當使用者貼上一個 Hugging Face 模型 URL，
> 依本流程評估、給建議，**經使用者明確同意後**才建成 `engines/` 模組。
> v1.1（2026-09-26 專家複審後強化：新增 parser 合法性檢查、gated model 檢查、
> 成本揭露與多模態驗證——複審實績：靠本流程抓到 model card 的
> `--reasoning-parser stepfun` 在 SGLang 0.5.20 不存在，正確值為 `step3p5`）

---

## 使用者端：自然語言 Prompt 範例

直接用日常語言描述即可，AI 會辨識意圖套用本 skill：

### 範例 1：標準評估（最常用）
```
評估一下 https://huggingface.co/TypeSafeAI/Step-5-Preview-BF16
我們的 H200 叢集跑得動嗎？用 vllm 還是 sglang？哪個版本？
```

### 範例 2：評估＋授權建模（一次到位）
```
評估 https://huggingface.co/Qwen/Qwen3.9-450B-FP8，
如果可行就直接照 engines 的架構寫成一個新引擎目錄給我
```

### 範例 3：只問可行性
```
https://huggingface.co/deepseek-ai/DeepSeek-V5 這個模型
我們四張 H200 放不放得下？記憶體幫我算一下
```

### 範例 4：指定框架偏好
```
評估這個模型 https://huggingface.co/xxx/yyy，
我比較想用 sglang（我們 pipeline 比較熟），可以嗎？
參數怎麼定？
```

### 範例 5：比較多個模型
```
幫我比較這兩個模型哪個適合我們叢集上線：
https://huggingface.co/A/model-1  和  https://huggingface.co/B/model-2
```

### 範例 6：追蹤進度型（模型還沒釋出）
```
評估 https://huggingface.co/xxx/Step-5-Preview-FP8
如果現在還不能跑（例如權重還沒出），先把引擎目錄 scaffold 好等它
```

---

## AI 端：標準作業流程

### Step 1：收集模型事實（抓 model card）
| 必查項目 | 用途 |
| :--- | :--- |
| 總參數量／激活參數（MoE?） | 記憶體計算 |
| 精度（BF16/FP8/INT4）與檔案大小 | 記憶體與磁碟計算 |
| 架構（dense／MoE／hybrid mamba／**VLM**／新注意力） | 引擎支援判定、特殊參數、**額外顯存** |
| Context length | `--context-length` 現實值 |
| **是否 gated（需 HF 同意條款）／檔案格式（safetensors?）** | 下載可行性：gated 需使用者先在 HF 網頁接受條款，`HF_TOKEN` 才有效 |
| 官方部署範例（vllm/sglang 指令） | 參數草案——**僅供參考，不可照抄**（見 Step 2 教訓） |
| License 條款（商用限制、用途禁止） | 合規判斷，有限制需明確告知使用者 |

### Step 2：實測引擎支援（不要用猜的，也不要盡信 model card）
```bash
# (a) 現有 image 有沒有原生支援該架構？（兩個 SGLang image 版本不同，都要查）
apptainer exec /path/to/work/containers/sglang_flash_latest.sif \
  bash -c "ls /sgl-workspace/sglang/python/sglang/srt/models/ | grep -i <關鍵字>"
apptainer exec /path/to/work/containers/sglang_latest.sif \
  bash -c "ls /sgl-workspace/sglang/python/sglang/srt/models/ | grep -i <關鍵字>"
apptainer exec /path/to/work/containers/vllm_latest.sif \
  bash -c "ls /vllm-workspace/vllm/model_executor/models/ | grep -i <關鍵字>"

# (b) 特殊參數的合法選項（例：reasoning-parser——model card 寫的值可能不存在！）
apptainer exec <SIF> bash -c \
  "sed -n '/DetectorMap/,/}/p' /sgl-workspace/sglang/python/sglang/srt/parser/reasoning_parser.py"
```
- 模型檔存在是**必要條件而非充分條件**（仍需 registry 註冊）——最終判定以
  Step 6 的煙霧測試為準
- **教訓實錄**：Step-5 model card 寫 `--reasoning-parser stepfun`，實測 0.5.20
  DetectorMap 無此值（正確為 `step3p5`）——照抄官方指令會啟動失敗
- 沒有原生支援 → 查該架構進入上游的版本，建議重拉 image 並**版本釘選**（避免 `latest`）；
  重拉共用 image 前注意會影響共用該 image 的其他引擎（重新驗證＋更新 KNOWN_GOOD）

### Step 3：硬體適配計算（殘酷但誠實）
```
權重需求 = 參數量 × 每參數位元組（BF16=2, FP8=1, INT4=0.5）
加計：
  多模態 encoder（VLM 的視覺塔另佔顯存，數值查 model card／實測）
  TP/EP 通訊緩衝與 CUDA Graph（TP8 比 TP4 顯著，預留 5-10%）
對照：
  4×H200 = 564 GB ／ 8×H200 = 1,128 GB（單節點上限）
  磁碟：df /work（HF cache 會另存一份，需 2× 權重大小的餘裕）
KV cache 預留：至少 20-30%（大 context 模型要更多）
```
結論必為下列之一：**✅ 直接上**／**🟡 等量化版**／**❌ 硬體不可行（建議 API 接入）**

### Step 4：輸出評估報告（給使用者決策）
必含：
- 框架建議（**含實測證據**：image 內 grep 結果、parser 合法選項）
- image 版本、記憶體計算表
- 啟動參數草案（TP/EP、context-length 現實值、reasoning-parser 實測合法值、
  MAX_RUNNING_REQUESTS 初始值、HEALTH_TIMEOUT）
- 埠位分配（快照：27b=30000、flash=32000、vllm=33000、step5=34000——
  **以各引擎 config.env 為準，新增引擎後同步更新本表**）
- **不部署的替代方案**（官方 API 接入的成本／可行性）——每份報告必列
- **成本預估**：下載時間（依歷史吞吐估算）、磁碟佔用、驗證所需 GPU 時數

### Step 5：等待使用者明確同意 ⚠️
**沒有明確同意（如「可以」「做吧」「建模」）絕不建立模組或下載權重。**
徵求同意時需揭露成本：磁碟空間、下載時間、驗證用 GPU 時數。

### Step 6：使用者同意後——建成 engines 模組
```bash
./new_engine.sh <框架>-<模型名>-<精度> --from <最接近的原型>   # scaffold
# → 改 config.env(.example)（模型名/埠/TP/參數/金鑰沿用）
# → 改 sglang_server.slurm（GPU 數/CPU/mem/啟動參數/特殊旗標）
# → 寫引擎 README（規格、參數理由、硬體評估摘要、狀態）
# → ./download_model.sh → ./validate_engine.sh <名稱> → ./start_models.sh <名稱>
# → 更新 engines/KNOWN_GOOD.md 登記（版本/參數/驗證日期）
# → 更新本檔下方「評估記錄」表
```
- 目錄命名慣例：`sglang-<模型>-<精度>`（如 `sglang-step5-fp8`）；job-name 為底線版本
- **VLM 模組**：煙霧驗證除文字 chat 外，**必加一筆帶圖片的請求**（視覺塔端到端）
- **`--trust-remote-code` 安全邊界**：會執行 HF repo 內的遠端 Python——僅用於
  官方／可信任組織的 repo，鏡像 repo 需核對原出處

---

## 已完成的評估記錄

| 日期 | 模型 | 結論 | 模組 |
| :--- | :--- | :--- | :--- |
| 2026-09-26 | [Step-5-Preview-BF16](https://huggingface.co/TypeSafeAI/Step-5-Preview-BF16) | 🟡 BF16（1.21TB）超出 8×H200 與磁碟；FP8＋8×H200 可行（SGLang **0.5.20** 原生支援 step3p5；⚠️ model card 的 `--reasoning-parser stepfun` 實測不存在，正確值 `step3p5`） | `engines/sglang-step5-fp8/`（等待 FP8 釋出） |

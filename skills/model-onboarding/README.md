# Skill：模型上線評估 (Model Onboarding Review)

> **這是給 AI 助手的技能指令**——當使用者貼上一個 Hugging Face 模型 URL，
> 依本流程評估、給建議，**經使用者同意後**才建成 `engines/` 模組。

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
| 架構（dense／MoE／hybrid mamba／VLM／新注意力） | 引擎支援判定、特殊參數 |
| Context length | `--context-length` 現實值 |
| 官方部署範例（vllm/sglang 指令） | 參數草案 |
| License | 使用限制 |

### Step 2：實測引擎支援（不要用猜的）
```bash
# 我們現有 image 有沒有原生支援該架構？
apptainer exec /path/to/work/containers/sglang_flash_latest.sif \
  bash -c "ls /sgl-workspace/sglang/python/sglang/srt/models/ | grep -i <關鍵字>"
apptainer exec /path/to/work/containers/vllm_latest.sif \
  bash -c "ls /vllm-workspace/vllm/model_executor/models/ | grep -i <關鍵字>"
```
- 有原生支援 → 用現有 image（版本以 `engines/KNOWN_GOOD.md` 登記為準）
- 沒有 → 查該架構進入上游的版本，建議重拉 image 並**版本釘選**（避免 `latest`）

### Step 3：硬體適配計算（殘酷但誠實）
```
權重需求 = 參數量 × 每參數位元組（BF16=2, FP8=1, INT4=0.5）
對照：
  4×H200 = 564 GB ／ 8×H200 = 1,128 GB（單節點上限）
  磁碟：df /work（下載與暫存需 2× 權重大小的餘裕）
KV cache 預留：至少 20-30%（大 context 模型要更多）
```
結論必為下列之一：**✅ 直接上**／**🟡 等量化版**／**❌ 硬體不可行（建議 API 接入）**

### Step 4：輸出評估報告（給使用者決策）
必含：框架建議（含實測證據）、image 版本、記憶體計算表、啟動參數草案
（TP/EP、context-length 現實值、reasoning-parser、MAX_RUNNING_REQUESTS 初始值、
HEALTH_TIMEOUT）、埠位分配（現用：27b=30000、flash=32000、vllm=33000、step5=34000）。

### Step 5：等待使用者同意 ⚠️
**沒有明確同意（如「可以」「做吧」「建模」）絕不建立模組或下載權重。**

### Step 6：使用者同意後——建成 engines 模組
```bash
./new_engine.sh <框架>-<模型名>-<精度> --from <最接近的原型>   # scaffold
# → 改 config.env(.example)（模型名/埠/TP/參數/金鑰沿用）
# → 改 sglang_server.slurm（GPU 數/CPU/mem/啟動參數/特殊旗標）
# → 寫引擎 README（規格、參數理由、硬體評估摘要、狀態）
# → ./download_model.sh → ./validate_engine.sh <名稱> → ./start_models.sh <名稱>
# → 更新 engines/KNOWN_GOOD.md 登記（版本/參數/驗證日期）
```
目錄命名慣例：`sglang-<模型>-<精度>`（如 `sglang-step5-fp8`）；job-name 為底線版本。

---

## 已完成的評估記錄

| 日期 | 模型 | 結論 | 模組 |
| :--- | :--- | :--- | :--- |
| 2026-09-26 | [Step-5-Preview-BF16](https://huggingface.co/TypeSafeAI/Step-5-Preview-BF16) | 🟡 BF16 超出硬體；FP8＋8×H200 可行（SGLang 0.520 原生支援） | `engines/sglang-step5-fp8/`（等待 FP8 釋出） |

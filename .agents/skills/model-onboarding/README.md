# Skill：模型上線評估 (Model Onboarding Review)

> **SKILL.md**＝AI 載入的技能指令（含觸發描述）；本 README＝人類說明文件。
> 附屬執行工具：`scripts/check_engine_support.sh`（引擎支援＋parser 合法選項實測）、
> `scripts/estimate_fit.py`（記憶體／磁碟適配估算）。
> v1.3（2026-09-26）：落腳 `.agents/skills/`（opencode 等 agent 之標準掃描位置，
> 供應商中立）；日後若需 Claude Code，加一條 symlink 即可：
> `mkdir -p .claude/skills && ln -s ../../.agents/skills/model-onboarding .claude/skills/`。

## 如何使用（三種方式）

**方式 ①（建議）：對 AI 助手說自然語言**——在 repo 內啟用 opencode 等 agent，
直接貼 HF 模型 URL＋你的問題（範例見下方）。Skill 依 frontmatter 描述自動載入，
AI 會：跑實測腳本 → 給評估報告（框架／版本／記憶體／參數草案）→ **等你點頭** →
`scaffold → 驗證 → 上線 → 登記` 一路做完。

**方式 ②：手動跑評估工具**（不想透過 AI、只要快速查證時）：
```bash
.agents/skills/model-onboarding/scripts/check_engine_support.sh <架構關鍵字>
.agents/skills/model-onboarding/scripts/estimate_fit.py --params 604 --precision fp8
```

**方式 ③：完全手動建模**（不經評估，適合熟手）：
```bash
./new_engine.sh <框架>-<模型>-<精度> --from <原型>   # scaffold
cd engines/<新引擎> && vim config.env                 # 改模型名/參數
cd ../.. && ./validate_engine.sh <新引擎>             # 兩階段驗證
./start_models.sh <新引擎>                            # 一鍵上線
```

完整流程細節與鐵律（實測優先／同意才動工／三選一結論）見
[SKILL.md](./SKILL.md)；操作全貌見
[docs/ENGINE_LIFECYCLE_GUIDE.md](../../docs/ENGINE_LIFECYCLE_GUIDE.md)。

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
https://huggingface.co/zai-org/GLM-5.3-Flash 這個模型
我們四張 H200 放不放得下？記憶體幫我算一下
```

### 範例 4：指定框架偏好
```
評估這個模型 https://huggingface.co/xxx/yyy，
我比較想用 sglang（我們 pipeline 比較熟），可以嗎？參數怎麼定？
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

## 工具用法

```bash
# 引擎支援實測（三 image 模型檔 + reasoning-parser 合法選項）
.agents/skills/model-onboarding/scripts/check_engine_support.sh step

# 硬體適配估算（權重 × 精度 vs 4×/8×H200 與 /work 磁碟）
.agents/skills/model-onboarding/scripts/estimate_fit.py --params 604 --precision fp8 --active 27
```

## 上線五步教學（模組建好之後）

> 建模（Step 6）完成 ≠ 上線。以下是把一個新建引擎帶到正式服務的完整流程，
> 在固定部署節點（現為 `login-2`）執行。實例對照：`engines/sglang-glm53-flash/`。

### ① 確認 config.env

```bash
cd engines/<新引擎> && grep -vE "^#|^$" config.env   # 檢視非註解行
```

| 必看欄位 | 說明 |
| :--- | :--- |
| `MODEL_NAME` / `MODEL_ALIAS` | HF repo 名／對外別名（別名＝使用者請求時填的 model） |
| `SIF_PATH` | image 路徑——共用 image 時**不要**跑 `pull_image.sh`（會覆蓋其他引擎的 image） |
| `SGLANG_API_KEY` | 引擎內部金鑰——scaffold 時自動沿用共用值，通常不用動 |
| `HF_TOKEN` | **gated 模型必須**（先去 HF 網頁接受條款）；**非 gated 建議帶**（避免匿名限流，大檔下載更穩）。scaffold 沿用前引擎的值 |
| `TP`/`EP`/`PORT`/`MEM_FRACTION` | 評估報告建議值，通常已填好 |

### ② 下載權重（背景執行）

```bash
cd engines/<新引擎>
nohup ./download_model.sh <org>/<model> > download_<引擎>.log 2>&1 &
tail -f download_<引擎>.log        # Ctrl+C 只離開檢視，不影響下載
```
- 磁碟：`--local-dir` 直落目標約 **1× 權重大小**；下載前 `df -h /path/to/work/models` 確認
- 時間：視權重與吞吐而定（百 GB 級約 1~3 小時）
- **完成判斷**：log 出現「✅ 模型下載完成」＋模型目錄有 `config.json`

### ③ 驗證（不佔卡，自動收工）

```bash
cd /path/to/work/github/litellm-proxy
./validate_engine.sh <新引擎>
```
Stage 0 靜態 → Stage 1 煙霧 job（載入＋暖機 → 測 models＋chat → 自動 scancel）。
**VLM 模組**：煙霧通過後必補一筆帶圖請求（curl 模板見 SKILL.md Step 6）。

### ④ 正式上線

```bash
./start_models.sh <新引擎>          # 派送 → 等 ready → Gateway 自動納入路由
```

### ⑤ 驗收

```bash
./healthcheck.sh                    # 全綠
curl -s -H "Authorization: Bearer <虛擬金鑰>" http://localhost:54921/v1/models
# 外部路徑（VM 隧道）抽測：http://VM_PUBLIC_IP:4000/v1/models
```

日常操作：`./stop_models.sh <新引擎>`（停）、`./start_models.sh <新引擎>`（重啟）。

## 已完成的評估記錄

| 日期 | 模型 | 結論 | 模組 |
| :--- | :--- | :--- | :--- |
| 2026-09-26 | [Step-5-Preview-BF16](https://huggingface.co/TypeSafeAI/Step-5-Preview-BF16) | 🟡 BF16（1.21TB）超出 8×H200 與磁碟；FP8＋8×H200 可行（SGLang **0.5.20** 原生支援 step3p5；⚠️ model card 的 `--reasoning-parser stepfun` 實測不存在，正確值 `step3p5`） | `engines/sglang-step5-fp8/`（等待 FP8 釋出） |
| 2026-09-26 | [GLM-5.3-Flash](https://huggingface.co/zai-org/GLM-5.3-Flash) | ✅ 可行：328.3GB 原生 FP8＋8×H200 官方配方（SGLang **0.5.20** 原生 glm5_next；glm45/glm47 parser、tilelang、deep_gemm、EAGLE 全數實測在 image 內；H200 無 4-GPU 配方） | `engines/sglang-glm53-flash/`（✅ 已上線，VLM 帶圖驗證通過） |

## 相關文件

- 已驗證配方登記表：[`engines/KNOWN_GOOD.md`](../../../engines/KNOWN_GOOD.md)
- 引擎操作手冊：[`docs/ENGINE_LIFECYCLE_GUIDE.md`](../../../docs/ENGINE_LIFECYCLE_GUIDE.md)

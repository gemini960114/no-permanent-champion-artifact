# Skill：模型上線評估 (Model Onboarding Review)

> **SKILL.md**＝AI 載入的技能指令（含觸發描述）；本 README＝人類說明文件。
> 附屬執行工具：`scripts/check_engine_support.sh`（引擎支援＋parser 合法選項實測）、
> `scripts/estimate_fit.py`（記憶體／磁碟適配估算）。
> v1.3（2026-09-26）：落腳 `.agents/skills/`（opencode 等 agent 之標準掃描位置，
> 供應商中立）；日後若需 Claude Code，加一條 symlink 即可：
> `mkdir -p .claude/skills && ln -s ../../.agents/skills/model-onboarding .claude/skills/`。

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

## 已完成的評估記錄

| 日期 | 模型 | 結論 | 模組 |
| :--- | :--- | :--- | :--- |
| 2026-09-26 | [Step-5-Preview-BF16](https://huggingface.co/TypeSafeAI/Step-5-Preview-BF16) | 🟡 BF16（1.21TB）超出 8×H200 與磁碟；FP8＋8×H200 可行（SGLang **0.5.20** 原生支援 step3p5；⚠️ model card 的 `--reasoning-parser stepfun` 實測不存在，正確值 `step3p5`） | `engines/sglang-step5-fp8/`（等待 FP8 釋出） |

## 相關文件

- 已驗證配方登記表：[`engines/KNOWN_GOOD.md`](../../../engines/KNOWN_GOOD.md)
- 引擎操作手冊：[`docs/ENGINE_LIFECYCLE_GUIDE.md`](../../../docs/ENGINE_LIFECYCLE_GUIDE.md)

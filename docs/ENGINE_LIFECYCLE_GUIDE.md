# 引擎生命週期操作手冊 (Engine Lifecycle Guide)

> **目的**：地端推論引擎（SGLang / vLLM）的**啟動、驗證、停止、新模型上線**一套完整操作指引。
> 對象：日常維運者與新成員。模型路由與 Gateway 的對外設定見
> [README.md](../README.md)；已驗證的引擎配方（image 版本 × 參數）見
> [engines/KNOWN_GOOD.md](../engines/KNOWN_GOOD.md)。

---

## 1. 指令總覽（角色分工）

| 指令 | 管什麼 | 關鍵行為 |
| :--- | :--- | :--- |
| `./start_models.sh <引擎...>` | **引擎 + Gateway** | 指定引擎派送 Slurm job → 等待 `STATE=ready` → 自動啟動 Gateway。已在跑的引擎冪等跳過；未指定的不啟動 |
| `./stop_models.sh [引擎...]` | **引擎** | 不帶參數停止**所有**引擎；帶參數停指定引擎。依 job-name 精準匹配，不誤停 `validate_*` 或其他作業；Gateway 不動 |
| `./new_engine.sh <名> --from <原型>` | 建新引擎目錄 | 從原型複製並改寫 `job-name`／`ENGINE_NAME`（防撞名） |
| `./validate_engine.sh <引擎>` | 引擎品質 | Stage 0 靜態檢查（不耗 GPU）＋ Stage 1 煙霧測試（自動回收） |
| `./start_background.sh` | Gateway | 冪等重啟 Gateway＋重算路由（引擎增減後刷新用） |
| `./stop.sh` | Gateway | 停止 Gateway |
| `./healthcheck.sh` | 全部 | 行程／監聽／鑑權／隧道／上游一次檢查 |
| `engines/<引擎>/submit_slurm.sh` | 單引擎 | 手動派送（`start_models.sh` 的底層） |

> 💡 **核心觀念**：引擎（廚房）與 Gateway（大門）分開管理。`start_models.sh` 只是把
> 「送 job → 等就緒 → 開大門」串成一鍵；Gateway **不會**自己啟動或停止任何引擎。

---

## 2. 設定檔與登記處分工

```
① .env（人工，一次性）      → 全域：HOST/PORT、Master Key、Portal 金鑰、OOD 開關
② engines/<引擎>/config.env → 引擎私有：內部金鑰、模型名、image、併發上限
                              （git 不追蹤；由 config.env.example 複製）
③ runtime/endpoints/*.env   → 引擎 job 啟動時「自動發布」的端點資訊（節點/埠/別名）
                              隨 job 生滅，退場 trap 自動清理
④ config.runtime.yaml       → generator 依 ②③ 自動合成，勿手改
```

- **覆寫優先序**：①（環境變數）> ②（引擎 config.env）——引擎金鑰常規留給 ② 管理。
- 詳細註記見 [`.env.example`](../.env.example)。
- 目錄名是「部署配方」（框架＋檔位），**不是**模型名——真實模型名稱與別名定義在 ②，
  使用 `./start_models.sh --list` 可一覽。

---

## 3. 每日運行 SOP

### 開市（建議在固定部署節點執行，現為 `login-2`——隧道目標綁定此節點）

```bash
cd /path/to/work/github/litellm-proxy
./start_models.sh sglang-qwen-27b sglang-qwen-flash   # 要跑哪些就列哪些
./healthcheck.sh                                       # 驗收：全綠即上線
```

### 驗收檢查點
- `start_models.sh` 輸出 `READY` 且 Gateway 健康檢查通過
- `/v1/models` 應列出預期模型（例：15 個＝Portal 3＋27B 家族＋flash 家族）
- 外部路徑（VM 隧道）抽測：`curl http://VM_PUBLIC_IP:4000/v1/models -H "Authorization: Bearer <金鑰>"`

### 下市（釋放 GPU）

```bash
./stop_models.sh                 # 一鍵停所有引擎
./stop.sh                        # （可選）一併停 Gateway
```

- 只停部分引擎：`./stop_models.sh sglang-qwen-flash`，之後 `./start_background.sh` 刷新路由。
- 引擎退場自動清理 ③（port 鎖與 endpoint 檔），Gateway 重啟後該模型自路由移除。

---

## 4. 新模型上線 SOP（六步）

> 💡 本 SOP 已 AI 技能化：貼上 HF 模型 URL 即可觸發自動評估（引擎支援實測、硬體適配、
> 參數草案），經同意後自動建模——見
> [`.agents/skills/model-onboarding/`](../.agents/skills/model-onboarding/README.md)。

```bash
# ① 從最接近的原型 scaffold（原型特性見 KNOWN_GOOD.md 總覽表）
./new_engine.sh my-model --from sglang-qwen-flash
./new_engine.sh --list-archetypes        # 不確定時先看三種原型

# ② 編輯 engines/my-model/config.env
#    MODEL_NAME / MODEL_ALIAS：新模型 HF 識別名
#    SIF_PATH：指向正確版本的 image（選版原則：HF model card 建議版本優先，
#              避免依賴 :latest 浮動 tag；版本登記於 KNOWN_GOOD.md）

# ③ 下載權重與 image
cd engines/my-model && ./download_model.sh && ./pull_image.sh && cd ../..

# ④ 驗證（不耗 GPU 的靜態檢查 → 煙霧啟動）
./validate_engine.sh my-model            # 已在運行則直測現有實例
./validate_engine.sh my-model --fresh    # 強制派新短時 job（參數調整後重驗）

# ⑤ 正式上線
./start_models.sh my-model

# ⑥ 更新 engines/KNOWN_GOOD.md（實測版本、參數、日期）——這步驟讓下一個人不用重新踩坑
```

> 🛑 下線／重啟：`./stop_models.sh my-model` 一鍵停止；參數調整後以
> `./validate_engine.sh my-model --fresh` 重新驗證再上線。
> 📖 建模後的完整上線教學（config 欄位說明、HF_TOKEN 判斷、下載/驗證/驗收細節）
> 見 [`.agents/skills/model-onboarding/README.md`](../.agents/skills/model-onboarding/README.md)〈上線五步教學〉。

### validate_engine.sh 兩階段說明

| Stage | 檢查項目 | 失敗時的提示 |
| :--- | :--- | :--- |
| 0（靜態） | config.env 存在、MODEL_NAME、權重就位（**沿用引擎 slurm 的 CANDIDATES 候選路徑解析**）、SIF 存在、金鑰已設、slurm 語法、跨引擎 job-name 撞名 | 逐項指出缺什麼與對應指令 |
| 1（煙霧） | 引擎 `/v1/models` 200＋一筆小 chat 200 | job 未就緒時提示查 `engines/<引擎>/logs/` |

- 煙霧 job 以 `--time`（預設 30 分鐘，`SMOKE_WALLTIME` 可調）限制牆鐘，測完**自動 scancel**。
- Stage 1 直連引擎（不經 Gateway），驗證的是引擎本身。

---

## 5. 疑難排解（實際踩過的坑）

| 症狀 | 原因 | 解法 |
| :--- | :--- | :--- |
| sbatch 後引擎正常但 `start_models.sh`／`validate_engine.sh` 等不到 ready | **提交目錄不對**：slurm 的 `#SBATCH --output=logs/...` 與 runtime 登記為相對路徑，從 repo root 提交會解析到 `/path/to/work/runtime/`（迷路登記處） | 一律從**引擎目錄**提交（`start_models.sh`／`validate_engine.sh` 已內建 cd；手動 `submit_slurm.sh` 也在目錄內執行）。發現迷路目錄確認無其他用途後刪除 |
| 兩個引擎互相「冪等跳過」誤判 | 共用 `--job-name`（新引擎 scaffold 未改名） | `new_engine.sh` 已自動改寫；`validate_engine.sh` Stage 0 會檢出撞名 |
| 權重明明下載了卻說「未就位」 | 模型目錄名與 `MODEL_NAME` 尾綴不一致（例：`Qwen3.8-27B` vs `...-FP8`） | 引擎 slurm 的 `CANDIDATES` 候選清單有 fallback；`validate_engine.sh` 沿用同一套解析。新引擎建議直接在 CANDIDATES 加候選路徑 |
| 引擎啟動逾時佔卡 | 載入超過 `HEALTH_TIMEOUT` | job 會自動 scancel 釋放 GPU（fail-safe 已內建）；flash／vLLM 預設 1800 秒 |
| 煙霧 job 殘留 | 驗證腳本中斷 | 牆鐘到自動結束；或手動 `scancel -n validate_<tag>` |
| Gateway 路由含已停引擎 | 引擎停止後 Gateway 未重啟 | `./start_background.sh` 冪等刷新 |
| 跨節點執行 start／stop 失敗 | Gateway PID 為節點區域 | 以 `.litellm_node` 記錄為準；`start_models.sh` 會拒絕錯節點執行並提示 |

---

## 6. 與其他文件的關係

| 文件 | 內容 |
| :--- | :--- |
| [README.md](../README.md) | 對外連線方式、安全設計、指令速查 |
| [engines/KNOWN_GOOD.md](../engines/KNOWN_GOOD.md) | 已驗證配方登記表（image 版本 × 參數 × 實績） |
| [docs/HPC_LITELLM_GATEWAY_ARCHITECTURE.md](./HPC_LITELLM_GATEWAY_ARCHITECTURE.md) | 整體架構設計 |
| [docs/PLAN_UPDATE_DAILY_MODEL_LIFECYCLE.md](./PLAN_UPDATE_DAILY_MODEL_LIFECYCLE.md) | 生命週期底層機制（兩階段發布、Port 原子鎖、三態對帳） |
| [docs/EXTERNAL_VM_TUNNEL.md](./EXTERNAL_VM_TUNNEL.md) | 外部 VM 反向隧道 |

# Plan Update：每日模型啟停與 LiteLLM 設定更新

> [!WARNING]
> ⚠️ **此為階段歷史記錄，現行行為以 [HPC_LITELLM_GATEWAY_ARCHITECTURE.md](./HPC_LITELLM_GATEWAY_ARCHITECTURE.md) 為準。**

> [!NOTE]
> **文件狀態：Phase 1A（Endpoint Registry、Port 原子鎖、三態對帳合成與雙向清理機制）已實作並完成實體驗收（經同節點雙 Job 418623/418624 現場實測通過）。**  
> 更新日期：2026-09-22  
> **成果簡述**：已完成「POSIX 原生原子目錄鎖 (`mkdir`) 探測 Port」、「端點登錄庫 (`runtime/endpoints/`)」、「Controller 設定合成器 (`scripts/generate_runtime_config.py`)」、「端點生命週期三態自動對帳清理」與「同機多實例連接埠避讓與清理現場實測」。完整技術細節與測試記錄請參閱 [WALKTHROUGH_PHASE1A.md](./WALKTHROUGH_PHASE1A.md)；相關維運與部署操作請參閱 [README.md](../README.md)。

## 1. 背景與目標

本服務預計供單位同仁於上班時段使用：

- 服務時段：08:00～20:00。
- 預計營運 3～5 個模型。
- 部分大型模型可能使用單一 Slurm Job 跨 2 個節點、共 16 張 GPU。
- 07:00 起預先提交模型 Job，保留模型下載、載入、跨節點初始化、CUDA Graph 捕獲與健全測試時間。
- 20:00 後停止服務並釋放 Slurm GPU 配額。

目標是在不引入 Kubernetes、額外 VM 或 HPC 登入節點 PostgreSQL 服務的前提下，建立簡單、可預測且可回復的每日啟停流程。

## 2. 本次架構決策

現階段採用「檔案式 endpoint 發布 + 集中產生設定 + 每日重啟 LiteLLM 一次」，暫不採用 LiteLLM PostgreSQL 動態模型管理。

主要理由：

1. 每天本來就有明確的服務啟動與停止窗口，07:00～08:00 期間重啟 LiteLLM 不影響正式服務。
2. 目前僅有 3～5 個模型，導入 PostgreSQL 的安裝、備份、遷移、權限及故障處理成本高於動態更新帶來的效益。
3. HPC 使用者沒有 root 權限，而且不宜自行在登入節點長期維護資料庫服務；是否允許也必須遵循 HPC 管理政策。
4. 統一等候模型完成後再重啟 LiteLLM，可避免多個 Slurm Job 同時修改設定或重複重啟服務。

未來若出現全天候服務、白天頻繁增刪模型、LiteLLM 多副本或高可用需求，再重新評估 PostgreSQL-backed model management。

## 3. 預定每日流程

```text
07:00  提交各模型的 Slurm Job
          │
          ├─ 單節點模型啟動
          └─ 多節點模型由同一個 Job 配置所有節點與 GPU
          │
          ▼
       各 Job 完成初始化與 readiness 測試
          │
          ▼
       各 Job 原子發布 endpoint 狀態檔
          │
          ▼
       單一控制器彙整所有模型狀態
          │
          ▼
07:50  產生 LiteLLM runtime config，重啟 LiteLLM 一次
          │
          ▼
       執行 Gateway 與各模型 smoke test
          │
          ▼
08:00  通過驗收後開放服務
          │
          ▼
20:00  停止接受新請求，保留短暫排空時間
          │
          ▼
       終止或由時限結束 Slurm Jobs，釋放 GPU
```

> [!IMPORTANT]
> `scancel` 或 Slurm Job 到期代表釋放配置的運算資源，不保證計算節點實體關機。節點電源管理由 HPC 管理端政策決定。

## 4. 元件責任

### 4.1 Slurm 模型 Job

每個模型 Job 僅負責自己的模型生命週期：

- 申請所需節點與 GPU。
- 啟動 SGLang 或其他推論後端。
- 完成 readiness 與最小推論測試。
- 成功後發布自己的 endpoint 狀態檔。
- 結束時清除或標記 endpoint 已失效。

Job 不應直接修改共用的 LiteLLM `config.yaml`，也不應自行重啟 LiteLLM。

多節點模型應由單一 Slurm Job 一次申請完整資源。只有提供 HTTP API 的 leader endpoint 需要發布給 LiteLLM；worker 位址屬模型內部拓撲。

### 4.2 Endpoint registry

建議每個模型使用獨立狀態檔：

```text
runtime/endpoints/qwen.env
runtime/endpoints/kimi.env
runtime/endpoints/<model-name>.env
```

狀態檔至少應包含：

```text
MODEL_NAME=<logical-model-name>
API_BASE=http://<leader-host>:<port>/v1
SLURM_JOB_ID=<job-id>
STATE=ready
UPDATED_AT=<timestamp>
```

安全與一致性要求：

- endpoint 狀態檔不可包含明文 API key。
- 先寫入同目錄暫存檔，驗證後以原子 `mv` 取代正式檔案。
- 檔案與目錄分別維持 `600` 與 `700` 權限。
- 控制器採用 Job ID 防護，避免舊 Job 在結束時刪除新 Job 發布的 endpoint。
- 控制器使用前須再次確認 Job 仍在執行，不能只相信狀態檔內容。

### 4.3 Morning controller

由登入節點上的單一控制器負責：

1. 防止相同模型重複提交 Job。
2. 提交當日需要的模型 Job。
3. 等候各模型發布 endpoint，並持續檢查 Slurm 狀態。
4. 對每個 endpoint 執行 readiness 與最小推論測試。
5. 依通過驗證的 endpoint 產生完整 runtime config。
6. 驗證 YAML 語法及必要欄位。
7. 只重啟 LiteLLM 一次。
8. 執行 LiteLLM `/health`、`/v1/models` 與逐模型 smoke test。
9. 僅在驗證通過後將當日服務標記為 ready；失敗則保留日誌並發出告警。

同一時間只能有一個 morning controller 執行，應使用 lock file 或 `flock` 防止重複排程。

## 5. LiteLLM 設定策略

- 人工維護的 `config.yaml` 作為設定範本或靜態設定來源。
- 自動化流程輸出獨立的 runtime config，避免直接覆寫人工維護版本。
- runtime config 只納入已通過 readiness 驗證的模型 endpoint。
- 所有 endpoint 都準備完成後才重啟 LiteLLM，避免每個 Job 各自完成時觸發多次重啟。
- LiteLLM 重啟失敗時，應保留前一版有效設定，以便快速回復。

若虛擬使用者金鑰或其他狀態目前由本機檔案保存，重啟前須確認相關資料具有持久性，不可因 Proxy 重啟而遺失。

## 6. 時間與失敗處理政策

不採用「07:50 無條件認定全部模型成功」；Slurm 可能因資源忙碌而延遲排程。

建議將模型分級：

- **必要模型**：缺少時不得宣告完整服務 ready。
- **可選模型**：未及時啟動時可先從 runtime config 排除，其餘模型照常服務。

07:50～08:00 的決策可依實際營運需求設定為下列其中一種：

1. **部分服務模式**：必要模型成功即可啟動 LiteLLM；尚未就緒的模型不列入當日設定。
2. **完整服務模式**：任一必要模型失敗即不開放服務，並通知管理者。

不得把尚未通過驗證的 endpoint 寫入正式 runtime config。白天若模型 Job 異常終止，健康檢查應將其標記為不可用並通知管理者；第一階段不要求自動重啟 LiteLLM 或自動重新派送大型 Job。

## 7. 20:00 停止流程

停止流程應依序執行：

1. Gateway 停止接受新的推論請求，或進入維護狀態。
2. 等待既有請求在設定的 grace period 內完成。
3. 停止 LiteLLM，或保留管理端但移除本機模型路由；實際策略於實作時確定。
4. 確認並終止當日模型 Slurm Jobs。
5. 將 endpoint 狀態標記為 stopped 或移出有效 registry。
6. 保存必要日誌與當日啟停結果。

Slurm Job 本身仍應設定合理的 `--time`，作為即使停止腳本失敗也能自動釋放 GPU 的最後一道保護。

## 8. 驗收條件

第一階段完成必須符合：

- 重複執行啟動流程不會提交重複 Job。
- 單節點及多節點模型都只發布可使用的 leader endpoint。
- endpoint 更新具備原子性，且不包含金鑰。
- 模型未 ready 時不會被加入 runtime config。
- LiteLLM 每日正常流程只需重啟一次。
- LiteLLM 重啟後健康檢查、模型清單與實際推論全部通過。
- 個別使用者 API key 的模型限制仍然有效。
- 20:00 後所有預定 GPU Job 均已釋放。
- 任一步驟失敗時有明確日誌、非零結束碼及可識別的失敗模型。
- 服務重啟不會在日誌或產生的設定中洩漏任何 API key。

## 9. 分階段實作建議

### Phase 1A：核心端點發布、Port 原子鎖與動態合成 (已完成並通過實體驗收)

- [x] **建立 Endpoint Registry 規格**：各實例獨立 `.env`，支援 `STATE=starting` 與 `STATE=ready` 二階段原子發布，目錄 `700`、檔案 `600`。
- [x] **POSIX 原生原子目錄鎖 (`runtime/port-locks/`)**：同機實例自動避讓 (30000->30001)，主 Shell 變數保留，清理時驗證 `job_id` 擁有者防誤刪；超過 10 分鐘無主孤兒鎖在嚴格確認本機 Socket free 或遠端連線 `ECONNREFUSED` 後自動回收，遇逾時/不可達/DNS 異常嚴格保留 (Fail-Closed)。
- [x] **Controller 設定合成器 (`scripts/generate_runtime_config.py`)**：
  - 嚴格 Fail-Closed：未就緒實例一律排除；Slurm 狀態三態判定 (`RUNNING` / `INACTIVE` / `UNKNOWN`)，遇逾時或連線異常（`UNKNOWN`）嚴格保留鎖與端點並終止生成；`SUSPENDED` 則保留 registry 與 lock，但不納入本次 runtime config，不影響其他健康端點合成。
  - 主動雙重探測：登入節點與計算節點自檢均嚴格驗證 HTTP 200 且為包含 `data`/`object` 之合法 OpenAI JSON。
  - 多實例負載平衡：同名模型自動多重註冊至 LiteLLM Router (`simple-shuffle`)。在雙 Job 情況下，LiteLLM 呈現 7 個 Deployment entries（3 Portal + 2 Qwen 主名稱 + 2 Qwen 別名，對應 5 個實體 Unique Upstreams）。
- [x] **生命週期行程納管**：追蹤背景健康自檢程序 `HEALTH_PID`，退出 trap 明確執行 `kill` 與 `wait`。
- [x] **徹底退役 Legacy 依賴**：完全移除 `endpoint.info`，更新 `check_service.sh` 掃描多實例端點。
- [x] **Slurm 計算節點實機驗收**：於計算節點 `node-L` 同時派送 2 個 SGLang Qwen Job (418624 與 418623) 驗證避讓與推論；於 `node-N` 派送新版共用函式庫 Job 419043 實機驗證 Spool 環境函式庫載入、Port 搶佔、二階段狀態過濾與單次退場清理。
- [x] **Python 單元測試與 Shell 邏輯回歸測試納入 Git 追蹤**：建立 [tests/test_lifecycle_logic.py](../tests/test_lifecycle_logic.py)（涵蓋 Slurm 三態判定、通訊異常過濾、孤兒鎖逾時 + Socket 佔用判定［本機佔用保留、遠端監聽保留、ECONNREFUSED 安全回收、ETIMEDOUT / EHOSTUNREACH / DNS 異常之 Fail-Closed 保留］與登入節點 HTTP 驗證）與 [tests/test_bash_locks.sh](../tests/test_bash_locks.sh)（直接載入正式共用函式庫 [sglang-qwen/lib/lifecycle.sh](../sglang-qwen/lib/lifecycle.sh)，涵蓋主 Shell 鎖變數保留、同機連接埠避讓、鎖擁有者核對、Cleanup 冪等防重入、計算節點 HTTP+JSON 校驗與 Slurm Spool 環境路徑動態模擬），並配合實機雙 Job (418624/418623/419043) 完整驗收。

### Phase 1B：Morning Controller 啟動排程與全自動生命週期 (規劃中)

- 防止相同模型重複提交 Job 機制。
- 定時提交當日各模型 Slurm Jobs。
- 等候必要模型發布端點，並以 `flock` 保護單一 Controller 併發。
- 自動重啟 LiteLLM 並執行開市前 smoke test 驗收。
- 20:00 停止流程、排空請求機制與 GPU 配額釋放。

### Phase 2：多模型與多節點

- 加入其他 2～4 個模型。
- 驗證 2 節點／16 GPU 模型的 leader/worker 啟動與失敗處理。
- 加入必要／可選模型政策與啟動逾時。

### Phase 3：營運強化

- 串接排程器（例如使用者層級 cron；是否可用須依 HPC 政策確認）。
- 加入告警、每日狀態摘要、日誌輪替與容量觀測。
- 依實際需求評估白天故障自動復原，以及是否需要 DB-backed 動態模型管理。

## 10. 非本階段範圍

- 在 HPC 登入節點自行維護 PostgreSQL。
- Kubernetes 或額外 VM 叢集。
- LiteLLM 多副本高可用。
- 白天任意增刪模型且完全不中斷。
- 控制計算節點實體電源開關。


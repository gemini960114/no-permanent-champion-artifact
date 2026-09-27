# Skill：高併發失敗診斷 (Concurrency Troubleshooting)

> **SKILL.md**＝AI 載入的技能指令（症狀→病因→處方對照＋分層診斷流程）；
> 本 README＝人類說明（三個實戰案例＋設定檔位置總覽）。
> 建立：2026-09-26，源自三引擎 1500 人混合壓測的完整診斷實錄。

## 使用時機（自然語言範例）

```
壓測 1500 人失敗一堆，幫我查是哪裡的問題
```
```
使用者反應連不上 / 回應到一半斷掉，怎麼診斷？
```
```
Errno 24 Too many open files 是什麼？怎麼修？
```

## 三個實戰案例（2026-09-26，1500 人混合壓測）

### 案例 ①：67.9% → 91.8%（VM 客戶端 fd）
- **症狀**：失敗是「秒殺」非逾時；錯誤 `Errno 24 Too many open files`；成功數卡在 ~1020
- **定罪**：1020 ≈ 1024（預設 fd 上限）扣掉行程開銷——數字本身就是鐵證
- **修復**：VM `~/.bashrc` **第 1 行**加 `ulimit -n 65535`
  （⚠️ 坑：Ubuntu `.bashrc` 有非互動守衛，加底部則 `ssh vm '指令'` 讀不到——務必放最頂端）
- **驗證**：`ssh litellm-vm 'ulimit -n'` → 65535

### 案例 ②：91.8% → 100%（真兇是 sshd fd，初判隧道是誤判）
- **症狀**：客戶端 fd 修好後仍 8.2% 失敗，錯誤變 `ReadError`（連上後中斷）
- **初判（後證實為誤）**：旁路直連 100% → 「隧道單流天花板 ~1000 併發」
- **真相**：隧道 sshd 的 fd soft limit 也是 1024（`/proc/<sshd>/limits` 實查）。
  修法＝`/etc/security/limits.conf` 加 `* soft/hard nofile 65535`（⚠️ 只改
  systemd override 無效——per-connection sshd 不吃）＋**彈隧道**＋重測
- **結局**：1500 人經隧道 **100%**（8,146 tok/s、P95 76.8s、零失敗）
- **教訓**：旁路測試只能證明「問題在 VM↔Gateway 之間」，不能細分 sshd fd vs
  隧道流控——**修一層、驗一層**；session fd 要量 sshd 本體（/proc），用 bash
  測會被 .bashrc 的 ulimit 污染

### 案例 ③：95.7% → 100%（引擎併發 cap）
- **症狀**：`ReadTimeout` 逾時、失敗集中在隊尾、引擎 log 顯示排隊 440
- **病因**：`MAX_RUNNING_REQUESTS=64`（投機解碼下併發上限）
- **修復**：64 → 128（同 flash 48→100 的 playbook）：成功率 100%、吞吐 +31%、峰值 6,980 tok/s
- **教訓**：GPU 記憶體遠大於權重時，cap 是最後才該懷疑也最常被忽略的瓶頸

## 設定檔位置總覽

| 要改什麼 | 檔案 | 注意 |
| :--- | :--- | :--- |
| VM 客戶端 shell fd | `~/.bashrc`（VM）**第 1 行** | 非互動守衛的坑；驗證用 `ssh vm 'ulimit -n'` |
| VM sshd fd | `/etc/systemd/system/ssh.service.d/override.conf`（VM，需 root） | `LimitNOFILE=65535`；restart 安全（KillMode=process）；**修後彈隧道** |
| 引擎併發 cap | `engines/<引擎>/config.env` 的 `MAX_RUNNING_REQUESTS` | 改後重啟引擎，log 驗證 `'max_running_requests'` 生效 |
| 多隧道（未來） | `~/start-litellm-tunnel.sh` 改迴圈＋VM HAProxy | 觸發條件：常態 >800-1000 併發 |

## 相關文件

- 隧道設定細節（含行內註解）：docs/EXTERNAL_VM_TUNNEL.md（私有部署文件，未收錄於公開版） 3.5 節
- 壓測方法與歷史數據：[`benchmarks/README.md`](../../../benchmarks/README.md)
- 已驗證引擎配方：[`engines/KNOWN_GOOD.md`](../../../engines/KNOWN_GOOD.md)

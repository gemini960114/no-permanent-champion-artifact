---
name: concurrency-troubleshooting
license: MIT
description: >-
  高併發失敗診斷與容量調校：當壓力測試或對外服務出現大量失敗時使用——
  症狀如 Errno 24 Too many open files、ReadError 連線中斷、ReadTimeout
  逾時、成功率卡在特定數字（如 ~1020）、或使用者反應「連不上／回應斷掉」。
  涵蓋分層定位（VM 客戶端→隧道→Gateway→引擎）、fd 上限檢查與修復、
  MAX_RUNNING_REQUESTS 併發調優。
---

# 高併發失敗診斷 (Concurrency Troubleshooting)

## 鐵律：先分層定位，再動手修

```
外部使用者 → VM sshd(:4000, fd 上限①) → SSH 隧道(單流天花板) → Gateway(login-2, fd 65535) → 引擎(併發 cap)
```
**逐層量測、用證據定罪**——不要看到失敗就調引擎。三個真實案例見 README.md。

## 症狀 → 病因 → 處方 對照表

| 症狀特徵 | 病因 | 處方 | 設定位置 |
| :--- | :--- | :--- | :--- |
| **秒殺失敗**＋`Errno 24 Too many open files`＋成功數卡在 ~1020 | 客戶端 shell fd 上限 1024 | `ulimit -n 65535`（永久版寫 bashrc 頂端） | VM `~/.bashrc` 第 1 行 |
| 秒殺失敗＋`ConnectError`＋外部連線 >1000 | **sshd** fd 上限 1024 | systemd override `LimitNOFILE=65535`＋彈隧道 | VM `/etc/systemd/system/ssh.service.d/override.conf` |
| 連上後中斷＋`ReadError`＋高併發長串流 | **優先查隧道 sshd 的 fd**（`/proc/<pid>/limits`；2026-09-26 實錄：修 fd 後 1500 併發 100%） | 修 `/etc/security/limits.conf`（`* soft/hard nofile 65535`）＋彈隧道 | 見 `docs/EXTERNAL_VM_TUNNEL.md` 3.5 |
| ReadError 且 sshd fd 已是 65535 | 隧道單流天花板（>1500 併發，尚未實測到） | 多隧道＋HAProxy（屆時才做） | 同上 |
| **逾時失敗**（`ReadTimeout`）＋失敗集中在隊尾＋引擎 log 顯示大排隊 | 引擎併發 cap 太低 | `MAX_RUNNING_REQUESTS` 調高（48→100→128 實證 playbook）＋重啟引擎 | 各引擎 `config.env` |
| 全面失敗（0%）＋耗時極短 | 服務沒起來／路由沒掛（例如 stop→start 競態跳過派送） | 查 `squeue`、endpoint 檔、Gateway 模型清單 | — |

## 標準診斷流程（依序執行）

```bash
# ① 客戶端 fd（用 ssh 非互動路徑測才準）
ssh litellm-vm 'ulimit -n'                      # <1000 → 病因①
# ⚠️ 量「服務進程」的 fd 要看 /proc/<pid>/limits——shell 測值會被 .bashrc 的
#    ulimit 行污染（外層 bash 先抬過，--norc 也躲不掉）

# ② 隧道 sshd fd（外部連線第一線）
ssh litellm-vm 'PID=$(sudo ss -ltnp | grep ":4000 " | grep -oE "pid=[0-9]+" | head -1 | cut -d= -f2); sudo cat /proc/$PID/limits | grep "open files"'

# ③ 旁路測試定罪隧道：同規模直連 Gateway（在 login-2）
#    旁路 100% ＋ 隧道失敗 → 隧道；兩邊都失敗 → Gateway/引擎
ulimit -n 65535
BENCH_MODELS="<模型>" LITELLM_BASE_URL="http://<GW_IP>:54921" LITELLM_API_KEY=<KEY> \
  .venv/bin/python benchmarks/stress_test.py -c <人數> -n <人數> --max-tokens <tokens> --timeout 600

# ④ 引擎端併發與排隊（引擎 log）
grep -o "#running-req: [0-9]*" engines/<引擎>/logs/*<jobid>*.err | awk '{print $2}' | sort -n | tail -1
grep -o "#queue-req: [0-9]*"   engines/<引擎>/logs/*<jobid>*.err | awk '{print $2}' | sort -n | tail -1

# ⑤ 資源排除法：Gateway/隧道/VM sshd 的 CPU（都不高的話＝設定限制非資源限制）
```

## 修復後必驗證

- fd 修復：重跑同規模壓測，成功率應恢复（參考實績：67.9% → 91.8% → 100%）
- sshd 修復後**必須彈隧道**（舊 sshd 子進程帶舊上限）：`~/stop-litellm-tunnel.sh && ~/start-litellm-tunnel.sh`
- 引擎 cap 調整後：重啟引擎→確認 log 的 `'max_running_requests'` 生效→重測

#!/usr/bin/env python3
"""
scripts/generate_runtime_config.py
==============================================================================
LiteLLM Runtime 設定動態產生器 (Morning Controller Core) - 工業級加固版
功能：
1. 讀取範本 config.yaml (保留 Portal 外部模型、認證與 Router 策略)
2. 掃描 runtime/endpoints/*.env 解析推論實例狀態
3. 嚴格審查：
   - 狀態必須為 STATE=ready (未就緒一律排除)
   - 透過 squeue 驗證狀態必須為 RUNNING (排除 PENDING / COMPLETING / 已終止)
     (manual 端點不做 squeue 判定，僅依 STATE=ready + HTTP 探測)
   - 登入節點主動向 API_BASE/models 進行 HTTP 200 探測 (防假性宣告)
   - 探測金鑰依 API_KEY_ENV + ENGINE_DIR 從「環境變數 → 所屬引擎 config.env」
     嚴格查找，絕不退回其他引擎之金鑰
4. 自動對帳 (Reconciliation)：
   - 主動清理已終止 Job 之過期端點檔與 runtime/port-locks/ 佔用鎖
5. 支援多實例負載平衡：同名模型多端點自動多重註冊至 LiteLLM Router
6. 徹底移除危險的 legacy fallback，落實 Fail-Closed 安全原則
7. 以 600 權限原子寫入 config.runtime.yaml
回傳碼：
   0 = 全部成功
   2 = 部分成功 (存在 Slurm 狀態 UNKNOWN 之端點，已略過但仍寫出可用設定)
   1 = 失敗 (範本遺失等，未寫出設定)
==============================================================================
"""

import os
import sys
import glob
import json
import time
import shutil
import subprocess
import urllib.request
import urllib.error
import yaml

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
TEMPLATE_CONFIG_PATH = os.path.join(PROJECT_ROOT, "config.yaml")
RUNTIME_CONFIG_PATH = os.path.join(PROJECT_ROOT, "config.runtime.yaml")
ENDPOINTS_DIR = os.path.join(PROJECT_ROOT, "runtime", "endpoints")
PORT_LOCKS_DIR = os.path.join(PROJECT_ROOT, "runtime", "port-locks")

def get_engine_dirs() -> list:
    """掃描專案下所有引擎目錄 (sglang-* / vllm-*)，以 realpath 對 symlink 去重"""
    dirs = []
    seen = set()
    for pattern in ("sglang-*", "vllm-*"):
        for d in sorted(glob.glob(os.path.join(PROJECT_ROOT, pattern))):
            if not os.path.isdir(d):
                continue
            real = os.path.realpath(d)
            if real in seen:
                continue
            seen.add(real)
            dirs.append(d)
    return dirs

def read_config_env_var(config_path: str, var_name: str) -> str:
    """自指定 config.env 讀取單一變數值 (無此檔或無此變數回傳空字串，絕不外印)"""
    if not var_name or not os.path.isfile(config_path):
        return ""
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith(f"{var_name}="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
    except OSError:
        pass
    return ""

def get_engine_api_key(key_name: str, engine_dir: str = "") -> str:
    """
    取得推論引擎鑑權金鑰 (嚴格依歸屬查找，絕不退回其他引擎之金鑰)：
    1. 環境變數優先 (含 .env 載入值)
    2. 指定 engine_dir 時：僅讀取該引擎目錄之 config.env
    3. 未指定 engine_dir (legacy 端點檔無 ENGINE_DIR)：掃描各引擎目錄 (symlink 去重)
    找不到回傳空字串 (Fail-Closed，探測將失敗並略過該端點)
    """
    if not key_name:
        return ""
    key = os.environ.get(key_name, "")
    if key:
        return key
    if engine_dir:
        return read_config_env_var(os.path.join(engine_dir, "config.env"), key_name)
    for d in get_engine_dirs():
        key = read_config_env_var(os.path.join(d, "config.env"), key_name)
        if key:
            return key
    return ""

def get_job_status(job_id: str) -> str:
    """
    透過 squeue 檢查 Slurm Job 狀態，嚴格回傳三態：
    - 'RUNNING'  : 作業正常運行中 (manual 端點不做 squeue 判定，直接視為運行中，
                   僅依 STATE=ready + HTTP 探測決定納入與否)
    - 'INACTIVE' : 作業已明確終止 (squeue 終止狀態碼，或明確回報 Invalid job id specified)；
                   legacy 端點檔之 'N/A' 亦沿用此行為 (允許清理)
    - 'UNKNOWN'  : squeue 逾時、連線異常或無法與 controller 通訊 (Fail-Closed 保留)
    """
    if not job_id or str(job_id) in ("N/A", "dummy"):
        return "INACTIVE"
    if str(job_id) == "manual":
        return "RUNNING"
    try:
        res = subprocess.run(
            ["squeue", "-j", str(job_id), "-h", "-o", "%T"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5
        )
        if res.returncode == 0:
            state = res.stdout.strip().upper()
            if state == "RUNNING":
                return "RUNNING"
            elif state in ("COMPLETED", "FAILED", "CANCELLED", "TIMEOUT", "PREEMPTED", "NODE_FAIL", "DEAD"):
                return "INACTIVE"
            elif state in ("PENDING", "CONFIGURING", "COMPLETING", "SUSPENDED"):
                return state
            else:
                return "UNKNOWN"
        else:
            combined_err = (res.stderr + " " + res.stdout).lower()
            if "invalid job id specified" in combined_err:
                return "INACTIVE"
            return "UNKNOWN"
    except subprocess.TimeoutExpired:
        return "UNKNOWN"
    except Exception:
        return "UNKNOWN"

def is_endpoint_alive(api_base: str, api_key: str, timeout: float = 2.5) -> bool:
    """
    從登入節點主動向 SGLang /v1/models 發送 HTTP GET 請求。
    必須回傳 HTTP 200 且回應為合法 JSON (含有 data 或 object 欄位) 才認定存活。
    """
    if not api_base:
        return False
    try:
        url = f"{api_base.rstrip('/')}/models"
        req = urllib.request.Request(url)
        if api_key:
            req.add_header("Authorization", f"Bearer {api_key}")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status != 200:
                return False
            payload = json.loads(resp.read().decode("utf-8"))
            return isinstance(payload, dict) and ("data" in payload or "object" in payload)
    except Exception:
        return False

def parse_env_file(filepath: str) -> dict:
    """解析 KEY=VALUE 格式環境變數檔"""
    data = {}
    with open(filepath, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                k, v = line.split("=", 1)
                data[k.strip()] = v.strip().strip('"').strip("'")
    return data

def reconcile_port_locks() -> bool:
    """
    清理已結束 Job 遺留之 port lock 目錄。
    - INACTIVE: 安全清除鎖目錄
    - RUNNING / PENDING / COMPLETING / SUSPENDED: 正常保留
    - UNKNOWN: 異常/逾時，嚴格保留以防衝突，並回報 False
    - 無 job_id 之孤兒鎖：若目錄 mtime 超過 600 秒 (10 分鐘) 則安全回收
    """
    if not os.path.isdir(PORT_LOCKS_DIR):
        return True
    clean_ok = True
    now = time.time()
    for lock_path in glob.glob(os.path.join(PORT_LOCKS_DIR, "*")):
        if not os.path.isdir(lock_path):
            continue
        job_id_file = os.path.join(lock_path, "job_id")
        if os.path.isfile(job_id_file):
            try:
                with open(job_id_file, "r", encoding="utf-8") as f:
                    job_id = f.read().strip()
                if not job_id:
                    continue
                status = get_job_status(job_id)
                if status == "INACTIVE":
                    print(f"🧹 清理失效 Port 鎖：Job {job_id} 已確認終止 ({os.path.basename(lock_path)})")
                    shutil.rmtree(lock_path, ignore_errors=True)
                elif status == "UNKNOWN":
                    print(f"⚠️  Slurm 狀態查詢異常 (Job {job_id} 狀態未知)，嚴格保留 Port 鎖以防衝突 ({os.path.basename(lock_path)})")
                    clean_ok = False
                # 若為 RUNNING / PENDING / COMPLETING / SUSPENDED 則保留
            except Exception as e:
                print(f"⚠️  檢查 Port 鎖發生例外 ({lock_path}): {e}")
                clean_ok = False
        else:
            # 處理缺少 job_id 的孤兒鎖目錄
            try:
                mtime = os.path.getmtime(lock_path)
                if now - mtime > 600:
                    dir_name = os.path.basename(lock_path)
                    can_remove = False
                    if "-" in dir_name:
                        node_part, port_str = dir_name.rsplit("-", 1)
                        if port_str.isdigit():
                            import socket
                            import errno
                            local_hostname = socket.gethostname()
                            if node_part in (local_hostname, "localhost", "127.0.0.1"):
                                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                                try:
                                    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                                    s.bind(("0.0.0.0", int(port_str)))
                                    can_remove = True
                                except OSError as e:
                                    can_remove = False
                                    clean_ok = False
                                    print(f"⚠️  無主孤兒 Port 鎖 {dir_name} 本地連接埠仍被佔用 ({e})，暫予保留防衝突")
                                finally:
                                    s.close()
                            else:
                                try:
                                    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                                    try:
                                        sock.settimeout(1.0)
                                        result = sock.connect_ex((node_part, int(port_str)))
                                        if result == 0:
                                            # 明確正在監聽
                                            can_remove = False
                                            clean_ok = False
                                            print(f"⚠️  無主孤兒 Port 鎖 {dir_name} 遠端連接埠仍處於監聽狀態，暫予保留防衝突")
                                        elif result == errno.ECONNREFUSED:
                                            # 主機可達、port 明確未監聽
                                            can_remove = True
                                        else:
                                            # timeout、host unreachable、network unreachable 等狀態未知
                                            can_remove = False
                                            clean_ok = False
                                            err_name = errno.errorcode.get(result, f"ERR_{result}")
                                            print(f"⚠️  無主孤兒 Port 鎖 {dir_name} 遠端探測異常 ({err_name})，狀態未知，嚴格保留防衝突")
                                    finally:
                                        sock.close()
                                except (socket.gaierror, OSError) as exc:
                                    can_remove = False
                                    clean_ok = False
                                    print(f"⚠️  無主孤兒 Port 鎖 {dir_name} 網路/DNS 連線例外 ({exc})，狀態未知，嚴格保留防衝突")
                        else:
                            can_remove = False
                            clean_ok = False
                            print(f"⚠️  無主孤兒 Port 鎖 {dir_name} 格式不合規 (非 node-port)，嚴格保留防衝突")
                    else:
                        can_remove = False
                        clean_ok = False
                        print(f"⚠️  無主孤兒 Port 鎖 {dir_name} 格式不合規 (缺分隔符號)，嚴格保留防衝突")

                    if can_remove:
                        print(f"🧹 清理遺留之無主孤兒 Port 鎖 (逾時 10 分鐘且確認無佔用)：{dir_name}")
                        shutil.rmtree(lock_path, ignore_errors=True)
                else:
                    print(f"⏳ 鎖目錄 {os.path.basename(lock_path)} 尚無 job_id 且未達 10 分鐘寬限期，暫予保留")
            except Exception as e:
                print(f"⚠️  檢查無主 Port 鎖發生例外 ({lock_path}): {e}")
                clean_ok = False
    return clean_ok

def main():
    if not os.path.isfile(TEMPLATE_CONFIG_PATH):
        print(f"❌ 錯誤：找不到基礎範本設定檔 {TEMPLATE_CONFIG_PATH}", file=sys.stderr)
        sys.exit(1)

    with open(TEMPLATE_CONFIG_PATH, "r", encoding="utf-8") as f:
        config = yaml.safe_load(f) or {}

    # 保留靜態模型 (如 NCHC GenAI Portal 外部模型，排除本機環境變數佔位符)
    # 內部模型一律由動態端點註冊取代，僅依 api_base 是否為 os.environ 佔位符判定，
    # 不做模型名稱比對 (避免日後 Portal 新增 Qwen/DeepSeek 同名模型遭誤刪)
    original_models = config.get("model_list", [])
    static_models = []
    for m in original_models:
        params = m.get("litellm_params", {})
        api_base = str(params.get("api_base", ""))
        # 若 api_base 為 os.environ 佔位符，交由動態端點註冊
        if api_base.startswith("os.environ/") and "PORTAL" not in api_base.upper():
            continue
        static_models.append(m)

    discovered_endpoints = []
    has_unknown = False

    # 1. 執行 Port Locks 對帳 (若遇到 UNKNOWN 狀態則保留並標記)
    if not reconcile_port_locks():
        has_unknown = True

    # 2. 掃描 runtime/endpoints/*.env (通用掃描任何引擎發布之端點)
    env_files = sorted(glob.glob(os.path.join(ENDPOINTS_DIR, "*.env")))
    for env_path in env_files:
        info = parse_env_file(env_path)
        job_id = info.get("SLURM_JOB_ID", "")
        state = info.get("STATE", "").lower()
        api_base = info.get("API_BASE", "")
        model_name = info.get("MODEL_NAME", "Qwen3.8-27B")
        model_alias = info.get("MODEL_ALIAS", "")
        model_path = info.get("RESOLVED_MODEL_PATH", "")
        api_key_env = info.get("API_KEY_ENV", "SGLANG_API_KEY")
        engine_dir = info.get("ENGINE_DIR", "")
        node = info.get("NODE_HOSTNAME", "unknown")
        port = info.get("PORT", "unknown")

        job_status = get_job_status(job_id)
        if job_status == "INACTIVE":
            print(f"🧹 清理失效端點檔：Job {job_id} 已確認終止 ({os.path.basename(env_path)})")
            try:
                os.remove(env_path)
            except OSError:
                pass
            continue
        elif job_status == "UNKNOWN":
            print(f"⚠️  Slurm 狀態查詢異常 (Job {job_id} 狀態未知)，略過此端點且不清理檔案 (Fail-Closed)")
            has_unknown = True
            continue
        elif job_status != "RUNNING":
            print(f"⏳ 略過非運行中端點：Job {job_id} on {node}:{port} (Slurm 狀態: {job_status})")
            continue

        # 檢查 2：狀態必須嚴格為 ready (若在 starting 則跳過，絕不寫入設定)
        if state != "ready":
            print(f"⏳ 略過未就緒端點：Job {job_id} on {node}:{port} (目前內部狀態: {state})")
            continue

        # 檢查 3：登入節點主動 HTTP 200 + 合法 JSON 探測 (防止假性 ready 或網路斷線)
        # 探測金鑰嚴格依 API_KEY_ENV + ENGINE_DIR 查找，絕不退回其他引擎之金鑰
        probe_key = get_engine_api_key(api_key_env, engine_dir)
        if not is_endpoint_alive(api_base, probe_key, timeout=2.5):
            print(f"⚠️  略過連線失敗端點：Job {job_id} on {node}:{port} (HTTP 200/JSON 檢測未通過)")
            continue

        discovered_endpoints.append({
            "model_name": model_name,
            "model_alias": model_alias,
            "api_base": api_base,
            "model_path": model_path,
            "api_key_env": api_key_env,
            "job_id": job_id,
            "node": node,
            "port": port,
            "state": state
        })

    # 3. 建構動態模型清單 (嚴格 Fail-Closed，僅採用通過檢查之活躍端點；
    #    存在 UNKNOWN 端點時仍寫出「靜態模型 + 已通過探測端點」之部分成功設定)
    dynamic_deployments = []
    alias_deployments = []
    for ep in discovered_endpoints:
        names_to_register = []
        if ep.get("model_name"):
            names_to_register.append(ep["model_name"])
        if ep.get("model_alias") and ep["model_alias"] not in names_to_register:
            names_to_register.append(ep["model_alias"])

        # 智慧別名映射庫 (自動補齊常用代號與簡稱)
        # A. Qwen 27B 系列
        if any("27b" in n.lower() for n in names_to_register) and any("qwen" in n.lower() for n in names_to_register):
            for std_name in ("Qwen3.8-27B", "qwen3.8", "qwen-27b", "sglang-qwen-27b", "Qwen/Qwen3.8-27B-FP8", "Qwen/Qwen3.8-27B"):
                if std_name not in names_to_register:
                    names_to_register.append(std_name)
        # B. Qwen Flash 系列
        elif any("flash" in n.lower() for n in names_to_register) and any("qwen" in n.lower() for n in names_to_register):
            for std_name in ("Qwen3.8-Flash", "qwen3.8-flash", "qwen-flash", "sglang-qwen-flash", "Qwen/Qwen3.8-Flash-Next-FP8", "Qwen/Qwen3.8-Flash-Next"):
                if std_name not in names_to_register:
                    names_to_register.append(std_name)
        # C. DeepSeek Flash 系列
        elif any("deepseek" in n.lower() for n in names_to_register) and any("flash" in n.lower() for n in names_to_register):
            for std_name in ("DeepSeek-V4-Flash", "deepseek-v4-flash", "deepseek-flash", "vllm-deepseek-flash", "deepseek-ai/DeepSeek-V4.1-Flash", "DeepSeek-V4.1-Flash", "deepseek-ai/DeepSeek-V4-Flash"):
                if std_name not in names_to_register:
                    names_to_register.append(std_name)

        model_ref = f"openai/{ep['model_path']}" if ep.get("model_path") else f"openai/{ep['model_name']}"
        api_key_target = f"os.environ/{ep.get('api_key_env', 'SGLANG_API_KEY')}"

        for name in names_to_register:
            deployment = {
                "model_name": name,
                "litellm_params": {
                    "model": model_ref,
                    "api_base": ep["api_base"],
                    "api_key": api_key_target
                }
            }
            if name == ep.get("model_name"):
                dynamic_deployments.append(deployment)
            else:
                alias_deployments.append(deployment)

    config["model_list"] = static_models + dynamic_deployments + alias_deployments

    # 4. 原子寫入 config.runtime.yaml (權限 600)
    tmp_file = RUNTIME_CONFIG_PATH + f".tmp.{os.getpid()}"
    with open(tmp_file, "w", encoding="utf-8") as f:
        f.write("# ==============================================================================\n")
        f.write("# LiteLLM Proxy - 動態自動產生的 Runtime 設定檔 (請勿手動修改)\n")
        f.write(f"# 產生來源: {TEMPLATE_CONFIG_PATH}\n")
        f.write("# ==============================================================================\n\n")
        yaml.dump(config, f, allow_unicode=True, sort_keys=False)

    os.chmod(tmp_file, 0o600)
    os.replace(tmp_file, RUNTIME_CONFIG_PATH)

    print("==========================================================")
    print(" 🛠️  LiteLLM Runtime 設定檔生成完成")
    print("==========================================================")
    print(f"🔹 輸出路徑 : {RUNTIME_CONFIG_PATH} (權限: 600)")
    print(f"🔹 靜態模型 : {len(static_models)} 個 (Portal 外部模型)")
    print(f"🔹 活躍後端 : {len(discovered_endpoints)} 個推論實例")
    if discovered_endpoints:
        for i, ep in enumerate(discovered_endpoints, 1):
            print(f"   [{i}] {ep['model_name']} ➔ {ep['api_base']} (Node: {ep['node']}:{ep['port']}, Job: {ep['job_id']})")
    else:
        print("   (目前無活躍推論實例，僅開放 Portal 外部模型服務)")
    print("==========================================================")

    # 結尾回報碼：0 = 全部成功；2 = 部分成功 (存在 UNKNOWN 端點，已略過)
    if has_unknown:
        print("⚠️  警告：Slurm 狀態查詢異常 (存在 UNKNOWN 狀態之 Job)，該等端點已略過，以其餘可用端點部分生成！", file=sys.stderr)
        sys.exit(2)

if __name__ == "__main__":
    main()

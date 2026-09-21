#!/usr/bin/env python3
"""
scripts/generate_runtime_config.py
==============================================================================
LiteLLM Runtime 設定動態產生器 (Morning Controller Core)
功能：
1. 讀取範本 config.yaml (保留 Portal 模型、認證與 Router 策略)
2. 掃描 runtime/endpoints/*.env 解析所有就緒之 Slurm SGLang 實例
3. 自動消除無效/已終止之作業端點 (透過 squeue 查核)
4. 若有同模型多實例，自動多重註冊以啟動 LiteLLM Router 負載平衡
5. 支援向後相容 (若無 runtime/endpoints 則回退讀取 sglang-qwen/endpoint.info)
6. 產出安全鎖定 (chmod 600) 的 config.runtime.yaml
==============================================================================
"""

import os
import sys
import glob
import subprocess
import tempfile
import yaml

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
TEMPLATE_CONFIG_PATH = os.path.join(PROJECT_ROOT, "config.yaml")
RUNTIME_CONFIG_PATH = os.path.join(PROJECT_ROOT, "config.runtime.yaml")
ENDPOINTS_DIR = os.path.join(PROJECT_ROOT, "runtime", "endpoints")
LEGACY_ENDPOINT_INFO = os.path.join(PROJECT_ROOT, "sglang-qwen", "endpoint.info")

def is_job_active(job_id: str) -> bool:
    """透過 squeue 檢查 Slurm Job 是否仍在運行中"""
    if not job_id or job_id in ("N/A", "manual", "dummy"):
        return True
    try:
        res = subprocess.run(
            ["squeue", "-j", str(job_id), "-h"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5
        )
        return bool(res.stdout.strip())
    except Exception:
        # 若 squeue 查詢失敗，先保守視為存活
        return True

def parse_env_file(filepath: str) -> dict:
    """解析簡單的 KEY=VALUE 格式環境變數檔"""
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

def main():
    if not os.path.isfile(TEMPLATE_CONFIG_PATH):
        print(f"❌ 錯誤：找不到基礎範本設定檔 {TEMPLATE_CONFIG_PATH}", file=sys.stderr)
        sys.exit(1)

    with open(TEMPLATE_CONFIG_PATH, "r", encoding="utf-8") as f:
        config = yaml.safe_load(f) or {}

    # 保留非動態 SGLang 的靜態模型 (例如 NCHC GenAI Portal 外部模型)
    original_models = config.get("model_list", [])
    static_models = []
    for m in original_models:
        name = m.get("model_name", "")
        # SGLang Qwen 本地模型將由端點動態重新產生，以支援多節點與多實例
        if name in ("Qwen3.8-27B", "qwen3.8"):
            continue
        static_models.append(m)

    dynamic_deployments = []
    discovered_endpoints = []

    # 1. 掃描 runtime/endpoints/*.env
    env_files = sorted(glob.glob(os.path.join(ENDPOINTS_DIR, "*.env")))
    for env_path in env_files:
        info = parse_env_file(env_path)
        job_id = info.get("SLURM_JOB_ID", "")
        state = info.get("STATE", "ready")
        api_base = info.get("API_BASE", "")
        model_name = info.get("MODEL_NAME", "Qwen3.8-27B")
        model_alias = info.get("MODEL_ALIAS", "qwen3.8")
        model_path = info.get("RESOLVED_MODEL_PATH", "/path/to/work/models/Qwen3.8-27B")
        node = info.get("NODE_HOSTNAME", "unknown")
        port = info.get("PORT", "unknown")

        # 雙重驗證：確認 Slurm Job 確實在執行中
        if not is_job_active(job_id):
            print(f"⚠️  略過失效作業端點：Job {job_id} 已結束 ({os.path.basename(env_path)})")
            # 清理過期端點檔
            try:
                os.remove(env_path)
            except OSError:
                pass
            continue

        if not api_base:
            continue

        discovered_endpoints.append({
            "model_name": model_name,
            "model_alias": model_alias,
            "api_base": api_base,
            "model_path": model_path,
            "job_id": job_id,
            "node": node,
            "port": port,
            "state": state
        })

    # 2. 向後相容回退機制：若無任何 runtime/endpoints 檔案，但有 legacy endpoint.info
    if not discovered_endpoints and os.path.isfile(LEGACY_ENDPOINT_INFO):
        legacy = parse_env_file(LEGACY_ENDPOINT_INFO)
        endpoint = legacy.get("ENDPOINT", "")
        if endpoint:
            api_base = f"{endpoint}/v1"
            discovered_endpoints.append({
                "model_name": "Qwen3.8-27B",
                "model_alias": "qwen3.8",
                "api_base": api_base,
                "model_path": "/path/to/work/models/Qwen3.8-27B",
                "job_id": legacy.get("JOB_ID", "legacy"),
                "node": legacy.get("NODE", "legacy"),
                "port": legacy.get("PORT", "legacy"),
                "state": "ready"
            })

    # 3. 建構動態模型清單 (支援多實例負載平衡)
    alias_deployments = []
    for ep in discovered_endpoints:
        # 主要模型項目 (LiteLLM Router 會自動將同名模型分配給不同 api_base 做負載平衡)
        dynamic_deployments.append({
            "model_name": ep["model_name"],
            "litellm_params": {
                "model": f"openai/{ep['model_path']}",
                "api_base": ep["api_base"],
                "api_key": "os.environ/SGLANG_API_KEY"
            }
        })
        # 別名項目
        if ep["model_alias"]:
            alias_deployments.append({
                "model_name": ep["model_alias"],
                "litellm_params": {
                    "model": f"openai/{ep['model_path']}",
                    "api_base": ep["api_base"],
                    "api_key": "os.environ/SGLANG_API_KEY"
                }
            })

    config["model_list"] = static_models + dynamic_deployments + alias_deployments

    # 4. 原子寫入 config.runtime.yaml
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
    print(f"🔹 動態後端 : {len(discovered_endpoints)} 個實例")
    for i, ep in enumerate(discovered_endpoints, 1):
        print(f"   [{i}] {ep['model_name']} ➔ {ep['api_base']} (Node: {ep['node']}:{ep['port']}, Job: {ep['job_id']})")
    print("==========================================================")

if __name__ == "__main__":
    main()

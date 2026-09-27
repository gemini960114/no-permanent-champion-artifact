#!/usr/bin/env python3
"""
LiteLLM 多金鑰管理工具 (key_tool.py)
用法：
  python key_tool.py generate --name "Alice" --models all
  python key_tool.py generate --name "Bob" --models GLM-5.2 Kimi-K3
  python key_tool.py generate --name "Carol" --rpm 3000 --tpm 10000000
  python key_tool.py update   --key <API_KEY> --rpm 600 --tpm 2000000
  python key_tool.py list
  python key_tool.py list --show-full
  python key_tool.py revoke --key <API_KEY>

速率限制 (由 Gateway 記憶體計數器強制執行，超過回 HTTP 429)：
  --rpm  每分鐘請求數上限 (預設 3000)
  --tpm  每分鐘 token 數上限 (預設 10,000,000)
  傳 0 表示不限額。既有未設限之金鑰維持不限額 (向後相容)。
"""

import argparse
import datetime
import fcntl
import json
import os
import secrets
import sys
from contextlib import contextmanager
from pathlib import Path

KEYS_FILE = Path(__file__).parent / "api_keys.json"
LOCK_FILE = Path(str(KEYS_FILE) + ".lock")

def load_keys() -> dict:
    if not KEYS_FILE.exists():
        return {}
    try:
        with open(KEYS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        # 解析失敗一律中止並報錯，嚴禁當成空字典繼續寫入 (避免清空整個金鑰庫)
        print(f"❌ 錯誤：無法解析金鑰庫檔案 {KEYS_FILE}: {e}", file=sys.stderr)
        sys.exit(1)

@contextmanager
def keys_lock():
    """以金鑰庫旁的 .lock 檔上獨佔鎖 (flock)，避免並發 generate/revoke 讀改寫時弄丟金鑰"""
    fd = os.open(LOCK_FILE, os.O_RDWR | os.O_CREAT, 0o600)
    with os.fdopen(fd, "a+") as f:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(f.fileno(), fcntl.LOCK_UN)

def save_keys(keys: dict):
    # 原子寫入：以 0600 權限建立同目錄暫存檔 → fsync → os.replace，
    # 避免 custom_auth 並發讀取到寫入一半的 JSON 導致所有虛擬金鑰瞬間 401
    tmp_file = str(KEYS_FILE) + f".tmp.{os.getpid()}"
    fd = os.open(tmp_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(keys, f, indent=2, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_file, KEYS_FILE)
    finally:
        # 寫入或取代失敗時清理暫存檔 (成功時 os.replace 後暫存檔已不存在)
        if os.path.exists(tmp_file):
            try:
                os.remove(tmp_file)
            except OSError:
                pass
    # 設定權限僅擁有者可讀寫 (os.replace 會保留暫存檔之 600 權限，此為雙重保險)
    os.chmod(KEYS_FILE, 0o600)

def mask_key(k: str) -> str:
    if len(k) <= 12:
        return "****"
    return f"{k[:7]}...{k[-4:]}"

def norm_limit(v):
    """0 或負值 → None (不限額)；正整數照存。"""
    if v is None:
        return None
    return v if v > 0 else None

def fmt_limit(v) -> str:
    return "不限額" if v is None else f"{v:,}"

def cmd_generate(args):
    with keys_lock():
        keys = load_keys()
        new_key = "sk-" + secrets.token_urlsafe(32)

        models = args.models
        if "all" in models or "*" in models:
            models = ["all"]
            models_desc = "所有模型 (ALL)"
        else:
            models_desc = ", ".join(models)

        keys[new_key] = {
            "user_id": args.name,
            "models": models,
            "rpm_limit": norm_limit(args.rpm),
            "tpm_limit": norm_limit(args.tpm),
            "description": args.desc or f"Key for {args.name}",
            "created_at": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        }
        save_keys(keys)

    print("\n✅ 成功建立新 API Key！")
    print(f"  • 使用者名稱 : {args.name}")
    print(f"  • 授權模型   : {models_desc}")
    print(f"  • RPM 上限   : {fmt_limit(keys[new_key]['rpm_limit'])} (每分鐘請求數)")
    print(f"  • TPM 上限   : {fmt_limit(keys[new_key]['tpm_limit'])} (每分鐘 token 數)")
    print(f"  • API Key    : {new_key}")
    print("  • 存放位置   : api_keys.json (chmod 600)")
    print("  • 對外 URL   : https://service.example.org/v1\n")

def cmd_update(args):
    with keys_lock():
        keys = load_keys()
        if args.key not in keys:
            print(f"\n❌ 找不到指定的 API Key: {args.key}\n")
            sys.exit(1)
        info = keys[args.key]
        changed = []
        if args.rpm is not None:
            info["rpm_limit"] = norm_limit(args.rpm)
            changed.append(f"RPM={fmt_limit(info['rpm_limit'])}")
        if args.tpm is not None:
            info["tpm_limit"] = norm_limit(args.tpm)
            changed.append(f"TPM={fmt_limit(info['tpm_limit'])}")
        if args.models is not None:
            models = args.models
            if "all" in models or "*" in models:
                models = ["all"]
            info["models"] = models
            changed.append(f"模型={'所有 (ALL)' if models == ['all'] else ', '.join(models)}")
        if not changed:
            print("\nℹ️  未指定任何更新 (--rpm / --tpm / --models 至少給一個)\n")
            sys.exit(1)
        save_keys(keys)
    print(f"\n✅ 已更新 [{info.get('user_id')}] 的設定：{'、'.join(changed)}")
    print("  ℹ️  設定由 Gateway 讀取 api_keys.json 生效 (最遲下一個請求；如未生效請 ./start_background.sh)\n")

def cmd_list(args):
    keys = load_keys()
    print("\n📋 目前已註冊的 API Key 清單：")
    print("=" * 70)
    if not keys:
        print("  目前尚無註冊的虛擬金鑰（僅有 .env 中的 Master Key）。")
    for key, info in keys.items():
        models = info.get("models", [])
        models_str = "ALL" if models in (["all"], ["*"], []) else ", ".join(models)
        display_key = key if getattr(args, "show_full", False) else mask_key(key)
        print(f"  使用者   : {info.get('user_id')}")
        print(f"  API Key  : {display_key}")
        print(f"  授權模型 : {models_str}")
        print(f"  速率限制 : RPM {fmt_limit(info.get('rpm_limit'))} / TPM {fmt_limit(info.get('tpm_limit'))}")
        print(f"  建立時間 : {info.get('created_at')}")
        print("-" * 70)
    if not getattr(args, "show_full", False) and keys:
        print("💡 提示：金鑰已遮罩保護。若需查看完整內容請加上 --show-full 參數。")
    print()

def cmd_revoke(args):
    with keys_lock():
        keys = load_keys()
        target_key = args.key
        if target_key in keys:
            info = keys.pop(target_key)
            save_keys(keys)
            print(f"\n🗑️ 已成功廢除使用者 [{info.get('user_id')}] 的 API Key: {target_key}\n")
        else:
            print(f"\n❌ 找不到指定的 API Key: {target_key}\n")

def main():
    parser = argparse.ArgumentParser(description="LiteLLM 多金鑰生成與管理工具")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # generate
    gen_parser = subparsers.add_parser("generate", help="生成新 API Key")
    gen_parser.add_argument("--name", "-n", required=True, help="使用者名稱或專案標籤")
    gen_parser.add_argument("--models", "-m", nargs="+", default=["all"], help="授權模型清單 (預設 all)")
    gen_parser.add_argument("--rpm", type=int, default=3000, help="每分鐘請求數上限 (預設 3000；0=不限額)")
    gen_parser.add_argument("--tpm", type=int, default=10000000, help="每分鐘 token 數上限 (預設 10,000,000；0=不限額)")
    gen_parser.add_argument("--desc", "-d", default="", help="備註說明")
    gen_parser.set_defaults(func=cmd_generate)

    # update
    upd_parser = subparsers.add_parser("update", help="更新既有金鑰（限額／模型白名單）")
    upd_parser.add_argument("--key", "-k", required=True, help="目標 API Key")
    upd_parser.add_argument("--rpm", type=int, default=None, help="每分鐘請求數上限 (0=不限額)")
    upd_parser.add_argument("--tpm", type=int, default=None, help="每分鐘 token 數上限 (0=不限額)")
    upd_parser.add_argument("--models", "-m", nargs="+", default=None,
                            help="模型白名單 (空白分隔多個名稱；all=全部)。清單同時決定該金鑰 /v1/models 看到的模型")
    upd_parser.set_defaults(func=cmd_update)

    # list
    list_parser = subparsers.add_parser("list", help="列出所有已建立的 API Key")
    list_parser.add_argument("--show-full", action="store_true", help="顯示完整 API Key (未遮罩)")
    list_parser.set_defaults(func=cmd_list)


    # revoke
    revoke_parser = subparsers.add_parser("revoke", help="刪除/廢除指定的 API Key")
    revoke_parser.add_argument("--key", "-k", required=True, help="要廢除的 API Key")
    revoke_parser.set_defaults(func=cmd_revoke)

    args = parser.parse_args()
    args.func(args)

if __name__ == "__main__":
    main()

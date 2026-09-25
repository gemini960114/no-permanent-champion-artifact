#!/usr/bin/env python3
"""
LiteLLM 多金鑰管理工具 (key_tool.py)
用法：
  python key_tool.py generate --name "Alice" --models all
  python key_tool.py generate --name "Bob" --models GLM-5.2 Kimi-K3
  python key_tool.py list
  python key_tool.py revoke --key <API_KEY>
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
            "description": args.desc or f"Key for {args.name}",
            "created_at": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        }
        save_keys(keys)

    print("\n✅ 成功建立新 API Key！")
    print(f"  • 使用者名稱 : {args.name}")
    print(f"  • 授權模型   : {models_desc}")
    print(f"  • API Key    : {new_key}")
    print("  • 存放位置   : api_keys.json (chmod 600)\n")

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
    gen_parser.add_argument("--desc", "-d", default="", help="備註說明")
    gen_parser.set_defaults(func=cmd_generate)

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

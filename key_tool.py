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
import json
import os
import secrets
from pathlib import Path

KEYS_FILE = Path(__file__).parent / "api_keys.json"

def load_keys() -> dict:
    if not KEYS_FILE.exists():
        return {}
    try:
        with open(KEYS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        print(f"⚠️ 警告：無法解析金鑰庫檔案 {KEYS_FILE}: {e}")
        return {}

def save_keys(keys: dict):
    with open(KEYS_FILE, "w", encoding="utf-8") as f:
        json.dump(keys, f, indent=2, ensure_ascii=False)
    # 設定權限僅擁有者可讀寫
    os.chmod(KEYS_FILE, 0o600)

def mask_key(k: str) -> str:
    if len(k) <= 12:
        return "****"
    return f"{k[:7]}...{k[-4:]}"

def cmd_generate(args):
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

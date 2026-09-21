import json
import logging
import os
import secrets
from pathlib import Path
from fastapi import Request, HTTPException, status
from litellm.proxy._types import UserAPIKeyAuth, LitellmUserRoles
from litellm.proxy.common_utils.http_parsing_utils import _read_request_body

logger = logging.getLogger("custom_auth")
KEYS_FILE = Path(__file__).parent / "api_keys.json"

def load_keys() -> dict:
    if not KEYS_FILE.exists():
        return {}
    try:
        with open(KEYS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        logger.error(f"❌ Failed to load {KEYS_FILE}: {e}", exc_info=True)
        return {}


async def user_api_key_auth(request: Request, api_key: str) -> UserAPIKeyAuth:
    """
    LiteLLM Proxy 自訂多金鑰鑑權函式：
    1. 驗證 Master Key（擁有最高管理員權限）
    2. 驗證 api_keys.json 中的虛擬 API Key（支援指定授權模型）
    """
    if not api_key:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"error": "Missing API key in Authorization header"}
        )

    if api_key.startswith("Bearer "):
        api_key = api_key[7:].strip()

    # 1. 檢查 Master Key
    master_key = os.environ.get("LITELLM_MASTER_KEY")
    if master_key and secrets.compare_digest(api_key, master_key):
        return UserAPIKeyAuth(
            api_key=api_key,
            user_role=LitellmUserRoles.PROXY_ADMIN,
        )

    # 2. 檢查 api_keys.json 內的金鑰庫
    keys = load_keys()
    if api_key in keys:
        info = keys[api_key]
        allowed_models = info.get("models", [])
        is_all_models = allowed_models in (["all"], ["*"], [])

        # 如果此金鑰有指定限制的模型清單，檢查請求中的 model 參數
        if not is_all_models:
            body = await _read_request_body(request)
            req_model = body.get("model") if isinstance(body, dict) else None
            if req_model and req_model not in allowed_models:
                raise HTTPException(
                    status_code=status.HTTP_403_FORBIDDEN,
                    detail={
                        "error": f"API key is not authorized for model '{req_model}'. Allowed models: {allowed_models}"
                    }
                )

        return UserAPIKeyAuth(
            api_key=api_key,
            user_id=info.get("user_id", "internal_user"),
            models=[] if is_all_models else allowed_models,
            user_role=LitellmUserRoles.INTERNAL_USER,
        )

    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail={"error": "Invalid API key"}
    )

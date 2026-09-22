#!/usr/bin/env python3
"""
LiteLLM Gateway 高併發壓力測試腳本 (支援 Qwen3.8-27B / qwen3.8 輪流負載)
"""
import os
import sys
import time
import random
import argparse
import asyncio
import statistics
from typing import List, Dict, Any, Optional

import httpx
from rich.console import Console
from rich.table import Table
from rich.panel import Panel
from tqdm.asyncio import tqdm

console = Console()

# 自動載入 .env 檔案
def load_env_fallback(filepath=".env"):
    if os.path.exists(filepath):
        with open(filepath, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    k, v = k.strip(), v.strip().strip('"').strip("'")
                    if k and k not in os.environ:
                        os.environ[k] = v

try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    load_env_fallback()

# 測試預設設定 (優先讀取環境變數 / .env)
DEFAULT_BASE_URL = os.getenv("LITELLM_BASE_URL", os.getenv("OPENAI_BASE_URL", "http://127.0.0.1:4000"))
DEFAULT_API_KEY = os.getenv("LITELLM_API_KEY", os.getenv("OPENAI_API_KEY", "REDACTED_API_KEY"))
DEFAULT_CONCURRENCY = int(os.getenv("DEFAULT_CONCURRENCY", "100"))
DEFAULT_TOTAL = int(os.getenv("DEFAULT_TOTAL", "300"))
DEFAULT_MAX_TOKENS = int(os.getenv("DEFAULT_MAX_TOKENS", "300"))
DEFAULT_TEMPERATURE = float(os.getenv("DEFAULT_TEMPERATURE", "0.7"))
DEFAULT_TIMEOUT = float(os.getenv("DEFAULT_TIMEOUT", "120.0"))

MODELS = ["Qwen3.8-27B", "qwen3.8"]

TEST_PROMPTS = [
    "請簡要說明分散式系統中的 Paxos 與 Raft 演算法的核心差異。",
    "請用繁體中文列出 3 個高效能推論引擎（如 SGLang、vLLM）的優勢比較。",
    "什麼是分散式系統中的 CAP 定理？請以簡短 2 句話說明。",
    "請說明 GPU H200 相比 H100 在記憶體頻寬與顯存容量上的關鍵升級。",
    "請簡述 Attention 機制中 KV Cache 壓縮與分頁（PagedAttention）的作用。"
]


def format_error(e: Exception) -> str:
    """格式化例外錯誤訊息，避免例外訊息為空時無法辨識問題"""
    err_type = type(e).__name__
    err_text = str(e).strip()
    return f"{err_type}: {err_text}" if err_text else err_type


def resolve_urls(base_url: str):
    """
    正規化 base_url，確保能正確解析 /health 與 /v1/chat/completions。
    無論輸入的是 http://127.0.0.1:4000 或是 http://127.0.0.1:4000/v1 皆能自動適配。
    """
    clean_url = base_url.rstrip("/")
    if clean_url.endswith("/v1"):
        root_url = clean_url[:-3].rstrip("/")
        v1_url = clean_url
    else:
        root_url = clean_url
        v1_url = f"{clean_url}/v1"
    return root_url, v1_url


async def check_connection(client: httpx.AsyncClient, root_url: str, v1_url: str, api_key: str) -> bool:
    """
    第一階段：連線健康檢查 (Pre-flight Check)
    1. GET /health
    2. GET /v1/models
    """
    console.print(Panel.fit("[bold cyan]🔍 步驟 1: 正在執行連線健康檢查 (Pre-flight Check)...[/bold cyan]", border_style="cyan"))

    headers = {"Authorization": f"Bearer {api_key}"}

    # 1. 檢查 /health
    health_url = f"{root_url}/health"
    try:
        res = await client.get(health_url, headers=headers, timeout=10.0)
        if res.status_code != 200:
            console.print(f"[bold red]❌ Gateway 健康檢查失敗 (HTTP {res.status_code}):[/bold red] {res.text[:200]}")
            return False
        console.print(f"  [green]✅ Gateway 健康檢查通過[/green] ([dim]{health_url}[/dim] HTTP 200)")
    except Exception as e:
        console.print(f"[bold red]❌ 連線至 /health 失敗:[/bold red] {format_error(e)}")
        console.print("[yellow]💡 請確認 SSH Tunnel 是否正常建立 (例如: 127.0.0.1:4000 -> 遠端 54821) 且遠端服務已啟動！[/yellow]")
        return False

    # 2. 檢查 /v1/models
    models_url = f"{v1_url}/models"
    try:
        res = await client.get(models_url, headers=headers, timeout=10.0)
        if res.status_code != 200:
            console.print(f"[bold red]❌ 查詢模型清單失敗 (HTTP {res.status_code}):[/bold red] {res.text[:200]}")
            return False

        data = res.json().get("data", [])
        models = [m.get("id", "") for m in data if isinstance(m, dict)]
        console.print(f"  [green]✅ 成功取得模型清單 (共 {len(models)} 個):[/green] {', '.join(models) if models else '無'}")

        missing_models = []
        for required in MODELS:
            if required not in models:
                missing_models.append(required)
                console.print(f"  [bold yellow]⚠️ 警告：模型清單中未見目標模型 '{required}'[/bold yellow]")

        if not missing_models:
            console.print(f"  [green]✅ 所有測試目標模型皆就緒: {', '.join(MODELS)}[/green]")

        console.print("[bold green]🎉 連線與模型確認完成！即將開始高併發壓力測試...[/bold green]\n")
        return True

    except Exception as e:
        console.print(f"[bold red]❌ 查詢 /v1/models 失敗:[/bold red] {format_error(e)}")
        return False


async def mock_worker(
    sem: asyncio.Semaphore,
    req_id: int,
    results: List[Dict[str, Any]],
    pbar: tqdm
):
    """用於離線模擬驗證的 Mock Worker"""
    model = MODELS[req_id % len(MODELS)]
    async with sem:
        start_time = time.perf_counter()
        # 模擬延遲 0.05 ~ 0.25 秒
        simulated_delay = random.uniform(0.05, 0.25)
        await asyncio.sleep(simulated_delay)
        latency = time.perf_counter() - start_time

        # 模擬極低失敗率以測試錯誤展示 (例如 2%)
        is_fail = random.random() < 0.02
        if is_fail:
            status = 503
            err_msg = "Service Unavailable (Simulated Mock Error)"
            comp_tokens = 0
            prompt_tokens = 0
        else:
            status = 200
            err_msg = ""
            comp_tokens = random.randint(80, 140)
            prompt_tokens = random.randint(20, 40)

        results.append({
            "id": req_id,
            "model": model,
            "status": status,
            "latency": latency,
            "completion_tokens": comp_tokens,
            "prompt_tokens": prompt_tokens,
            "error": err_msg
        })
        pbar.update(1)


async def worker(
    sem: asyncio.Semaphore,
    client: httpx.AsyncClient,
    chat_url: str,
    api_key: str,
    req_id: int,
    max_tokens: int,
    temperature: float,
    timeout: float,
    results: List[Dict[str, Any]],
    pbar: tqdm
):
    """
    單一壓力測試請求 Worker
    """
    model = MODELS[req_id % len(MODELS)]
    prompt = TEST_PROMPTS[req_id % len(TEST_PROMPTS)]

    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": temperature
    }
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json"
    }

    async with sem:
        start_time = time.perf_counter()
        status = 0
        error_msg = ""
        completion_tokens = 0
        prompt_tokens = 0

        try:
            res = await client.post(
                chat_url,
                json=payload,
                headers=headers,
                timeout=timeout
            )
            latency = time.perf_counter() - start_time
            status = res.status_code
            if status == 200:
                try:
                    data = res.json()
                    usage = data.get("usage", {})
                    completion_tokens = usage.get("completion_tokens", 0)
                    prompt_tokens = usage.get("prompt_tokens", 0)
                except Exception:
                    pass
            else:
                error_msg = res.text[:120].replace("\n", " ")
        except Exception as e:
            latency = time.perf_counter() - start_time
            error_msg = format_error(e)[:120].replace("\n", " ")

        results.append({
            "id": req_id,
            "model": model,
            "status": status,
            "latency": latency,
            "completion_tokens": completion_tokens,
            "prompt_tokens": prompt_tokens,
            "error": error_msg
        })
        pbar.update(1)


def display_reports(results: List[Dict[str, Any]], total_duration: float, concurrency: int, total_requests: int, output_json: Optional[str] = None):
    """統計並以 Rich 表格輸出詳細測試成果報告，並可選輸出為 JSON"""
    import json
    successes = [r for r in results if r["status"] == 200]
    failures = [r for r in results if r["status"] != 200]
    latencies = [r["latency"] for r in successes]

    total_completion_tokens = sum(r.get("completion_tokens", 0) for r in successes)
    total_prompt_tokens = sum(r.get("prompt_tokens", 0) for r in successes)

    success_rate = (len(successes) / total_requests * 100) if total_requests > 0 else 0
    failure_rate = (len(failures) / total_requests * 100) if total_requests > 0 else 0
    qps = (len(successes) / total_duration) if total_duration > 0 else 0
    tps = (total_completion_tokens / total_duration) if total_duration > 0 else 0

    # 1. 整體成果表格
    table = Table(title="📊 LiteLLM & SGLang H200 壓力測試成果報告", show_lines=True)
    table.add_column("指標項目 (Metric)", style="cyan bold", no_wrap=True)
    table.add_column("測試數據 (Value)", style="green bold")

    table.add_row("並發人數 (Concurrency)", f"{concurrency} 人")
    table.add_row("總請求數 (Total Requests)", f"{total_requests} 筆")
    table.add_row("成功次數 (Success Count)", f"{len(successes)} 筆 ({success_rate:.1f}%)")
    table.add_row("失敗次數 (Failed Count)", f"{len(failures)} 筆 ({failure_rate:.1f}%)")
    table.add_row("總執行耗時 (Total Time)", f"{total_duration:.2f} 秒")
    table.add_row("整體請求吞吐量 (QPS / RPS)", f"{qps:.2f} req/s")

    if total_completion_tokens > 0:
        table.add_row("Token 生成吞吐量 (Output TPS)", f"{tps:.2f} tokens/s")
        table.add_row("總輸出 Token 數 (Generated Tokens)", f"{total_completion_tokens} tokens")

    p50 = p90 = p95 = p99 = min_lat = max_lat = avg_lat = 0.0
    if latencies:
        latencies.sort()
        n = len(latencies)
        avg_lat = statistics.mean(latencies)
        p50 = statistics.median(latencies)
        p90 = latencies[min(int(n * 0.90), n - 1)]
        p95 = latencies[min(int(n * 0.95), n - 1)]
        p99 = latencies[min(int(n * 0.99), n - 1)]
        min_lat = min(latencies)
        max_lat = max(latencies)

        table.add_row("平均延遲 (Avg Latency)", f"{avg_lat:.3f} 秒")
        table.add_row("中位數延遲 (P50 Latency)", f"{p50:.3f} 秒")
        table.add_row("P90 延遲 (P90 Latency)", f"{p90:.3f} 秒")
        table.add_row("P95 延遲 (P95 Latency)", f"{p95:.3f} 秒")
        table.add_row("P99 延遲 (P99 Latency)", f"{p99:.3f} 秒")
        table.add_row("最短延遲 (Min Latency)", f"{min_lat:.3f} 秒")
        table.add_row("最長延遲 (Max Latency)", f"{max_lat:.3f} 秒")

    console.print("\n", table)

    # 2. 個別模型分流詳細統計表格
    model_table = Table(title="🏷️ 個別模型負載分流統計", show_lines=True)
    model_table.add_column("模型名稱 (Model)", style="magenta bold")
    model_table.add_column("總請求數", justify="right")
    model_table.add_column("成功數", justify="right", style="green")
    model_table.add_column("失敗數", justify="right", style="red")
    model_table.add_column("成功率", justify="right")
    model_table.add_column("平均延遲", justify="right")
    model_table.add_column("P95 延遲", justify="right")
    if total_completion_tokens > 0:
        model_table.add_column("平均 Token/req", justify="right")

    model_stats = {}
    for m_name in MODELS:
        m_all = [r for r in results if r["model"] == m_name]
        m_succ = [r for r in m_all if r["status"] == 200]
        m_fail = [r for r in m_all if r["status"] != 200]
        m_lat = [r["latency"] for r in m_succ]
        m_rate = (len(m_succ) / len(m_all) * 100) if m_all else 0

        avg_lat_str = f"{statistics.mean(m_lat):.3f}s" if m_lat else "N/A"
        if m_lat:
            m_lat.sort()
            p95_val = m_lat[min(int(len(m_lat) * 0.95), len(m_lat) - 1)]
            p95_str = f"{p95_val:.3f}s"
        else:
            p95_str = "N/A"

        row_data = [
            m_name,
            str(len(m_all)),
            str(len(m_succ)),
            str(len(m_fail)),
            f"{m_rate:.1f}%",
            avg_lat_str,
            p95_str
        ]

        avg_tok = 0.0
        if total_completion_tokens > 0:
            m_tokens = sum(r.get("completion_tokens", 0) for r in m_succ)
            avg_tok = (m_tokens / len(m_succ)) if m_succ else 0
            row_data.append(f"{avg_tok:.1f}")

        model_table.add_row(*row_data)

        model_stats[m_name] = {
            "total": len(m_all),
            "success": len(m_succ),
            "failed": len(m_fail),
            "success_rate": m_rate,
            "avg_latency": statistics.mean(m_lat) if m_lat else 0.0,
            "p95_latency": p95_val if m_lat else 0.0,
            "avg_tokens": avg_tok
        }

    console.print(model_table)

    # 3. 失敗請求取樣輸出
    if failures:
        console.print("\n[bold red]⚠️ 失敗請求取樣 (最多顯示前 5 筆):[/bold red]")
        for f in failures[:5]:
            console.print(f"  • [yellow]Req #{f['id']}[/yellow] | Model: [cyan]{f['model']}[/cyan] | HTTP [red]{f['status']}[/red] | Error: {f['error']}")

    # 若指定 JSON 輸出
    if output_json:
        summary_data = {
            "concurrency": concurrency,
            "total_requests": total_requests,
            "total_duration": total_duration,
            "success_count": len(successes),
            "failure_count": len(failures),
            "success_rate": success_rate,
            "qps": qps,
            "tps": tps,
            "total_tokens": total_completion_tokens,
            "avg_latency": avg_lat,
            "p50_latency": p50,
            "p90_latency": p90,
            "p95_latency": p95,
            "p99_latency": p99,
            "min_latency": min_lat,
            "max_latency": max_lat,
            "model_stats": model_stats
        }
        with open(output_json, "w", encoding="utf-8") as jf:
            json.dump(summary_data, jf, indent=2, ensure_ascii=False)
        console.print(f"[dim]📁 成果已儲存至 JSON: {output_json}[/dim]")


async def run_stress_test(args):
    # 若啟用 mock 模式（用於離線功能驗證）
    if args.mock:
        console.print(
            Panel.fit(
                f"[bold yellow]🛠️ [MOCK 模擬模式] 開始壓力測試模擬[/bold yellow]\n"
                f"• 並發人數 (Concurrency): [green]{args.concurrency}[/green]\n"
                f"• 總請求數 (Total Requests): [green]{args.total}[/green]\n"
                f"• 輪流分流模型: [green]{', '.join(MODELS)}[/green]",
                border_style="yellow"
            )
        )
        sem = asyncio.Semaphore(args.concurrency)
        results: List[Dict[str, Any]] = []
        pbar = tqdm(total=args.total, desc="推論進度", unit="req", ncols=90)
        start_all = time.perf_counter()

        tasks = [
            asyncio.create_task(mock_worker(sem, i, results, pbar))
            for i in range(args.total)
        ]
        await asyncio.gather(*tasks)
        total_duration = time.perf_counter() - start_all
        pbar.close()

        display_reports(results, total_duration, args.concurrency, args.total, args.output_json)
        return

    # 正式網路請求模式
    root_url, v1_url = resolve_urls(args.base_url)
    chat_url = f"{v1_url}/chat/completions"

    limits = httpx.Limits(
        max_keepalive_connections=args.concurrency,
        max_connections=args.concurrency * 2
    )

    async with httpx.AsyncClient(limits=limits, http2=True) as client:
        # 1. 前置健康檢查
        if not args.skip_check:
            connected = await check_connection(client, root_url, v1_url, args.api_key)
            if not connected:
                console.print("[bold red]⛔ 因健康檢查未通過，中止壓測。若需強制執行請加上 --skip-check[/bold red]")
                return

        # 2. 開始壓測
        console.print(
            Panel.fit(
                f"[bold cyan]🚀 開始壓力測試配置[/bold cyan]\n"
                f"• 目標端點: [yellow]{chat_url}[/yellow]\n"
                f"• 並發人數 (Concurrency): [green]{args.concurrency}[/green]\n"
                f"• 總請求數 (Total Requests): [green]{args.total}[/green]\n"
                f"• 單次 Token 上限 (Max Tokens): [green]{args.max_tokens}[/green]\n"
                f"• 輪流分流模型: [green]{', '.join(MODELS)}[/green]",
                border_style="cyan"
            )
        )

        sem = asyncio.Semaphore(args.concurrency)
        results: List[Dict[str, Any]] = []

        pbar = tqdm(total=args.total, desc="推論進度", unit="req", ncols=90)
        start_all = time.perf_counter()

        tasks = [
            asyncio.create_task(
                worker(
                    sem=sem,
                    client=client,
                    chat_url=chat_url,
                    api_key=args.api_key,
                    req_id=i,
                    max_tokens=args.max_tokens,
                    temperature=args.temperature,
                    timeout=args.timeout,
                    results=results,
                    pbar=pbar
                )
            )
            for i in range(args.total)
        ]

        await asyncio.gather(*tasks)
        total_duration = time.perf_counter() - start_all
        pbar.close()

        # 3. 統計與報告輸出
        display_reports(results, total_duration, args.concurrency, args.total, args.output_json)


def main():
    parser = argparse.ArgumentParser(
        description="LiteLLM & SGLang H200 叢集高併發壓力測試腳本",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL, help="Gateway Base URL (例如 http://127.0.0.1:4000 或 http://127.0.0.1:4000/v1)")
    parser.add_argument("--api-key", default=DEFAULT_API_KEY, help="LiteLLM User API Key (亦可透過環境變數 LITELLM_API_KEY 設定)")
    parser.add_argument("-c", "--concurrency", type=int, default=DEFAULT_CONCURRENCY, help="同時並發請求數 (Concurrency)")
    parser.add_argument("-n", "--total", type=int, default=DEFAULT_TOTAL, help="總測試請求數 (Total Requests)")
    parser.add_argument("--max-tokens", type=int, default=DEFAULT_MAX_TOKENS, help="每次生成的 max_tokens")
    parser.add_argument("--temperature", type=float, default=DEFAULT_TEMPERATURE, help="生成溫度 Temperature")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT, help="單一請求逾時時間 (秒)")
    parser.add_argument("--skip-check", action="store_true", help="跳過前置健康檢查直接壓測")
    parser.add_argument("--mock", action="store_true", help="離線模擬測試模式 (驗證進度條與報表輸出)")
    parser.add_argument("--output-json", type=str, default=None, help="將測試成果輸出為 JSON 檔案路徑")

    args = parser.parse_args()
    asyncio.run(run_stress_test(args))


if __name__ == "__main__":
    main()

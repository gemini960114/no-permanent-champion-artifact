#!/usr/bin/env python3
"""
硬體適配估算 (estimate_fit.py) — model-onboarding skill 附屬工具
用法：estimate_fit.py --params 604 --precision fp8 [--active 27] [--context-kv-gb 200]
估算權重記憶體需求並對照本叢集硬體（4×/8×H200）與 /work 磁碟剩餘空間。
"""
import argparse
import subprocess


BYTES_PER_PARAM = {"bf16": 2, "fp8": 1, "int4": 0.5}
H200_GB = 141
NODE_4 = 4 * H200_GB
NODE_8 = 8 * H200_GB
KV_RESERVE_RATIO = 0.25  # KV cache + 通訊緩衝預留比例（保守值）


def df_free_gb(path: str):
    """以 df 查詢（與使用者所見一致；shutil/statfs 在 Lustre 上讀數可能不同）"""
    try:
        out = subprocess.run(
            ["df", "-B1G", "--output=avail", path],
            capture_output=True, text=True, timeout=10, check=True,
        ).stdout.strip().splitlines()[-1]
        return float(out)
    except Exception:
        return None


def main():
    p = argparse.ArgumentParser(description="H200 叢集模型適配估算")
    p.add_argument("--params", type=float, required=True, help="總參數量（十億，例 604 = 604B）")
    p.add_argument("--precision", choices=list(BYTES_PER_PARAM), required=True)
    p.add_argument("--active", type=float, help="激活參數（十億，MoE 資訊用）")
    p.add_argument("--extra-gb", type=float, default=0, help="額外顯存（多模態視覺塔等）")
    p.add_argument("--disk-path", default="/path/to/work/models",
                   help="磁碟檢查路徑（⚠️ 必須是實際落點：Lustre 根目錄回報整個檔案系統，"
                        "不是專案 quota——查 /path/to/work 才準）")
    args = p.parse_args()

    weights_gb = args.params * BYTES_PER_PARAM[args.precision]
    total_gb = weights_gb + args.extra_gb
    kv_needed_4 = NODE_4 * (1 - KV_RESERVE_RATIO)
    kv_needed_8 = NODE_8 * (1 - KV_RESERVE_RATIO)

    disk_free_gb = df_free_gb(args.disk_path)

    print("════ 模型適配估算 ════")
    print(f"權重      : {args.params:.0f}B × {BYTES_PER_PARAM[args.precision]} bytes = {weights_gb:,.0f} GB")
    if args.active:
        print(f"激活參數  : {args.active:.0f}B（MoE，計算量參考，不影響權重記憶體）")
    if args.extra_gb:
        print(f"額外顯存  : +{args.extra_gb:,.0f} GB（多模態等）")
    print(f"合計需求  : {total_gb:,.0f} GB（未含 KV cache；建議預留 {KV_RESERVE_RATIO:.0%}）")
    print()
    print("──── GPU 記憶體對照 ────")
    for label, budget, usable in (("4×H200", NODE_4, kv_needed_4), ("8×H200", NODE_8, kv_needed_8)):
        if total_gb <= usable:
            verdict = "✅ 可行（含 KV 預留）"
        elif total_gb <= budget:
            verdict = "⚠️ 剛好塞下權重，KV cache 不足——不建議"
        else:
            verdict = "❌ 權重即超出"
        print(f"{label:8s} ({budget} GB，可用 {usable:,.0f} GB) → {verdict}")
    print()
    print("──── 磁碟對照 ────")
    if disk_free_gb is not None:
        verdict = "✅" if weights_gb <= disk_free_gb else "❌"
        print(f"{args.disk_path} 剩餘 {disk_free_gb:,.0f} GB vs 權重 {weights_gb:,.0f} GB → {verdict}")
        print(f"ℹ️ 本專案 download_model.sh 採 hf download --local-dir 直落目標（約 1×）；")
        print(f"   若用快取式下載需 2×（~{weights_gb * 2:,.0f} GB）。共用 Lustre 讀數會浮動，大下載前請再 df 確認。")
    else:
        print("（無法查詢磁碟路徑）")
    print()
    print("結論只能是：✅ 直接上／🟡 等量化版／❌ 不可行（建議 API 接入）")


if __name__ == "__main__":
    main()

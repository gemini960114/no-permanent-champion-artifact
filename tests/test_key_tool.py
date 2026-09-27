#!/usr/bin/env python3
"""
tests/test_key_tool.py
==============================================================================
key_tool.py 金鑰庫併發安全與 Fail-Safe 單元測試
涵蓋：
1. 並發 generate 不遺失金鑰 (flock 序列化讀取→修改→寫回)
2. 解析失敗時中止並報錯，絕不將金鑰庫清空
3. 原子寫入：不留暫存檔、檔案權限 600
測試金鑰一律使用工具自行產生或明文假值，不含任何真實秘密。
==============================================================================
"""

import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import unittest

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
KEY_TOOL_SRC = os.path.join(PROJECT_ROOT, "key_tool.py")


class TestKeyTool(unittest.TestCase):
    """key_tool.py 金鑰庫寫入安全測試 (於暫存目錄執行複本，不碰正式 api_keys.json)"""

    def setUp(self):
        self.test_dir = tempfile.mkdtemp()
        # 複製 key_tool.py 至暫存目錄，使其 KEYS_FILE 指向暫存目錄
        self.tool = os.path.join(self.test_dir, "key_tool.py")
        shutil.copyfile(KEY_TOOL_SRC, self.tool)
        self.keys_file = os.path.join(self.test_dir, "api_keys.json")

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def _run(self, *args):
        return subprocess.run(
            [sys.executable, self.tool, *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=120,
        )

    def test_concurrent_generate_no_key_loss(self):
        """並發 generate：flock 序列化讀改寫，N 個程序產生 N 把金鑰、零遺失"""
        n = 12
        results = [None] * n

        def worker(i):
            results[i] = self._run("generate", "--name", f"user{i}", "--models", "GLM-Test")

        threads = [threading.Thread(target=worker, args=(i,)) for i in range(n)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        for i, r in enumerate(results):
            self.assertEqual(r.returncode, 0, f"worker {i} 失敗: {r.stderr}")

        with open(self.keys_file, "r", encoding="utf-8") as f:
            keys = json.load(f)
        self.assertEqual(len(keys), n, f"並發 generate 遺失金鑰！預期 {n} 把，實際 {len(keys)} 把")
        user_ids = {info["user_id"] for info in keys.values()}
        self.assertEqual(user_ids, {f"user{i}" for i in range(n)})

    def test_parse_failure_does_not_wipe_store(self):
        """金鑰庫解析失敗：key_tool 應中止並報錯，不得當成空字典寫回清空"""
        # 先建立一把合法金鑰
        r = self._run("generate", "--name", "alice", "--models", "GLM-Test")
        self.assertEqual(r.returncode, 0)

        # 寫入損壞內容 (模擬寫到一半的半成品)
        corrupted = "{ this is not valid json"
        with open(self.keys_file, "w", encoding="utf-8") as f:
            f.write(corrupted)

        r = self._run("generate", "--name", "bob", "--models", "GLM-Test")
        self.assertNotEqual(r.returncode, 0, "解析失敗應以非 0 回傳碼中止")
        self.assertIn("無法解析", r.stderr)

        with open(self.keys_file, "r", encoding="utf-8") as f:
            self.assertEqual(f.read(), corrupted, "解析失敗後金鑰庫內容不得被變更！")

    def test_atomic_write_no_tmp_left_and_mode_600(self):
        """原子寫入：不留暫存檔，金鑰庫權限 600"""
        r = self._run("generate", "--name", "carol", "--models", "GLM-Test")
        self.assertEqual(r.returncode, 0)

        leftovers = [f for f in os.listdir(self.test_dir) if ".tmp." in f]
        self.assertEqual(leftovers, [], f"殘留暫存檔: {leftovers}")

        mode = stat.S_IMODE(os.stat(self.keys_file).st_mode)
        self.assertEqual(mode, 0o600, f"金鑰庫權限應為 600，實際為 {oct(mode)}")

        # revoke 亦應維持原子性與權限
        with open(self.keys_file, "r", encoding="utf-8") as f:
            first_key = next(iter(json.load(f)))
        r = self._run("revoke", "--key", first_key)
        self.assertEqual(r.returncode, 0)
        leftovers = [f for f in os.listdir(self.test_dir) if ".tmp." in f]
        self.assertEqual(leftovers, [], f"revoke 後殘留暫存檔: {leftovers}")
        mode = stat.S_IMODE(os.stat(self.keys_file).st_mode)
        self.assertEqual(mode, 0o600)

    def test_rate_limit_roundtrip_and_update(self):
        """--rpm/--tpm 寫入金鑰庫、update 可調整、0=不限額 (None)"""
        r = self._run("generate", "--name", "dave", "--models", "all",
                      "--rpm", "3000", "--tpm", "10000000")
        self.assertEqual(r.returncode, 0, r.stderr)

        with open(self.keys_file, "r", encoding="utf-8") as f:
            keys = json.load(f)
        info = next(iter(keys.values()))
        self.assertEqual(info["rpm_limit"], 3000)
        self.assertEqual(info["tpm_limit"], 10000000)

        # update 調整限額＋模型白名單
        the_key = next(iter(keys))
        r = self._run("update", "--key", the_key, "--rpm", "600", "--tpm", "0",
                      "--models", "qwen-27b", "glm5.3-flash")
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(self.keys_file, "r", encoding="utf-8") as f:
            keys = json.load(f)
        self.assertEqual(keys[the_key]["rpm_limit"], 600)
        self.assertIsNone(keys[the_key]["tpm_limit"], "0 應存為不限額 (None)")
        self.assertEqual(keys[the_key]["models"], ["qwen-27b", "glm5.3-flash"])

        # update --models all → 恢復全部
        r = self._run("update", "--key", the_key, "--models", "all")
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(self.keys_file, "r", encoding="utf-8") as f:
            self.assertEqual(json.load(f)[the_key]["models"], ["all"])

        # 未指定金鑰不存在 → 非 0 退出
        r = self._run("update", "--key", "sk-nonexistent", "--rpm", "1")
        self.assertNotEqual(r.returncode, 0)

    def test_legacy_keys_have_no_limits(self):
        """舊格式金鑰 (無 rpm_limit/tpm_limit 欄位)：list 應正常顯示為不限額"""
        legacy = {"sk-legacy0000000000000000000000000000": {
            "user_id": "legacy-user", "models": ["all"],
            "description": "old", "created_at": "2026-01-01 00:00:00"}}
        with open(self.keys_file, "w", encoding="utf-8") as f:
            json.dump(legacy, f)
        r = self._run("list")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("不限額", r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)

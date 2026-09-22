#!/usr/bin/env python3
"""
tests/test_lifecycle_logic.py
==============================================================================
LiteLLM Gateway & SGLang 生命週期核心邏輯單元測試庫
涵蓋：
1. Slurm 三態判定 (RUNNING / INACTIVE / UNKNOWN) 與各種錯誤文字過濾
2. 狀態分類 (SUSPENDED / PENDING / COMPLETING 嚴格保留防誤刪)
3. 連線逾時與控制器通訊故障之 Fail-Closed 安全防護
4. Port 鎖對帳：安全清除 INACTIVE、嚴格保留 UNKNOWN、回收 >10 分鐘孤兒鎖
5. HTTP 探測：HTTP 200 狀態碼與 OpenAI JSON 結構之雙重嚴格校驗
==============================================================================
"""

import os
import sys
import time
import json
import shutil
import tempfile
import unittest
import subprocess
import http.server
import threading
from unittest.mock import patch, MagicMock

# 載入受測模組
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(PROJECT_ROOT, "scripts"))
import generate_runtime_config as grc

class TestSlurmJobStatus(unittest.TestCase):
    """測試 get_job_status 的三態判定與文字匹配"""

    def test_empty_and_special_job_ids(self):
        self.assertEqual(grc.get_job_status(""), "INACTIVE")
        self.assertEqual(grc.get_job_status("N/A"), "INACTIVE")
        self.assertEqual(grc.get_job_status("dummy"), "INACTIVE")
        self.assertEqual(grc.get_job_status("manual"), "RUNNING")

    @patch("subprocess.run")
    def test_running_and_preserved_states(self, mock_run):
        # 1. RUNNING
        mock_run.return_value = MagicMock(returncode=0, stdout="RUNNING\n", stderr="")
        self.assertEqual(grc.get_job_status("12345"), "RUNNING")

        # 2. PENDING / CONFIGURING / COMPLETING / SUSPENDED (保留、不上線、不刪除)
        for st in ("PENDING", "CONFIGURING", "COMPLETING", "SUSPENDED"):
            mock_run.return_value = MagicMock(returncode=0, stdout=f"{st}\n", stderr="")
            self.assertEqual(grc.get_job_status("12345"), st)

        # 3. 終止狀態 (INACTIVE)
        for st in ("COMPLETED", "FAILED", "CANCELLED", "TIMEOUT", "PREEMPTED", "NODE_FAIL", "DEAD"):
            mock_run.return_value = MagicMock(returncode=0, stdout=f"{st}\n", stderr="")
            self.assertEqual(grc.get_job_status("12345"), "INACTIVE")

    @patch("subprocess.run")
    def test_slurm_error_text_matching(self, mock_run):
        # 1. 明確無效 Job ID -> INACTIVE (允許破壞性清理)
        mock_run.return_value = MagicMock(
            returncode=1,
            stdout="",
            stderr="slurm_load_jobs error: Invalid job id specified\n"
        )
        self.assertEqual(grc.get_job_status("99999"), "INACTIVE")

        # 2. 通訊逾時 -> 必須為 UNKNOWN (嚴格禁止誤判為 INACTIVE)
        mock_run.return_value = MagicMock(
            returncode=1,
            stdout="",
            stderr="slurm_load_jobs error: Socket timed out on send/recv operation\n"
        )
        self.assertEqual(grc.get_job_status("99999"), "UNKNOWN")

        # 3. 控制器斷線 -> 必須為 UNKNOWN (嚴格禁止誤判為 INACTIVE)
        mock_run.return_value = MagicMock(
            returncode=1,
            stdout="",
            stderr="slurm_load_jobs error: Unable to contact slurm controller\n"
        )
        self.assertEqual(grc.get_job_status("99999"), "UNKNOWN")

        # 4. 其它未預期錯誤 -> UNKNOWN
        mock_run.return_value = MagicMock(
            returncode=1,
            stdout="",
            stderr="squeue: fatal: Zero Bytes were read or written\n"
        )
        self.assertEqual(grc.get_job_status("99999"), "UNKNOWN")

    @patch("subprocess.run", side_effect=subprocess.TimeoutExpired(cmd="squeue", timeout=5))
    def test_subprocess_timeout(self, mock_run):
        self.assertEqual(grc.get_job_status("12345"), "UNKNOWN")

    @patch("subprocess.run", side_effect=OSError("Command not found"))
    def test_subprocess_exception(self, mock_run):
        self.assertEqual(grc.get_job_status("12345"), "UNKNOWN")


class TestPortLockReconciliation(unittest.TestCase):
    """測試 Port 鎖自動對帳與孤兒鎖清理"""

    def setUp(self):
        self.test_dir = tempfile.mkdtemp()
        self.orig_locks_dir = grc.PORT_LOCKS_DIR
        grc.PORT_LOCKS_DIR = self.test_dir

    def tearDown(self):
        grc.PORT_LOCKS_DIR = self.orig_locks_dir
        shutil.rmtree(self.test_dir, ignore_errors=True)

    @patch("generate_runtime_config.get_job_status")
    def test_reconcile_active_inactive_unknown(self, mock_status):
        # 建立 3 個鎖目錄
        lock_inactive = os.path.join(self.test_dir, "node-30000")
        lock_running = os.path.join(self.test_dir, "node-30001")
        lock_unknown = os.path.join(self.test_dir, "node-30002")
        lock_suspended = os.path.join(self.test_dir, "node-30003")

        for d, jid in [(lock_inactive, "101"), (lock_running, "102"), (lock_unknown, "103"), (lock_suspended, "104")]:
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, "job_id"), "w") as f:
                f.write(jid)

        def mock_status_impl(jid):
            if jid == "101":
                return "INACTIVE"
            elif jid == "102":
                return "RUNNING"
            elif jid == "103":
                return "UNKNOWN"
            elif jid == "104":
                return "SUSPENDED"
            return "UNKNOWN"

        mock_status.side_effect = mock_status_impl

        res = grc.reconcile_port_locks()

        # 遇到 UNKNOWN 應回傳 False 以便通知主流程中斷生成 (Fail-Closed)
        self.assertFalse(res)
        # INACTIVE 應被安全清除
        self.assertFalse(os.path.exists(lock_inactive))
        # RUNNING 應保留
        self.assertTrue(os.path.exists(lock_running))
        # UNKNOWN 嚴格保留以防連接埠衝突！
        self.assertTrue(os.path.exists(lock_unknown))
        # SUSPENDED 保留以防搶鎖衝突！
        self.assertTrue(os.path.exists(lock_suspended))

    def test_orphan_lock_reclamation(self):
        # 1. 建立剛產生不久的無 job_id 目錄 (未達 10 分鐘)
        recent_orphan = os.path.join(self.test_dir, "node-30010")
        os.makedirs(recent_orphan, exist_ok=True)

        # 2. 建立逾時的孤兒目錄 (> 600 秒)
        expired_orphan = os.path.join(self.test_dir, "node-30011")
        os.makedirs(expired_orphan, exist_ok=True)
        old_time = time.time() - 700
        os.utime(expired_orphan, (old_time, old_time))

        res = grc.reconcile_port_locks()
        self.assertTrue(res)

        # 未達寬限期之孤兒鎖應暫予保留
        self.assertTrue(os.path.exists(recent_orphan))
        # 超過 10 分鐘之無主孤兒鎖應被清除
        self.assertFalse(os.path.exists(expired_orphan))


class TestEndpointHttpJsonValidation(unittest.TestCase):
    """測試 HTTP 200 與合法 OpenAI JSON 結構之雙重驗證"""

    @classmethod
    def setUpClass(cls):
        class MockServer(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == "/v1/models":
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    self.wfile.write(b'{"object": "list", "data": [{"id": "Qwen3.8-27B"}]}')
                elif self.path == "/html_error/models":
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html")
                    self.end_headers()
                    self.wfile.write(b'<html><body>502 Bad Gateway</body></html>')
                elif self.path == "/wrong_json/models":
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    self.wfile.write(b'{"status": "starting", "progress": 0.5}')
                elif self.path == "/http_500/models":
                    self.send_response(500)
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    self.wfile.write(b'{"object": "error", "message": "server error"}')
                else:
                    self.send_response(404)
                    self.end_headers()
            def log_message(self, format, *args):
                pass

        cls.httpd = http.server.HTTPServer(("127.0.0.1", 0), MockServer)
        cls.port = cls.httpd.server_port
        cls.thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()

    def test_http_validation(self):
        # 1. 正確 HTTP 200 + 合法 OpenAI JSON
        self.assertTrue(grc.is_endpoint_alive(f"http://127.0.0.1:{self.port}/v1", ""))

        # 2. HTTP 200 但為 HTML 錯誤頁
        self.assertFalse(grc.is_endpoint_alive(f"http://127.0.0.1:{self.port}/html_error", ""))

        # 3. HTTP 200 但非 OpenAI 結構 (缺 data/object)
        self.assertFalse(grc.is_endpoint_alive(f"http://127.0.0.1:{self.port}/wrong_json", ""))

        # 4. 非 HTTP 200 (例如 500) 即使是 JSON 亦拒絕
        self.assertFalse(grc.is_endpoint_alive(f"http://127.0.0.1:{self.port}/http_500", ""))

        # 5. 連線不存在 Port
        self.assertFalse(grc.is_endpoint_alive("http://127.0.0.1:59999/v1", ""))

if __name__ == "__main__":
    unittest.main(verbosity=2)

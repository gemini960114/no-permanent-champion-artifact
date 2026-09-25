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
6. 引擎金鑰嚴格歸屬查找 (API_KEY_ENV + ENGINE_DIR，絕不跨引擎退回)
7. Generator 主流程：manual 端點保留、UNKNOWN exit 2 部分成功、靜態過濾不依名稱
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
import errno
import socket
import yaml
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

    def test_orphan_lock_recent_and_local(self):
        """測試無 job_id 孤兒鎖：未達寬限期保留，本機 port free 清除，本機 port occupied 保留"""
        # 1. 建立剛產生不久的無 job_id 目錄 (未達 10 分鐘)
        recent_orphan = os.path.join(self.test_dir, "127.0.0.1-39980")
        os.makedirs(recent_orphan, exist_ok=True)

        # 2. 建立逾時且本地 Port 空閒的孤兒目錄 (> 600 秒)
        expired_free = os.path.join(self.test_dir, "127.0.0.1-39981")
        os.makedirs(expired_free, exist_ok=True)
        old_time = time.time() - 700
        os.utime(expired_free, (old_time, old_time))

        res = grc.reconcile_port_locks()
        self.assertTrue(res)
        # 未達寬限期應保留
        self.assertTrue(os.path.exists(recent_orphan))
        # 逾時且 port free 應被安全清除
        self.assertFalse(os.path.exists(expired_free))

    def test_orphan_lock_local_occupied(self):
        """測試本機 Port 正在佔用時，孤兒鎖嚴格保留且標記 clean_ok=False (Fail-Closed)"""
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", 0))
        s.listen(1)
        bound_port = s.getsockname()[1]
        try:
            expired_occupied = os.path.join(self.test_dir, f"127.0.0.1-{bound_port}")
            os.makedirs(expired_occupied, exist_ok=True)
            old_time = time.time() - 700
            os.utime(expired_occupied, (old_time, old_time))

            res = grc.reconcile_port_locks()
            # 實體 port 仍被佔用，應回傳 False (Fail-Closed) 並保留鎖
            self.assertFalse(res)
            self.assertTrue(os.path.exists(expired_occupied))
        finally:
            s.close()

    def test_orphan_lock_remote_scenarios(self):
        """測試遠端節點孤兒鎖之各類 Socket 探測情境：
        - ECONNREFUSED: 刪除 orphan lock (Port free)
        - 0 (listening): 保留 orphan lock
        - ETIMEDOUT / EHOSTUNREACH / ENETUNREACH: 保留 (Fail-Closed)
        - DNS 解析例外 (gaierror): 保留 (Fail-Closed)
        """
        old_time = time.time() - 700

        # 情境 A: 遠端 ECONNREFUSED -> 主機可達、Port free -> 應刪除，clean_ok = True
        lock_refused = os.path.join(self.test_dir, "remotehost-30001")
        os.makedirs(lock_refused, exist_ok=True)
        os.utime(lock_refused, (old_time, old_time))

        with patch("socket.socket") as mock_sock_cls:
            mock_sock = MagicMock()
            mock_sock_cls.return_value = mock_sock
            mock_sock.connect_ex.return_value = errno.ECONNREFUSED

            res = grc.reconcile_port_locks()
            self.assertTrue(res)
            self.assertFalse(os.path.exists(lock_refused))

        # 情境 B: 遠端 0 (正在監聽) -> 應保留，且回傳 clean_ok=False (Fail-Closed)
        lock_listening = os.path.join(self.test_dir, "remotehost-30002")
        os.makedirs(lock_listening, exist_ok=True)
        os.utime(lock_listening, (old_time, old_time))

        with patch("socket.socket") as mock_sock_cls:
            mock_sock = MagicMock()
            mock_sock_cls.return_value = mock_sock
            mock_sock.connect_ex.return_value = 0

            res = grc.reconcile_port_locks()
            # 監聽中，鎖目錄保留且 clean_ok = False (與本機佔用行為一致)
            self.assertFalse(res)
            self.assertTrue(os.path.exists(lock_listening))

        shutil.rmtree(lock_listening, ignore_errors=True)

        # 情境 C: 遠端異常代碼 (ETIMEDOUT / EHOSTUNREACH / ENETUNREACH) -> Fail-Closed 保留
        for err_code, err_name in [
            (errno.ETIMEDOUT, "ETIMEDOUT"),
            (errno.EHOSTUNREACH, "EHOSTUNREACH"),
            (errno.ENETUNREACH, "ENETUNREACH")
        ]:
            lock_err = os.path.join(self.test_dir, f"remotehost-{err_code}")
            os.makedirs(lock_err, exist_ok=True)
            os.utime(lock_err, (old_time, old_time))

            with patch("socket.socket") as mock_sock_cls:
                mock_sock = MagicMock()
                mock_sock_cls.return_value = mock_sock
                mock_sock.connect_ex.return_value = err_code

                res = grc.reconcile_port_locks()
                self.assertFalse(res, f"Expected clean_ok=False for {err_name}")
                self.assertTrue(os.path.exists(lock_err), f"Expected lock retained for {err_name}")

            shutil.rmtree(lock_err, ignore_errors=True)

        # 情境 D: DNS 解析例外 (socket.gaierror) -> 狀態未知 -> 應保留，clean_ok = False (Fail-Closed)
        lock_dns_err = os.path.join(self.test_dir, "unresolvablehost-30003")
        os.makedirs(lock_dns_err, exist_ok=True)
        os.utime(lock_dns_err, (old_time, old_time))

        with patch("socket.socket") as mock_sock_cls:
            mock_sock = MagicMock()
            mock_sock_cls.return_value = mock_sock
            mock_sock.connect_ex.side_effect = socket.gaierror(-2, "Name or service not known")

            res = grc.reconcile_port_locks()
            self.assertFalse(res)
            self.assertTrue(os.path.exists(lock_dns_err))

        shutil.rmtree(lock_dns_err, ignore_errors=True)


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
        cls.httpd.server_close()

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

class TestEngineApiKeyLookup(unittest.TestCase):
    """測試 get_engine_api_key 之嚴格歸屬查找 (環境變數優先、絕不跨引擎退回) 與引擎發現規則"""

    def setUp(self):
        self.test_dir = tempfile.mkdtemp()
        self.engines_dir = os.path.join(self.test_dir, "engines")
        self.sglang_dir = os.path.join(self.engines_dir, "sglang-fake")
        self.vllm_dir = os.path.join(self.engines_dir, "vllm-fake")
        os.makedirs(self.sglang_dir)
        os.makedirs(self.vllm_dir)
        # 測試用假金鑰 (非真實秘密)
        with open(os.path.join(self.sglang_dir, "config.env"), "w", encoding="utf-8") as f:
            f.write("SGLANG_API_KEY=fake-sglang-key-000\n")
        with open(os.path.join(self.vllm_dir, "config.env"), "w", encoding="utf-8") as f:
            f.write("VLLM_API_KEY=fake-vllm-key-111\n")

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def _clean_key_env(self):
        # 移除可能存在之真實環境金鑰變數，確保測試隔離
        for k in ("SGLANG_API_KEY", "VLLM_API_KEY"):
            os.environ.pop(k, None)

    def test_env_variable_takes_priority(self):
        """環境變數 (含 .env 載入值) 優先於引擎 config.env"""
        with patch.dict(os.environ):
            self._clean_key_env()
            os.environ["VLLM_API_KEY"] = "fake-env-key-222"
            self.assertEqual(grc.get_engine_api_key("VLLM_API_KEY", self.vllm_dir), "fake-env-key-222")

    def test_engine_dir_strict_lookup_no_cross_engine_fallback(self):
        """指定引擎目錄時嚴格讀取該目錄 config.env，找不到回空字串、絕不退回其他引擎金鑰"""
        with patch.dict(os.environ):
            self._clean_key_env()
            # 指定 vllm 目錄 → 取得 vllm 金鑰
            self.assertEqual(grc.get_engine_api_key("VLLM_API_KEY", self.vllm_dir), "fake-vllm-key-111")
            # 指定 sglang 目錄查找 VLLM_API_KEY → 嚴格回空 (不得退回 sglang 金鑰)
            self.assertEqual(grc.get_engine_api_key("VLLM_API_KEY", self.sglang_dir), "")
            self.assertEqual(grc.get_engine_api_key("SGLANG_API_KEY", self.vllm_dir), "")

    def test_engine_discovery_requires_config_env(self):
        """engines/ 發現規則：含 config.env 或 config.env.example 之子目錄才視為引擎；
        無設定檔之子目錄 (如 _template/) 不被掃入；symlink 以 realpath 去重"""
        # 只含 config.env.example 之目錄 → 應視為引擎
        example_only = os.path.join(self.engines_dir, "new-engine")
        os.makedirs(example_only)
        with open(os.path.join(example_only, "config.env.example"), "w", encoding="utf-8") as f:
            f.write("# example only\n")
        # 無任何設定檔之子目錄 → 不應被視為引擎
        for non_engine in ("_template", "docs", "scratch"):
            os.makedirs(os.path.join(self.engines_dir, non_engine))
        # symlink 指向 sglang-fake → 應去重
        link = os.path.join(self.engines_dir, "sglang-link")
        os.symlink(self.sglang_dir, link)
        # 排序在實體目錄之前的 symlink (模擬 sglang-qwen < sglang-qwen-27b)
        # → 去重時應保留實體目錄 vllm-fake，而非 symlink
        early_link = os.path.join(self.engines_dir, "aaa-link")
        os.symlink(self.vllm_dir, early_link)

        with patch.object(grc, "PROJECT_ROOT", self.test_dir):
            dirs = grc.get_engine_dirs()
        names = sorted(os.path.basename(d) for d in dirs)
        self.assertIn("sglang-fake", names)
        self.assertIn("vllm-fake", names)
        self.assertIn("new-engine", names, "只含 config.env.example 之子目錄應視為引擎")
        self.assertNotIn("_template", names, "無設定檔之子目錄不應被掃入")
        self.assertNotIn("docs", names, "無設定檔之子目錄不應被掃入")
        self.assertNotIn("scratch", names, "無設定檔之子目錄不應被掃入")
        self.assertNotIn("sglang-link", names, "symlink 應以 realpath 去重")
        self.assertNotIn("aaa-link", names, "排序在前的 symlink 不應取代實體目錄")
        reals = [os.path.realpath(d) for d in dirs]
        self.assertEqual(len(reals), len(set(reals)), "symlink 未正確去重！")

        os.remove(link)
        os.remove(early_link)

    def test_legacy_scan_without_engine_dir(self):
        """legacy 端點檔無 ENGINE_DIR 時掃描 engines/ 下之引擎目錄"""
        with patch.dict(os.environ):
            self._clean_key_env()
            with patch.object(grc, "PROJECT_ROOT", self.test_dir):
                self.assertEqual(grc.get_engine_api_key("VLLM_API_KEY"), "fake-vllm-key-111")
                self.assertEqual(grc.get_engine_api_key("SGLANG_API_KEY"), "fake-sglang-key-000")
                self.assertEqual(grc.get_engine_api_key("NOT_EXIST_KEY_XYZ"), "")


class TestGeneratorMainFlow(unittest.TestCase):
    """以假引擎 config.env 與假 HTTP 端點整合測試 generator 主流程 (金鑰一律假值)"""

    EXPECTED_TOKEN = "fake-vllm-key-111"  # 測試用假金鑰 (非真實秘密)

    TEMPLATE_YAML = """model_list:
  - model_name: GLM-Test
    litellm_params:
      model: openai/GLM-Test
      api_base: https://portal.example.test/api/v1
      api_key: os.environ/NCHC_FAKE_TEST_KEY
  - model_name: Qwen-Portal-Future
    litellm_params:
      model: openai/Qwen-Portal-Future
      api_base: https://portal.example.test/api/v1
      api_key: os.environ/NCHC_FAKE_TEST_KEY
  - model_name: internal-qwen
    litellm_params:
      model: openai/internal-qwen
      api_base: os.environ/SGLANG_API_BASE
      api_key: os.environ/SGLANG_API_KEY
general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
"""

    def setUp(self):
        self.test_dir = tempfile.mkdtemp()

        # 1. 假引擎目錄 (vllm 含正確假金鑰；sglang 僅含 SGLang 假金鑰)
        self.vllm_dir = os.path.join(self.test_dir, "vllm-fake")
        self.sglang_dir = os.path.join(self.test_dir, "sglang-fake")
        os.makedirs(self.vllm_dir)
        os.makedirs(self.sglang_dir)
        with open(os.path.join(self.vllm_dir, "config.env"), "w", encoding="utf-8") as f:
            f.write(f"VLLM_API_KEY={self.EXPECTED_TOKEN}\n")
        with open(os.path.join(self.sglang_dir, "config.env"), "w", encoding="utf-8") as f:
            f.write("SGLANG_API_KEY=fake-sglang-key-000\n")

        # 2. 假 HTTP 推論端點：僅接受正確 Bearer 假金鑰，其餘回 401
        server_token = self.EXPECTED_TOKEN

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.headers.get("Authorization", "") == f"Bearer {server_token}":
                    body = b'{"object": "list", "data": [{"id": "DeepSeek-V4-Flash"}]}'
                    self.send_response(200)
                else:
                    body = b'{"object": "error", "message": "Unauthorized"}'
                    self.send_response(401)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, format, *args):
                pass

        self.httpd = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        self.server_port = self.httpd.server_port
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

        # 3. 假範本設定檔
        self.template_path = os.path.join(self.test_dir, "config.template.yaml")
        with open(self.template_path, "w", encoding="utf-8") as f:
            f.write(self.TEMPLATE_YAML)

        # 4. 將 generator 路徑常數導向暫存目錄
        self._orig_paths = (grc.TEMPLATE_CONFIG_PATH, grc.RUNTIME_CONFIG_PATH,
                            grc.ENDPOINTS_DIR, grc.PORT_LOCKS_DIR, grc.PROJECT_ROOT)
        grc.TEMPLATE_CONFIG_PATH = self.template_path
        grc.RUNTIME_CONFIG_PATH = os.path.join(self.test_dir, "config.runtime.yaml")
        grc.ENDPOINTS_DIR = os.path.join(self.test_dir, "endpoints")
        grc.PORT_LOCKS_DIR = os.path.join(self.test_dir, "port-locks")
        grc.PROJECT_ROOT = self.test_dir
        os.makedirs(grc.ENDPOINTS_DIR, exist_ok=True)
        os.makedirs(grc.PORT_LOCKS_DIR, exist_ok=True)

        # 5. 隔離環境：移除可能存在之真實金鑰變數
        self._env_patch = patch.dict(os.environ)
        self._env_patch.start()
        for k in ("SGLANG_API_KEY", "VLLM_API_KEY"):
            os.environ.pop(k, None)

    def tearDown(self):
        self._env_patch.stop()
        (grc.TEMPLATE_CONFIG_PATH, grc.RUNTIME_CONFIG_PATH,
         grc.ENDPOINTS_DIR, grc.PORT_LOCKS_DIR, grc.PROJECT_ROOT) = self._orig_paths
        self.httpd.shutdown()
        self.httpd.server_close()
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def _write_endpoint(self, filename, **overrides):
        fields = {
            "MODEL_NAME": "DeepSeek-V4-Flash",
            "MODEL_ALIAS": "deepseek-flash",
            "RESOLVED_MODEL_PATH": "/work/fake/models/DeepSeek-V4.1-Flash",
            "API_KEY_ENV": "VLLM_API_KEY",
            "ENGINE_DIR": self.vllm_dir,
            "NODE_HOSTNAME": "127.0.0.1",
            "NODE_IP": "127.0.0.1",
            "PORT": str(self.server_port),
            "ENDPOINT": f"http://127.0.0.1:{self.server_port}",
            "API_BASE": f"http://127.0.0.1:{self.server_port}/v1",
            "SLURM_JOB_ID": "12345",
            "STATE": "ready",
        }
        fields.update(overrides)
        path = os.path.join(grc.ENDPOINTS_DIR, filename)
        with open(path, "w", encoding="utf-8") as f:
            for k, v in fields.items():
                f.write(f"{k}={v}\n")
        return path

    def _runtime_model_names(self):
        with open(grc.RUNTIME_CONFIG_PATH, "r", encoding="utf-8") as f:
            cfg = yaml.safe_load(f)
        return [m["model_name"] for m in cfg["model_list"]]

    @patch("generate_runtime_config.get_job_status", return_value="RUNNING")
    def test_correct_engine_key_registers_endpoint(self, _mock):
        """API_KEY_ENV + ENGINE_DIR 取得正確引擎金鑰 → 探測通過 → 端點註冊"""
        self._write_endpoint("vllm_deepseek_12345.env")
        grc.main()
        names = self._runtime_model_names()
        self.assertIn("GLM-Test", names)               # 靜態模型保留
        self.assertIn("DeepSeek-V4-Flash", names)      # 動態端點註冊成功
        # api_key 必須維持 os.environ/XXX 引用，絕不寫入明文金鑰
        with open(grc.RUNTIME_CONFIG_PATH, "r", encoding="utf-8") as f:
            content = f.read()
        self.assertNotIn(self.EXPECTED_TOKEN, content)
        self.assertIn("os.environ/VLLM_API_KEY", content)

    @patch("generate_runtime_config.get_job_status", return_value="RUNNING")
    def test_no_fallback_to_other_engine_key(self, _mock):
        """ENGINE_DIR 所屬引擎無 API_KEY_ENV 指定之金鑰 → 探測不得攜帶其他引擎金鑰"""
        ep = self._write_endpoint("vllm_deepseek_12345.env", ENGINE_DIR=self.sglang_dir)
        with patch("generate_runtime_config.is_endpoint_alive",
                   side_effect=grc.is_endpoint_alive) as spy:
            grc.main()
        spy.assert_called_once()
        used_key = spy.call_args[0][1]
        self.assertEqual(used_key, "", "探測金鑰應為空，不得退回其他引擎 (SGLang) 之金鑰！")
        self.assertNotIn("DeepSeek-V4-Flash", self._runtime_model_names())
        self.assertTrue(os.path.exists(ep), "探測失敗之端點檔不應被刪除 (僅 INACTIVE 才清理)")

    def test_manual_endpoint_not_deleted_and_no_squeue(self):
        """manual 端點：不做 squeue 判定、不刪檔，HTTP 探測通過即納入"""
        ep = self._write_endpoint("vllm_deepseek_manual.env", SLURM_JOB_ID="manual")
        with patch("subprocess.run", side_effect=AssertionError("manual 端點不應呼叫 squeue")):
            grc.main()
        self.assertTrue(os.path.exists(ep), "manual 端點檔不應被刪除！")
        self.assertIn("DeepSeek-V4-Flash", self._runtime_model_names())

    def test_manual_endpoint_unreachable_keeps_file(self):
        """manual 端點連不上：檔案保留、不納入設定 (Fail-Closed)"""
        ep = self._write_endpoint(
            "vllm_deepseek_manual2.env", SLURM_JOB_ID="manual",
            PORT="59999", ENDPOINT="http://127.0.0.1:59999", API_BASE="http://127.0.0.1:59999/v1",
        )
        grc.main()
        self.assertTrue(os.path.exists(ep))
        self.assertNotIn("DeepSeek-V4-Flash", self._runtime_model_names())

    def test_na_legacy_endpoint_deleted(self):
        """legacy N/A 端點維持舊行為：判定 INACTIVE 並清理"""
        ep = self._write_endpoint("vllm_deepseek_na.env", SLURM_JOB_ID="N/A")
        grc.main()
        self.assertFalse(os.path.exists(ep), "legacy N/A 端點應被清理")

    @patch("generate_runtime_config.get_job_status", return_value="UNKNOWN")
    def test_unknown_exit2_and_partial_config_written(self, _mock):
        """UNKNOWN：exit 2 (部分成功)、端點檔保留、仍寫出靜態模型設定"""
        ep = self._write_endpoint("vllm_deepseek_12345.env", SLURM_JOB_ID="12345")
        with self.assertRaises(SystemExit) as ctx:
            grc.main()
        self.assertEqual(ctx.exception.code, 2)
        self.assertTrue(os.path.exists(grc.RUNTIME_CONFIG_PATH), "UNKNOWN 時仍應寫出部分成功之設定檔")
        names = self._runtime_model_names()
        self.assertIn("GLM-Test", names)
        self.assertNotIn("DeepSeek-V4-Flash", names)
        self.assertTrue(os.path.exists(ep), "UNKNOWN 端點檔不應被刪除")

    def test_static_filter_by_api_base_not_name(self):
        """靜態過濾僅依 api_base 規則：名稱含 qwen 之 Portal 模型保留、os.environ 佔位者排除"""
        grc.main()
        names = self._runtime_model_names()
        self.assertIn("Qwen-Portal-Future", names, "名稱比對已移除，Portal Qwen 模型不應被誤刪")
        self.assertIn("GLM-Test", names)
        self.assertNotIn("internal-qwen", names, "os.environ 佔位 api_base 仍應交由動態端點取代")


if __name__ == "__main__":
    unittest.main(verbosity=2)

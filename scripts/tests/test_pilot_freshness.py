import http.server
import json
import os
from pathlib import Path
import subprocess
import threading
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "check-pilot-freshness.sh"

class PilotFreshnessTest(unittest.TestCase):
    def setUp(self):
        self.requests = []
        self.status = 200
        self.body = json.dumps({"status": "ok", "reason": "current"})
        owner = self
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                owner.requests.append(self.path)
                self.send_response(owner.status)
                if owner.status == 302:
                    self.send_header("Location", "/unexpected")
                self.end_headers()
                self.wfile.write(owner.body.encode())
            def log_message(self, *args):
                pass
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def run_check(self):
        env = {**os.environ, "PILOT_FRESHNESS_URL": f"http://127.0.0.1:{self.server.server_port}/healthz/briefs"}
        result = subprocess.run(["bash", str(SCRIPT)], env=env, text=True, capture_output=True, timeout=65)
        self.assertNotIn("private-diagnostic", result.stdout + result.stderr)
        return result

    def test_healthy_probe_performs_real_request(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.requests, ["/healthz/briefs"])

    def test_degraded_probe_retries_boundedly_and_fails(self):
        self.status = 503
        self.body = json.dumps({"status": "degraded", "reason": "private-diagnostic"})
        self.assertNotEqual(self.run_check().returncode, 0)
        self.assertEqual(len(self.requests), 3)

    def test_redirect_cannot_masquerade_as_healthy(self):
        self.status = 302
        self.assertNotEqual(self.run_check().returncode, 0)
        self.assertEqual(self.requests, ["/healthz/briefs"])

    def test_wrong_or_malformed_health_body_fails(self):
        for body in ("not json private-diagnostic", '{"status":"ok"}',
                     '{"status":"degraded","reason":"current"}', '[]'):
            with self.subTest(body=body):
                self.body = body
                self.assertNotEqual(self.run_check().returncode, 0)

"""Run the real release script against a local API and a recording cloud CLI."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


SCRIPT = Path(__file__).resolve().parents[1] / "deploy-daily-agent.sh"
TOKEN = "test-pipeline-token"
ENGINEERING = {
    "slug": "engineering", "name": "Engineering", "description": None,
    "topics": [], "sources": [], "is_active": True,
}


class DeployDailyAgentTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.events = self.root / "events.jsonl"
        self.health = (200, {"status": "ok", "db": "ok"})
        self.feeds = (200, [ENGINEERING])
        self.secret_failure = False
        self.build_failure = False
        test = self

        class API(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                test.record(["http", self.path])
                if self.path == "/healthz":
                    status, body = test.health
                elif self.path == "/internal/feeds":
                    if self.headers.get("Authorization") != f"Bearer {TOKEN}":
                        status, body = 401, {"error": "unauthorized"}
                    else:
                        status, body = test.feeds
                else:
                    status, body = 404, {}
                self.send_response(status)
                self.end_headers()
                self.wfile.write((body if isinstance(body, str) else json.dumps(body)).encode())

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), API)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        fake = self.root / "gcloud"
        fake.write_text("""#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ['TEST_EVENTS'], 'a') as f:
    f.write(json.dumps(['gcloud', *args]) + '\\n')
if args[:3] == ['secrets', 'versions', 'access']:
    if os.environ['TEST_SECRET_FAILURE'] == 'true':
        sys.exit(1)
    print(os.environ['TEST_TOKEN'])
elif args[:2] == ['builds', 'submit'] and os.environ['TEST_BUILD_FAILURE'] == 'true':
    sys.exit(1)
""")
        fake.chmod(0o755)

    def record(self, event):
        with self.events.open("a") as f:
            f.write(json.dumps(event) + "\n")

    def run_deploy(self, enabled="false"):
        self.events.write_text("")
        env = {**os.environ, "PATH": f"{self.root}:{os.environ['PATH']}",
               "PROJECT_ID": "test-project", "REGION": "test-region",
               "REPO_NAME": "test-repo", "IMAGE_TAG": "test-revision",
               "PULSE_API_URL": f"http://127.0.0.1:{self.server.server_port}",
               "TEST_EVENTS": str(self.events), "TEST_TOKEN": TOKEN,
               "TEST_SECRET_FAILURE": str(self.secret_failure).lower(),
               "TEST_BUILD_FAILURE": str(self.build_failure).lower()}
        env.pop("PULSE_API_ENABLED", None)
        env.pop("GITHUB_ACTIONS", None)
        if enabled is not None:
            env["PULSE_API_ENABLED"] = enabled
        result = subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True,
                                text=True, timeout=20)
        events = [json.loads(line) for line in self.events.read_text().splitlines()]
        self.assertNotIn(TOKEN, result.stdout + result.stderr)
        return result, events

    def assert_no_mutations(self, events):
        self.assertFalse([e for e in events if e[:2] in
                          (["gcloud", "builds"], ["gcloud", "run"])], events)

    def test_disabled_or_unset_keeps_gcp_independent_of_api_and_secret(self):
        self.secret_failure = True
        self.health = (503, {})
        for enabled in (None, "", "false"):
            with self.subTest(enabled=enabled):
                result, events = self.run_deploy(enabled)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse([e for e in events if e[:2] in
                                  (["http", "/healthz"], ["gcloud", "secrets"])])
                deploys = [e for e in events if e[:4] == ["gcloud", "run", "jobs", "deploy"]]
                self.assertEqual(len(deploys), 1)
                args = deploys[0]
                self.assertIn("ANTHROPIC_API_KEY=anthropic-api-key:latest,OPENAI_API_KEY=openai-api-key:latest", args)
                self.assertFalse(any("pipeline-service-token" in arg for arg in args))
                self.assertTrue(any("PULSE_API_URL" in arg for arg in args
                                    if arg.startswith("--remove-env-vars=")))

    def test_ready_api_is_checked_before_any_cloud_mutation(self):
        result, events = self.run_deploy("true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events[0][:4], ["gcloud", "secrets", "versions", "access"])
        self.assertEqual(events[1:3], [["http", "/healthz"], ["http", "/internal/feeds"]])
        self.assertEqual(events[3][:3], ["gcloud", "builds", "submit"])
        self.assertEqual(events[4][:4], ["gcloud", "run", "jobs", "deploy"])
        self.assertEqual(len(events), 5, "No separate credential-clearing job update")
        self.assertIn("ANTHROPIC_API_KEY=anthropic-api-key:latest,OPENAI_API_KEY=openai-api-key:latest,PIPELINE_SERVICE_TOKEN=pipeline-service-token:latest", events[4])
        self.assertTrue(any(f"PULSE_API_URL=http://127.0.0.1:{self.server.server_port}" in arg for arg in events[4]))

    def test_unready_api_never_changes_running_job(self):
        cases = [
            ("unseeded", []),
            ("inactive", [{**ENGINEERING, "is_active": False}]),
            ("wrong-feed", [{**ENGINEERING, "slug": "other"}]),
            ("extra-feed", [ENGINEERING, {**ENGINEERING, "slug": "other"}]),
            ("wrong-shape", {"feeds": [ENGINEERING]}),
            ("malformed", "not json"),
        ]
        for label, body in cases:
            with self.subTest(case=label):
                self.feeds = (200, body)
                result, events = self.run_deploy("true")
                self.assertNotEqual(result.returncode, 0)
                self.assert_no_mutations(events)

    def test_auth_or_route_failure_never_changes_running_job(self):
        for status in (301, 401, 403, 404, 500):
            with self.subTest(status=status):
                self.feeds = (status, [ENGINEERING])
                result, events = self.run_deploy("true")
                self.assertNotEqual(result.returncode, 0)
                self.assert_no_mutations(events)

    def test_unhealthy_db_or_invalid_health_response_blocks_deployment(self):
        for response in ((503, {}), (200, {"status": "ok", "db": "error"}),
                         (200, "not json"), (302, {"status": "ok", "db": "ok"})):
            with self.subTest(response=response):
                self.health = response
                result, events = self.run_deploy("true")
                self.assertNotEqual(result.returncode, 0)
                self.assert_no_mutations(events)

    def test_missing_secret_blocks_deployment(self):
        self.secret_failure = True
        result, events = self.run_deploy("true")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_mutations(events)

    def test_invalid_switch_does_not_silently_disable_integration(self):
        result, events = self.run_deploy("TRUE")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, [])

    def test_failed_build_leaves_running_job_untouched(self):
        self.build_failure = True
        result, events = self.run_deploy("true")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse([e for e in events if e[:2] == ["gcloud", "run"]])

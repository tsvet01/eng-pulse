import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import sys
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "release_selection.py"
SPEC = importlib.util.spec_from_file_location("release_selection", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ReleaseSelectionTest(unittest.TestCase):
    def select(self, event="workflow_dispatch", api_changed=True, agents_changed=True,
               request_api=False, request_agents=False):
        return MODULE.release_targets(event, api_changed=api_changed,
                                      agents_changed=agents_changed,
                                      request_api=request_api, request_agents=request_agents)

    def test_agent_only_dispatch_can_disable_integration_after_an_api_changing_commit(self):
        self.assertEqual(self.select(request_agents=True),
                         {"deploy_api": False, "deploy_agents": True})

    def test_api_only_dispatch_does_not_redeploy_agents_from_last_commit(self):
        self.assertEqual(self.select(request_api=True),
                         {"deploy_api": True, "deploy_agents": False})

    def test_unselected_dispatch_never_deploys(self):
        self.assertEqual(self.select(), {"deploy_api": False, "deploy_agents": False})

    def test_combined_dispatch_selects_both_even_without_changed_files(self):
        self.assertEqual(self.select(api_changed=False, agents_changed=False,
                                     request_api=True, request_agents=True),
                         {"deploy_api": True, "deploy_agents": True})

    def test_push_uses_changed_targets(self):
        self.assertEqual(self.select(event="push", api_changed=False),
                         {"deploy_api": False, "deploy_agents": True})
        self.assertEqual(self.select(event="push", agents_changed=False),
                         {"deploy_api": True, "deploy_agents": False})
        self.assertEqual(self.select(event="push"),
                         {"deploy_api": True, "deploy_agents": True})

    def test_api_direct_dependency_edit_only_skips_agent_deployment(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            path = repo / "Cargo.lock"
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=repo, text=True).strip()

            git("init", "-q")
            original = ('version = 4\n[[package]]\nname = "pulse-api"\nversion = "0.1.0"\n'
                        'dependencies = ["shared"]\n[[package]]\nname = "base64"\nversion = "0.22.1"\n'
                        '[[package]]\nname = "shared"\nversion = "1.0.0"\n')
            path.write_text(original)
            git("add", "Cargo.lock")
            git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "initial")
            base = git("rev-parse", "HEAD")
            env = {**os.environ, "RELEASE_EVENT": "push", "API_CHANGED": "true", "AGENTS_CHANGED": "true",
                   "ONLY_AGENT_LOCKFILE": "true", "RELEASE_BASE": base}
            update = original.replace('["shared"]', '["base64", "shared"]')
            for contents, only_lock, want_agents in (
                (update, "true", False),
                (update, "false", True),  # an agent source or manifest also changed
                (update.replace('version = "1.0.0"', 'version = "1.0.1"'), "true", True),
                (update.replace('name = "pulse-api"', 'name = "renamed"'), "true", True),
                (update + 'dependencies = ["pulse-api"]\n', "true", True),
                ("truncated [", "true", True),
                (update.replace("version = 4", "version = 5"), "true", True),
                (update.replace('["base64", "shared"]', '7'), "true", True),
            ):
                with self.subTest(contents=contents, only_lock=only_lock):
                    path.write_text(contents)
                    result = subprocess.run([sys.executable, str(SCRIPT)], cwd=repo, text=True, capture_output=True,
                                            env={**env, "ONLY_AGENT_LOCKFILE": only_lock}, check=True)
                    self.assertEqual(result.stdout, f"deploy_api=true\ndeploy_agents={str(want_agents).lower()}\n")

            # Even an indirect agent dependency on the API invalidates the exception.
            edge = '[[package]]\nname = "consumer"\nversion = "0.1.0"\ndependencies = ["pulse-api 0.1.0"]\n'
            path.write_text(original + edge)
            git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qam", "add consumer")
            path.write_text(update + edge)
            result = subprocess.run([sys.executable, str(SCRIPT)], cwd=repo, text=True, capture_output=True,
                                    env={**env, "RELEASE_BASE": git("rev-parse", "HEAD")}, check=True)
            self.assertIn("deploy_agents=true", result.stdout)

    def test_unavailable_base_keeps_the_normal_agent_release(self):
        for base in (None, "0" * 40, "missing-release-before-sha"):
            with self.subTest(base=base):
                self.assertFalse(MODULE.api_only_lock_update(base))

    def test_cli_outputs_manual_selection_despite_true_change_flags(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT)], text=True, capture_output=True, check=True,
            env={**os.environ, "RELEASE_EVENT": "workflow_dispatch", "API_CHANGED": "true",
                 "AGENTS_CHANGED": "true", "REQUEST_API": "false", "REQUEST_AGENTS": "true"})
        self.assertEqual(result.stdout, "deploy_api=false\ndeploy_agents=true\n")

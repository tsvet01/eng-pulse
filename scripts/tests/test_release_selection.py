import importlib.util
import os
from pathlib import Path
import subprocess
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

    def test_cli_outputs_manual_selection_despite_true_change_flags(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT)], text=True, capture_output=True, check=True,
            env={**os.environ, "RELEASE_EVENT": "workflow_dispatch", "API_CHANGED": "true",
                 "AGENTS_CHANGED": "true", "REQUEST_API": "false", "REQUEST_AGENTS": "true"})
        self.assertEqual(result.stdout, "deploy_api=false\ndeploy_agents=true\n")

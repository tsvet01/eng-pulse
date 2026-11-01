"""Exercise the report with historical and promoted production model IDs."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "shadow-eval-report.sh"


class ShadowEvalReportTest(unittest.TestCase):
    def test_reports_old_and_new_production_and_pairwise_winners(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            curl = root / "curl"
            curl.write_text('#!/bin/sh\ncat "$TEST_REPORT"\n')
            curl.chmod(0o755)
            report = root / "report.json"
            env = {**os.environ, "PATH": f"{root}:{os.environ['PATH']}",
                   "TEST_REPORT": str(report)}
            for prod_id in ("v3-claude", "v3-gpt"):
                for winner, label in ((prod_id, "prod"), ("v3-shadow", "SHADOW"), ("tie", "tie")):
                    with self.subTest(prod_id=prod_id, winner=winner):
                        report.write_text(json.dumps({
                            "scores": [{"summary_id": sid, "key_idea_clarity": 5,
                                        "why_it_matters_relevance": 5, "deep_dive_depth": 5,
                                        "action_quality": 5} for sid in ("v3-shadow", prod_id)],
                            "pairwise_winner": winner,
                        }))
                        result = subprocess.run(["bash", str(SCRIPT), "1"], env=env,
                                                capture_output=True, text=True, check=True)
                        self.assertIn(f"prod=5.0  shadow=5.0  winner={label}", result.stdout)

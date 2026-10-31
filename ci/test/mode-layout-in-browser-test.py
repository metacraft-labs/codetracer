"""Check the browser gate's verdicts using supplied measurement reports.

Synthetic reports isolate the gate's parser/verdict contract; the browser probe
and Electron regressions separately exercise the product without these fixtures.
"""

import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


GATE = Path(__file__).with_name("mode-layout-in-browser.sh")
LEGS = (
    "boot", "debug", "edit", "debug-trip2", "edit-trip2", "debug-trip3",
    "edit-trip3", "after-drag", "after-reload", "after-corrupt",
    "after-corrupt-debug",
)


def report():
    legs = []
    for name in LEGS:
        debug = "debug" in name
        titles = ["FILES", "TESTS", "VCS", "src/main.nr"]
        titles += ["VARIABLES", "EVENT LOG"] if debug else ["CONSTRAINTS"]
        strips = {
            title: {"present": True, "stackKey": "files" if title in
                    ("FILES", "TESTS", "VCS") else title,
                    "stackBox": {"w": 400}, "exiled": []}
            for title in titles
        }
        legs.append({
            "leg": name, "goldenLayoutPresent": True,
            "allTabTitles": titles, "strips": strips,
            "stackCount": 5 if debug else 3,
            "contentBoxes": {"filesystem": {"w": 400, "h": 800},
                             "editor": {"w": 800, "h": 800}},
            "editorLines": 6,
        })
    return {"legs": legs, "arms": {
        "drag": {"ok": True, "moved": True, "before": 240, "after": 400},
        "corruptWritten": {"wrote": 2},
    }}


class BrowserGateVerdicts(unittest.TestCase):
    def run_gate(self, data):
        import os
        with tempfile.TemporaryDirectory(prefix="ct-mode-report-") as scratch:
            fixture = Path(scratch) / "report.json"
            fixture.write_text(json.dumps(data))
            return subprocess.run(
                ["bash", str(GATE)], text=True, capture_output=True,
                env={**os.environ, "CT_MODE_LAYOUT_REPORT": str(fixture)},
            )

    def test_painted_source_survives_every_leg(self):
        result = self.run_gate(report())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_each_debug_leg_refuses_missing_source_or_paint(self):
        for name in (leg for leg in LEGS if "debug" in leg):
            for defect in ("missing-tab", "zero-height", "no-lines"):
                with self.subTest(leg=name, defect=defect):
                    data = copy.deepcopy(report())
                    leg = next(item for item in data["legs"] if item["leg"] == name)
                    if defect == "missing-tab":
                        leg["allTabTitles"].remove("src/main.nr")
                    elif defect == "zero-height":
                        leg["contentBoxes"]["editor"]["h"] = 0
                    else:
                        leg["editorLines"] = 0
                    result = self.run_gate(data)
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn(name, result.stdout)
                    self.assertIn("[FAILED]", result.stdout)
                    self.assertNotIn("[SKIPPED]", result.stdout)


if __name__ == "__main__":
    unittest.main()

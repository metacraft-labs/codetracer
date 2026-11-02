"""Real FLIP integration over small synthetic PNGs, with no mocked oracle.

Synthetic uniform frames isolate capture stability from OS/window permissions;
black versus white is visibly different, identical independently acquired frames
are valid, and an alpha-only change is below FLIP's perceptual threshold.
"""
import hashlib
import json
import os
import pathlib
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

from plat37_parity import Flip, grade
from plat37_parity_capture import fingerprint

ROOT = pathlib.Path(__file__).resolve().parents[2]
LIBRARY = pathlib.Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else ROOT / "build/plat37-stability/flip.dylib"


def png(path, color):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    width = height = 32
    raw = (b"\0" + bytes(color) * width) * height
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


class Stability(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.flip = Flip(LIBRARY)

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="plat37-parity-")
        self.addCleanup(self.scratch.cleanup)
        self.path = pathlib.Path(self.scratch.name)
        self.records = []
        for renderer in ("electron", "gpui"):
            for n in range(2):
                path = self.path / f"{renderer}-{n}.png"
                png(path, [0, 0, 0, 255])
                self.records.append(dict(captureId=f"{renderer}-{n}", renderer=renderer,
                                         view="eventLog", scenario="continued-event-log", viewport="wide",
                                         build=f"{renderer}-binary-sha256", outcome="captured",
                                         png=str(path), imageSha1=hashlib.sha1(path.read_bytes()).hexdigest(), sha256=hashlib.sha256(path.read_bytes()).hexdigest()))

    def report(self):
        return grade(self.records, self.flip)

    def assert_refused(self, report, reason):
        self.assertEqual(report["verdict"], "REFUSED", report)
        self.assertIn(reason, report["reason"])
        self.assertNotIn("views", report)
        self.assertNotIn("meanFracOver0_10", report)

    def change(self, n, color):
        path = pathlib.Path(self.records[n]["png"])
        png(path, color)
        self.records[n]["imageSha1"] = hashlib.sha1(path.read_bytes()).hexdigest()
        self.records[n]["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()

    def test_independent_identical_captures_allow_scalar(self):
        report = self.report()
        self.assertEqual(report["verdict"], "OK", report)
        self.assertEqual(len(report["stability"]), 2)
        self.assertEqual(report["meanFracOver0_10"], 0)

    def test_visible_electron_drift_refuses_scalar_and_mean(self):
        self.change(1, [255, 255, 255, 255])
        report = self.report()
        self.assert_refused(report, "disagree above JND")
        self.assertGreater(report["stability"][0]["fracOver0_10"], 0.5)

    def test_visible_gpui_drift_also_refuses(self):
        self.change(3, [255, 255, 255, 255])
        self.assert_refused(self.report(), "disagree above JND")

    def test_alpha_only_drift_is_below_jnd(self):
        self.change(1, [0, 0, 0, 128])
        self.assertEqual(self.report()["verdict"], "OK")

    def test_regrading_copy_is_not_an_independent_capture(self):
        self.records[1]["captureId"] = self.records[0]["captureId"]
        self.assert_refused(self.report(), "reused")

    def test_single_capture_refuses(self):
        del self.records[1]
        self.assert_refused(self.report(), "at least two")

    def test_every_pair_is_graded(self):
        copy = self.path / "electron-third.png"
        copy.write_bytes(pathlib.Path(self.records[1]["png"]).read_bytes())
        extra = dict(self.records[1], captureId="electron-third", png=str(copy))
        self.records.append(extra)
        self.assertEqual(len(self.report()["stability"]), 4)
        self.change(4, [255, 255, 255, 255])
        self.assert_refused(self.report(), "disagree above JND")

    def test_changed_build_refuses(self):
        self.records[1]["build"] = "different-build"
        self.assert_refused(self.report(), "build/scenario/viewport changed")

    def test_alternate_playwright_executable_cannot_borrow_bundle_identity(self):
        # Real temporary files exercise the environment/path boundary; no
        # renderer process or FLIP implementation is replaced.
        bundle = self.path / "bundle"
        (bundle / "bin").mkdir(parents=True)
        for name in ("bin/ct", "index.js", "ui.js"):
            (bundle / name).write_bytes(name.encode())
        alias = self.path / "ct-alias"
        alias.symlink_to(bundle / "bin/ct")
        keys = ("CODETRACER_E2E_CT_PATH", "CODETRACER_BUILD_DIR")
        previous = {key: os.environ.get(key) for key in keys}
        os.environ["CODETRACER_BUILD_DIR"] = str(bundle)
        try:
            os.environ["CODETRACER_E2E_CT_PATH"] = str(alias)
            self.assertEqual(len(fingerprint("electron")), 64)
            os.environ["CODETRACER_E2E_CT_PATH"] = str(self.path / "alternate-ct")
            with self.assertRaisesRegex(ValueError, "disagrees with CODETRACER_BUILD_DIR"):
                fingerprint("electron")
        finally:
            for key, value in previous.items():
                if value is None:
                    del os.environ[key]
                else:
                    os.environ[key] = value

    def test_cross_renderer_viewports_must_match_even_at_equal_pixel_extent(self):
        for record in self.records:
            if record["renderer"] == "gpui":
                record["viewport"] = "different-point-viewport"
        self.assert_refused(self.report(), "renderer scenarios/viewports disagree")

    def test_replaced_png_refuses(self):
        png(pathlib.Path(self.records[1]["png"]), [255, 255, 255, 255])
        self.assert_refused(self.report(), "digest disagrees")

    def test_cli_overwrites_previous_scalar_on_refusal(self):
        manifest, output = self.path / "captures.json", self.path / "grade.json"
        manifest.write_text(json.dumps(self.records))
        command = [sys.executable, str(ROOT / "ci/test/plat37_parity.py"), "--captures", str(manifest),
                   "--flip-library", str(LIBRARY), "--output", str(output)]
        self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
        self.assertIn("views", json.loads(output.read_text()))
        self.change(1, [255, 255, 255, 255])
        manifest.write_text(json.dumps(self.records))
        self.assertEqual(subprocess.run(command, capture_output=True).returncode, 1)
        self.assert_refused(json.loads(output.read_text()), "disagree above JND")

    def test_scenario_and_viewport_must_agree_between_arms(self):
        for field in ("scenario", "viewport"):
            saved = [r[field] for r in self.records]
            self.records[2][field] = self.records[3][field] = "other"
            self.assert_refused(self.report(), "renderer scenarios/viewports disagree")
            for record, value in zip(self.records, saved):
                record[field] = value

    def test_no_aggregate_escapes_when_another_view_is_stable(self):
        for n, original in enumerate(list(self.records)):
            self.records.append(dict(original, captureId=f"shell-{n}", view="shell"))
        self.change(1, [255, 255, 255, 255])
        self.assert_refused(self.report(), "disagree above JND")

    def test_invalid_evidence_overwrites_previous_scalar(self):
        manifest, output = self.path / "captures.json", self.path / "grade.json"
        command = [sys.executable, str(ROOT / "ci/test/plat37_parity.py"), "--captures", str(manifest),
                   "--flip-library", str(LIBRARY), "--output", str(output)]
        for invalid in (None, {}, [None], "malformed"):
            output.write_text(json.dumps({"verdict": "OK", "views": {}, "meanFracOver0_10": 0}))
            manifest.write_text(json.dumps(invalid))
            result = subprocess.run(command, capture_output=True)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(json.loads(output.read_text())["verdict"], "REFUSED")
            self.assertNotIn("views", json.loads(output.read_text()))
        path = pathlib.Path(self.records[0]["png"])
        path.write_bytes(b"\x89PNG\r\n\x1a\n")
        self.records[0]["imageSha1"] = hashlib.sha1(path.read_bytes()).hexdigest()
        self.records[0]["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        output.write_text(json.dumps({"verdict": "OK", "views": {}}))
        manifest.write_text(json.dumps(self.records))
        result = subprocess.run(command, capture_output=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assert_refused(json.loads(output.read_text()), "truncated PNG")

    def test_original_single_capture_flip_is_a_coin_flip(self):
        # Positive control of the actual historical grading operation: direct
        # FLIP over one Electron frame versus a fixed GPUI frame computes a
        # scalar for either branch, even though the build has not changed.
        from plat37_parity import read_frame
        self.change(1, [255, 255, 255, 255])
        a, width, height = read_frame(self.records[0])
        b, _, _ = read_frame(self.records[1])
        gpui, _, _ = read_frame(self.records[2])
        old_a = self.flip(a, gpui, width, height)["fracOver0_10"]
        old_b = self.flip(b, gpui, width, height)["fracOver0_10"]
        self.assertEqual(old_a, 0)
        self.assertGreater(old_b, 0.5)
        self.assert_refused(self.report(), "disagree above JND")


if __name__ == "__main__":
    unittest.main()

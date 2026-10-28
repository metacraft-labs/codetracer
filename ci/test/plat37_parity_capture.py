"""Acquire two fresh observations of each renderer, then run the parity gate."""
import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import uuid

from plat37_parity import Flip, grade

ROOT = pathlib.Path(__file__).resolve().parents[2]


def fingerprint(renderer):
    """Identify the actual executable/renderer bytes, including the native shim."""
    if renderer == "electron":
        build = pathlib.Path(os.environ.get("CODETRACER_BUILD_DIR", ROOT / "src/build-debug-repro"))
        paths = [build / "bin/ct", build / "index.js", build / "ui.js"]
        # Playwright's launch override must identify the same executable as
        # the bundle whose bytes and freshness this lane records.
        override = os.environ.get("CODETRACER_E2E_CT_PATH")
        if override and pathlib.Path(override).resolve() != paths[0].resolve():
            raise ValueError("CODETRACER_E2E_CT_PATH disagrees with CODETRACER_BUILD_DIR/bin/ct")
    else:
        sibling = pathlib.Path(os.environ.get("ISONIM_GPUI", ROOT.parent / "isonim-gpui"))
        paths = [ROOT / "build/bin/codetracer-gpui",
                 sibling / "rust/target/plat37/libgpui_nim_shim.windowed.dylib"]
    digest = hashlib.sha256()
    for path in paths:
        digest.update(str(path.resolve()).encode())
        if not path.is_file():
            remedy = "just build-once" if renderer == "electron" else "just build-gpui; build isonim-gpui windowed shim with just plat37-shims"
            raise ValueError(f"{renderer} binary prerequisite missing: {path}. Run {remedy} before capturing")
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
    return digest.hexdigest()


def capture(out, only):
    """Each invocation drives a new process from the scenario's initial state."""
    definition = json.loads((ROOT / "src/tests/visual/scenarios.json").read_text())
    expected = {s["view"] for s in definition["scenarios"] if only is None or s["view"] == only}
    if not expected:
        raise ValueError("unknown view")
    records = []
    for renderer in ("electron", "gpui"):
        script = "plat37-macos-electron-capture.sh" if renderer == "electron" else "plat37-macos-window-capture.sh"
        build = fingerprint(renderer)
        for n in range(2):
            directory = out / f"{renderer}-{n + 1}"
            args = ["bash", str(ROOT / "ci/test" / script), "--out", str(directory)]
            if only is not None:
                args += ["--only", only]
            # Each independent app launch gets its own first-run state. Never
            # let a raw GPUI lane rewrite the operator's profile or layout.
            with tempfile.TemporaryDirectory(prefix="plat37-home-") as home:
                env = dict(os.environ, CODETRACER_PARITY_BUILD=build,
                           CODETRACER_HOME=home, CODETRACER_TUI_LAYOUT_DIR=str(pathlib.Path(home) / "layout"))
                subprocess.run(args, cwd=ROOT, env=env, check=True)
            if fingerprint(renderer) != build:
                raise ValueError(f"{renderer} build changed during capture")
            observed = []
            for line in (directory / "records.jsonl").read_text().splitlines():
                record = json.loads(line)
                if record.get("laneVerdict") != "OK" or record.get("build") != build:
                    raise ValueError(f"{renderer}: capture lane refused frame or build identity")
                record["renderer"] = renderer
                record["viewport"] = json.dumps(record["requestedPoints"], sort_keys=True)
                # Electron window has no title bar; GPUI's attested chrome crop
                # is allowed only for cross-renderer content comparison.
                if renderer == "electron":
                    record["cropPx"] = 0
                record["png"] = str(pathlib.Path(record["png"]).resolve())
                record["sha256"] = hashlib.sha256(pathlib.Path(record["png"]).read_bytes()).hexdigest()
                records.append(record)
                observed.append(record["view"])
            if set(observed) != expected or len(observed) != len(expected):
                raise ValueError(f"{renderer}: missing or duplicate scenario capture")
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=pathlib.Path, default=ROOT / "build/plat37-parity")
    parser.add_argument("--only")
    parser.add_argument("--flip-library", type=pathlib.Path, required=True)
    args = parser.parse_args()
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=True)
    report_path = args.out / "grade.json"
    # Replace a stale successful grade before any build/capture can fail.
    report_path.write_text(json.dumps({"verdict": "REFUSED", "reason": "capture incomplete"}) + "\n")
    run = args.out / str(uuid.uuid4())
    run.mkdir()
    try:
        records = capture(run, args.only)
        manifest = run / "captures.json"
        manifest.write_text(json.dumps(records, indent=2) + "\n")
        report = grade(records, Flip(args.flip_library))
        report["captureManifest"] = str(manifest)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        report = {"verdict": "REFUSED", "reason": str(error)}
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    return 0 if report["verdict"] == "OK" else 1


if __name__ == "__main__":
    sys.exit(main())

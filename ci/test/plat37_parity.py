"""Grade independently captured renderer frames through the real FLIP oracle.

Capture producers remain useful on their own for OCR diagnostics. Only this
entry point emits parity scalars: stability is checked before any cross-arm
comparison, including when preserved captures are graded again.
"""
import argparse
import ctypes
import hashlib
import itertools
import json
import pathlib
import struct
import subprocess
import sys


class Refused(ValueError):
    """The supplied captures cannot support a parity scalar."""


class Flip:
    """Bind the existing codetracer-image-diff C ABI; never reimplement FLIP."""
    def __init__(self, library):
        self.lib = ctypes.CDLL(str(library))
        self.lib.ct_flip_compute.argtypes = [ctypes.c_char_p, ctypes.c_char_p,
                                            ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                            ctypes.POINTER(ctypes.POINTER(ctypes.c_float))]
        self.lib.ct_flip_compute.restype = ctypes.c_int
        self.free = ctypes.CDLL(None).free
        self.free.argtypes = [ctypes.c_void_p]

    def __call__(self, a, b, width, height):
        result = ctypes.POINTER(ctypes.c_float)()
        rc = self.lib.ct_flip_compute(a, b, width, height, 4, ctypes.byref(result))
        if rc or not result:
            raise Refused(f"FLIP failed ({rc})")
        try:
            count = width * height
            over = sum(result[i] > 0.1 for i in range(count))
            return {"fracOver0_10": over / count,
                    "maxError": max(result[i] for i in range(count))}
        finally:
            self.free(result)


def read_frame(record):
    path = pathlib.Path(record["png"])
    data = path.read_bytes()
    if hashlib.sha1(data).hexdigest().upper() != record["imageSha1"].upper():
        raise Refused(f"source capture digest disagrees: {path}")
    if hashlib.sha256(data).hexdigest() != record["sha256"]:
        raise Refused(f"capture digest disagrees: {path}")
    if (len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n"
            or data[8:16] != b"\0\0\0\rIHDR"):
        raise Refused(f"missing or truncated PNG IHDR: {path}")
    width, height = struct.unpack(">II", data[16:24])
    if width == 0 or height == 0:
        raise Refused(f"empty PNG extent: {path}")
    rgba = subprocess.check_output(["ffmpeg", "-v", "error", "-threads", "1",
                                    "-i", str(path), "-f", "rawvideo",
                                    "-pix_fmt", "rgba", "-threads", "1", "-"])
    if len(rgba) != width * height * 4:
        raise Refused(f"decoded extent disagrees: {path}")
    return rgba, width, height


def grade(records, compare):
    """All-or-nothing report: no view scalar or aggregate survives a refusal."""
    diagnostics = []
    try:
        if not isinstance(records, list):
            raise Refused("capture manifest must be a list")
        groups = {}
        identities = set()
        for record in records:
            if not isinstance(record, dict):
                raise Refused("capture record must be an object")
            identity = record.get("captureId")
            if not identity or identity in identities:
                raise Refused("reused or missing independent captureId")
            identities.add(identity)
            if record.get("outcome") != "captured" or not record.get("build"):
                raise Refused("capture lacks successful outcome or build identity")
            key = (record["view"], record["renderer"])
            if key[1] not in ("electron", "gpui"):
                raise Refused("unknown renderer")
            groups.setdefault(key, []).append(record)
        views = sorted({key[0] for key in groups})
        if not views:
            raise Refused("no captures")
        frames = {}
        for view in views:
            for renderer in ("electron", "gpui"):
                captures = groups.get((view, renderer), [])
                if len(captures) < 2:
                    raise Refused(f"{view}/{renderer}: at least two independent captures required")
                # Build and scenario equality apply within a renderer; the two
                # renderers naturally have different binary identities.
                signatures = {(r["build"], r["scenario"], r["viewport"]) for r in captures}
                if len(signatures) != 1:
                    raise Refused(f"{view}/{renderer}: build/scenario/viewport changed")
                decoded = [read_frame(r) for r in captures]
                if len({(f[1], f[2]) for f in decoded}) != 1:
                    raise Refused(f"{view}/{renderer}: capture extents changed")
                for a, b in itertools.combinations(range(len(captures)), 2):
                    frame = decoded[a]
                    metric = compare(frame[0], decoded[b][0], frame[1], frame[2])
                    diagnostics.append({"view": view, "renderer": renderer,
                                        "captures": [captures[a]["captureId"], captures[b]["captureId"]],
                                        **metric})
                    if metric["fracOver0_10"] > 0:
                        raise Refused(f"{view}/{renderer}: independent captures disagree above JND")
                frames[(view, renderer)] = decoded[0]
                if len({r.get("cropPx", 0) for r in captures}) != 1:
                    raise Refused(f"{view}/{renderer}: crop changed")
            if any(groups[(view, "electron")][0][field] != groups[(view, "gpui")][0][field]
                   for field in ("scenario", "viewport")):
                raise Refused(f"{view}: renderer scenarios/viewports disagree")
        # Scalar production is deliberately after the entire stability gate.
        scalars = {}
        for view in views:
            pair = []
            for renderer in ("electron", "gpui"):
                rgba, width, height = frames[(view, renderer)]
                crop = groups[(view, renderer)][0].get("cropPx", 0)
                if type(crop) is not int or not 0 <= crop < height:
                    raise Refused("invalid content crop")
                pair.append((rgba[crop * width * 4:], width, height - crop))
            if pair[0][1:] != pair[1][1:]:
                raise Refused(f"{view}: cross-renderer content extents disagree")
            scalars[view] = compare(pair[0][0], pair[1][0], *pair[0][1:])
        return {"verdict": "OK", "stability": diagnostics, "captures": records,
                "independentCaptureCounts": {view: {renderer: len(groups[(view, renderer)])
                                                  for renderer in ("electron", "gpui")} for view in views},
                "views": scalars,
                "meanFracOver0_10": sum(x["fracOver0_10"] for x in scalars.values()) / len(scalars)}
    except (Refused, KeyError, TypeError, AttributeError, struct.error, OSError, ValueError, subprocess.CalledProcessError) as error:
        return {"verdict": "REFUSED", "reason": str(error), "stability": diagnostics}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--captures", type=pathlib.Path, required=True)
    parser.add_argument("--flip-library", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    # Invalidate before parsing or loading the oracle: malformed evidence
    # must not leave an earlier scalar report current.
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"verdict": "REFUSED", "reason": "grading incomplete"}) + "\n")
    try:
        report = grade(json.loads(args.captures.read_text()), Flip(args.flip_library))
    except (OSError, ValueError, TypeError, AttributeError) as error:
        report = {"verdict": "REFUSED", "reason": str(error)}
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    return 0 if report["verdict"] == "OK" else 1


if __name__ == "__main__":
    sys.exit(main())

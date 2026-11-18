"""mutation_views.py — the part of a file a mutation harness's suites read.

A harness digests every file its suites read, so that an edit to one while the
harness is live is a refusal rather than a grade against moving bytes
(Verification-Harness-Traps §32). Some of those files are large shared ones,
such as the CI workflow and the justfile, and the suite reads a few facts out
of them. Digesting the whole file made the harness owe a re-grade for every
pin bump in the workflow, which a day of sibling bumps turned into a re-grade
per bump, while nothing the suite reads had moved.

A control entry may therefore name a VIEW of a file instead of the file:

    <sha256>  .github/workflows/codetracer.yml#plat33-collab-lanes

and the digest is the SHA-256 of the view's text. The view states exactly what
the suite reads, as the suite reads it (`find`, `contains`), so an edit that
can change the suite's verdict changes the view, and nothing else does.

One definition, two readers: the harness (`digest()`) and
`ci/test/mutation-control-drift.sh` both call `view_text`. The gate runs this
file as a script (`python3 mutation_views.py --sha256 <file> <view>`, the
digest on stdout), so the two cannot disagree about a view.
"""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path

SEPARATOR = "#"

PLAT33_LANES = ("vm-collab-units", "vm-collab-integration")
# `test_editor_collab_examples.nim` reads the 400 characters before each lane's
# step (`WorkflowSource[max(0, at - 400) ..< at]`) for `!cancelled()`.
PLAT33_WINDOW = 400


def _plat33_collab_lanes(text: str) -> str:
    """What the examples suite reads of `.github/workflows/codetracer.yml`:
    for each collaboration lane, whether `just test-<lane>` occurs, and the
    window before its first occurrence that the suite searches for
    `!cancelled()`."""
    out = []
    for lane in PLAT33_LANES:
        needle = "just test-" + lane
        at = text.find(needle)
        if at < 0:
            out.append(f"{lane}: absent")
        else:
            window = text[max(0, at - PLAT33_WINDOW):at]
            out.append(f"{lane}: at {at > 0}\n{window}{needle}")
    return "\n".join(out) + "\n"


def _plat33_collab_recipes(text: str) -> str:
    """What the examples suite reads of the `justfile`: whether each
    collaboration lane has its recipe and the recipe runs that lane."""
    out = []
    for lane in PLAT33_LANES:
        for fact in ("test-" + lane + ":", "run-nim-test-lane.sh " + lane):
            out.append(f"{fact!r}: {fact in text}")
    return "\n".join(out) + "\n"


VIEWS = {
    "plat33-collab-lanes": _plat33_collab_lanes,
    "plat33-collab-recipes": _plat33_collab_recipes,
}


def split_subject(subject: str) -> tuple[str, str]:
    """`path#view` -> (path, view); a plain path -> (path, "")."""
    path, sep, view = subject.partition(SEPARATOR)
    return path, view if sep else ""


def view_text(path: Path, view: str) -> str:
    """The view's text over `path`. An unknown view is a KeyError: an entry
    naming a view nobody defines has nothing to digest, and is never quietly
    read as the whole file."""
    return VIEWS[view](path.read_text(encoding="utf-8"))


def view_digest(path: Path, view: str) -> str:
    """The SHA-256 a control entry `path#view` records."""
    return hashlib.sha256(view_text(path, view).encode("utf-8")).hexdigest()


def main(argv: list[str]) -> int:
    """`[--sha256] <file> <view>`: the view's text, or with `--sha256` its
    digest. Exits 2 for an unknown view and 3 for a missing file, printing
    nothing on stdout, so a caller cannot mistake a failure for a digest."""
    args = argv[1:]
    as_digest = bool(args) and args[0] == "--sha256"
    if as_digest:
        args = args[1:]
    if len(args) != 2:
        print("usage: mutation_views.py [--sha256] <file> <view>",
              file=sys.stderr)
        return 2
    path, view = Path(args[0]), args[1]
    if view not in VIEWS:
        print(f"mutation_views.py: no view named {view!r}", file=sys.stderr)
        return 2
    if not path.is_file():
        print(f"mutation_views.py: {path} does not exist", file=sys.stderr)
        return 3
    sys.stdout.write(view_digest(path, view) + "\n" if as_digest
                     else view_text(path, view))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
"""generated-code-operation-guard.py — the Show Generated Code chain must be reached.

WHY THIS EXISTS AND WHY IT IS NOT `frontend-reachability-guard.py`
------------------------------------------------------------------
That guard is right and it did find this.  It reported ``produceAnchors``,
``readArtefactJson``, ``setAnchors``, ``syncFromSource`` and
``syncFromGeneratedRow`` as unreached — inside a backlog of 1,228 findings,
in ``--report`` mode, exiting 0.  A finding nobody reads and a check nobody
fails is not a gate.

So this one is narrow and ENFORCING.  It asserts one chain: the operation a
developer invokes from a cursor to see what their code compiled to.  Every
symbol below is a link in it, and the chain is only worth anything whole —
a producer nothing calls, a ViewModel nothing constructs, or a context-menu
entry with no handler behind it each leave the same user-visible face, which
is a feature that looks present and does nothing.

THE RULE, AND THE TWO WAYS IT FAILS
-----------------------------------
For each symbol below:

  MISSING    it is not declared anywhere under ``src/frontend``.  The chain
             has a hole, or this list has rotted and names code that was
             deleted.  Either is a finding, and the second is why the check
             is on DECLARATIONS as well as on reaches: an allow-list that
             can quietly stop matching anything becomes vacuous without ever
             going red.

  TEST-ONLY  it is declared, and the only files that mention it are its own
             module and test files.  This is the exact shape the whole
             chain was in before it was wired: correct, tested, and reached
             by nothing a user can get to.

``*`` means "for other modules", so the reach must be CROSS-MODULE.  The
weaker rule — "does any production file mention it" — was measured against
this campaign's canonical instance and ran green over ``BuildLocationScanner``,
because that name appears on its own module's signature lines and those were
themselves unreached.  A symbol propped up by its unreached siblings is not
reached.

PROVED ABLE TO FAIL, AND THIS IS THE MEASUREMENT
------------------------------------------------
Run with ``--root`` at a tree that predates the wiring.  ``git archive`` is
enough — the guard reads only ``src/frontend``::

    git archive origin/dev src/frontend | tar -x -C /tmp/before
    ci/test/generated-code-operation-guard.py --root /tmp/before

MEASURED against ``origin/dev`` at ``a861f5b7bd04a27a379135a5bc850d09d0f257a7``:
**exit 1, 17 of 19 links broken** — two TEST-ONLY (``produceAnchors``,
``readArtefactJson``, each reached only by ``test_noir_anchor_producer.nim``
and ``test_noir_generated_listing.nim``) and fifteen MISSING.  On the tree
that wires them: **exit 0, 0 broken**.

TWO OF THE NINETEEN DO NOT GO RED ON THAT TREE, and saying which is the point
of writing the measurement down rather than the count:

* ``syncFromSource`` is reached, by ``low_level_code_vm.syncFromSourceLine``
  — which was itself unreached.  Limitation 2 below: the check is not
  transitive, so a symbol called only from another unreached symbol in a
  THIRD module reads as reached.
* ``noteSourceEdited`` is reached, but by ``ui/constraints.nim`` calling
  ``constraints_vm``'s proc of the same name.  Limitation 1: the check is
  name-based, and Nim overloads freely.

Both are under-reports, which is the direction a guard should err in.  A
guard whose red has never been seen is a guard whose subject might be empty.

WHAT IT DOES NOT CATCH
----------------------
Stated plainly, because a guard whose reach is overstated gets cited as
coverage it does not provide.

1. **It is name-based, not a call graph**, exactly as
   ``frontend-reachability-guard.py`` is.  A mention outside an import list
   and outside a comment counts.  It is a caller-count check, not proof that
   the path runs.

2. **It cannot see a wiring that is not a symbol.**  A context-menu row whose
   handler is installed and never fires, or a hook assigned in a branch the
   shipped build excludes, both satisfy this.  That second one is not
   hypothetical: the hooks here are installed inside ``when defined(ctWeb)
   and not defined(ctInExtension)``, so they are absent from the extension
   bundle by design and present in the web one.  The check that the chain
   reaches the SHIPPED artefact is a bundle grep, and it belongs with the
   browser probes rather than here.

3. **It says nothing about behaviour.**
   ``src/frontend/viewmodel/tests/unit/test_generated_code_operation.nim`` is
   what asserts that the listing is on demand, that the cursor moves it, and
   that it follows the active tab.  This guard asserts only that a user can
   reach any of it.

USAGE
    ci/test/generated-code-operation-guard.py            # exit 1 on findings
    ci/test/generated-code-operation-guard.py --root DIR # check another tree
    ci/test/generated-code-operation-guard.py --json out.json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

FRONTEND_ROOT = Path("src/frontend")

TEST_MARKERS = ("/tests/", "/test_suites/", "/stubs/")
TEST_FILENAME_RE = re.compile(r"(^test_|_test\.nim$|_test_plan\.nim$|_probe\.nim$)")


def is_test_path(path: Path) -> bool:
    posix = "/" + path.as_posix().lstrip("/")
    if any(marker in posix for marker in TEST_MARKERS):
        return True
    return bool(TEST_FILENAME_RE.search(path.name))


# ---------------------------------------------------------------------------
# THE CHAIN.  Each entry: symbol, the module that should declare it, and what
# breaks if nothing reaches it.  The third field is required — an entry that
# cannot say what its absence costs is one nobody can review.
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class Link:
    symbol: str
    module: str
    because: str


CHAIN: tuple[Link, ...] = (
    # --- The producer: what the compiler actually emitted -------------------
    Link("produceAnchors", "viewmodel/viewmodels/noir_anchor_producer.nim",
         "nothing turns a compile artefact into anchors, so no cursor can be "
         "projected into a listing"),
    Link("readArtefactJson", "viewmodel/viewmodels/noir_anchor_producer.nim",
         "the artefact is never decoded, so every row would render unmapped"),

    # --- The model: what a mapping claim may say ---------------------------
    Link("syncFromSource", "viewmodel/viewmodels/generated_code_anchors.nim",
         "the source-to-generated projection is never queried — this is the "
         "cursor-anchored half of the feature"),
    Link("anchorsFromSource", "viewmodel/viewmodels/generated_code_anchors.nim",
         "the instantiation COUNT is never read, so a line that became three "
         "ranges is silently shown as one (GCL-D29)"),

    # --- The operation's ViewModel -----------------------------------------
    Link("createGeneratedCodeVM", "viewmodel/viewmodels/generated_code_vm.nim",
         "the operation has no state, so nothing can be open or closed"),
    Link("openListing", "viewmodel/viewmodels/generated_code_vm.nim",
         "the on-demand entry point is never taken — the listing can never "
         "appear"),
    Link("noteCursorMoved", "viewmodel/viewmodels/generated_code_vm.nim",
         "the cursor never leads, so the listing is a static dump"),
    Link("noteActiveTabChanged", "viewmodel/viewmodels/generated_code_vm.nim",
         "the listing does not follow the active source tab"),
    Link("noteSourceEdited", "viewmodel/viewmodels/generated_code_vm.nim",
         "an edit never marks the tab stale, so a listing keeps synchronising "
         "against line numbers it no longer addresses (GCL-D18)"),

    # --- The declared ladder ------------------------------------------------
    Link("commandsForPath", "viewmodel/viewmodels/generated_code_operation.nim",
         "GCL-D17's availability table is never evaluated, so a command that "
         "cannot run is either absent or silently broken"),
    Link("commandLabel", "viewmodel/viewmodels/generated_code_operation.nim",
         "no target is named on any surface, which is GCL-D11's whole point"),
    # `keybindingTarget` is deliberately NOT in this chain: no key is bound to
    # the operation, so there is no link to check. Listing it would have made
    # this guard demand a symbol whose only possible reader would itself be
    # unreached — a chain check that manufactures its own subject.

    # --- The production open path (GCL-D19's fourth bullet) -----------------
    Link("showGeneratedCode", "ui/generated_code.nim",
         "THERE IS NO WAY TO INVOKE THE OPERATION.  Removing the pane from "
         "the default layout without this removes the feature"),
    Link("generatedCodeCommandsAt", "ui/generated_code.nim",
         "the editor's context menu offers no generated-code row"),
    Link("noteCompileArtefact", "ui/generated_code.nim",
         "no compile ever reaches the operation, so every invocation reports "
         "that nothing has been built"),
    Link("noteEditorCursorMoved", "ui/generated_code.nim",
         "the editor's caret never reaches the listing"),
    Link("noteEditorTabActivated", "ui/generated_code.nim",
         "switching source tabs never reaches the listing"),

    # --- The editor's and the toolchain's ends ------------------------------
    Link("editorCursorMovedHook", "ui/editor.nim",
         "Monaco's cursor events go nowhere"),
    Link("editorActiveTabChangedHook", "ui/editor.nim",
         "tab activation goes nowhere"),
    Link("noirGeneratedCodeSink", "ui/web_noir_build.nim",
         "a successful compile never publishes its artefact to the operation"),
)


# ---------------------------------------------------------------------------
# Nim identifier equality: style-insensitive after the first character.
# `markStale` and `mark_stale` are one symbol, as the compiler sees them.
# ---------------------------------------------------------------------------

def nim_key(name: str) -> str:
    if not name:
        return name
    return name[0] + name[1:].replace("_", "").lower()


COMMENT_RE = re.compile(r"#.*$")
IMPORT_LINE_RE = re.compile(r"^\s*(import|export|from)\b")


def mentions(text_lines: list[str], key: str) -> bool:
    """Whether any line mentions `key` outside a comment and outside an import.

    Import lists are excluded for the reason the rule exists: naming a symbol
    in order to be allowed to use it is not using it, and a module that
    imports a dead symbol and never calls it is the case this guard is for.
    """
    for raw in text_lines:
        if IMPORT_LINE_RE.match(raw):
            continue
        line = COMMENT_RE.sub("", raw)
        if not line.strip():
            continue
        for ident in re.findall(r"[A-Za-z][A-Za-z0-9_]*", line):
            if nim_key(ident) == key:
                return True
    return False


DECL_RE_TEMPLATE = (
    # A routine: `proc produceAnchors*(...)`.
    r"^\s*(?:proc|func|template|macro|iterator|converter|method)\s+{name}\b"
    # A variable or constant, either on its own line after `var` / `let` /
    # `const` or as an indented member of such a section:
    #
    #     var editorCursorMovedHook*: proc(path: cstring; line: int)
    #     var
    #       noirGeneratedCodeSink*: proc(...)
    #
    # THE SECTION FORM IS THE ONE THAT WAS MISSING, and it cost two false
    # MISSINGs on a tree where both hooks were declared and wired. A guard
    # that reports a symbol as absent when it is present is worse than one
    # that misses a real absence: the first teaches its reader that its
    # findings are noise.
    r"|^\s*(?:var|let|const)\s+{name}\*?\s*[:*=]"
    r"|^\s+{name}\*?\s*[:=]"
)


@dataclass
class Finding:
    symbol: str
    module: str
    kind: str          # "MISSING" or "TEST-ONLY"
    because: str
    detail: str = ""
    readers: list[str] = field(default_factory=list)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".",
                    help="repository root to check (default: cwd)")
    ap.add_argument("--json", default="", help="write findings as JSON")
    args = ap.parse_args()

    root = Path(args.root).resolve()
    frontend = root / FRONTEND_ROOT
    if not frontend.is_dir():
        print(f"error: {frontend} is not a directory", file=sys.stderr)
        return 2

    # Read every .nim under src/frontend once.
    product: dict[Path, list[str]] = {}
    tests: set[Path] = set()
    for path in sorted(frontend.rglob("*.nim")):
        rel = path.relative_to(root)
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        product[rel] = lines
        if is_test_path(rel):
            tests.add(rel)

    findings: list[Finding] = []

    for link in CHAIN:
        key = nim_key(link.symbol)
        decl_re = re.compile(
            DECL_RE_TEMPLATE.format(name=re.escape(link.symbol)), re.MULTILINE)

        declaring: list[Path] = []
        for rel, lines in product.items():
            if rel in tests:
                continue
            if any(decl_re.match(line) for line in lines):
                declaring.append(rel)

        if not declaring:
            findings.append(Finding(
                symbol=link.symbol, module=link.module, kind="MISSING",
                because=link.because,
                detail=f"no production module under {FRONTEND_ROOT} declares it"))
            continue

        declaring_set = set(declaring)
        readers = [
            rel.as_posix() for rel, lines in product.items()
            if rel not in tests and rel not in declaring_set
            and mentions(lines, key)
        ]
        if not readers:
            test_readers = [
                rel.as_posix() for rel, lines in product.items()
                if rel in tests and mentions(lines, key)
            ]
            findings.append(Finding(
                symbol=link.symbol, module=link.module, kind="TEST-ONLY",
                because=link.because,
                detail=("declared in "
                        + ", ".join(p.as_posix() for p in declaring)
                        + "; reached only by "
                        + (", ".join(test_readers) if test_readers
                           else "nothing at all")),
                readers=test_readers))

    print(f"Show Generated Code — operation reachability")
    print(f"  tree:   {root}")
    print(f"  chain:  {len(CHAIN)} symbols")
    print(f"  found:  {len(findings)} broken")
    print()

    if not findings:
        print("The chain is whole: every link is declared and reached from a")
        print("production module other than its own.")
        return 0

    for f in findings:
        print(f"  [{f.kind}] {f.symbol}  ({f.module})")
        print(f"      {f.detail}")
        print(f"      without it: {f.because}")
        print()

    if args.json:
        Path(args.json).write_text(json.dumps(
            [f.__dict__ for f in findings], indent=2), encoding="utf-8")

    print(f"{len(findings)} of {len(CHAIN)} links in the Show Generated Code")
    print("chain are missing or reached only by their own tests.")
    return 1


if __name__ == "__main__":
    sys.exit(main())

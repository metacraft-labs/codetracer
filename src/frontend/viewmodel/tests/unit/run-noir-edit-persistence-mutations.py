#!/usr/bin/env python3
"""Mutation harness for `test_noir_edit_persistence.nim`.

The suite asserts that what a visitor types in Noir Studio is what the compiler
is handed. This script proves each of its checks detects something: it patches
one line of `ui/web_project_store.nim` -- the code under test, never the test
-- and requires that the **named** check fails. A mutation killed by some other
check is MISDIRECTED and counts as a failure of this harness, because an arm
that reddens somebody else's assertion has not shown that its own works.

WHY THE "DID THE PATCH DO ANYTHING" GUARD IS NOT PARANOIA. On this campaign a
mutation runner used `rm -f` on a path that did not exist, succeeded, and left
six arms measuring an unmutated tree -- every arm "survived", which read as a
weak test suite rather than as a broken harness. So `apply()` here does three
things before a build is allowed to start:

  * requires the search pattern to occur EXACTLY ONCE (a table that has drifted
    from the source is an error, not a silent zero-replacement);
  * requires the file's bytes to actually DIFFER after the write; and
  * requires the mutated text to be readable back off disk.

Per `codetracer-specs/Testing/Verification-Harness-Traps.md` the verdict comes
from the parsed `[OK]` / `[FAILED]` lines that `unittest` prints, never from the
exit code: `nim c -r` exits non-zero for a *compile* error too, and a compile
error is not a kill -- it is a mutation that never ran.

Usage (from the repository root):
  python3 src/frontend/viewmodel/tests/unit/run-noir-edit-persistence-mutations.py
"""

import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
SUITE = "src/frontend/viewmodel/tests/unit/test_noir_edit_persistence.nim"
STORE = "src/frontend/ui/web_project_store.nim"

# The checks, by the names `unittest` prints.
FRESH = "a fresh session compiles the bundled template"
BYTES = "a save changes the bytes the compiler is handed"
OUTCOME = "the_edit_changes_the_outcome_not_merely_the_input"
ONLY = "only the saved file changes"
WHOLE = "the whole project is still handed over, not only the edited file"
WRITER = "the writer is asked for exactly the edit"
REFUSED = "a refused write still leaves the editor's bytes in what Build compiles"
NOSTORE = "with no store the save still succeeds, in this tab"
ABSENT = "a file the project does not have is refused and nothing is written"
ONCE = "every save is reported exactly once"
ABSPATH = "an absolute renderer path becomes a project-relative store key"
OUTSIDE = "a path outside the project is refused rather than coerced"
INDEX = "the index a tab-load resolves to is the file it names"
VIAABS = "a save arriving by absolute path reaches the right file"
DURABLE = "a durable session and a volatile one are different sentences"
VOLATILE = "a volatile session says so rather than staying silent"
HEADER = "the header names every file saved"
SILENT = "a build that saved nothing says nothing"
LABELONCE = "the label names each file exactly once"
COUNT = "noir_edit_persistence_assertion_count_is_measured"

CHECKS = [FRESH, BYTES, OUTCOME, ONLY, WHOLE, WRITER, REFUSED, NOSTORE, ABSENT,
          ONCE, ABSPATH, OUTSIDE, INDEX, VIAABS, DURABLE, VOLATILE, HEADER,
          SILENT, LABELONCE, COUNT]


@dataclass
class Mutation:
    id: str
    path: str
    find: str
    replace: str
    killer: str
    why: str = ""


MUTATIONS = [
    # --- THE DEFECT ITSELF, reconstructed -----------------------------------
    # The shipped product: a save is accepted, reported as successful, and
    # changes nothing that Build reads. This is the exact state that made a
    # visitor watch a green build of code they had not written.
    Mutation(
        "M1", STORE,
        "      liveProject.files[index].content = content\n      return true",
        "      return true",
        BYTES,
        "the save reports success and mutates nothing -- the shipped defect",
    ),
    # The same defect one layer up: the store keeps a project, but Build reads
    # a different one. Modelled by handing back a pristine copy.
    Mutation(
        "M2", STORE,
        "proc currentProject*(): ProjectTemplate =\n  ## What Build compiles",
        "proc currentProject*(): ProjectTemplate =\n  if true: return ProjectTemplate(language: \"noir\", name: \"hello_noir\", entryFile: \"src/main.nr\", files: @[TemplateFile(path: \"Nargo.toml\", content: \"[package]\\nname = \\\"hello_noir\\\"\\n\"), TemplateFile(path: \"Prover.toml\", content: \"x = \\\"1\\\"\\ny = \\\"2\\\"\\n\"), TemplateFile(path: \"src/main.nr\", content: \"fn main(x: Field, y: pub Field) {\\n    assert(x != y);\\n}\\n\")])\n  ## What Build compiles",
        BYTES,
        "Build reads a pristine template rather than the edited one",
    ),
    # --- the refusal of unknown paths ---------------------------------------
    Mutation(
        "M3", STORE,
        "  if not applyEditToMemory(relativePath, content):",
        "  if false:",
        ABSENT,
        "a save for a file the project does not have is accepted",
    ),
    # --- write-through ------------------------------------------------------
    Mutation(
        "M4", STORE,
        "  writeThrough(relativePath, content, onDone)",
        "  onDone(true, \"\")",
        WRITER,
        "the store is never asked to persist anything",
    ),
    # --- the ordering that keeps a failed write from losing the edit --------
    Mutation(
        "M5", STORE,
        "  if not applyEditToMemory(relativePath, content):\n    onDone(false,",
        "  if writeThrough.isNil and not applyEditToMemory(relativePath, content):\n    onDone(false,",
        REFUSED,
        "the in-memory edit is skipped whenever a writer is installed, so a "
        "failed write silently reverts what Build compiles",
    ),
    # --- exactly one report per save ----------------------------------------
    Mutation(
        "M6", STORE,
        "    onDone(true, \"\")\n    return\n  writeThrough(relativePath, content, onDone)",
        "    onDone(true, \"\")\n    onDone(true, \"\")\n    return\n  writeThrough(relativePath, content, onDone)",
        NOSTORE,
        "a storeless save reports its outcome twice",
    ),
    # --- the project root ---------------------------------------------------
    Mutation(
        "M7", STORE,
        '  "/" & tmpl.name',
        "  tmpl.name",
        ABSPATH,
        "the project root loses its leading slash",
    ),
    # --- the prefix check that keeps a save inside the project --------------
    Mutation(
        "M8", STORE,
        "  if path.len <= prefix.len or path[0 ..< prefix.len] != prefix:\n    return \"\"\n  path[prefix.len .. ^1]",
        "  if path.len <= prefix.len:\n    return \"\"\n  path[prefix.len .. ^1]",
        OUTSIDE,
        "a path outside the project is coerced into a key instead of refused",
    ),
    # --- EMT-D17's header ---------------------------------------------------
    Mutation(
        "M9", STORE,
        "  command & \" — saved \" & saved.join(\", \")",
        "  command",
        HEADER,
        "the header stops naming the files Run saved",
    ),
    Mutation(
        "M10", STORE,
        "  if saved.len == 0:\n    return command",
        "  if false:\n    return command",
        SILENT,
        "a Build that saved nothing claims it saved something",
    ),
    # --- what the user is told about durability -----------------------------
    Mutation(
        "M11", STORE,
        "  durabilityIsDurable = durable",
        "  durabilityIsDurable = true",
        DURABLE,
        "a volatile session is reported as durable",
    ),
]

DECLARED_SURVIVORS: list = []

RESULT_LINE = re.compile(r"^\s*\[(OK|FAILED)\]\s+(.*?)\s*$")


@dataclass
class RunResult:
    rc: int
    passed: list = field(default_factory=list)
    failed: list = field(default_factory=list)
    compiled: bool = True

    @property
    def total(self):
        return len(self.passed) + len(self.failed)


def run_suite() -> RunResult:
    proc = subprocess.run(
        ["nim", "c", "-r", "--hints:off", "--warnings:off", SUITE],
        cwd=ROOT, capture_output=True, text=True, timeout=3600,
    )
    out = proc.stdout + proc.stderr
    res = RunResult(rc=proc.returncode)
    for line in out.splitlines():
        m = RESULT_LINE.match(line)
        if m:
            (res.passed if m.group(1) == "OK" else res.failed).append(m.group(2))
    if res.total == 0:
        res.compiled = False
        print("---- no result lines; last 25 lines of output ----")
        print("\n".join(out.splitlines()[-25:]))
    return res


def apply(mut: Mutation) -> str:
    """Patch one file, and PROVE the patch landed. See the module docstring."""
    path = ROOT / mut.path
    original = path.read_text()
    occurrences = original.count(mut.find)
    if occurrences != 1:
        raise SystemExit(
            f"{mut.id}: pattern occurs {occurrences} times in {mut.path}, "
            f"expected exactly 1. The mutation table has drifted from the "
            f"source, and an arm that replaces nothing measures an unmutated "
            f"tree."
        )
    mutated = original.replace(mut.find, mut.replace)
    if mutated == original:
        raise SystemExit(
            f"{mut.id}: the replacement is identical to the original in "
            f"{mut.path}; this arm would measure an unmutated tree."
        )
    path.write_text(mutated)
    readback = path.read_text()
    if readback != mutated:
        raise SystemExit(f"{mut.id}: {mut.path} did not take the write.")
    if readback == original:
        raise SystemExit(f"{mut.id}: {mut.path} is unchanged on disk.")
    return original


def main() -> int:
    print("== control ==")
    control = run_suite()
    if control.failed or not control.compiled:
        print(f"CONTROL IS NOT GREEN: rc={control.rc} failed={control.failed}")
        return 1
    missing = [c for c in CHECKS if c not in control.passed]
    if missing:
        print(f"CONTROL DID NOT RUN {len(missing)} CHECKS: {missing}")
        return 1
    print(f"control: {control.total} checks, 0 failures\n")

    problems = 0
    for mut in MUTATIONS + DECLARED_SURVIVORS:
        original = apply(mut)
        try:
            res = run_suite()
        finally:
            (ROOT / mut.path).write_text(original)
        declared = mut in DECLARED_SURVIVORS
        if not res.compiled:
            verdict, note = "DID-NOT-COMPILE", "the mutation never ran"
            problems += 1
        elif declared and res.failed:
            verdict, note = "NO-LONGER-A-SURVIVOR", f"now killed by {res.failed}"
            problems += 1
        elif declared:
            verdict, note = "survived (declared)", mut.why
        elif not res.failed:
            verdict, note = "SURVIVED", "no check noticed: " + mut.why
            problems += 1
        elif mut.killer in res.failed:
            others = [f for f in res.failed if f != mut.killer]
            verdict = "killed"
            note = mut.killer + (f" (+{len(others)} more)" if others else "")
        else:
            verdict, note = "MISDIRECTED", f"died in {res.failed}, not {mut.killer!r}"
            problems += 1
        print(f"{mut.id:<4} {verdict:<22} {note}")

    print(f"\n{len(MUTATIONS)} arms, {problems} problems")
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

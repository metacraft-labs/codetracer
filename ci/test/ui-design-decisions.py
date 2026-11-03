#!/usr/bin/env python3
"""Every recorded UI design decision is still in the source tree.

THE DEFECT
----------
Part 6's × on the strip tabs had no test, so PR #893 could remove it while every
check stayed as it was. A later three-way merge would also have dropped its
styling without a conflict: one side deleted the block and the other left it
unchanged.

WHAT THIS CHECKS
----------------
`docs/UI-Design-Decisions.md` holds `guard` blocks of `path :: text` pairs. Each
`text` must appear in its `path`. Standard library only and no build, so it runs
in seconds and can be a required status check, unlike the wider suites.

It also enforces the one standing rule a source check can judge: no stylesheet
under `src/frontend/styles` sizes anything in px.

Run from the repository root:

    python3 ci/test/ui-design-decisions.py

The positive and negative controls run first, so a parser that stopped finding
guards fails here rather than reporting a clean tree.
"""

import re
import sys
from pathlib import Path

DECISIONS_DOC = Path("docs/UI-Design-Decisions.md")
GUARD_BLOCK = re.compile(
    r"^### (D-\d+):[^\n]*\n(?:(?!^### ).)*?^```guard\n(.*?)^```",
    re.MULTILINE | re.DOTALL,
)
SEPARATOR = " :: "


def parse_guards(document):
    """The (decision, path, text) triples of a decisions document."""
    guards = []
    for decision, block in GUARD_BLOCK.findall(document):
        for line in block.splitlines():
            if not line.strip():
                continue
            if SEPARATOR not in line:
                raise ValueError(f"{decision}: malformed guard line: {line!r}")
            path, text = line.split(SEPARATOR, 1)
            guards.append((decision, path.strip(), text.strip()))
    return guards


def missing_guards(guards, read_file):
    """The guards whose text is not in their file, with the reason."""
    missing = []
    for decision, path, text in guards:
        content = read_file(path)
        if content is None:
            missing.append((decision, path, text, "the file is gone"))
        elif text not in content:
            missing.append((decision, path, text, "the text is gone"))
    return missing


STYLES_DIR = Path("src/frontend/styles")
PX_VALUE = re.compile(r"(?<![\w.#$])\d*\.?\d+px\b")
BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.DOTALL)
LINE_COMMENT = re.compile(r"(?<![:\w])//.*")
QUOTED = re.compile(r"\"[^\"\n]*\"|'[^'\n]*'|url\([^)\n]*\)")


def px_values(stylesheet):
    """The (line number, line) pairs that size something in px.

    The units rule: styles are written in rem or em (root 16px). Comments and
    strings may still mention px.
    """
    blanked = BLOCK_COMMENT.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), stylesheet)
    found = []
    for number, line in enumerate(blanked.splitlines(), 1):
        code = LINE_COMMENT.sub("", QUOTED.sub('""', line))
        if PX_VALUE.search(code):
            found.append((number, line.strip()))
    return found


def read_repo_file(path):
    try:
        return Path(path).read_text(encoding="utf-8")
    except OSError:
        return None


def run_controls():
    """A scan that matches nothing, or everything, must not look clean."""
    document = (
        "### D-01: first\n\nProse.\n\n```guard\na.styl :: .kept\nb.nim :: gone\n```\n\n"
        "### D-02: no guard\n\nProse only.\n\n"
        "### D-03: third\n\n```guard\nc.nim :: anything\n```\n"
    )
    guards = parse_guards(document)
    assert guards == [
        ("D-01", "a.styl", ".kept"),
        ("D-01", "b.nim", "gone"),
        ("D-03", "c.nim", "anything"),
    ], f"control: parsed {guards}"

    files = {"a.styl": "x .kept y", "b.nim": "nothing here"}
    missing = missing_guards(guards, files.get)
    assert [(m[0], m[1], m[3]) for m in missing] == [
        ("D-01", "b.nim", "the text is gone"),
        ("D-03", "c.nim", "the file is gone"),
    ], f"control: reported {missing}"

    try:
        parse_guards("### D-09: bad\n\n```guard\nno separator\n```\n")
    except ValueError:
        pass
    else:
        raise AssertionError("control: a malformed guard line was accepted")

    stylesheet = (
        ".a\n  padding: 0.5rem 4px\n  // 8px in a comment\n"
        "  /* 2px\n  3px */\n  content: \"9px\"\n  margin: 1em // 6px\n  top: -2px\n"
    )
    found = [number for number, _ in px_values(stylesheet)]
    assert found == [2, 8], f"control: px found on lines {found}"


def main():
    run_controls()

    if not DECISIONS_DOC.is_file():
        print(f"FAILED: {DECISIONS_DOC} is missing. Run from the repository root.")
        return 1

    document = DECISIONS_DOC.read_text(encoding="utf-8")
    guards = parse_guards(document)
    if not guards:
        print(f"FAILED: {DECISIONS_DOC} has no guards, so nothing was checked.")
        return 1

    # A decision that lost its whole guard block would otherwise pass unseen.
    headed = set(re.findall(r"^### (D-\d+):", document, re.MULTILINE))
    unguarded = sorted(headed - {guard[0] for guard in guards})
    if unguarded:
        print(f"FAILED: decisions with no guard block: {', '.join(unguarded)}")
        return 1

    missing = missing_guards(guards, read_repo_file)
    if missing:
        print("FAILED: a recorded UI design decision is missing from the code.\n")
        for decision, path, text, reason in missing:
            print(f"  {decision}: {reason}")
            print(f"    file: {path}")
            print(f"    text: {text}")
        print(
            f"\nRestore the decision; see {DECISIONS_DOC}. Do not edit the guard to"
            "\npass this check. If the decision should change, ask Nikolay Fenixov"
            "\n(fenix-ov)."
        )
        return 1

    in_px = [
        (path, number, line)
        for path in sorted(STYLES_DIR.rglob("*.styl"))
        for number, line in px_values(path.read_text(encoding="utf-8"))
    ]
    if in_px:
        print("FAILED: a stylesheet sizes something in px.\n")
        for path, number, line in in_px:
            print(f"  {path}:{number}: {line}")
        print(
            f"\nWrite it in rem (px / 16) or em; see Units in {DECISIONS_DOC}."
        )
        return 1

    print(f"OK: {len(guards)} guards across {len(headed)} UI design decisions;"
          " no px in the stylesheets.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

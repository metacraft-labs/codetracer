#!/usr/bin/env python3
"""css-token-resolution-guard.py — a style variable that resolves to nothing is a defect.

WHY THIS EXISTS
---------------
Stylus passes an unknown identifier through to the output VERBATIM.  It does
not warn, it does not fail, it emits the identifier as if it were a CSS
keyword::

    // source
    color: colors-ui-text-accent      // no such variable

    // compiled output
    color: colors-ui-text-accent;     // not a colour; the browser drops it

The browser then discards the declaration and the element falls back to
whatever it inherits.  The page still renders.  Nothing anywhere reports it.
The only symptom is that something is the wrong colour, and the only detector
so far has been a person looking at the screen.

That has now shipped three times in this repo:

  * buttons that painted blank,
  * the FiraCode settings rules rendering in a serif face,
  * the build output panel, where two text tiers had no colour at all and
    painted at 1.05:1 in Electron.

Three is enough to stop finding them one screenshot at a time.
``components/ns9_panes.styl`` already carries a comment saying so in prose —
"a misspelling that compiles is the shape a token lint exists to catch; there
is no such lint over ``src/frontend/styles``".  This is that lint.

IT READS THE COMPILED STYLESHEET, NOT THE SOURCE
------------------------------------------------
That is the whole point.  The failure mode IS source and output disagreeing
silently, so a check over the source could only re-implement Stylus'
resolution and would be wrong in exactly the cases that matter.  The runner
(``css-token-resolution.sh``) compiles each shipped entry point with the same
``stylus`` the build uses and hands the emitted CSS to this script.

The list of stylesheets is READ FROM ``src/frontend/styles/Tupfile`` rather
than copied here, so a theme added to the build is covered the day it is
added and cannot drift out of this guard's sight.

THE RULE (token arm — enforcing)
--------------------------------
For every declaration in the compiled CSS, every bare hyphenated identifier in
its VALUE is examined.  It is reported when:

  1. it is not a defined Stylus variable, AND
  2. some defined variable shares its first two hyphen-separated segments.

Condition 2 is the namespace test and it is what makes this usable.
``colors-ui-text-accent`` is reported because 113 variables begin
``colors-ui-`` and none is that one.  ``border-box`` is not reported because
nothing defines a ``border-box-*`` variable — it is a CSS keyword that merely
happens to contain a hyphen.  Measured over this tree the namespace test
removes every false positive (``border-box``, ``padding-box``,
``border-color`` as a ``transition`` operand, and the ``caption-progress-pulse``
animation name) and removes no true one.

The defined set is the union of ``styles/generated/*.styl`` (the design
tokens) and every other ``.styl`` under ``styles/`` (the per-theme palettes),
so the ``ct-images-*`` namespace the palettes define is protected on the same
terms as ``colors-*``.

THE RULE (legacy arm — ratchet)
-------------------------------
The palettes also carry the older ``SCREAMING_CASE`` variables, and they leak
in exactly the same way and for a related reason: ``codetracer.styl`` uses a
name that one palette defines and another does not, so the build that omits it
emits the bare identifier.  No legal CSS value is ``[A-Z][A-Z0-9]*(_[A-Z0-9]+)+``,
so no namespace test is needed — every such identifier in a value is a leak.

This arm is a RATCHET, not a gate, because it starts with a backlog: 23
declarations in the dark build and 34 in the light one, and clearing them means
choosing colours for 57 surfaces, which is a different piece of work from
installing the guard.  ``css-token-resolution-legacy.baseline`` records the
ceiling per stylesheet.  Going ABOVE a ceiling fails.  Going BELOW it also
fails, with the one-line edit that fixes it — a ceiling allowed to drift above
reality is a hole, and the point of a ratchet is that it only turns one way.

INSTRUMENT CHECKS
-----------------
A guard that scans an empty file passes.  ``default_white_theme.styl`` is a
palette-only entry point that the Tupfile nonetheless ships as a stylesheet,
and it compiles to ZERO BYTES today — so this is not hypothetical, it is the
state of the tree.  Two checks stop that reading as a pass:

  * every shipped stylesheet must emit at least one declaration, unless it is
    listed in ``PALETTE_ONLY`` below with a reason;
  * a ``PALETTE_ONLY`` entry that names a stylesheet which DOES emit
    declarations fails, so the exemption cannot outlive the defect it excuses.

A third check guards an assumption rather than an artefact, and is
unconditional.  ``colors-*`` are compile-time variables and no theme redefines
any of them, which is why one token set is valid for every theme and why a
finding count is one number rather than one per theme.
``theme_files_redefining`` asserts that: if a future light palette assigns a
name ``styles/generated`` owns, this guard's single resolved set stops being
true for both builds, and it says so instead of silently measuring the dark
theme twice.

WHAT IT DOES NOT CATCH
----------------------
Stated plainly, because a guard whose reach is overstated gets cited as
coverage it does not provide.

1. **A typo in the first two segments escapes.**  ``colour-ui-text-primary``
   has no known namespace, so the namespace test does not fire.  The bias is
   deliberate and CONSERVATIVE: the alternative — reporting every hyphenated
   identifier and allow-listing the ~50 CSS keywords, the ``@keyframes``
   names, the font-face family names and the SVG sprite ids — was written
   first and measured at 40-plus false positives on this tree.  A guard that
   cries wolf on day one is a guard that is disabled on day one.

2. **It does not check that a resolved value is the RIGHT value.**  A
   declaration that resolves correctly to an unreadable colour is invisible
   here.  That is what the Playwright contrast specs are for.

3. **It does not catch a missing declaration.**  The build-output-panel defect
   had a second half: a rule that set ``background-color`` and no ``color``,
   on an element that inherited none.  Nothing is wrong with that rule's TEXT
   — the defect is in what it omits, and whether the omission matters depends
   on where the element sits in the DOM, which a static pass over a stylesheet
   cannot know.  It is deliberately out of scope here and belongs in a
   rendered-page check.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter
from typing import Dict, Iterable, List, NamedTuple, Set, Tuple

# Entry points the Tupfile ships that compile to nothing because they hold
# variables and no rules.  An entry here must say why, and is itself checked:
# if the named stylesheet ever emits declarations, this guard fails until the
# entry is removed.
PALETTE_ONLY: Dict[str, str] = {
    "default_white_theme.css": (
        "default_white_theme.styl is a palette: it assigns variables and "
        "declares no rules, so it compiles to zero bytes. The Tupfile ships "
        "it as a stylesheet anyway. The rules for the light build come from "
        "default_white_theme_electron.styl, which imports this palette and "
        "then codetracer.styl."
    ),
}

# A bare hyphenated identifier. The lookbehind keeps us out of hex colours
# (#fff-ish), class fragments in url() targets (…svg#dot-call-…) and the tails
# of longer identifiers; the lookahead keeps us out of function calls
# (translate-x(…)) and identifiers we have only partly matched.
IDENT_RE = re.compile(r"(?<![\w#.\-])([a-zA-Z][a-zA-Z0-9]*(?:-[a-zA-Z0-9]+)+)(?![\w(\-])")

# SCREAMING_CASE with at least one underscore. No CSS keyword has this shape.
LEGACY_RE = re.compile(r"(?<![\w\-])([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)(?![\w\-])")

# `prop: value` on its own line, which is how Stylus pretty-prints.
DECL_RE = re.compile(r"^(-{0,2}[a-zA-Z][-a-zA-Z0-9]*)\s*:\s*(.+?);?$")

VAR_DEF_RE = re.compile(r"^\s*([a-zA-Z][\w-]*)\s*=")
TUP_SHIP_RE = re.compile(r"^:\s*(\S+\.styl)\s*\|>\s*!stylus\s*\|>\s*(\S+\.css)\s*$")


class Finding(NamedTuple):
    stylesheet: str
    line: int
    prop: str
    identifier: str


def read_shipped_stylesheets(tupfile: str) -> List[Tuple[str, str]]:
    """The (source, output) pairs the build compiles with !stylus.

    Read rather than hardcoded: a theme added to the build is covered the day
    it is added.
    """
    pairs: List[Tuple[str, str]] = []
    with open(tupfile, encoding="utf-8") as handle:
        for raw in handle:
            match = TUP_SHIP_RE.match(raw.strip())
            if match:
                pairs.append((match.group(1), match.group(2)))
    return pairs


def read_defined_variables(styles_dir: str) -> Tuple[Set[str], Set[str]]:
    """Every Stylus variable name in the tree, and the namespaces they form.

    A namespace is the first two hyphen-separated segments of a name that has
    at least three; `colors-ui-text-primary-body` contributes `colors-ui`.
    """
    names: Set[str] = set()
    for root, _dirs, files in os.walk(styles_dir):
        for name in files:
            if not name.endswith(".styl"):
                continue
            with open(os.path.join(root, name), encoding="utf-8") as handle:
                for raw in handle:
                    match = VAR_DEF_RE.match(raw)
                    if match:
                        names.add(match.group(1))
    namespaces = {
        "-".join(name.split("-")[:2]) for name in names if name.count("-") >= 2
    }
    return names, namespaces


def theme_files_redefining(styles_dir: str, generated_names: Set[str]) -> List[str]:
    """Theme/component files that assign a name the generated token set owns.

    Empty is the state this guard assumes. See the module docstring.
    """
    offenders: List[str] = []
    for root, _dirs, files in os.walk(styles_dir):
        if os.path.basename(root) == "generated":
            continue
        for name in sorted(files):
            if not name.endswith(".styl"):
                continue
            path = os.path.join(root, name)
            with open(path, encoding="utf-8") as handle:
                for lineno, raw in enumerate(handle, 1):
                    match = VAR_DEF_RE.match(raw)
                    if match and match.group(1) in generated_names:
                        offenders.append(f"{path}:{lineno}: {match.group(1)}")
    return offenders


def declarations(text: str) -> Iterable[Tuple[int, str, str]]:
    for lineno, raw in enumerate(text.split("\n"), 1):
        stripped = raw.strip()
        match = DECL_RE.match(stripped)
        if not match:
            continue
        prop, value = match.group(1), match.group(2)
        # A selector line (`button:focus-visible {`) and the head of a nested
        # at-rule both parse as `name: rest` — neither is a declaration.
        if value.endswith("{") or value.endswith(","):
            continue
        yield lineno, prop, value


def scan(
    stylesheet: str, text: str, names: Set[str], namespaces: Set[str]
) -> Tuple[List[Finding], List[Finding], int]:
    token_findings: List[Finding] = []
    legacy_findings: List[Finding] = []
    count = 0
    for lineno, prop, value in declarations(text):
        count += 1
        for ident in IDENT_RE.findall(value):
            if ident in names:
                continue
            if ident.count("-") >= 2 and "-".join(ident.split("-")[:2]) in namespaces:
                token_findings.append(Finding(stylesheet, lineno, prop, ident))
        for ident in LEGACY_RE.findall(value):
            legacy_findings.append(Finding(stylesheet, lineno, prop, ident))
    return token_findings, legacy_findings, count


def read_baseline(path: str) -> Dict[str, int]:
    ceilings: Dict[str, int] = {}
    if not os.path.exists(path):
        return ceilings
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            stylesheet, _, count = line.partition("=")
            ceilings[stylesheet.strip()] = int(count.strip())
    return ceilings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--repo-root", required=True)
    parser.add_argument(
        "--css-dir",
        required=True,
        help="directory holding the COMPILED stylesheets, one per Tupfile output",
    )
    parser.add_argument("--baseline", default=None)
    parser.add_argument("--json", default=None)
    parser.add_argument(
        "--enforce-legacy",
        action="store_true",
        help="fail on any legacy leak instead of honouring the ratchet ceilings",
    )
    args = parser.parse_args()

    styles_dir = os.path.join(args.repo_root, "src", "frontend", "styles")
    generated_dir = os.path.join(styles_dir, "generated")
    tupfile = os.path.join(styles_dir, "Tupfile")
    baseline_path = args.baseline or os.path.join(
        args.repo_root, "ci", "test", "css-token-resolution-legacy.baseline"
    )

    names, namespaces = read_defined_variables(styles_dir)
    generated_names, _ = read_defined_variables(generated_dir)
    shipped = read_shipped_stylesheets(tupfile)

    failures: List[str] = []

    if not shipped:
        failures.append(
            f"{tupfile}: no !stylus outputs found. The guard reads its file "
            "list from the build; if the Tupfile's rule syntax changed, this "
            "guard has been scanning nothing."
        )

    # ---- instrument check: the token set must be theme-independent ---------
    redefinitions = theme_files_redefining(styles_dir, generated_names)
    if redefinitions:
        failures.append(
            "A theme or component file assigns a name that styles/generated "
            "owns. One resolved token set is no longer valid for every theme, "
            "so this guard must become per-theme before it can be believed:\n  "
            + "\n  ".join(redefinitions)
        )

    all_token: List[Finding] = []
    all_legacy: List[Finding] = []
    decl_counts: Dict[str, int] = {}
    legacy_counts: Dict[str, int] = {}

    for _source, output in shipped:
        path = os.path.join(args.css_dir, output)
        if not os.path.exists(path):
            failures.append(
                f"{output}: the Tupfile ships this stylesheet and it was not "
                f"compiled into {args.css_dir}. The guard cannot report on a "
                "file it never read."
            )
            continue
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        token_findings, legacy_findings, count = scan(output, text, names, namespaces)
        decl_counts[output] = count
        legacy_counts[output] = len(legacy_findings)
        all_token.extend(token_findings)
        all_legacy.extend(legacy_findings)

        # ---- instrument check: an empty stylesheet is not a pass -----------
        if count == 0 and output not in PALETTE_ONLY:
            failures.append(
                f"{output}: compiled to {len(text)} bytes and 0 declarations. "
                "A guard that scans nothing reports nothing; either the build "
                "of this stylesheet is broken or it belongs in PALETTE_ONLY "
                "with a reason."
            )
        if count > 0 and output in PALETTE_ONLY:
            failures.append(
                f"{output}: listed in PALETTE_ONLY, but it emitted {count} "
                "declarations. The exemption has outlived the thing it "
                "excused — delete it from PALETTE_ONLY."
            )

    # ---- token arm: enforcing --------------------------------------------
    if all_token:
        lines = [
            f"  {f.stylesheet}:{f.line}  {f.prop}: {f.identifier}" for f in all_token
        ]
        distinct = sorted({f.identifier for f in all_token})
        failures.append(
            f"{len(all_token)} declaration(s) name a style variable that "
            f"resolves to nothing, across {len(distinct)} distinct "
            "identifier(s). Stylus emitted each verbatim; the browser drops "
            "the declaration and the element inherits whatever is behind "
            "it.\n" + "\n".join(lines) + "\n  distinct: " + ", ".join(distinct)
        )

    # ---- token arm: the count is one number, not one per theme ------------
    per_theme = Counter(f.stylesheet for f in all_token)
    scanned = [out for out in decl_counts if decl_counts[out] > 0]
    observed = {out: per_theme.get(out, 0) for out in scanned}

    # ---- legacy arm: ratchet ---------------------------------------------
    ceilings = read_baseline(baseline_path)
    for output in sorted(legacy_counts):
        if decl_counts.get(output, 0) == 0:
            continue
        found = legacy_counts[output]
        if args.enforce_legacy:
            if found:
                failures.append(
                    f"{output}: {found} legacy SCREAMING_CASE variable(s) "
                    "reached the output unresolved (--enforce-legacy)."
                )
            continue
        if output not in ceilings:
            failures.append(
                f"{output}: no ceiling in {os.path.basename(baseline_path)}. "
                f"Add `{output} = {found}` with a reason, or the ratchet is "
                "not holding this stylesheet at all."
            )
        elif found > ceilings[output]:
            examples = "\n".join(
                f"    {f.stylesheet}:{f.line}  {f.prop}: {f.identifier}"
                for f in all_legacy
                if f.stylesheet == output
            )
            failures.append(
                f"{output}: {found} legacy leaks, ceiling is "
                f"{ceilings[output]}. The ratchet only turns one way — a "
                "palette is missing a variable codetracer.styl uses.\n"
                + examples
            )
        elif found < ceilings[output]:
            failures.append(
                f"{output}: {found} legacy leaks, ceiling is "
                f"{ceilings[output]}. Lower the ceiling to {found} in "
                f"{os.path.basename(baseline_path)}. A ceiling above reality "
                "is room for a regression to hide in."
            )

    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump(
                {
                    "declarations": decl_counts,
                    "token_findings": [f._asdict() for f in all_token],
                    "token_findings_per_stylesheet": observed,
                    "legacy_counts": legacy_counts,
                    "legacy_findings": [f._asdict() for f in all_legacy],
                },
                handle,
                indent=2,
                sort_keys=True,
            )

    print("css-token-resolution: scanned", len(decl_counts), "compiled stylesheet(s)")
    for output in sorted(decl_counts):
        print(
            f"  {output:38s} {decl_counts[output]:6d} declarations"
            f"  unresolved-token={per_theme.get(output, 0):3d}"
            f"  legacy={legacy_counts.get(output, 0):3d}"
        )

    if failures:
        print("\nFAIL\n")
        for failure in failures:
            print(failure)
            print()
        return 1

    print("\nOK — every style variable in every shipped stylesheet resolves.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

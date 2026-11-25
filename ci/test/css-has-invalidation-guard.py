#!/usr/bin/env python3
"""css-has-invalidation-guard.py — a `:has()` that restyles the whole document.

WHY THIS EXISTS
---------------
A `:has()` rule (https://drafts.csswg.org/selectors-4/#relational) matches its
anchor by looking at the anchor's subtree, so the browser has to re-check it
whenever something its argument could match changes anywhere in that subtree.
Chromium narrows that re-check by the features the argument names (ids,
classes, attribute names), which is what keeps ordinary `:has()` rules cheap.
Two shapes defeat it, and both were measured in this app with Chromium's
`UpdateLayoutTree` element counts (StoryBook `ChangesCodeLongKeyboard`, 3493
elements, 2026-11-24):

``style-attribute``
    An argument that names the ``style`` attribute, such as
    ``:not([style*="display: none"])``. Every inline-style write is a change of
    the ``style`` attribute, so the rule is re-checked on every
    ``el.style.x = ...`` anywhere under its anchor. The caption bar's height
    switch was ``:root:has(> body > #welcomeScreen:not([style*="display:
    none"]) > *)``; the Changes panel's path cut writes inline style for each
    row it cuts, and every write restyled all 3394 elements: ~2500 whole-
    document restyles, 86 s of style recalculation, to mount 300 rows at 360px
    (0.8 s without the rule). Every drag, positioned popup and tooltip in the
    app paid the same tax.

``root-anchor``
    A `:has()` anchored at ``:root`` (or ``html``). Chromium re-checks it on
    every element inserted anywhere in the document, whatever its argument
    names, and the re-check restyles the whole document: 3094 elements for one
    inserted ``<span>``, where the same rule anchored at ``body`` restyles 8.

Both compile clean, both render correctly, and the only symptom is a page that
is slow in proportion to how much it does, which is how the 300-file Code tab
came to take 45-100 s to mount. Find the state another way: give the element a
dedicated attribute or class that the code which changes the state sets (the
caption bar's switch now reads ``#welcomeScreen[data-welcome-shown]`` from
``body:has(...)``, see shared_widgets.styl).

IT READS THE COMPILED STYLESHEET
--------------------------------
Stylus nests selectors (``&:has(...)`` under a parent rule), so only the
compiled output says what a `:has()` is anchored at. The runner
(``css-has-invalidation.sh``) compiles the shipped entry points with
``ci/lib/compile-shipped-stylesheets.sh`` and hands the directory here.

INSTRUMENT CHECKS
-----------------
An empty directory, or one whose stylesheets are all empty, is a failure, not a
pass: a guard that read nothing has checked nothing.

``--self-test`` runs the rules over planted fixtures (each shape above, the
legal shapes next to them, comments, and the instrument checks) and fails unless
each verdict is the expected one.

WHAT IT DOES NOT CATCH
----------------------
Rules a script inserts at run time, and other costly shapes that have not been
measured here (a universal argument under a broad anchor, for instance). The
browser-level check, ``just storybook-check-style-invalidation``, measures the
restyles a path cut costs and catches those by their effect.
"""

import argparse
import os
import re
import sys
import tempfile
from typing import List, NamedTuple, Tuple

COMMENT_RE = re.compile(r"/\*.*?\*/", re.S)
# `[style]`, `[style="..."]`, `[style*="..."]`, `[ style ~= ... i]` — the
# attribute named exactly `style`, not `data-style` or `styleset`.
STYLE_ATTRIBUTE_RE = re.compile(r"\[\s*style\s*(?:[~|^$*]?=|\])", re.I)
ROOT_COMPOUND_RE = re.compile(r"(?::root(?![\w-]))|(?:^html(?![\w-]))", re.I)
SEPARATORS = set(" \t\n\r>+~,{};")


class Finding(NamedTuple):
    stylesheet: str
    line: int
    rule: str
    selector: str


def strip_comments(text: str) -> str:
    """Blank out comments, keeping newlines so line numbers stay right."""
    return COMMENT_RE.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), text)


def has_argument(text: str, open_paren: int) -> str:
    """The balanced argument of the `:has(` whose `(` is at ``open_paren``."""
    depth = 0
    for i in range(open_paren, len(text)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return text[open_paren + 1 : i]
    return text[open_paren + 1 :]


def anchor_compound(text: str, has_at: int) -> str:
    """The compound selector a `:has(` at ``has_at`` belongs to.

    Walks back to the previous combinator, comma or rule boundary outside
    parentheses. A `:has()` written inside another pseudo-class's parentheses
    (``.a:not(:has(.b))``) belongs to the compound around that pseudo-class,
    so an unmatched ``(`` met on the way is stepped over, not stopped at.
    """
    depth = 0
    i = has_at - 1
    while i >= 0:
        c = text[i]
        if c == ")":
            depth += 1
        elif c == "(":
            if depth > 0:
                depth -= 1
        elif depth == 0 and c in SEPARATORS:
            break
        i -= 1
    return text[i + 1 : has_at]


def selector_around(text: str, at: int) -> str:
    start = max(text.rfind("}", 0, at), text.rfind(";", 0, at), text.rfind("{", 0, at)) + 1
    end = text.find("{", at)
    return " ".join(text[start : end if end >= 0 else len(text)].split())


def scan_text(name: str, text: str) -> Tuple[int, List[Finding]]:
    """(number of `:has(` seen, findings) for one stylesheet's text."""
    text = strip_comments(text)
    findings: List[Finding] = []
    seen = 0
    for match in re.finditer(r":has\(", text):
        seen += 1
        at = match.start()
        line = text.count("\n", 0, at) + 1
        selector = selector_around(text, at)
        if STYLE_ATTRIBUTE_RE.search(has_argument(text, match.end() - 1)):
            findings.append(Finding(name, line, "style-attribute", selector))
        if ROOT_COMPOUND_RE.search(anchor_compound(text, at)):
            findings.append(Finding(name, line, "root-anchor", selector))
    return seen, findings


def scan_dir(css_dir: str) -> Tuple[List[str], int, List[Finding]]:
    """(problems with the input itself, `:has(` count, findings)."""
    problems: List[str] = []
    names = sorted(n for n in os.listdir(css_dir) if n.endswith(".css")) if os.path.isdir(css_dir) else []
    if not names:
        return [f"no stylesheets in {css_dir}: nothing was checked"], 0, []
    total = 0
    findings: List[Finding] = []
    nonempty = 0
    for name in names:
        with open(os.path.join(css_dir, name), encoding="utf-8") as handle:
            text = handle.read()
        if text.strip():
            nonempty += 1
        seen, found = scan_text(name, text)
        total += seen
        findings.extend(found)
    if nonempty == 0:
        problems.append(f"every stylesheet in {css_dir} is empty: nothing was checked")
    return problems, total, findings


def report(css_dir: str) -> int:
    problems, total, findings = scan_dir(css_dir)
    for problem in problems:
        print(f"css-has-invalidation: INSTRUMENT FAILURE: {problem}")
    if problems:
        return 1
    print(f"css-has-invalidation: {total} :has() selector(s) checked")
    for f in findings:
        print(f"  {f.rule:16} {f.stylesheet}:{f.line}  {f.selector}")
    if findings:
        print(
            "css-has-invalidation: FAILED. A :has() that names the `style` attribute is\n"
            "  re-evaluated on every inline-style write, and one anchored at :root/html on\n"
            "  every element inserted; both restyle the whole document each time. Read the\n"
            "  state from a dedicated attribute or class instead (see the header of\n"
            "  ci/test/css-has-invalidation-guard.py)."
        )
        return 1
    return 0


# --- self-test ----------------------------------------------------------------

SELF_TEST_CASES = [
    # (name, css, expected rules)
    ("the shipped caption switch before the fix",
     ':root:has(> body > #welcomeScreen:not([style*="display: none"]):not([style*="display:none"]) > *) { --x: 1 }',
     ["style-attribute", "root-anchor"]),
    ("the caption switch after the fix",
     "body:has(> #welcomeScreen[data-welcome-shown]) { --x: 1 }", []),
    ("style named under a narrow anchor", ".panel:has(> .row[style]) { color: red }", ["style-attribute"]),
    ("style named with a case-insensitive flag", '.p:has([ STYLE ~= "x" i ]) { color: red }', ["style-attribute"]),
    ("an attribute that merely contains `style`", ".p:has([data-style-kind]) .q { color: red }", []),
    (":root anchor naming only a class", ":root:has(.welcome-shown) { --x: 1 }", ["root-anchor"]),
    ("html anchor", "html:has(#a.b) body { color: red }", ["root-anchor"]),
    ("html as an ancestor of a narrow anchor",
     'html:not([data-focus-mode="mouse"]) .col:has(> .check:focus-visible) { outline: 0 }', []),
    ("a :has() inside :not() of a narrow compound",
     ".form:not(.x):not(:has(#exe:not(:placeholder-shown))) .btn { opacity: .5 }", []),
    ("a :has() inside :not() of a :root compound", ":root:not(:has(.a)) { --x: 1 }", ["root-anchor"]),
    ("a commented-out rule", '/* :root:has(> body > #w:not([style*="x"])) { } */ .a { color: red }', []),
    ("a later selector in a list", ".a, :root:has(.b) { --x: 1 }", ["root-anchor"]),
]


def self_test() -> int:
    failures = 0
    for name, css, expected in SELF_TEST_CASES:
        _, found = scan_text("fixture.css", css)
        got = sorted(f.rule for f in found)
        ok = got == sorted(expected)
        failures += not ok
        print(f"  {'ok  ' if ok else 'FAIL'} {name}: {', '.join(got) or 'clean'}"
              + ("" if ok else f" (expected {', '.join(sorted(expected)) or 'clean'})"))
    with tempfile.TemporaryDirectory() as empty:
        problems, _, _ = scan_dir(empty)
        ok = bool(problems)
        failures += not ok
        print(f"  {'ok  ' if ok else 'FAIL'} an empty stylesheet directory is an instrument failure")
        with open(os.path.join(empty, "theme.css"), "w", encoding="utf-8") as handle:
            handle.write("\n")
        problems, _, _ = scan_dir(empty)
        ok = bool(problems)
        failures += not ok
        print(f"  {'ok  ' if ok else 'FAIL'} a directory of empty stylesheets is an instrument failure")
    print("css-has-invalidation self-test " + ("passed" if failures == 0 else f"FAILED ({failures})"))
    return 0 if failures == 0 else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--css-dir", help="directory of compiled stylesheets to check")
    group.add_argument("--self-test", action="store_true", help="run the planted fixtures")
    args = parser.parse_args()
    return self_test() if args.self_test else report(args.css_dir)


if __name__ == "__main__":
    sys.exit(main())

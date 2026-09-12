#!/usr/bin/env python3
"""frontend-reachability-guard.py — an exported symbol nothing reaches is a defect.

WHY THIS EXISTS
---------------
This campaign has now found twelve instances of ONE defect shape: a correct,
tested capability that no product code reaches.  The call trace.  The event log.
Locals' origin summary.  The origin chain.  The ``tasks.json`` parser.  Five
zero-caller storage sites.  ``setBreakpoints`` sent zero times.
``CalltraceVM.selectedEntry``, read and never written.  A 1043-line edit-mode
toolbar viewmodel imported by nothing.  A settings dialog whose toggle could
never open it.  ``build-clickable``, a row that looked clickable and did
nothing.  ``BuildLocationScanner``, the reader written to stop ``nargo``
warnings being reported as errors, reached only from its own unit test.

Their user-visible face is always the same: a feature that looks present and
does nothing.  Every one of them passed a structural check, because a
structural check asks whether the code EXISTS.  This asks whether anything
reaches it.

Twelve is enough to stop finding them one user report at a time.

THE RULE
--------
``*`` means "for other modules".  So for every exported symbol declared under
``src/frontend`` (test trees excluded), the question is: does a DIFFERENT
product module mention this name, outside an import list and outside a
comment?  If not, it is reported.

The obvious weaker rule — "does any product file mention it" — was written
first and was measured against the campaign's canonical instance.  It ran
GREEN over ``BuildLocationScanner``, because that name appears on the
signature lines of ``reset`` and ``scan`` in its own module and those two were
themselves unreached.  A symbol propped up by its unreached siblings is not
reached.  A guard that says otherwise is precisely the coverage-that-is-not-
coverage this campaign exists to end, so the rule is cross-module.

Verified both ways on this tree: with ``ui/build.nim`` reverted to the state
in which nothing called the scanner, the guard reports
``BuildLocationScanner``; with the fix applied, it does not.

Nim identifier equality is honoured (style-insensitive: first character is
case-sensitive, the rest ignores case and underscores), so ``markStale`` and
``mark_stale`` are one symbol, as the compiler sees them.

WHAT IT DOES NOT CATCH
----------------------
Stated plainly, because a guard whose reach is overstated gets cited as
coverage it does not provide.

1. **It is name-based, not a call graph.**  Nim overloads freely and two
   modules may declare the same name, so a mention anywhere counts as a reach
   for every declaration of that name.  ``scan`` is a live example: another
   module in this tree uses that identifier for something else, so
   ``build_location_parser.scan`` reads as reached even when it is not.  The
   bias is CONSERVATIVE — it under-reports rather than crying wolf — but a
   non-finding is not proof of reachability.

2. **It is not transitive.**  A symbol called only from another unreached
   symbol in a THIRD module counts as reached.  The cross-module rule closes
   the same-module case, which is where the observed instances lived, and not
   the general one.  A fixed-point over the mention graph is the obvious next
   increment; it is deliberately not attempted here rather than half-done.

3. **It cannot see reachability that is not a name.**  ``setBreakpoints`` sent
   zero times, a settings toggle that could never open its dialog, and a row
   that carries ``build-clickable`` with no listener behind it are defects in
   a WIRING — an event name, a click path — not in a symbol's caller count.
   Those need the assertion that drives the path and observes the effect, and
   this guard does not replace it.  It finds the subset that is a caller
   count, which was most of the twelve, not all of them.

REPORT, DO NOT FAIL
-------------------
The first run produces a backlog, and a guard that reddens CI on day one gets
disabled on day one.  So the default is ``--report``: it prints findings,
groups them by module, and exits 0.  ``--enforce`` exits non-zero and is what
CI switches to once the backlog is cleared.  ``--max <n>`` is the ratchet in
between: fail only if the count EXCEEDS a recorded ceiling, so the number can
only go down.

THE RATCHET POLICY, DECIDED 2026-09-12 — AND NOT IMPLEMENTED HERE
------------------------------------------------------------------
The ceiling has been red since 2026-09-05 and the reason is not a bad merge:
this repository lands large tested subsystems that nothing wires yet, so the
backlog grows by construction.  Three repairs were costed over the 45
first-parent commits since the ceiling was last set, and are written up in
PLAT-11's section of
``codetracer-specs/Planned-Work/CodeTracer-Platform.milestones.org``.

**The decision is (c): "no new findings in files this change touched."**  It is
recorded here, beside the instrument, rather than only in a milestone document,
because the next person to read this file is the next person tempted to move
the number.

Why (c), in the terms the three were costed in:

* Across all 45 commits, only **10 of 746** new findings (1.3%) appeared in a
  file the commit did not touch.  So it is not a weakened ratchet — it catches
  98.7% of the same additions, and it attributes each one to the commit that
  caused it, which no count can.
* It is the only one of the three that needs **no checked-in number that 29 of
  45 commits must edit**.  That is the property that matters most, because a
  number 64% of commits have to edit is a number that rots, and this ceiling
  rotting is the whole reason any of this was costed.

Why not the other two:

* **(b), a per-directory ratchet, is the one to drop.**  It buys LOCALITY and
  pays for it by reproducing the slack-side failure 10 or 26 times over —
  multiplying the one failure mode that has already fired — while editing
  exactly as many commits as (a).  "The same, but in more places" is not a
  repair.
* **(a), a checked-in baseline, has a silent hole.**  Its stated cost is size
  (1709 lines / 101 KB); its real cost is RESOLUTION.  It keys on
  ``path:symbol``, and 91 of the findings already share a key with another, so
  a newly-added **overload** of an already-baselined symbol passes UNSEEN.
  That is this repository's own trap §4 — a scan that finds nothing satisfying
  a "must not contain" check — installed deliberately.  Keying on the line
  number closes it and churns on every edit, which is the same trade in the
  other direction.

**IT IS DELIBERATELY NOT IMPLEMENTED IN THIS DIFF.**  (c) is a repo-wide policy
change: it needs a per-file diff scope, an escape hatch, and its own contract
suite proving it fires and can be seen to fire.  It also has an honest and
large cost — 15 of the last 20 commits would have failed it — which is the
backlog becoming visible rather than a defect in the rule, and is a
conversation this lane's owner should have before the switch is thrown.

**TWO THINGS CAME FIRST AND ARE DONE, because all three proposals were
otherwise costed against a miscounted bucket:**

1. ``--max`` is a CEILING again and not an equality (see the ratchet block near
   the bottom of this file).  The equality had already reddened CI for five
   hours over a tree that had got better.
2. The bucket-A reclassification is done (see the bucket order in ``main``).
   It moved 722 findings out of the counted total: 1800 -> **1078**.

The ceiling was NOT raised, and must not be.  A ceiling re-fitted to whatever
the tree carries converts a broken gate into a silent one.  Note the
consequence of the two changes above, stated rather than left to be found: at
1078 against a ceiling of 1226 the lane now passes with 148 slots of reported
slack.  That slack is exactly what (c) is for, and lowering the ceiling to the
measured number is the ratchet-policy pass's call, not this one's.

THE ALLOW-LIST IS THE PART THAT ROTS
------------------------------------
An allow-list that grows without review becomes the thing it was meant to
prevent.  So ``frontend-reachability-allowlist.txt`` requires a REASON on
every entry, and an entry without one fails the guard even in report mode —
that failure is about the allow-list's own hygiene, not about the backlog.
Entries that no longer match any declared symbol are also reported, so the
list cannot quietly accumulate names for code that has been deleted.

USAGE
    ci/test/frontend-reachability-guard.py                 # report, exit 0
    ci/test/frontend-reachability-guard.py --enforce       # exit 1 on findings
    ci/test/frontend-reachability-guard.py --max 400       # ratchet
    ci/test/frontend-reachability-guard.py --json out.json # machine-readable
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------
# What counts as frontend, and what counts as a test
# ---------------------------------------------------------------------------

FRONTEND_ROOT = Path("src/frontend")

TEST_MARKERS = (
    "/tests/",
    "/test_suites/",
    "/stubs/",
)
"""Path fragments that make a file a non-product reader.

``stubs/`` is here with the test trees deliberately: ``viewmodel/stubs`` exists
to poison declarations for the host-free build gate, so a mention there is a
compile-time assertion about a symbol, not a use of it.
"""

TEST_FILENAME_RE = re.compile(r"(^test_|_test\.nim$|_test_plan\.nim$|_probe\.nim$)")


def is_test_path(path: Path) -> bool:
    posix = "/" + path.as_posix().lstrip("/")
    if any(marker in posix for marker in TEST_MARKERS):
        return True
    return bool(TEST_FILENAME_RE.search(path.name))


# ---------------------------------------------------------------------------
# Nim identifier equality
# ---------------------------------------------------------------------------


def nim_key(ident: str) -> str:
    """Normalise an identifier the way the Nim compiler compares them.

    First character is case-sensitive; every later character is compared
    case-insensitively with underscores ignored.  ``markStale``,
    ``mark_stale`` and ``markstale`` are therefore one symbol here exactly as
    they are one symbol to the compiler — a guard that treated them as three
    would report two phantom findings for every snake_case call site.
    """
    if not ident:
        return ident
    return ident[0] + ident[1:].replace("_", "").lower()


# ---------------------------------------------------------------------------
# Declaration extraction
# ---------------------------------------------------------------------------

ROUTINE_KEYWORDS = (
    "proc",
    "func",
    "method",
    "iterator",
    "template",
    "macro",
    "converter",
)

# `proc foo*(...)`, `func foo*[T](...)`, ``proc `==`*(...)``
ROUTINE_RE = re.compile(
    r"^\s*(?:" + "|".join(ROUTINE_KEYWORDS) + r")\s+"
    r"(?:`(?P<op>[^`]+)`|(?P<name>[A-Za-z_][A-Za-z0-9_]*))\s*\*"
)

# `Foo* = object`, `Foo*[T] = ref object`, `Foo* {.pure.} = enum`
TYPE_RE = re.compile(
    r"^\s{2,}(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*\*"
    r"(?:\[[^\]]*\])?\s*(?:\{\.[^}]*\.\}\s*)?="
)

# `var foo*: T`, `let foo* = ...`, `const foo* = ...` — one-liner form.
SECTION_ONELINE_RE = re.compile(
    r"^\s*(?:var|let|const)\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*\*"
)

# Inside an indented `var:` / `let:` / `const:` section body.
SECTION_BODY_RE = re.compile(r"^\s{2,}(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*\*\s*[:=]")

SECTION_OPEN_RE = re.compile(r"^\s*(?:var|let|const|type)\s*$")
TYPE_OPEN_RE = re.compile(r"^\s*type\s*$")

COMMENT_ONLY_RE = re.compile(r"^\s*#")


@dataclass
class Decl:
    name: str
    kind: str
    path: str
    line: int


@dataclass
class Finding:
    name: str
    kind: str
    path: str
    line: int
    bucket: str = ""


def strip_comment(line: str) -> str:
    """Drop a trailing ``#`` comment, respecting string literals crudely.

    Crudely is enough: this only feeds MENTION counting, and the failure mode
    of getting it slightly wrong is counting a mention inside a comment, which
    makes the guard more conservative rather than less.
    """
    out = []
    in_str = False
    quote = ""
    i = 0
    while i < len(line):
        ch = line[i]
        if in_str:
            if ch == "\\":
                out.append(ch)
                i += 1
                if i < len(line):
                    out.append(line[i])
                    i += 1
                continue
            if ch == quote:
                in_str = False
            out.append(ch)
        else:
            if ch in "\"'":
                in_str = True
                quote = ch
                out.append(ch)
            elif ch == "#":
                break
            else:
                out.append(ch)
        i += 1
    return "".join(out)


def declarations_in(path: Path, text: str) -> list[Decl]:
    decls: list[Decl] = []
    in_type_section = False
    in_value_section = False
    for lineno, raw in enumerate(text.splitlines(), start=1):
        if COMMENT_ONLY_RE.match(raw):
            continue
        line = strip_comment(raw)
        if not line.strip():
            continue

        indent = len(line) - len(line.lstrip())
        if indent == 0 and not SECTION_OPEN_RE.match(line):
            in_type_section = False
            in_value_section = False

        if TYPE_OPEN_RE.match(line):
            in_type_section = True
            in_value_section = False
            continue
        if SECTION_OPEN_RE.match(line):
            in_value_section = True
            in_type_section = False
            continue

        m = ROUTINE_RE.match(line)
        if m:
            name = m.group("op") or m.group("name")
            decls.append(Decl(name, "routine", str(path), lineno))
            continue

        m = SECTION_ONELINE_RE.match(line)
        if m:
            decls.append(Decl(m.group("name"), "value", str(path), lineno))
            continue

        # `type Foo* = object` on one line.
        if re.match(r"^\s*type\s+[A-Za-z_]", line):
            m = re.match(
                r"^\s*type\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*\*"
                r"(?:\[[^\]]*\])?\s*(?:\{\.[^}]*\.\}\s*)?=",
                line,
            )
            if m:
                decls.append(Decl(m.group("name"), "type", str(path), lineno))
            continue

        if in_type_section:
            m = TYPE_RE.match(line)
            if m:
                decls.append(Decl(m.group("name"), "type", str(path), lineno))
                continue

        if in_value_section:
            m = SECTION_BODY_RE.match(line)
            if m:
                decls.append(Decl(m.group("name"), "value", str(path), lineno))
                continue

    return decls


# ---------------------------------------------------------------------------
# Mention counting
# ---------------------------------------------------------------------------

IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


IMPORT_OPEN_RE = re.compile(r"^\s*(?:import|export|from)\b")


def mentions_in(text: str, skip_lines: set[int]) -> set[str]:
    """Every identifier mentioned in ``text``, minus the lines that are not uses.

    Three exclusions, and each one was a measured false negative rather than a
    precaution:

    * **Declaration lines**, so a symbol does not count as reaching itself.

    * **Comments and doc comments.**  ``BuildLocationScanner`` is named
      fourteen times in its own module's prose.  Counting prose would have
      declared it reached during the entire period when nothing called it —
      the guard would have been green over the defect it exists to find.

    * **`import` / `export` / `from` statements, including their continuation
      lines.**  This is the one that matters most and the one that is easiest
      to get wrong.  Naming a symbol in an import list is not calling it, and
      a guard that counts the mention reports an unreached symbol as reached,
      which is exactly backwards.

      The instance this rule was derived from: ``constraints_vm.markStale``
      then had ZERO call sites tree-wide, and its only mention outside its own
      declaration was ``ui/constraints.nim``'s `from ... import` list — a
      symbol imported, never applied, for the whole life of the pane whose
      staleness label it was supposed to set.  It has since been wired
      (`constraints_vm.noteSourceEdited` calls it, and `ui/constraints`
      imports THAT), and the import list no longer names it.  The example is
      kept because the rule is not: an import list still is not a call site.
    """
    found: set[str] = set()
    import_depth = 0
    in_import = False

    def continues(line: str, depth: int) -> bool:
        """Does this import statement carry on to the next line?

        Three real spellings in this tree, all of which must be followed:

            import
              ui_imports,
              ../[ types, communication ]

            from ../viewmodel/viewmodels/constraints_vm import
              ConstraintsVM, createConstraintsVM, setReport, setAbsence,
              noteSourceEdited

            import viewmodels/trace_log_vm except NO_SELECTED_INDEX

        The second is the one that matters: it ends on the keyword ``import``
        with nothing after it, so a continuation rule keyed only on a trailing
        comma stops at the wrong line and counts every name on the following
        line as reached.  When this was written that line ended in
        ``markStale``, a symbol with zero call sites, and counting it made the
        guard green over precisely the defect it exists to find.
        """
        tail = line.rstrip()
        if depth > 0:
            return True
        if tail.endswith(","):
            return True
        return bool(re.search(r"\b(?:import|export|from|except)\s*$", tail))

    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = strip_comment(raw)
        stripped_raw = raw.strip()

        if in_import:
            import_depth += line.count("[") - line.count("]")
            if not continues(line, import_depth):
                in_import = False
                import_depth = 0
            continue

        if IMPORT_OPEN_RE.match(line):
            import_depth = line.count("[") - line.count("]")
            in_import = continues(line, import_depth)
            continue

        if stripped_raw.startswith("#"):
            continue
        if lineno in skip_lines:
            continue
        # Drop a `##` doc body trailing real code.
        line = re.split(r"##", line, maxsplit=1)[0]
        for ident in IDENT_RE.findall(line):
            found.add(nim_key(ident))
    return found


# ---------------------------------------------------------------------------
# Allow-list
# ---------------------------------------------------------------------------


@dataclass
class AllowList:
    reasons: dict[str, str] = field(default_factory=dict)
    spelling: dict[str, str] = field(default_factory=dict)
    """Normalised key -> the spelling the file actually used, so a stale-entry
    report names the line a maintainer has to delete rather than its
    lower-cased shadow."""
    malformed: list[str] = field(default_factory=list)

    def allows(self, name: str) -> bool:
        return nim_key(name) in self.reasons


def load_allowlist(path: Path) -> AllowList:
    allow = AllowList()
    if not path.exists():
        return allow
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "#" not in line:
            allow.malformed.append(
                f"{path}:{lineno}: `{line}` has no reason. "
                f"Every entry must be `symbol  # why this is deliberate public API`."
            )
            continue
        symbol, reason = line.split("#", 1)
        symbol = symbol.strip()
        reason = reason.strip()
        if not symbol:
            allow.malformed.append(f"{path}:{lineno}: entry has no symbol.")
            continue
        if len(reason) < 12:
            allow.malformed.append(
                f"{path}:{lineno}: `{symbol}` has reason {reason!r}, which says nothing. "
                f"Write why an unreached export is correct here."
            )
            continue
        allow.reasons[nim_key(symbol)] = reason
        allow.spelling[nim_key(symbol)] = symbol
    return allow


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def collect(repo_root: Path) -> tuple[list[Decl], dict[str, set[str]], set[str]]:
    """Returns (declarations, key -> product modules mentioning it, keys tests mention)."""
    root = repo_root / FRONTEND_ROOT
    product_files: list[tuple[Path, str]] = []
    test_files: list[tuple[Path, str]] = []
    for path in sorted(root.rglob("*.nim")):
        rel = path.relative_to(repo_root)
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if is_test_path(rel):
            test_files.append((rel, text))
        else:
            product_files.append((rel, text))

    decls: list[Decl] = []
    decl_lines: dict[str, set[int]] = defaultdict(set)
    for rel, text in product_files:
        for decl in declarations_in(rel, text):
            decls.append(decl)
            decl_lines[str(rel)].add(decl.line)

    # WHICH MODULES mention a name, not merely whether any does. The
    # distinction is the whole accuracy of this guard; see `main`.
    mentioned_by: dict[str, set[str]] = defaultdict(set)
    for rel, text in product_files:
        for key in mentions_in(text, decl_lines[str(rel)]):
            mentioned_by[key].add(str(rel))

    tested: set[str] = set()
    for rel, text in test_files:
        tested |= mentions_in(text, set())

    return decls, mentioned_by, tested


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--enforce", action="store_true",
                        help="exit non-zero when there are findings")
    parser.add_argument("--max", type=int, default=None,
                        help="ratchet: exit non-zero only above this count")
    parser.add_argument("--json", type=Path, default=None,
                        help="also write findings as JSON")
    parser.add_argument("--kind", action="append", default=None,
                        choices=["routine", "type", "value"],
                        help="restrict to one declaration kind (repeatable)")
    parser.add_argument("--include-own-module", action="store_true",
                        help="also report exports only their own module reaches "
                             "(bucket C: large, low-yield, off by default)")
    parser.add_argument("--repo-root", type=Path,
                        default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    allow_path = Path(__file__).resolve().parent / "frontend-reachability-allowlist.txt"
    allow = load_allowlist(allow_path)

    decls, mentioned_by, tested = collect(repo_root)

    declared_keys = {nim_key(d.name) for d in decls}
    wanted_kinds = set(args.kind) if args.kind else {"routine", "type", "value"}

    # THE RULE, and the correction that made this guard worth having.
    #
    # The first cut asked "does any product file mention this name". It ran
    # green over `BuildLocationScanner` — the campaign's canonical instance,
    # which at the time had no product caller at all. The name appears on the
    # signature lines of `reset` and `scan` in its OWN module, and those two
    # were themselves unreached. A symbol propped up only by its unreached
    # siblings is not reached, and a guard that says otherwise is exactly the
    # coverage-that-is-not-coverage this campaign exists to stop.
    #
    # So: `*` means "for other modules". An exported symbol is reached when a
    # DIFFERENT product module mentions it. That single change turns the
    # canonical instance from a miss into a finding, and it is honest about
    # what it means — it is a statement about the export, not a whole-program
    # liveness proof.
    findings: list[Finding] = []
    allowed_hits: set[str] = set()
    for decl in decls:
        if decl.kind not in wanted_kinds:
            continue
        key = nim_key(decl.name)
        readers = mentioned_by.get(key, set())
        external = readers - {decl.path}
        if external:
            continue
        if allow.allows(decl.name):
            allowed_hits.add(key)
            continue
        # THE BUCKET ORDER, CORRECTED 2026-09-12. This read `if key in tested`
        # FIRST, so any symbol its own module already used was RELABELLED the
        # moment a test mentioned its name — moved out of bucket C ("only its
        # own module reaches it", deliberately not counted) and into bucket A
        # ("tested, and no product module reaches it", counted). Bucket A's
        # printed sentence was then false for 722 of its 1167 entries: a
        # product module did reach them, namely the declaring one.
        #
        # `ci/lint/nim.sh`'s own header had argued for this correction and
        # measured it at 355 of the then-1226; it is 722 of 1800 now, and the
        # growth is the point — this campaign GENERATES the shape by design,
        # building and testing a ViewModel before any front-end wires it.
        #
        # The two buckets are different defects and the difference is what a
        # reader does about them. Bucket A is "a tested capability that is dead
        # in the product" — wire it, delete it, or allow-list it. Bucket C is
        # "an export nobody outside needs" — drop the `*`. Counting the second
        # as the first inflates the number the ratchet enforces AND makes the
        # triage advice wrong for most of the rows it is printed beside.
        #
        # `readers` is product-module mentions only (`collect` builds
        # `mentioned_by` from product files and `tested` from test files), and
        # by this line `external` is empty — so `readers` non-empty means
        # exactly "the declaring module mentions it", which is bucket C's
        # definition. Asking that first is the whole fix.
        if readers:
            bucket = "own-module-only"
        elif key in tested:
            bucket = "tested-only"
        else:
            bucket = "nothing"
        findings.append(Finding(decl.name, decl.kind, decl.path, decl.line, bucket))

    def bucketed(name: str) -> list[Finding]:
        return [f for f in findings if f.bucket == name]

    tested_only = bucketed("tested-only")
    own_module_only = bucketed("own-module-only")
    nothing = bucketed("nothing")

    # BUCKET C IS OFF BY DEFAULT, and that is a triage decision rather than a
    # softening. It is 1473 entries against A+B's 1180, and almost all of it is
    # a module's own helpers carrying a `*` nobody outside needs — a style
    # debt, not a feature that looks present and does nothing. Counting it in
    # the headline would bury the bucket that matters under more than half the
    # report, and a report nobody reads is the failure mode this guard is meant
    # to end. `--include-own-module` when you want the style pass.
    counted = tested_only + nothing
    if args.include_own_module:
        counted = counted + own_module_only

    stale_allow = sorted(
        allow.spelling.get(key, key)
        for key in allow.reasons
        if key not in declared_keys
    )

    # ---- report ----------------------------------------------------------
    print("frontend reachability guard")
    print("=" * 72)
    print(f"scanned      : {FRONTEND_ROOT} ({len(decls)} exported declarations)")
    print(f"allow-listed : {len(allow.reasons)} entries, {len(allowed_hits)} matched")
    print(f"findings     : {len(counted)}")
    print(f"  [A] tested, no product module reaches it : {len(tested_only)}")
    print(f"  [B] nothing reaches it at all            : {len(nothing)}")
    print(f"  [C] only its own module reaches it       : {len(own_module_only)}"
          + ("" if args.include_own_module else "   (not counted; --include-own-module)"))
    print()

    sections = [
        (
            tested_only,
            "[A] TESTED, AND NO PRODUCT MODULE REACHES IT",
            [
                "This is the shape of all twelve instances: a correct, tested",
                "capability that no product code calls. A test proves it works;",
                "nothing proves anyone can get to it. TRIAGE THIS BUCKET FIRST.",
            ],
        ),
        (
            nothing,
            "[B] NOTHING REACHES IT AT ALL",
            [
                "Not product, not tests. Either delete it or wire it. An unreached",
                "implementation is worse than an absent one, because the next",
                "reader believes the capability is present.",
            ],
        ),
        (
            own_module_only if args.include_own_module else [],
            "[C] ONLY ITS OWN MODULE REACHES IT",
            [
                "The `*` has no product reader. Often harmless (an export kept for",
                "a sibling that was deleted), sometimes the same defect one level",
                "in. Lowest priority; drop the `*` or allow-list it with a reason.",
            ],
        ),
    ]

    for items, title, blurb in sections:
        if not items:
            continue
        print(f"-- {title} " + "-" * max(0, 68 - len(title)))
        for sentence in blurb:
            print(f"   {sentence}")
        print()
        by_module: dict[str, list[Finding]] = defaultdict(list)
        for f in items:
            by_module[f.path].append(f)
        for module in sorted(by_module):
            print(f"  {module}  ({len(by_module[module])})")
            for f in sorted(by_module[module], key=lambda x: x.line):
                print(f"    {f.line:>5}  {f.kind:<8} {f.name}")
        print()

    exit_code = 0

    if allow.malformed:
        print("-- ALLOW-LIST IS MALFORMED -------------------------------------------")
        print("   An allow-list that grows without review becomes the thing it was")
        print("   meant to prevent, so a reason is mandatory. These fail the guard")
        print("   regardless of --report/--enforce: this is the list's own hygiene,")
        print("   not the backlog.")
        for problem in allow.malformed:
            print(f"   {problem}")
        print()
        exit_code = 2

    if stale_allow:
        print("-- ALLOW-LIST HAS STALE ENTRIES --------------------------------------")
        print("   These name no declared symbol. Delete them, or the list becomes a")
        print("   record of code that no longer exists.")
        for name in stale_allow:
            print(f"   {name}")
        print()
        exit_code = max(exit_code, 2)

    if args.json:
        args.json.write_text(
            json.dumps(
                {
                    "declarations": len(decls),
                    "findings": [f.__dict__ for f in counted],
                    "tested_only": [f.__dict__ for f in tested_only],
                    "nothing": [f.__dict__ for f in nothing],
                    "own_module_only": [f.__dict__ for f in own_module_only],
                    "allowlist_entries": len(allow.reasons),
                    "allowlist_malformed": allow.malformed,
                    "allowlist_stale": stale_allow,
                },
                indent=2,
            ),
            encoding="utf-8",
        )

    # THE RATCHET IS A CEILING. IT WAS AN EQUALITY FOR SEVEN DAYS AND THE
    # EQUALITY COST MORE THAN THE SLACK IT CLOSED (changed 2026-09-12).
    #
    # The equality landed for a real reason, and the reason still reads well:
    # `ci/lint/nim.sh` had recorded, in its own words, "WHEN YOU DELETE OR WIRE A
    # SYMBOL, LOWER THIS NUMBER. Nothing forces that yet ... so slack accumulates
    # silently under it." It had: the ceiling went 1224 -> 1226 -> 1228 in
    # twenty-nine minutes on 2026-09-04, the backlog was then brought DOWN to 1223
    # by deleting dead entry points, and nobody lowered the ceiling — five free
    # slots for five new unreached exports. The shell-gate inventory next door
    # refuses exactly that budget, in a sentence this file copied:
    #
    #     "Not `<=`: slack under a ceiling is a budget for new dark gates, and the
    #      cheapest way to make this guard green has always been to append a line."
    #
    # WHAT THE EQUALITY ACTUALLY DID, MEASURED. `f274fa68` and `ab7ce4c1`
    # (2026-09-05) carry 1225 findings against a ceiling of 1226 and BOTH EXIT 1,
    # with `RATCHET SLACK`. CI was red for five hours because somebody had made
    # the tree better, and it went green again when an unrelated commit put the
    # count back up to exactly 1226. That is not a hypothetical cost of the
    # equality; it is a gate whose failure told a developer to undo an
    # improvement.
    #
    # AND IT IS THE FAILURE MODE THIS WHOLE FILE EXISTS TO AVOID. Its own header
    # says a guard that reddens CI on day one gets disabled on day one. A guard
    # that reddens CI for the tree getting BETTER teaches the same lesson faster,
    # because the developer it fires on has no repair to make — the only way to
    # clear it is to edit a number in a different file, or to put the finding
    # back.
    #
    # SO THE SLACK IS ANSWERED BY REPORTING IT LOUDLY RATHER THAN BY FAILING ON
    # IT. The message below is unchanged and still names the value to lower the
    # ceiling to; what changed is that it no longer sets the exit code. The
    # budget that leaves is real and is not the permanent answer — see "THE
    # RATCHET POLICY, DECIDED" in this file's header for what is, and why it
    # needs a pass of its own rather than a line here.
    over_ceiling = args.max is not None and len(counted) > args.max
    under_ceiling = args.max is not None and len(counted) < args.max

    if over_ceiling:
        print(f"RATCHET: {len(counted)} findings exceeds the recorded ceiling of {args.max}.")
        print(f"         {len(counted) - args.max} more than the tree is allowed to carry.")
        print("         Wire or delete the new one; do not raise the ceiling by reflex.")
        exit_code = max(exit_code, 1)
    else:
        if under_ceiling:
            # REPORTED, NOT FAILED. See the block above. The slack branch is
            # deliberately NOT an `elif` in front of `--enforce` any more: when
            # it set the exit code, making it stop doing so would also have made
            # it swallow `--enforce`, which is the harder setting and must not be
            # weakened by the softer one being relaxed.
            slack = args.max - len(counted)
            print(f"RATCHET SLACK: {len(counted)} findings, ceiling is still {args.max}.")
            print(f"         Lower it to {len(counted)}, in this diff. A ceiling with {slack} "
                  "slot(s) under")
            print("         it is a budget: that many unreached exports can land without this")
            print("         lane noticing, and the ratchet only ratchets if it tightens.")
            print("         Three sentences name this threshold — the setter and step label in")
            print("         ci/lint/nim.sh and the header of ci/test/frontend-reachability.sh.")
            print("         All three must move together or the prose guard fails.")
            print("         THIS IS A REPORT AND NOT A FAILURE since 2026-09-12: failing on")
            print("         slack reddened CI for five hours over a tree that had improved.")
        if args.enforce and counted:
            print(f"ENFORCE: {len(counted)} exported symbols have no cross-module product reader.")
            exit_code = max(exit_code, 1)
        elif exit_code == 0 and not under_ceiling:
            print("Reported, not enforced. Pass --enforce once the backlog is cleared,")
            print("or --max <n> to ratchet it down.")

    return exit_code


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Mutation harness for PLAT-11's declarative project definitions.

WHAT THIS COVERS. Project-Definitions.md §2 (the trust rule and the two
tiers), §4 (named point collections and per-point re-resolution), §5 (per-type
visualiser DECLARATIONS), §6 (the `.codetracer/` layout, schema versioning,
composition, and the user's own definitions kept separate) and §7's
declarative half (selecting a scratchpad diff CodeTracer ships). Seven subject
files, three suites.

THE RULE THE ARMS ARE AIMED AT, AND WHY THEY ARE AIMED THERE RATHER THAN AT
"EXECUTING". §2's rule is that cloning a repository and opening it must not
execute code from that repository, and this implementation satisfies it by
making executing INEXPRESSIBLE rather than expressible-and-refused. That is
the right design and it has an awkward consequence for a mutation harness:
there is no `if` that refuses to execute, so there is no `if` to mutate, and
an arm aimed at "the sentinel file did not appear" could never be killed by
any edit to this tree — which is Verification-Harness-Traps §10's assertion
that cannot fail, wearing a security badge.

So the arms are aimed at the four PROPERTIES that make executing
inexpressible, each of which is real code with a real failure mode:

  * the accepted-key set is closed and an unknown key ABANDONS the entry
    (P1, P2, P15);
  * the path grammar is closed (C1-C7) and is applied wherever a path enters
    (P8, L2, D3, D4);
  * the file set the reader opens is a constant, and an executable-tier
    file's BYTES never enter the process (D1, D5, L3);
  * matching, templating and re-resolution are bounded and total (P12, P16,
    P17, P18, R1-R3).

The sentinel assertion itself lives in
`src/ct/launch/project_definitions_dir_test.nim` with a PLANTED CONTROL
(Verification-Harness-Traps §4) rather than a mutation arm, and that file's
header says so.

IT IS A SEPARATE FILE FROM THE PLAT-7, PLAT-8, PLAT-9 AND PLAT-10 HARNESSES,
for the reason PLAT-8's header gives: each records control digests over its
own campaign's subjects, and merging them would mean one
`--record-control-hashes` step re-blessing several campaigns' files at once.

FOUR VERDICTS, NOT TWO (Verification-Harness-Traps §1a and §17):

  killed           the named case reported [FAILED] **and** the failure output
                   carries the arm's own `because`
  MIS-ATTRIBUTED   the named case went red, but not for the arm's reason — it
                   died upstream of the mutated line (§17). This sits beside
                   HARNESS-FAILURE rather than beside `killed`, because like
                   it the run told you nothing
  SURVIVED         the run produced result lines and the named case was green
  SUITE-DIED       the run produced result lines and the named case is in
                   NEITHER list — the binary died before reaching it
  HARNESS-FAILURE  the mutation did not apply, did not compile, or the run
                   produced NO result lines at all

THE FIFTH VERDICT WAS ADDED AFTER THIS HARNESS'S FIRST FULL RUN SCORED A CRASH
AS `SURVIVED`. Arm P7 removed a nil guard, the suite segfaulted part-way
through, and every case after the crash simply never appeared in the output —
so `newly_failed` was empty and the arm was graded "no case noticed". That is
Verification-Harness-Traps §1a's shape in a new place: a run that DIED is not a
run that passed, and a verdict computed only from the failures cannot tell them
apart. The check is `killer in res.passed or killer in res.failed`; anything
else means the case did not run.

Verdicts are parsed out of `[OK]` / `[FAILED]` RESULT LINES, never out of an
exit status: `nim c -r` returns the same non-zero code for a compile error, a
failed assertion and an OOM.

EVERY KILL ARM CARRIES A NAMED BEHAVIOUR-PRESERVING CONTROL in the same file,
applied on its own, which must leave the suite GREEN. A renamed local, a
hoisted binding, a swapped disjunction, a bound written as arithmetic.

EVERY ARM'S `because` IS CHECKED AGAINST THE CONTROL RUN, BEFORE ANY MUTATION.
A `because` that already occurs in a passing run is true for free.

A `because` IS A QUOTATION OF THE FAILURE TEXT, NOT OF THE SOURCE
(Verification-Harness-Traps §17a). `unittest.check` stringifies the AST it
receives and a template's body is substituted before it gets there, so:

  * a `because` quoting an assertion inside a helper template must quote the
    expression AS SUBSTITUTED at the call site — `ckEq rows.len, 5` prints as
    `rows.len == 5`, and `ckRefused problems, pdcUnknownKey` prints its
    template-local `sawWanted` as ``sawWanted`gensymNNN``, whose NUMBER IS NOT
    STABLE ACROSS COMPILATIONS;
  * so no `because` in this file names `sawWanted`. The ones that grade a
    `ckRefused` quote the CHECKPOINT line the helper prints instead — `wanted
    pdcUnknownKey, got:` — which is ordinary text and is stable.

Every `because` below was taken from a real failure transcript rather than
typed from the source.

ONLY ONE INSTANCE MAY RUN IN A WORKTREE, enforced with an exclusive `flock`
taken BEFORE the control-hash check.

THE CONTROL HASHES ARE RECORDED ON DISK, NOT TAKEN AT START-UP. A baseline
taken at start-up reads a mutation a killed run left behind as the baseline.

THE NEEDLE SCAN GATES `--record-control-hashes` (Verification-Harness-Traps
§16): re-recording is exactly the moment an arm's needle has just been moved
by the repair that made the re-record necessary.

Usage (from the repository root):
  direnv exec . python3 -u \\
    src/frontend/viewmodel/tests/unit/run-plat11-definitions-mutations.py

`-u` matters when the output is redirected: python otherwise block-buffers
stdout and a log stays empty until the last arm.

Arms naming one case are run individually:
  direnv exec . python3 -u \\
    src/frontend/viewmodel/tests/unit/run-plat11-definitions-mutations.py C1 V4
"""

from __future__ import annotations

import fcntl
import hashlib
import os
import re
import signal
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]

# --- the files an arm may touch -------------------------------------------

CONTAIN = "src/common/project_definitions/containment.nim"
PARSE = "src/common/project_definitions/parse.nim"
LOAD = "src/common/project_definitions/load.nim"
RESOLVE = "src/common/project_definitions/resolve.nim"
DIR = "src/ct/launch/project_definitions_dir.nim"
SOURCE = "src/frontend/viewmodel/viewmodels/point_collection_source.nim"
LAYOUT = "src/common/project_definitions/layout.nim"

TOUCHED = [CONTAIN, PARSE, LOAD, RESOLVE, DIR, SOURCE, LAYOUT]

PURE_SUITE = "src/common/project_definitions_test.nim"
CLI_SUITE = "src/ct/launch/project_definitions_dir_test.nim"
VM_SUITE = ("src/frontend/viewmodel/tests/unit/"
            "test_point_collections_fill_the_point_list.nim")

CONTROL_HASHES = HERE / "plat11-definitions-mutation-control.sha256"
LOCK_PATH = HERE / ".plat11-definitions-mutation.lock"

NIM_RESULT = re.compile(r"^\s*\[(OK|FAILED)\]\s+(.*)$")


def digest(path: str) -> str:
    return hashlib.sha256((ROOT / path).read_bytes()).hexdigest()


def acquire_lock():
    """Take the exclusive run lock, or explain who holds it and refuse."""
    fh = open(LOCK_PATH, "a+")
    try:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        fh.seek(0)
        holder = fh.read().strip() or "(the holder recorded no details)"
        fh.close()
        print("ANOTHER MUTATION RUN HOLDS THE LOCK — nothing was mutated.")
        print(f"  lock: {LOCK_PATH}")
        print(f"  held by: {holder}")
        print("  Two instances in one worktree corrupt each other's restores.")
        return None
    fh.seek(0)
    fh.truncate()
    fh.write(f"pid {os.getpid()} on {os.uname().nodename}, cwd {ROOT}\n")
    fh.flush()
    return fh


# --- the case names, spelled once ------------------------------------------
#
# A typo here shows up as "the killer resolves to 0 green cases" in the
# pre-flight rather than as a silently unkillable arm.

# `src/common/project_definitions_test.nim`
P_ESCAPES = "every way a path can leave the project has its own answer"
P_NUL = "a NUL cannot hide in a path, and it is its OWN answer"
P_META = "shell, glob and expansion metacharacters are outside the grammar"
P_BOUNDS = "the bounds are numbers, and are asserted as numbers"
P_EXPLAINS = "every refusal explains itself, and names the path"
P_NONASCII = "non-ASCII is refused, and the limitation is measured not assumed"
P_INTERP = ("a definition declaring an interpreter, an exec or a command is "
            "not a definition")
P_OVERSIZE = "an oversized file is refused before it is tokenised"
P_LINES = "a file that is small in bytes and enormous in lines is refused too"
P_FUTURE = "a future schema version is REPORTED, never partially honoured"
P_NOSCHEMA = "a file declaring no schema is refused rather than assumed current"
P_STRAYTABLE = ("a top-level table belonging to another file is refused, not "
                "ignored")
P_ANCHOR = "a point with only a line number is refused"
P_PATHOUT = "a path outside the checkout is refused, and says WHICH rule it broke"
P_PRESENT = "a visualiser naming a presentation a VALUE cannot be is refused"
P_MEDIA = "a media type nothing renders is refused, and the list is closed"
P_ALGO = ("a scratchpad diff naming an algorithm CodeTracer does not ship is "
          "refused")
P_TEMPLATE = "a summary template that could loop or run away is refused"
P_DECIMAL = "a quoted decimal outside its bound is refused"
P_TOLERANCE = "a tolerance that is not a bounded decimal is refused"
P_ENTRYBOUNDS = "every bounded collection has its bound enforced"
P_TOOLONG = "an over-long value is refused rather than truncated"
P_DUP = "two collections of one name are refused, not last-wins"
P_EMPTY = "an empty collection is refused"
P_SHADOW = "a nested package's collection replaces an ancestor's of the same name"
P_ORDER = "the nearer definition wins whatever order the caller enumerated them"
P_SCOPEOUT = "a package scope outside the checkout is refused"
P_RULEORDER = "visualiser rules are ORDERED by nearness, not overridden"
P_TIE = "a precedence tie is broken by declaration order AND reported"
P_SPECIFIC = "a more specific rule outranks a less specific one at the same scope"
P_USERSEP = "the user's definitions are a different field, never merged in"
P_MIXED = "a user file offered as part of the project's set is refused"
P_EXECTIER = ("an executable-tier file is reported and the declarative tier "
              "still loads")
P_RESOLVE = ("each point reports resolved, moved or unresolvable — and none is "
             "dropped")
P_OCCUR = "the occurrence is what stops a point sliding onto a new duplicate"
P_REINDENT = "re-indentation does not unresolve a point"
P_OFFEND = "an offset past the end of the file is unresolvable, never clamped"

# `src/ct/launch/project_definitions_dir_test.nim`
C_HOSTILE = "a hostile .codetracer/ is refused, and nothing in it runs"
C_BYTES = "the executable-tier file's BYTES never enter the process"
C_FILESET = "the set of files opened is the constant set, and nothing else"
C_DISKSIZE = "an oversized definition is refused by its SIZE, before it is read"
C_SCOPE = "a definition in a package scope outside the checkout is refused"
C_READGUARD = "readSourceFile refuses a path outside the checkout, at the syscall"

# `test_point_collections_fill_the_point_list.nim`
V_GATE = "applyCollections WRITES the signal — the verification gate"
V_ROW = "a point that no longer resolves is a ROW, not an absence"
V_ENABLED = "the enabled set is the definition's default, and nothing more"


@dataclass
class Suite:
    path: str
    binary: str
    extra_path: bool = False


NIM_PURE = Suite(PURE_SUITE, "/tmp/plat11-mut-pure")
NIM_CLI = Suite(CLI_SUITE, "/tmp/plat11-mut-cli")
NIM_VM = Suite(VM_SUITE, "/tmp/plat11-mut-vm", extra_path=True)


@dataclass
class Mutation:
    id: str
    path: str
    find: str
    replace: str
    killer: str
    suite: Suite
    because: str
    why: str = ""
    control_name: str = ""
    control_find: str = ""
    control_replace: str = ""


MUTATIONS: list[Mutation] = [
    # -- §2.2's containment: the one predicate that decides whether a string a
    # -- cloned repository wrote may name a file -----------------------------
    Mutation(
        "C1", CONTAIN,
        '      if seg == "..": return ppParentSegment',
        '      if seg == "...": return ppParentSegment',
        P_ESCAPES, NIM_PURE, 'pathProblem("../secrets") == ppParentSegment',
        "`..` stops being a segment the grammar refuses, so a definition can "
        "name any file on the machine the user runs CodeTracer as — the "
        "directory-traversal family, in a file acquired by `git clone`",
        control_name="the parent segment is tested through a named binding",
        control_find='      if seg == "..": return ppParentSegment',
        control_replace='      let isParent = seg == ".."\n'
                        '      if isParent: return ppParentSegment',
    ),
    Mutation(
        "C2", CONTAIN,
        "  if path[0] == '/' or path[0] == '\\\\':\n    return ppAbsolute",
        "  if false:\n    return ppAbsolute",
        P_ESCAPES, NIM_PURE, 'pathProblem("/etc/passwd") == ppAbsolute',
        "an absolute path is no longer refused for being absolute; it falls "
        "through to the segment walk, where a leading `/` is an EMPTY segment "
        "— so `/etc/passwd` is refused for the wrong reason and a reader is "
        "told to fix a doubled slash",
        control_name="the two leading separators are tested in the other order",
        control_find="  if path[0] == '/' or path[0] == '\\\\':\n    return ppAbsolute",
        control_replace="  if path[0] == '\\\\' or path[0] == '/':\n    return ppAbsolute",
    ),
    Mutation(
        "C3", CONTAIN,
        "    if ch < ' ' or ch == '\\x7f':\n      return ppControlChar",
        "    if false:\n      return ppControlChar",
        P_NUL, NIM_PURE, 'pathProblem("\\x00") == ppControlChar',
        "a NUL can sit in a declared path. Every check above it then runs on "
        "the whole string and every C API below it sees the string truncated "
        "at the NUL — so the path that was checked and the path that is opened "
        "are different paths",
        control_name="the control-character test is written as a set membership",
        control_find="    if ch < ' ' or ch == '\\x7f':\n      return ppControlChar",
        control_replace="    if ch in {'\\x00' .. '\\x1f', '\\x7f'}:\n      return ppControlChar",
    ),
    Mutation(
        "C4", CONTAIN,
        "        if ch notin ContainedSegmentChars:\n          return ppBadChar",
        "        if false:\n          return ppBadChar",
        P_META, NIM_PURE, 'pathProblem(bad) != ppOk',
        "the closed character set stops being closed, so `$HOME`, a backtick, "
        "a glob and a `;` are all path characters — and the grammar becomes a "
        "blocklist of the two or three shapes still checked above",
        control_name="the membership is tested through a named binding",
        control_find="        if ch notin ContainedSegmentChars:\n          return ppBadChar",
        control_replace="        let allowed = ch in ContainedSegmentChars\n"
                        "        if not allowed:\n          return ppBadChar",
    ),
    Mutation(
        "C5", CONTAIN,
        "    if c in {'A' .. 'Z', 'a' .. 'z'}:\n      return ppDriveLetter",
        "    if false:\n      return ppDriveLetter",
        P_ESCAPES, NIM_PURE,
        'pathProblem("C:\\\\Windows\\\\System32\\\\cmd.exe") == ppDriveLetter',
        "a Windows drive letter is no longer diagnosed as one. It is still "
        "refused — `:` is outside the character set — but as a generic bad "
        "character, so a Windows author is told their path has a character "
        "problem rather than that it names another filesystem",
        control_name="the letter test is written as two ranges in the other order",
        control_find="    if c in {'A' .. 'Z', 'a' .. 'z'}:\n      return ppDriveLetter",
        control_replace="    if c in {'a' .. 'z', 'A' .. 'Z'}:\n      return ppDriveLetter",
    ),
    Mutation(
        "C6", CONTAIN,
        "  MaxContainedPathSegments* = 32",
        "  MaxContainedPathSegments* = 4096",
        P_BOUNDS, NIM_PURE, "MaxContainedPathSegments == 32",
        "the segment bound stops being a bound anything reaches, so the walk "
        "over a declared path is bounded by the length of attacker-controlled "
        "input rather than by a constant",
        control_name="the same bound written as an arithmetic expression",
        control_find="  MaxContainedPathSegments* = 32",
        control_replace="  MaxContainedPathSegments* = 16 + 16",
    ),
    Mutation(
        "C7", CONTAIN,
        '  "\'" & path & "\' " & reason(p)',
        "  reason(p)",
        P_EXPLAINS, NIM_PURE, 'text.contains("the/offending/path")',
        "a containment refusal stops naming the path it refused. In a monorepo "
        "with several `.codetracer/` directories that is a message a reader "
        "cannot act on, which is the blank surface this whole package refuses "
        "in a different costume",
        control_name="the subject is prefixed through a named binding",
        control_find='  "\'" & path & "\' " & reason(p)',
        control_replace='  let subject = "\'" & path & "\' "\n  subject & reason(p)',
    ),
    Mutation(
        "C8", CONTAIN,
        "        if ch notin ContainedSegmentChars:",
        "        if ch notin ContainedSegmentChars + {'\\x80' .. '\\xff'}:",
        P_NONASCII, NIM_PURE, 'pathProblem("src/café.nim") == ppBadChar',
        "non-ASCII bytes become path characters, which admits overlong UTF-8 "
        "encodings of `/` and `.` — the exact mechanism of the classic "
        "directory-traversal family — into a predicate that does no UTF-8 "
        "validation",
        control_name="the set is named before the membership test",
        control_find="        if ch notin ContainedSegmentChars:",
        control_replace="        let permitted = ContainedSegmentChars\n"
                        "        if ch notin permitted:",
    ),

    # -- the closed grammar --------------------------------------------------
    Mutation(
        "P1", PARSE,
        '        "per-repository trust grant (Project-Definitions.md §2.1)")\n'
        "      result = false",
        '        "per-repository trust grant (Project-Definitions.md §2.1)")',
        P_INTERP, NIM_PURE, "defs.visualisers.len == 0",
        "an unknown key is REPORTED and the entry is loaded anyway. A rule "
        "carrying `interpreter = \"/bin/sh\"` becomes a live visualiser rule "
        "whose author wrote something this build did not read — which is a "
        "partial honouring of a file, and §6 forbids exactly that one level up",
        control_name="the verdict is set through a named binding",
        control_find='        "per-repository trust grant (Project-Definitions.md §2.1)")\n'
                     "      result = false",
        control_replace='        "per-repository trust grant (Project-Definitions.md §2.1)")\n'
                        "      let keyIsUnknown = true\n"
                        "      result = not keyIsUnknown",
    ),
    Mutation(
        "P2", PARSE,
        "    if key notin AcceptedKeys[table]:",
        "    if false:",
        P_INTERP, NIM_PURE, "wanted pdcUnknownKey, got:",
        "THE CLOSED-KEY CHECK STOPS BEING A CHECK. Every key a repository "
        "cares to write is accepted and silently ignored, which is the "
        "'unrecognised, ignored' arm this whole file exists not to have — and "
        "the one an author would discover by their definitions never applying",
        control_name="the membership is tested through a named binding",
        control_find="    if key notin AcceptedKeys[table]:",
        control_replace="    let accepted = key in AcceptedKeys[table]\n"
                        "    if not accepted:",
    ),
    Mutation(
        "P3", PARSE,
        '    @["schema", "collection"],',
        '    @["schema", "collection", "visualiser", "diff"],',
        P_STRAYTABLE, NIM_PURE, "wanted pdcUnknownKey, got:",
        "`points.toml` starts accepting the other files' top-level tables. A "
        "`[[visualiser]]` written into `points.toml` is then read by nobody "
        "and reported by nobody — the silently-ignored arm arriving through a "
        "TABLE NAME instead of through a key",
        control_name="the two-name row is written by concatenation",
        control_find='    @["schema", "collection"],',
        control_replace='    @["schema"] & @["collection"],',
    ),
    Mutation(
        "P4", PARSE,
        "  if file.text.len > MaxDefinitionBytes:",
        "  if false:",
        P_OVERSIZE, NIM_PURE, "wanted pdcFileTooLarge, got:",
        "the size bound stops being applied before the parser is entered, so "
        "a definition of any size is tokenised — §2.2's bounded evaluation, "
        "removed at the one place where the input is attacker-chosen and "
        "unbounded",
        control_name="the byte count is compared through a named binding",
        control_find="  if file.text.len > MaxDefinitionBytes:",
        control_replace="  let bytes = file.text.len\n"
                        "  if bytes > MaxDefinitionBytes:",
    ),
    Mutation(
        "P5", PARSE,
        "  if lines > MaxDefinitionLines:",
        "  if false:",
        P_LINES, NIM_PURE, "wanted pdcTooManyLines, got:",
        "a definition can be small in bytes and enormous in lines, and every "
        "diagnostic it produces then costs a full scan of the file to find "
        "its line number",
        control_name="the line bound is compared the other way round",
        control_find="  if lines > MaxDefinitionLines:",
        control_replace="  if not (lines <= MaxDefinitionLines):",
    ),
    Mutation(
        "P6", PARSE,
        "  if schema != schemaOf(file.kind):",
        "  if false:",
        P_FUTURE, NIM_PURE, "wanted pdcUnknownSchemaVersion, got:",
        "a file from a FUTURE CodeTracer is read with this build's reader. "
        "Whatever the new version added is silently dropped and whatever it "
        "kept is honoured, so the project gets half of a definition nobody "
        "wrote — the failure §6 names `LayoutDecodeError`'s rule to prevent",
        control_name="the schema comparison is written as a negated equality",
        control_find="  if schema != schemaOf(file.kind):",
        control_replace="  if not (schema == schemaOf(file.kind)):",
    ),
    Mutation(
        # THE ARM DOES NOT REMOVE THE GUARD, and the reason is worth a note:
        # removing it leaves `schemaNode.strVal` on a nil ref two lines later,
        # which SEGFAULTS the suite rather than reddening a case — and on this
        # harness's first run that was scored `SURVIVED`, because a crashed
        # run has no failures in it. The `SUITE-DIED` verdict now catches that
        # shape; the arm was re-aimed at the thing actually worth grading,
        # which is that the two refusals are DIFFERENT refusals.
        "P7", PARSE,
        "    r.note(pdcMissingSchema,",
        "    r.note(pdcUnknownSchemaVersion,",
        P_NOSCHEMA, NIM_PURE, "wanted pdcMissingSchema, got:",
        "a file that never declared a schema is reported as one this build is "
        "too old for. The two have OPPOSITE remedies — 'add the schema line' "
        "and 'upgrade CodeTracer' — and §4b's lesson is that a refusal "
        "asserted only as 'it refused' passes when the refusal was for the "
        "wrong reason",
        control_name="the code is passed through a named binding",
        control_find="    r.note(pdcMissingSchema,",
        control_replace="    let noSchemaDeclared = pdcMissingSchema\n"
                        "    r.note(noSchemaDeclared,",
    ),
    Mutation(
        "P8", PARSE,
        "      let pp = pathProblem(rawPath)",
        "      let pp = ppOk",
        P_PATHOUT, NIM_PURE, "wanted pdcPathEscapesProject, got:",
        "THE CONTAINMENT PREDICATE STOPS BEING CALLED. The grammar still "
        "refuses nothing itself; a point may name `../../etc/passwd`, and "
        "every consumer downstream of the parse receives it as an ordinary "
        "source path",
        control_name="the verdict is read through a second named binding",
        control_find="      let pp = pathProblem(rawPath)",
        control_replace="      let verdict = pathProblem(rawPath)\n      let pp = verdict",
    ),
    Mutation(
        "P9", PARSE,
        "      if k notin ValuePresentationKinds: return false",
        "      if false: return false",
        P_PRESENT, NIM_PURE, "wanted pdcUnknownPresentation, got:",
        "a visualiser may declare `present = \"Button\"`. A recorded value has "
        "no actuation, so the declaration names something a value cannot be — "
        "and PLAT-12 would discover it at render time, as a blank cell, which "
        "is §4.1's silently-missing-feature",
        control_name="the membership is tested through a named binding",
        control_find="      if k notin ValuePresentationKinds: return false",
        control_replace="      let aValueCanBeThis = k in ValuePresentationKinds\n"
                        "      if not aValueCanBeThis: return false",
    ),
    Mutation(
        "P10", PARSE,
        "    if v.mediaType.len > 0 and v.mediaType notin DeclarativeMediaTypes:",
        "    if false:",
        P_MEDIA, NIM_PURE, "wanted pdcUnknownMediaType, got:",
        "the media list stops being closed, so a rule may declare any MIME "
        "type at all — and a type nothing renders is a value that shows up "
        "blank on every surface with no message anywhere",
        control_name="the two conditions are tested in the other order",
        control_find="    if v.mediaType.len > 0 and v.mediaType notin DeclarativeMediaTypes:",
        control_replace="    if v.mediaType notin DeclarativeMediaTypes and v.mediaType.len > 0:",
    ),
    Mutation(
        "P11", PARSE,
        "    if not diffAlgorithmByName(algName, d.algorithm):",
        "    if false:",
        P_ALGO, NIM_PURE, "wanted pdcUnknownDiffAlgorithm, got:",
        "a scratchpad diff may name anything at all as its algorithm, and the "
        "selection silently becomes the enum's zero value. §7's declarative "
        "half is SELECTING from a closed set; a name outside it that is "
        "accepted is the first half of turning a name into a lookup",
        control_name="the lookup is written through a named binding",
        control_find="    if not diffAlgorithmByName(algName, d.algorithm):",
        control_replace="    let known = diffAlgorithmByName(algName, d.algorithm)\n"
                        "    if not known:",
    ),
    Mutation(
        "P12", PARSE,
        "        if s[j] == '{': return tpNested",
        "        if false: return tpNested",
        P_TEMPLATE, NIM_PURE, 'templateProblem("{a{b}}") == tpNested',
        "a summary template may nest placeholders, so substitution is no "
        "longer one linear pass over text it does not re-scan — which is what "
        "made §2.2's 'templating is total and terminates by construction' true "
        "without a step budget",
        control_name="the brace test is written as a set membership",
        control_find="        if s[j] == '{': return tpNested",
        control_replace="        if s[j] in {'{'}: return tpNested",
    ),
    Mutation(
        "P13", PARSE,
        "    if n > hi: return false",
        "    if false: return false",
        P_DECIMAL, NIM_PURE, 'boundedDecimal("101", n, 0, 100) was true',
        "a quoted decimal is no longer bounded during accumulation, so an "
        "`occurrence` of nine digits is accepted — and the anchor scan it "
        "drives becomes a walk the definition chose the length of",
        control_name="the bound is compared the other way round",
        control_find="    if n > hi: return false",
        control_replace="    if not (n <= hi): return false",
    ),
    Mutation(
        "P14", PARSE,
        "    if expDigits == 0 or expDigits > 2: return false",
        "    if false: return false",
        P_TOLERANCE, NIM_PURE, 'boundedTolerance("1e") was true',
        "a tolerance may carry an empty or enormous exponent. `1e` parses as "
        "valid and `1e1000` with it, so the value a scratchpad diff is "
        "configured with stops being a number anything can use",
        control_name="the two conditions are tested in the other order",
        control_find="    if expDigits == 0 or expDigits > 2: return false",
        control_replace="    if expDigits > 2 or expDigits == 0: return false",
    ),
    Mutation(
        "P15", PARSE,
        "  if child.items.len > maxEntries:",
        "  if false:",
        P_ENTRYBOUNDS, NIM_PURE, "wanted pdcTooManyEntries, got:",
        "every `[[...]]` bound goes at once — collections, points, rules, "
        "hidden fields, diff selections — so one definition file can declare "
        "as many entries as it has bytes for",
        control_name="the entry count is compared through a named binding",
        control_find="  if child.items.len > maxEntries:",
        control_replace="  let declared = child.items.len\n"
                        "  if declared > maxEntries:",
    ),
    Mutation(
        "P16", PARSE,
        "  if child.strVal.len > maxBytes:",
        "  if false:",
        P_TOOLONG, NIM_PURE, "wanted pdcValueTooLong, got:",
        "every bounded string in the grammar stops being bounded: a collection "
        "name, an anchor, an expression and a type match may each be the "
        "whole file",
        control_name="the string length is compared the other way round",
        control_find="  if child.strVal.len > maxBytes:",
        control_replace="  if not (child.strVal.len <= maxBytes):",
    ),
    Mutation(
        "P17", PARSE,
        "    if p.anchor.text.strip().len == 0:",
        "    if false:",
        P_ANCHOR, NIM_PURE, "wanted pdcAnchorMissing, got:",
        "a point may be located by a BARE LINE NUMBER, which §4 forbids by "
        "name: the point then silently marks a different statement the first "
        "time anything is inserted above it, and nothing anywhere says it "
        "moved",
        control_name="the anchor emptiness is tested through a named binding",
        # SIX SPACES, NOT FOUR. The `find` above matches as a SUBSTRING of a
        # line indented six, which is fine for a replacement that is one line;
        # a control that adds a line has to carry the real indentation or Nim
        # reports `invalid indentation` and the control is scored
        # CONTROL-DID-NOT-RUN. Measured on this harness's first full run.
        control_find="      if p.anchor.text.strip().len == 0:",
        control_replace="      let anchorText = p.anchor.text.strip()\n"
                        "      if anchorText.len == 0:",
    ),
    Mutation(
        "P18", PARSE,
        "    if seen.hasKey(c.name):",
        "    if false:",
        P_DUP, NIM_PURE, "wanted pdcDuplicateName, got:",
        "two collections may share a name. Enabling it could only ever enable "
        "one of them and nothing would say which, so a user turns on 'the "
        "request path' and gets somebody else's points",
        control_name="the presence is tested through a named binding",
        control_find="    if seen.hasKey(c.name):",
        control_replace="    let alreadyDeclared = seen.hasKey(c.name)\n"
                        "    if alreadyDeclared:",
    ),
    Mutation(
        "P19", PARSE,
        "    if c.points.len == 0:",
        "    if false:",
        P_EMPTY, NIM_PURE, "wanted pdcEmptyCollection, got:",
        "a named collection with no points loads. A user sees a name they can "
        "enable, enables it, and nothing happens — `lpUnknownPane`'s blank "
        "surface with a label on it",
        control_name="the point count is compared the other way round",
        control_find="    if c.points.len == 0:",
        control_replace="    if not (c.points.len > 0):",
    ),

    # -- §6's composition and the user's own definitions ---------------------
    Mutation(
        "L1", LOAD,
        "    if f.origin != origin:",
        "    if false:",
        P_MIXED, NIM_PURE, "wanted pdcOriginMixed, got:",
        "the project's set and the user's stop being kept apart by anything "
        "other than the caller's memory. §6's whole point is that a user's "
        "local experiment must never become a diff, and the one function that "
        "could merge them stops checking",
        control_name="the origin comparison is written as a negated equality",
        control_find="    if f.origin != origin:",
        control_replace="    if not (f.origin == origin):",
    ),
    Mutation(
        "L2", LOAD,
        "    let sp = if f.scope.len == 0: ppOk else: pathProblem(f.scope)",
        "    let sp = ppOk",
        P_SCOPEOUT, NIM_PURE, "wanted pdcScopeEscapesProject, got:",
        "a package scope is no longer a path inside the checkout. Composition "
        "becomes the channel the per-path check closes: every point of a "
        "definition found at `../../elsewhere` is joined onto that scope and "
        "lands outside the project",
        control_name="the scope check is written with an explicit branch",
        control_find="    let sp = if f.scope.len == 0: ppOk else: pathProblem(f.scope)",
        control_replace="    var sp = ppOk\n"
                        "    if f.scope.len > 0: sp = pathProblem(f.scope)",
    ),
    Mutation(
        "L3", LOAD,
        "    if tierOf(f.kind) == dtExecutable:",
        "    if false:",
        P_EXECTIER, NIM_PURE, "wanted notice pdnExecutableTierPresent, got:",
        "an executable-tier file is handed to the DECLARATIVE reader instead "
        "of being reported unread. It is still not run — there is nothing "
        "that runs — but the tier boundary stops being a boundary and the "
        "notice that tells a user their visualiser was not loaded disappears",
        control_name="the tier is read into a named binding",
        control_find="    if tierOf(f.kind) == dtExecutable:",
        control_replace="    let tier = tierOf(f.kind)\n"
                        "    if tier == dtExecutable:",
    ),
    Mutation(
        "L4", LOAD,
        "    result = cmp(scopeDepth(a.scope), scopeDepth(b.scope))\n"
        "    if result == 0: result = cmp(a.scope, b.scope)",
        "    result = cmp(scopeDepth(b.scope), scopeDepth(a.scope))\n"
        "    if result == 0: result = cmp(a.scope, b.scope)",
        P_SHADOW, NIM_PURE,
        'pr.detail.contains("ENTIRELY rather than merging")',
        "the files stop being ordered nearest-last before composition, so "
        "the shadow REPORT names the wrong side as the winner: the nested "
        "definition is described as the one that was replaced. §6 asks for "
        "the override rules to be stated rather than emergent, and a "
        "statement that is backwards is worse than none. (The chosen "
        "collection itself survives this arm, because the depth test below is "
        "the second of two mechanisms — which is what makes this an arm about "
        "the REPORT, and why its killer is the shadowing case rather than the "
        "ordering one.)",
        control_name="the depth comparison is written through named bindings",
        control_find="    result = cmp(scopeDepth(a.scope), scopeDepth(b.scope))\n"
                     "    if result == 0: result = cmp(a.scope, b.scope)",
        control_replace="    let da = scopeDepth(a.scope)\n"
                        "    let db = scopeDepth(b.scope)\n"
                        "    result = cmp(da, db)\n"
                        "    if result == 0: result = cmp(a.scope, b.scope)",
    ),
    Mutation(
        "L5", LOAD,
        "        if scopeDepth(c.scope) >= scopeDepth(prev.scope):",
        "        if false:",
        P_SHADOW, NIM_PURE, "c.points[0].path was shared.rs",
        "a nested package can no longer override an ancestor's collection of "
        "the same name — the ancestor's wins whatever the nesting — so §6's "
        "'a nested project inherits AND MAY OVERRIDE' loses its second half",
        control_name="the two depths are compared through named bindings",
        control_find="        if scopeDepth(c.scope) >= scopeDepth(prev.scope):",
        control_replace="        let here = scopeDepth(c.scope)\n"
                        "        let there = scopeDepth(prev.scope)\n"
                        "        if here >= there:",
    ),
    Mutation(
        "L6", LOAD,
        "    result = cmp(scopeDepth(b.scope), scopeDepth(a.scope))\n"
        "    if result == 0: result = cmp(specificity(b), specificity(a))",
        "    result = cmp(scopeDepth(a.scope), scopeDepth(b.scope))\n"
        "    if result == 0: result = cmp(specificity(b), specificity(a))",
        P_RULEORDER, NIM_PURE,
        'loaded.project.visualisers[0].summary == "nested"',
        "a visualiser rule declared in a package ranks BELOW the repository "
        "root's, so the most specific knowledge — the package's own — is the "
        "one that loses every contest",
        control_name="the depth comparison is written through named bindings",
        control_find="    result = cmp(scopeDepth(b.scope), scopeDepth(a.scope))\n"
                     "    if result == 0: result = cmp(specificity(b), specificity(a))",
        control_replace="    let deeper = scopeDepth(b.scope)\n"
                        "    let shallower = scopeDepth(a.scope)\n"
                        "    result = cmp(deeper, shallower)\n"
                        "    if result == 0: result = cmp(specificity(b), specificity(a))",
    ),
    Mutation(
        "L7", LOAD,
        "    if result == 0: result = cmp(specificity(b), specificity(a))",
        "    if result == 0: result = cmp(specificity(a), specificity(b))",
        P_SPECIFIC, NIM_PURE,
        'loaded.project.visualisers[0].summary == "a vec3"',
        "§5.4's 'within a tier the more specific match wins' inverts: a "
        "prefix rule matching every `Vec*` outranks the exact rule for `Vec3`, "
        "so the general case shadows the particular one",
        control_name="the specificities are compared through named bindings",
        control_find="    if result == 0: result = cmp(specificity(b), specificity(a))",
        control_replace="    if result == 0:\n"
                        "      let sb = specificity(b)\n"
                        "      let sa = specificity(a)\n"
                        "      result = cmp(sb, sa)",
    ),
    Mutation(
        "L8", LOAD,
        "      if a.match == b.match and a.matchKind == b.matchKind and",
        "      if false and a.matchKind == b.matchKind and",
        P_TIE, NIM_PURE, "wanted notice pdnRuleTieReported, got:",
        "§5.4's 'ties broken by declaration order AND REPORTED' loses the "
        "reporting. The tie is still broken deterministically and a user "
        "asking which visualiser rendered a value gets 'the first one' with "
        "no way to know there was a contest",
        control_name="the match equality is tested through a named binding",
        control_find="      if a.match == b.match and a.matchKind == b.matchKind and",
        control_replace="      let sameMatch = a.match == b.match\n"
                        "      if sameMatch and a.matchKind == b.matchKind and",
    ),
    Mutation(
        "L9", LOAD,
        "  for c in l.project.collections: result.add c\n"
        "  for c in l.user.collections: result.add c",
        "  for c in l.project.collections: result.add c",
        P_USERSEP, NIM_PURE, "all.len was 1",
        "the one function that shows a user BOTH sets stops showing them "
        "their own. §6 forbids merging the user's into the project's; it does "
        "not ask for the user's to be hidden from them, and a pane listing "
        "only the project's is how a user loses track of what they wrote",
        control_name="the two loops are written over a named sequence",
        control_find="  for c in l.project.collections: result.add c\n"
                     "  for c in l.user.collections: result.add c",
        control_replace="  let both = [l.project.collections, l.user.collections]\n"
                        "  for group in both:\n"
                        "    for c in group: result.add c",
    ),

    # -- §4's re-resolution --------------------------------------------------
    Mutation(
        "R1", RESOLVE,
        "    result.points.add resolvePoint(p, src.lines, src.present)",
        "    let pr = resolvePoint(p, src.lines, src.present)\n"
        "    if isUsable(pr.outcome): result.points.add pr",
        P_RESOLVE, NIM_PURE, "r.points.len == c.points.len",
        "THE FILTER §4 FORBIDS. 'A point whose location no longer resolves is "
        "reported, not dropped. A collection that silently loses half its "
        "points as a file evolves is worse than one that says so.' With this "
        "arm applied a collection of four returns two, and nothing anywhere "
        "records that two are missing",
        control_name="the resolution is bound before it is appended",
        control_find="    result.points.add resolvePoint(p, src.lines, src.present)",
        control_replace="    let resolved = resolvePoint(p, src.lines, src.present)\n"
                        "    result.points.add resolved",
    ),
    Mutation(
        "R2", RESOLVE,
        "      if seen == anchor.occurrence:",
        "      if true:",
        P_OCCUR, NIM_PURE, "r.points[1].outcome == prUnresolved",
        "the occurrence is ignored and every anchor resolves to its FIRST "
        "match. A point anchored on the second `fn helper` slides onto the "
        "first the moment either is touched — the silent mislocation the "
        "anchor mechanism exists to prevent, inside the anchor mechanism",
        control_name="the occurrence is compared through a named binding",
        control_find="      if seen == anchor.occurrence:",
        control_replace="      let wanted = anchor.occurrence\n"
                        "      if seen == wanted:",
    ),
    Mutation(
        "R3", RESOLVE,
        "    if raw.strip().contains(anchor.text):",
        "    if raw == anchor.text:",
        P_REINDENT, NIM_PURE,
        "resolveCollection(c, sources).points[0].outcome == prResolved",
        "an anchor must be the WHOLE line, stripped of nothing. A formatter "
        "re-indenting a file unresolves every point in it at once, and so "
        "does any anchor an author wrote as a fragment of a line rather than "
        "the whole of it",
        control_name="the stripped line is bound before it is searched",
        control_find="    if raw.strip().contains(anchor.text):",
        control_replace="    let stripped = raw.strip()\n"
                        "    if stripped.contains(anchor.text):",
    ),
    Mutation(
        "R4", RESOLVE,
        "  if target > lines.len:",
        "  if false:",
        P_OFFEND, NIM_PURE, "r.points[0].outcome == prUnresolved",
        "a point whose offset walks past the end of the file resolves anyway, "
        "to a line that is not there. A pane then offers a jump to it, which "
        "is the arbitrary target the whole anchor design refuses",
        control_name="the target is compared the other way round",
        control_find="  if target > lines.len:",
        control_replace="  if not (target <= lines.len):",
    ),
    Mutation(
        "R5", RESOLVE,
        "  if p.anchor.line == 0 or p.anchor.line == target:",
        "  if true:",
        P_RESOLVE, NIM_PURE, "r.points[0].outcome == prMoved",
        "every point reports `resolved`, including the ones that moved. A "
        "collection pointing at a restructured file then looks perfectly "
        "healthy, which is the one signal a user has that a definition needs "
        "re-recording",
        control_name="the line hint is read into a named binding",
        control_find="  if p.anchor.line == 0 or p.anchor.line == target:",
        control_replace="  let hint = p.anchor.line\n"
                        "  if hint == 0 or hint == target:",
    ),
    Mutation(
        "R6", RESOLVE,
        "  if not presentInCheckout:",
        "  if false:",
        P_RESOLVE, NIM_PURE, "r.points[3].outcome == prFileAbsent",
        "'the file you named is not in this checkout' collapses into 'the "
        "code you anchored to has been rewritten'. Both send a reader "
        "somewhere, and with this arm applied one of them sends them to the "
        "wrong place",
        control_name="the presence is tested with an explicit comparison",
        control_find="  if not presentInCheckout:",
        control_replace="  if presentInCheckout == false:",
    ),

    # -- the filesystem half -------------------------------------------------
    Mutation(
        "D1", DIR,
        "  if tierOf(kind) == dtExecutable:",
        "  if false:",
        C_BYTES, NIM_CLI, "f.text == \"\"",
        "THE BYTES OF AN EXECUTABLE-TIER DEFINITION ENTER THE PROCESS. "
        "Nothing runs them — there is nothing that runs anything — but §2.3's "
        "grant is supposed to gate the file BEFORE it is read, and a build "
        "that has already read it is one repair away from a build that uses "
        "what it read",
        control_name="the tier is read into a named binding",
        control_find="  if tierOf(kind) == dtExecutable:",
        control_replace="  let tier = tierOf(kind)\n"
                        "  if tier == dtExecutable:",
    ),
    Mutation(
        "D2", DIR,
        "  if size > MaxDefinitionBytes:",
        "  if false:",
        C_DISKSIZE, NIM_CLI, 'pr.detail.contains("bytes on disk")',
        "an oversized definition is READ INTO MEMORY and then refused by the "
        "parser's own byte bound. The refusal still happens and the message "
        "still says 'too large', which is exactly why this is worth an arm: "
        "the only observable difference is a four-gigabyte read nobody "
        "budgeted for",
        control_name="the size is compared the other way round",
        control_find="  if size > MaxDefinitionBytes:",
        control_replace="  if not (size <= MaxDefinitionBytes):",
    ),
    Mutation(
        "D3", DIR,
        "    let sp = pathProblem(scope)\n    if sp != ppOk:",
        "    let sp = ppOk\n    if sp != ppOk:",
        C_SCOPE, NIM_CLI, "wanted pdcScopeEscapesProject, got:",
        "a caller's package scope stops being checked at the point it is "
        "joined to the checkout root, so `../elsewhere` and `/etc` become "
        "directories this scanner walks",
        control_name="the verdict is read through a second named binding",
        control_find="    let sp = pathProblem(scope)\n    if sp != ppOk:",
        control_replace="    let verdict = pathProblem(scope)\n"
                        "    let sp = verdict\n    if sp != ppOk:",
    ),
    Mutation(
        "D4", DIR,
        "  if pathProblem(repoRelativePath) != ppOk:",
        "  if false:",
        C_READGUARD, NIM_CLI,
        'readSourceFile(root, "../ct-plat11-outside-" & '
        '$getCurrentProcessId() & ".txt").present was true',
        "THE CHECK AT THE SYSCALL GOES. The grammar upstream still refuses "
        "an escaping path, so nothing breaks today — and the one check that "
        "would survive a refactor of everything upstream of it is the one "
        "removed",
        control_name="the verdict is read into a named binding",
        control_find="  if pathProblem(repoRelativePath) != ppOk:",
        control_replace="  let contained = pathProblem(repoRelativePath) == ppOk\n"
                        "  if not contained:",
    ),
    Mutation(
        "D5", DIR,
        "      if name in known: continue",
        "      continue",
        C_FILESET, NIM_CLI, "strayNames.len == 2",
        "the typo report stops reporting. `point.toml` — one character from "
        "`points.toml` — is then read by nobody and mentioned by nobody, and "
        "its author sees their definitions simply not apply",
        control_name="the membership is tested through a named binding",
        control_find="      if name in known: continue",
        control_replace="      let isADefinition = name in known\n"
                        "      if isADefinition: continue",
    ),

    # -- the verification gate -----------------------------------------------
    Mutation(
        "V1", SOURCE,
        "  vm.setPoints rowsOf(resolutions, enabledCollections)",
        "  discard rowsOf(resolutions, enabledCollections)",
        V_GATE, NIM_VM, "vm.points.val.len > 0",
        "PLAT-11'S VERIFICATION GATE, REMOVED. `PointListVM.points` goes back "
        "to being written by nothing — the state six other modules in this "
        "tree cite by name as the canonical never-filled signal",
        control_name="the rows are bound before they are written",
        control_find="  vm.setPoints rowsOf(resolutions, enabledCollections)",
        control_replace="  let rows = rowsOf(resolutions, enabledCollections)\n"
                        "  vm.setPoints rows",
    ),
    Mutation(
        "V2", SOURCE,
        "    for pr in cr.points:\n      result.add rowOf(pr, cr.collection.name, on)",
        "    for pr in cr.points:\n"
        "      if isUsable(pr.outcome):\n"
        "        result.add rowOf(pr, cr.collection.name, on)",
        V_ROW, NIM_VM, "rows.len == 5",
        "the producer FILTERS. A point whose anchor is gone, and a point whose "
        "file is gone, both vanish from the pane — §4's 'reported, not "
        "dropped', deleted at the one place a user would have seen it",
        control_name="the row is bound before it is appended",
        control_find="    for pr in cr.points:\n      result.add rowOf(pr, cr.collection.name, on)",
        control_replace="    for pr in cr.points:\n"
                        "      let row = rowOf(pr, cr.collection.name, on)\n"
                        "      result.add row",
    ),
    Mutation(
        "V3", SOURCE,
        "    line: r.line,",
        "    line: (if r.line > 0: r.line else: r.point.anchor.line),",
        V_ROW, NIM_VM, "rows[2].line == 0",
        "an unresolvable point gets a PLAUSIBLE-LOOKING line — the one the "
        "definition recorded before the file changed. A pane then offers a "
        "jump to a statement that has nothing to do with the point, which is "
        "the silent mislocation the anchor design exists to prevent, arriving "
        "one layer after the anchor did its job",
        control_name="the resolved line is bound before the row is built",
        control_find="    line: r.line,",
        control_replace="    line: block:\n      let resolvedLine = r.line\n      resolvedLine,",
    ),
    Mutation(
        "V4", SOURCE,
        "    let on = cr.collection.name in enabledCollections",
        "    let on = true",
        V_ENABLED, NIM_VM, "enabledRows == 0",
        "every point is enabled whatever the definition or the user said, so "
        "opening a project turns on every tracepoint any collection declares "
        "— including the ones its author marked `enabled = false`",
        control_name="the enabled set is queried through a named binding",
        control_find="    let on = cr.collection.name in enabledCollections",
        control_replace="    let name = cr.collection.name\n"
                        "    let on = name in enabledCollections",
    ),
]


DECLARED_SURVIVORS: list[Mutation] = []


@dataclass
class RunResult:
    rc: int = 0
    ran: bool = True
    passed: list[str] = None
    failed: list[str] = None
    output: str = ""

    def __post_init__(self):
        if self.passed is None:
            self.passed = []
        if self.failed is None:
            self.failed = []

    @property
    def total(self) -> int:
        return len(self.passed) + len(self.failed)


def run_suite(suite: Suite, label: str) -> RunResult:
    """Compile and run one suite; parse its verdict out of its RESULT LINES."""
    res = RunResult()
    compile_cmd = ["nim", "c", "-f", "--hints:off", "--warnings:off"]
    if suite.extra_path:
        compile_cmd.append("--path:src/frontend/viewmodel")
    compile_cmd += [f"--nimcache:/tmp/plat11-mut-cache-{Path(suite.path).stem}",
                    f"-o:{suite.binary}", suite.path]
    compile_proc = subprocess.run(compile_cmd, cwd=ROOT, capture_output=True,
                                  text=True, errors="replace", timeout=3600)
    if compile_proc.returncode != 0:
        res.rc = compile_proc.returncode
        res.ran = False
        res.output = compile_proc.stdout + compile_proc.stderr
        print("      ---- did not compile; last 12 lines ----")
        for line in res.output.splitlines()[-12:]:
            print("      " + line)
        return res
    # `errors="replace"` IS LOAD-BEARING, not defensive tidiness. Arm C4's
    # suite prints a `checkpoint` containing the bytes `\xc0\xaf` — an overlong
    # UTF-8 encoding of `/`, which is the whole point of the case it belongs
    # to — and a strict decode raises out of the harness MID-ARM, with a
    # mutation applied and the traceback pointing at `subprocess`. Measured on
    # this harness's first full run: arms C1-C3 graded, C4 crashed the driver.
    proc = subprocess.run([suite.binary], cwd=ROOT, capture_output=True,
                          text=True, errors="replace", timeout=3600)
    out = proc.stdout + proc.stderr
    res.output = out
    res.rc = proc.returncode
    for line in out.splitlines():
        m = NIM_RESULT.match(line)
        if m:
            (res.passed if m.group(1) == "OK" else res.failed).append(m.group(2))
    if res.total == 0:
        res.ran = False
        print("      ---- no result lines; last 12 lines of output ----")
        for line in out.splitlines()[-12:]:
            print("      " + line)
    return res


def apply_once(path: str, find: str, replace: str) -> tuple[str, str]:
    """Return (original, error). The needle must occur exactly once."""
    p = ROOT / path
    original = p.read_text()
    n = original.count(find)
    if n != 1:
        return original, f"pattern occurs {n} times in {path}, expected 1"
    p.write_text(original.replace(find, replace))
    return original, ""


def restore(path: str, original: str) -> None:
    (ROOT / path).write_text(original)


def read_control_hashes() -> dict[str, str]:
    if not CONTROL_HASHES.exists():
        return {}
    out: dict[str, str] = {}
    for line in CONTROL_HASHES.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        h, _, p = line.partition("  ")
        if h and p:
            out[p] = h
    return out


def needle_scan() -> list[str]:
    """Every arm whose `find` or `control_find` does not occur EXACTLY ONCE.

    Verification-Harness-Traps §16. A mutation arm is a QUOTATION of the code,
    held somewhere the compiler does not look, and every repair to the quoted
    file is an opportunity for it to stop matching. When it does, the arm can
    never be applied, so it can never be killed, and what it leaves behind is a
    row in the table that LOOKS like coverage.

    It gates `--record-control-hashes` rather than sitting beside it: blessing
    new bytes as the baseline is exactly the moment an arm's needle has just
    been moved, and recording first would certify the drift.
    """
    problems: list[str] = []
    for mut in MUTATIONS + DECLARED_SURVIVORS:
        body = (ROOT / mut.path).read_text()
        for label, needle in (("find", mut.find),
                              ("control_find", mut.control_find)):
            if not needle:
                continue
            n = body.count(needle)
            if n != 1:
                problems.append(
                    f"{mut.id}: {label} occurs {n} time(s) in {mut.path}, "
                    f"expected exactly 1")
    return problems


def report_needle_scan() -> int:
    problems = needle_scan()
    if not problems:
        print(f"  all {len(MUTATIONS) + len(DECLARED_SURVIVORS)} arm(s) resolve "
              f"to exactly one needle and one control needle")
        return 0
    print("ARM NEEDLES DO NOT RESOLVE — nothing was mutated and nothing recorded.")
    for line in problems:
        print(f"  {line}")
    print("  An arm whose needle no longer occurs can never be applied and can")
    print("  never be killed; it sits in the table looking like coverage.")
    print("  Re-aim it at the code as it is now, then re-run.")
    return 2


def write_control_hashes() -> None:
    body = ["# Control digests for run-plat11-definitions-mutations.py.",
            "#",
            "# ABSOLUTE, and that is the point. A baseline taken at start-up",
            "# cannot tell a clean tree from one a killed run left a mutation",
            "# in: it reads the mutation as the baseline, every restore then",
            "# verifies against the mutated bytes, and the only symptom is",
            "# `CONTROL IS NOT GREEN` — which describes a red suite without",
            "# naming the cause.",
            "#",
            "# Rewrite with --record-control-hashes, deliberately, when one of",
            "# these files changes on purpose. The needle scan gates that step",
            "# (Verification-Harness-Traps §16).",
            ""]
    for p in TOUCHED:
        body.append(f"{digest(p)}  {p}")
    CONTROL_HASHES.write_text("\n".join(body) + "\n")


def check_control_hashes() -> int:
    recorded = read_control_hashes()
    if not recorded:
        print(f"NO CONTROL HASHES: {CONTROL_HASHES.relative_to(ROOT)} is missing.")
        print("  Every restore below would verify against digests taken from")
        print("  THIS tree, so a mutation a killed run left behind would be")
        print("  adopted as the baseline. Record them from a tree you have")
        print("  checked, with --record-control-hashes.")
        return 2
    missing = [p for p in TOUCHED if p not in recorded]
    if missing:
        print(f"CONTROL HASHES INCOMPLETE: no entry for {missing}")
        print("  Re-record with --record-control-hashes.")
        return 2
    drifted = [p for p in TOUCHED if recorded.get(p) != digest(p)]
    if drifted:
        print("TREE IS NOT AT THE CONTROL BYTES — nothing was mutated.")
        for p in drifted:
            print(f"  {p}")
            print(f"      recorded {recorded[p]}")
            print(f"      on disk  {digest(p)}")
        print("  Either a previous run was killed before it restored, or one")
        print("  of these files changed on purpose. Check the diff, then")
        print("  re-record with --record-control-hashes.")
        return 2
    return 0


def install_signal_restore() -> None:
    """Turn SIGTERM/SIGHUP into an exception so `finally: restore(...)` runs."""

    def raise_on(signum, _frame):
        raise KeyboardInterrupt(f"signal {signum}")

    for sig in (signal.SIGTERM, signal.SIGHUP):
        try:
            signal.signal(sig, raise_on)
        except (ValueError, OSError):
            pass


def main() -> int:
    if "--needle-scan" in sys.argv[1:]:
        return report_needle_scan()

    if "--record-control-hashes" in sys.argv[1:]:
        rc = report_needle_scan()
        if rc:
            return rc
        write_control_hashes()
        print(f"recorded {len(TOUCHED)} control digest(s) in "
              f"{CONTROL_HASHES.relative_to(ROOT)}")
        return 0

    install_signal_restore()

    # THE LOCK IS TAKEN BEFORE THE HASH CHECK, and is held in a local for the
    # whole run: a garbage-collected file object closes its descriptor, and a
    # closed descriptor releases the flock.
    lock = acquire_lock()
    if lock is None:
        return 2

    rc = check_control_hashes()
    if rc:
        return rc

    # BEFORE ANY MUTATION. An arm that cannot be applied is not a thing to
    # discover forty minutes in, next to nineteen results you now have to
    # decide whether to trust.
    rc = report_needle_scan()
    if rc:
        return rc

    wanted = [a for a in sys.argv[1:] if not a.startswith("-")]
    selected = MUTATIONS + DECLARED_SURVIVORS
    if wanted:
        selected = [m for m in selected if m.id in wanted]
        missing = set(wanted) - {m.id for m in selected}
        if missing:
            print(f"no such arm(s): {sorted(missing)}")
            return 2
    survivors = [m for m in selected if m in DECLARED_SURVIVORS]

    baseline = {p: digest(p) for p in TOUCHED}

    # THE SUITE SET IS DERIVED FROM THE ARMS, not written out beside them —
    # a second registry of the same fact is where the two drift apart
    # (Verification-Harness-Traps §14).
    suites = []
    seen_suite_paths = set()
    for m in selected:
        if m.suite.path not in seen_suite_paths:
            seen_suite_paths.add(m.suite.path)
            suites.append(m.suite)
    controls: dict[str, RunResult] = {}

    print("== control ==")
    for s in suites:
        r = run_suite(s, "control-" + Path(s.path).stem)
        if not r.ran or r.failed:
            print(f"CONTROL IS NOT GREEN for {s.path}: rc={r.rc} failed={r.failed}")
            return 1
        controls[s.path] = r
        print(f"  {s.path}: {r.total} cases, 0 failures")

    problems = 0

    # EVERY KILLER MUST RESOLVE TO EXACTLY ONE GREEN CASE IN ITS OWN SUITE,
    # checked BEFORE any mutation. An arm whose killer does not is an arm that
    # can never legitimately be killed, and it would sit in the table looking
    # like coverage.
    for mut in selected:
        matches = [c for c in controls[mut.suite.path].passed if c == mut.killer]
        if len(matches) != 1:
            print(f"{mut.id}: killer {mut.killer!r} resolves to {len(matches)} "
                  f"green case(s) in {mut.suite.path}, expected exactly 1")
            problems += 1
    if problems:
        print(f"\n{problems} unusable arm(s); nothing was mutated")
        return 1
    print(f"  all {len(selected)} killers resolve to exactly one green case")

    # EVERY `because` MUST BE ABSENT FROM THE GREEN OUTPUT (§17's fix, and §5's
    # sentinel rule applied to it). A `because` that already occurs in a
    # passing run is true for free, so an arm carrying one could be scored
    # `killed` for a case that died three hundred lines upstream.
    for mut in selected:
        if not mut.because:
            print(f"{mut.id}: no `because`; a kill could not be attributed")
            problems += 1
            continue
        if mut.because in controls[mut.suite.path].output:
            print(f"{mut.id}: because {mut.because!r} already occurs in the "
                  f"GREEN output of {mut.suite.path}; it cannot be evidence "
                  f"that this arm is what reddened the case")
            problems += 1
    if problems:
        print(f"\n{problems} unusable arm(s); nothing was mutated")
        return 1
    print(f"  all {len(selected)} `because` needles are absent from the green "
          f"output\n")

    killed = 0
    for mut in selected:
        original, err = apply_once(mut.path, mut.find, mut.replace)
        if err:
            print(f"{mut.id:<5} HARNESS-FAILURE      {err}")
            problems += 1
            continue
        try:
            res = run_suite(mut.suite, f"{mut.id}-kill")
        finally:
            restore(mut.path, original)
            for p in TOUCHED:
                if digest(p) != baseline[p]:
                    print(f"{mut.id:<5} HARNESS-FAILURE      {p} did not restore "
                          f"to its control bytes")
                    return 2

        declared = mut in survivors
        newly_failed = [f for f in res.failed
                        if f not in controls[mut.suite.path].failed]
        attributed = mut.because in res.output
        if not res.ran:
            verdict, note = "HARNESS-FAILURE", "the mutation never ran"
            problems += 1
        elif declared and newly_failed:
            verdict, note = "NO-LONGER-A-SURVIVOR", f"now killed by {newly_failed}"
            problems += 1
        elif declared:
            verdict, note = "survived (declared)", mut.why
        elif (mut.killer not in res.passed) and (mut.killer not in res.failed):
            # See the header's fifth verdict. The binary produced result lines
            # and the killer case is in neither list, so it never ran.
            verdict = "SUITE-DIED"
            note = (f"the suite produced {res.total} result line(s) and "
                    f"{mut.killer!r} was not among them")
            problems += 1
        elif not newly_failed:
            verdict, note = "SURVIVED", "no case noticed"
            problems += 1
        elif mut.killer not in newly_failed:
            verdict, note = "MISDIRECTED", f"died in {newly_failed}, not {mut.killer!r}"
            problems += 1
        elif not attributed:
            # Verification-Harness-Traps §17: the case went red, and not for
            # this arm's reason. `the run told you nothing` — so this belongs
            # beside HARNESS-FAILURE, not beside `killed`.
            verdict = "MIS-ATTRIBUTED"
            note = f"the case died without {mut.because!r} in the failure output"
            problems += 1
        else:
            others = [f for f in newly_failed if f != mut.killer]
            killed += 1
            verdict = "killed"
            note = mut.killer + (f"  (+{len(others)} more)" if others else "")
        print(f"{mut.id:<5} {verdict:<20} {note}")

        # --- the named behaviour-preserving control ------------------------
        if not mut.control_find:
            print(f"{'':<5} NO-CONTROL           this arm has no behaviour-preserving control")
            problems += 1
            continue
        original, err = apply_once(mut.path, mut.control_find,
                                   mut.control_replace)
        if err:
            print(f"{'':<5} CONTROL-HARNESS-FAILURE  {err}")
            problems += 1
            continue
        try:
            cres = run_suite(mut.suite, f"{mut.id}-control")
        finally:
            restore(mut.path, original)
            for p in TOUCHED:
                if digest(p) != baseline[p]:
                    print(f"{mut.id:<5} HARNESS-FAILURE      {p} did not restore "
                          f"after the control")
                    return 2
        c_newly_failed = [f for f in cres.failed
                          if f not in controls[mut.suite.path].failed]
        if not cres.ran:
            print(f"{'':<5} CONTROL-DID-NOT-RUN  {mut.control_name}")
            problems += 1
        elif c_newly_failed:
            print(f"{'':<5} CONTROL-RED          {mut.control_name} -> {c_newly_failed}")
            problems += 1
        else:
            print(f"{'':<5} control green        {mut.control_name}")

    print(f"\n{killed} killed, {len(survivors)} declared survivor(s), "
          f"{problems} problems")
    # THE LOCK IS NAMED HERE ON PURPOSE. It is held by an open descriptor and
    # nothing else reads the variable, so a tidying pass would delete the
    # binding and silently re-open the concurrency hole it exists to close.
    print(f"run lock held for the whole run: {LOCK_PATH.name} (fd {lock.fileno()})")
    lock.close()
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

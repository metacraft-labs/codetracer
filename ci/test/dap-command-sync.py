#!/usr/bin/env python3
"""Keep `VALID_DAP_COMMANDS` in sync with the tables it mirrors — in BOTH
directions.

Why this exists
---------------
`src/frontend/viewmodel/backend/dap_commands.nim` opens by promising that its
strings "MUST match the non-empty values in ``EVENT_KIND_TO_DAP_MAPPING``" and
that "when a new CtEventKind with a DAP command is added, the corresponding
string must be added here as well". That promise was kept by hand, and a
hand-maintained mirror of a machine-readable fact drifts. It had:

  * `ct/set-active-source-view` and `ct/install-source-view` were already in
    `EVENT_KIND_TO_DAP_MAPPING` (`src/frontend/dap.nim`) and absent from the
    allow-list;
  * ten commands the Rust engine actually dispatches were absent from it —
    `scopes`, `threads`, `stackTrace`, `variables`, `restart`, `disconnect`,
    `ct/originMode`, `ct/load-request-spans`, `ct/set-active-source-view`,
    `ct/install-source-view`.

`backend/dap_dialect.md` §7b recorded that second drift as nine commands. It is
ten: `disconnect` is dispatched from the message loop rather than from
`handle_request`'s `match`, so an eye scanning the one obvious table misses it.
That is the argument for this file in one line — the drift was found by reading
a table, and the item the reader's eye skipped was in a different table.

Why this is a CHECK and not a derivation
----------------------------------------
Deriving `VALID_DAP_COMMANDS` outright was the first choice and it does not
work, because the list is not a mirror of one fact. It is the union of three,
and they do not all live in a table:

  1. requests the engine dispatches — `dap_server.rs`, and even this is four
     constructs (the `handle_request` match, its `_` fallthrough's `next` /
     `stepBack` / `stepIn` / `stepOut` special cases, the
     `dap_command_to_step_action` match, and the message-loop
     `DapMessage::Request` guards);
  2. events the engine EMITS — `stopped`, `output`, `ct/updated-*`,
     `ct/notification`, `tracepoint-locals` and friends. These are `sender.send`
     call sites scattered through the Rust, not a table anything can read;
  3. `internal/last-complete-move`, which no engine implements at all and which
     exists only inside the frontend.

Deriving the list from (1) alone would DELETE about twenty-five event strings
and break the renderer. And `dap_commands.nim` is deliberately pure Nim, with no
JS FFI, so that both the JS renderer and the native headless tests can import
it; teaching it to `staticRead` and regex-parse a Rust source file at compile
time would couple it to the layout of a tree it must not depend on.

So the derivable direction is derived and enforced here instead: everything the
engine dispatches, and everything the event mapping names, must appear in the
allow-list. That closes the class rather than the instance — the next command
added to `dap_server.rs` reddens this guard by name.

The three checks
----------------
  ENGINE   every command the engine dispatches is in `VALID_DAP_COMMANDS`.
           A command the engine implements but the allow-list omits is traffic
           `isValidDapCommand` would reject although it works.

  MAPPING  every non-empty `EVENT_KIND_TO_DAP_MAPPING` value is in
           `VALID_DAP_COMMANDS`. This is the module header's own promise.

  RESIDUE  the allow-list entries that have NO `CtEventKind` are pinned to an
           expected set. These are valid on the wire but `dapCommandToEventKind`
           raises `ValueError` on them, so `RealBackendService` cannot translate
           one if a ViewModel ever sends it. That set was empty before the ten
           were added and is deliberately non-empty now; pinning it is what
           stops it growing silently, since nothing else in the tree would
           notice.

Deliberately NOT checked: the reverse of ENGINE. The allow-list legitimately
contains strings the engine never dispatches — every emitted event, and the one
frontend-internal command — so "in the allow-list but not in `dap_server.rs`" is
the normal case and asserting on it would be noise.

Usage:
  ci/test/dap-command-sync.py
  ci/test/dap-command-sync.py --root DIR
  ci/test/dap-command-sync.py --commands-from F --mapping-from F --engine-from F
                              --residue a,b,c

The overrides exist so ci/test/dap-command-sync-test.sh can drive the checks
against synthetic inputs. They are not used in CI.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

# Relative to the repo root.
COMMANDS_NIM = "src/frontend/viewmodel/backend/dap_commands.nim"
MAPPING_NIM = "src/frontend/dap.nim"
ENGINE_RS = "src/db-backend/src/dap_server.rs"

# Allow-list entries with no CtEventKind. See RESIDUE above. Every one is a
# command the ENGINE dispatches (so it belongs in the allow-list) that no
# frontend ViewModel sends through BackendService (so it never needed an event
# kind). If you add to this set, say why here.
EXPECTED_RESIDUE = {
    # Standard DAP requests the engine answers. `worker_backend.nim` reaches
    # the engine directly for these rather than going through BackendService.
    "scopes",
    "threads",
    "stackTrace",
    "variables",
    "restart",
    "disconnect",
    # CodeTracer extension requests answered by the engine and driven from
    # `headless_session.nim` / the origin-mode bridge rather than from a VM.
    "ct/originMode",
    "ct/load-request-spans",
}

# Below these, an extractor has silently stopped matching and every subset check
# would pass vacuously. Universal quantification over an empty set is the
# failure mode these floors exist to remove.
MIN_COMMANDS = 60
MIN_MAPPING = 60
MIN_ENGINE = 40


def fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)


def read(path: pathlib.Path) -> str:
    if not path.is_file():
        print(f"ERROR: {path} does not exist", file=sys.stderr)
        sys.exit(2)
    return path.read_text(encoding="utf-8")


def brace_body(text: str, signature: str) -> str:
    """The `{...}` body following `signature`, brace-matched."""
    i = text.index(signature)
    j = text.index("{", i)
    depth = 0
    for k in range(j, len(text)):
        if text[k] == "{":
            depth += 1
        elif text[k] == "}":
            depth -= 1
            if depth == 0:
                return text[j : k + 1]
    raise ValueError(f"unbalanced braces after {signature!r}")


def extract_commands(text: str) -> set[str]:
    """VALID_DAP_COMMANDS_SEQ's string literals."""
    block = text.split("VALID_DAP_COMMANDS_SEQ*: seq[string] = @[", 1)[1]
    block = block.split("\n]", 1)[0]
    return set(re.findall(r'"([^"]+)"', block))


def extract_mapping(text: str) -> set[str]:
    """EVENT_KIND_TO_DAP_MAPPING's non-empty values."""
    block = text.split(
        "EVENT_KIND_TO_DAP_MAPPING*: array[CtEventKind, cstring] = [", 1
    )[1]
    block = block.split("\n]", 1)[0]
    return {v for _, v in re.findall(r'(\w+):\s*"([^"]*)"', block) if v}


def extract_engine(text: str) -> set[str]:
    """Every command the engine dispatches, from all four constructs.

    `#[cfg(test)]` is cut first: the Rust unit tests drive commands as string
    literals in exactly the shapes matched below, and counting those would make
    the guard assert that the allow-list mirrors the engine's TEST fixtures.
    """
    lines = text.split("\n")
    for i, line in enumerate(lines):
        if line.strip().startswith("#[cfg(test)]"):
            text = "\n".join(lines[:i])
            break

    found: set[str] = set()
    request = brace_body(text, "fn handle_request(")
    # 1. the match arms themselves
    found |= set(re.findall(r'^\s+"([^"]+)"\s*=>', request, re.M))
    # 2. the `_ =>` fallthrough's `if req.command == "x"` special cases
    found |= set(re.findall(r'req\.command == "([^"]+)"', request))
    # 3. the step-action match, which handle_request delegates to
    step = brace_body(text, "fn dap_command_to_step_action")
    found |= set(re.findall(r'^\s+"([^"]+)"\s*=>', step, re.M))
    # 4. the message loop, which answers some requests before handle_request
    #    ever sees them. `disconnect` lives only here.
    found |= set(
        re.findall(r'DapMessage::Request\(req\) if req\.command == "([^"]+)"', text)
    )
    return found


def main() -> int:
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--root", default=None)
    parser.add_argument("--commands-from", default=None)
    parser.add_argument("--mapping-from", default=None)
    parser.add_argument("--engine-from", default=None)
    parser.add_argument(
        "--residue",
        default=None,
        help="comma-separated expected residue; overrides EXPECTED_RESIDUE",
    )
    args = parser.parse_args()

    root = pathlib.Path(
        args.root
        if args.root
        else pathlib.Path(__file__).resolve().parent.parent.parent
    )

    commands_path = pathlib.Path(args.commands_from or root / COMMANDS_NIM)
    mapping_path = pathlib.Path(args.mapping_from or root / MAPPING_NIM)
    engine_path = pathlib.Path(args.engine_from or root / ENGINE_RS)

    allow = extract_commands(read(commands_path))
    mapping = extract_mapping(read(mapping_path))
    engine = extract_engine(read(engine_path))

    residue_expected = (
        {s for s in (x.strip() for x in args.residue.split(",")) if s}
        if args.residue is not None
        else EXPECTED_RESIDUE
    )

    # Synthetic runs are small by construction; the floors are about the real
    # tree, where a broken extractor is the thing that would go unnoticed.
    real_run = args.commands_from is None and args.engine_from is None

    print("=== DAP command table sync ===")
    print(f"VALID_DAP_COMMANDS:        {len(allow)}")
    print(f"EVENT_KIND_TO_DAP_MAPPING: {len(mapping)}")
    print(f"engine dispatches:         {len(engine)}")
    print("")

    status = 0

    if real_run:
        for name, got, floor in (
            ("VALID_DAP_COMMANDS", len(allow), MIN_COMMANDS),
            ("EVENT_KIND_TO_DAP_MAPPING", len(mapping), MIN_MAPPING),
            ("engine dispatch", len(engine), MIN_ENGINE),
        ):
            if got < floor:
                status = 1
                fail(
                    f"only {got} entries extracted for {name}, expected at least "
                    f"{floor}. The extractor has stopped matching, and every "
                    f"check below it would pass vacuously."
                )

    missing_engine = sorted(engine - allow)
    if missing_engine:
        status = 1
        fail(
            f"{len(missing_engine)} command(s) the ENGINE dispatches are absent "
            f"from VALID_DAP_COMMANDS:"
        )
        for c in missing_engine:
            print(f"  {c}", file=sys.stderr)
        print(
            "\n  isValidDapCommand rejects these although the engine implements\n"
            f"  them. Add them to {COMMANDS_NIM}.\n",
            file=sys.stderr,
        )

    missing_mapping = sorted(mapping - allow)
    if missing_mapping:
        status = 1
        fail(
            f"{len(missing_mapping)} EVENT_KIND_TO_DAP_MAPPING value(s) are "
            f"absent from VALID_DAP_COMMANDS:"
        )
        for c in missing_mapping:
            print(f"  {c}", file=sys.stderr)
        print(
            f"\n  {COMMANDS_NIM}'s header promises these two lists match.\n",
            file=sys.stderr,
        )

    residue = allow - mapping
    if residue != residue_expected:
        status = 1
        fail("the set of allow-listed commands with NO CtEventKind has changed.")
        for c in sorted(residue - residue_expected):
            print(f"  + {c}  (new: no CtEventKind)", file=sys.stderr)
        for c in sorted(residue_expected - residue):
            print(f"  - {c}  (gained a CtEventKind, or was removed)", file=sys.stderr)
        print(
            "\n  These are valid on the wire but dapCommandToEventKind raises\n"
            "  ValueError on them, so RealBackendService cannot translate one if\n"
            "  a ViewModel sends it. Update EXPECTED_RESIDUE in this file, with a\n"
            "  reason, in the same commit as the change that moved it.\n",
            file=sys.stderr,
        )

    if status == 0:
        print(
            "OK: every engine-dispatched command and every mapped event kind is "
            "in VALID_DAP_COMMANDS,"
        )
        print(
            f"    and the {len(residue)} allow-listed command(s) without a "
            "CtEventKind are the expected ones."
        )
    return status


if __name__ == "__main__":
    sys.exit(main())

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

The FOURTH table, and why it took issue #690 to find it
-------------------------------------------------------
There are four command tables, not three. The fourth is
`commandToCtResponseEventKind` — the `case` that decides which `CtEventKind` a
DAP **response** fans out as. It lived in `src/frontend/dap.nim` behind the JS
FFI, nothing read it, and `ct/load-request-spans-since` was correctly present in
all three tables above and absent from it. Every response to the Request
Panel's poll therefore raised `ValueError`, was caught in
`src/frontend/ui_js.nim::onDapReceiveResponse`, and logged
`dap: ignoring response for unmapped command: …` — the line issue #690 pasted.

The table is now `src/common/ct_event.nim::commandToCtResponseEventKind` (pure
Nim, so the headless ViewModel tests can call it too) and is reconciled here.

The four checks
---------------
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

  RESPONSE every command that a `BackendService` caller CAN send AND that the
           engine dispatches must have an arm in
           `commandToCtResponseEventKind`, or be named in one of the two
           residue maps below with a reason.

           "can send" is `EVENT_KIND_TO_DAP_MAPPING`: `RealBackendService`
           translates a command string through `dapCommandToEventKind` before
           it reaches the wire, so a command with no `CtEventKind` cannot be
           sent at all and cannot come back. "the engine dispatches" is the
           ENGINE set: a command no engine answers produces no response frame.
           The intersection is exactly the traffic that can reach
           `receiveResponse`.

Deliberately NOT checked: the reverse of ENGINE. The allow-list legitimately
contains strings the engine never dispatches — every emitted event, and the one
frontend-internal command — so "in the allow-list but not in `dap_server.rs`" is
the normal case and asserting on it would be noise.

Usage:
  ci/test/dap-command-sync.py
  ci/test/dap-command-sync.py --root DIR
  ci/test/dap-command-sync.py --commands-from F --mapping-from F --engine-from F
                              --response-from F
                              --residue a,b,c --response-residue a,b,c

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
RESPONSE_NIM = "src/common/ct_event.nim"

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
    # `source` (CTUI-4). The engine answers it in `Handler::source` and the
    # Embed SDK's `sdk/source_provider.nim` sends it through `BackendService`,
    # but it produces no EVENT, so it has no `CtEventKind` and
    # `dapCommandToEventKind` still raises on it. That is correct rather than a
    # gap: `RealBackendService` — the Electron renderer's bridge — has no reason
    # to send it, because the desktop reads source files with node's `fs` and
    # hands them to Monaco. The consumers that do send it are the headless
    # native transport (`stdio_backend`, which forwards command strings
    # verbatim) and the WASM worker transport, neither of which goes through
    # the event-kind translation.
    "source",
}

# ---------------------------------------------------------------------------
# RESPONSE residue, in two maps, because the reasons are not the same kind of
# reason and collapsing them would hide the second one.
#
# The check's source set is `EVENT_KIND_TO_DAP_MAPPING ∩ engine-dispatch`: the
# commands a `BackendService` caller can put on the wire that an engine answers.
# Anything in it without an arm in `commandToCtResponseEventKind` must be named
# below, WITH ITS REASON. A bare set would have let #690 be "fixed" by adding
# one name to a list nobody could audit.
# ---------------------------------------------------------------------------

# (1) The engine sends NO DAP Response for these, so no response frame ever
#     bears the command and `receiveResponse` is never called with it. An arm
#     here would be dead code. Each reason names the handler and what it does
#     with its `sender` instead; all of them were read, not assumed.
RESPONSE_RESIDUE_NO_RESPONSE = {
    "ct/collapse-calls": (
        "dap_handler.rs::collapse_calls mutates `self.calltrace` and returns; "
        "the arm passes no `sender` at all."
    ),
    "ct/expand-calls": (
        "dap_handler.rs::expand_calls — same shape as collapse_calls, no "
        "`sender` in the arm."
    ),
    "ct/history-jump": (
        "dap_handler.rs::history_jump jumps and calls `complete_move`, which "
        "emits the `ct/complete-move` EVENT. No respond_dap."
    ),
    "ct/local-step-jump": (
        "dap_handler.rs::local_step_jump — same: the outcome is the "
        "`ct/complete-move` event, not a response body."
    ),
    "ct/run-to-entry": (
        "dap_handler.rs::run_to_entry — same: `complete_move` event only."
    ),
    "ct/run-tracepoints": (
        "dap_handler.rs::run_tracepoints answers with the `ct/updated-trace` "
        "EVENT via `sender`; it never calls respond_dap."
    ),
    "ct/setup-trace-session": (
        "dap_handler.rs::setup_trace_session takes `_sender` — underscored, "
        "i.e. deliberately unused. It allocates event tables and returns."
    ),
    "ct/tracepoint-delete": (
        "dap_handler.rs::tracepoint_delete sends `updated_trace_event` — an "
        "EVENT — and returns."
    ),
    "ct/tracepoint-toggle": (
        "dap_handler.rs::tracepoint_toggle — same as tracepoint_delete."
    ),
}

# (2) KNOWN GAPS. The engine DOES respond to these — every handler named here
#     calls `respond_dap` — so each one logs
#     `dap: ignoring response for unmapped command: …` in the product today,
#     exactly as `ct/load-request-spans-since` did before #690 was fixed. They
#     are pinned, not excused: this set may SHRINK freely and may not grow, and
#     the run prints its size so it cannot be forgotten.
#
#     They are not fixed here because each needs its own decision that #690's
#     does not: which `CtEventKind` the body should fan out as, and whether the
#     resulting second delivery (several of these also emit a `ct/updated-*`
#     event carrying the same data) is idempotent at the receiving VM. Adding
#     an arm that double-applies a calltrace or an event-log page is a worse
#     bug than the log line. See the M45 report.
RESPONSE_RESIDUE_KNOWN_GAPS = {
    "ct/calltrace-jump": "dap_handler.rs::calltrace_jump calls respond_dap.",
    "ct/event-jump": "dap_handler.rs::event_jump calls respond_dap.",
    "ct/event-load": (
        "dap_handler.rs::event_load calls respond_dap; ui_js.nim's own comment "
        "already names this command as one the fan-out raises on."
    ),
    "ct/goto-ticks": "dap_handler.rs::goto_ticks calls respond_dap.",
    "ct/load-calltrace-section": (
        "dap_handler.rs::load_calltrace_section calls respond_dap AND emits "
        "`ct/updated-calltrace`; the double-delivery question is live here."
    ),
    "ct/load-flow": (
        "dap_handler.rs::load_flow calls respond_dap AND emits "
        "`ct/updated-flow`."
    ),
    "ct/load-history": (
        "dap_handler.rs::load_history calls respond_dap AND emits "
        "`ct/updated-history`."
    ),
    "ct/load-terminal": "dap_handler.rs::load_terminal calls respond_dap.",
    "ct/search-calltrace": (
        "dap_handler.rs::calltrace_search calls respond_dap; the results also "
        "travel as `ct/calltrace-search-res`."
    ),
    "ct/source-call-jump": "dap_handler.rs::source_call_jump calls respond_dap.",
    "ct/source-line-jump": "dap_handler.rs::source_line_jump calls respond_dap.",
    "ct/timeline-seek": (
        "the arm routes to dap_handler.rs::goto_ticks, which calls respond_dap "
        "— and respond_dap echoes the REQUEST's command, so the frame comes "
        "back labelled `ct/timeline-seek`, not `ct/goto-ticks`."
    ),
    "ct/trace-jump": "dap_handler.rs::trace_jump calls respond_dap.",
    "ct/update-table": (
        "dap_handler.rs::update_table calls respond_dap AND emits "
        "`ct/updated-table`."
    ),
    "setBreakpoints": "dap_handler.rs::set_breakpoints calls respond_dap.",
}

EXPECTED_RESPONSE_RESIDUE = (
    set(RESPONSE_RESIDUE_NO_RESPONSE) | set(RESPONSE_RESIDUE_KNOWN_GAPS)
)

# Below these, an extractor has silently stopped matching and every subset check
# would pass vacuously. Universal quantification over an empty set is the
# failure mode these floors exist to remove.
MIN_COMMANDS = 60
MIN_MAPPING = 60
MIN_ENGINE = 40
MIN_RESPONSE = 20


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


RESPONSE_SIGNATURE = "func commandToCtResponseEventKind*(command: string): CtEventKind ="


def extract_response(text: str) -> set[str]:
    """The command strings `commandToCtResponseEventKind` has an arm for.

    The function body is taken as "everything indented under the signature",
    which ends at the next top-level declaration. Only lines whose first
    non-space token is `of` are read, so a command name quoted inside a comment
    in the body is not mistaken for an arm.
    """
    if RESPONSE_SIGNATURE not in text:
        # Loud rather than empty: an empty set would make the RESPONSE check
        # pass vacuously, which is the one thing these extractors must not do.
        raise ValueError(
            f"{RESPONSE_SIGNATURE!r} not found — the response table has moved "
            f"or been renamed, and the RESPONSE check cannot read it"
        )
    body_lines: list[str] = []
    for line in text.split(RESPONSE_SIGNATURE, 1)[1].split("\n")[1:]:
        if line.strip() and not line[0].isspace():
            break
        body_lines.append(line)
    found: set[str] = set()
    for line in body_lines:
        if re.match(r"\s*of\s+\"", line):
            found |= set(re.findall(r'"([^"]+)"', line))
    return found


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
    parser.add_argument("--response-from", default=None)
    parser.add_argument(
        "--residue",
        default=None,
        help="comma-separated expected residue; overrides EXPECTED_RESIDUE",
    )
    parser.add_argument(
        "--response-residue",
        default=None,
        help=(
            "comma-separated expected RESPONSE residue; overrides "
            "EXPECTED_RESPONSE_RESIDUE"
        ),
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
    response_path = pathlib.Path(args.response_from or root / RESPONSE_NIM)

    allow = extract_commands(read(commands_path))
    mapping = extract_mapping(read(mapping_path))
    engine = extract_engine(read(engine_path))
    response = extract_response(read(response_path))

    residue_expected = (
        {s for s in (x.strip() for x in args.residue.split(",")) if s}
        if args.residue is not None
        else EXPECTED_RESIDUE
    )
    response_residue_expected = (
        {s for s in (x.strip() for x in args.response_residue.split(",")) if s}
        if args.response_residue is not None
        else EXPECTED_RESPONSE_RESIDUE
    )

    # Synthetic runs are small by construction; the floors are about the real
    # tree, where a broken extractor is the thing that would go unnoticed.
    real_run = args.commands_from is None and args.engine_from is None

    print("=== DAP command table sync ===")
    print(f"VALID_DAP_COMMANDS:        {len(allow)}")
    print(f"EVENT_KIND_TO_DAP_MAPPING: {len(mapping)}")
    print(f"engine dispatches:         {len(engine)}")
    print(f"response arms:             {len(response)}")
    print("")

    status = 0

    if real_run:
        for name, got, floor in (
            ("VALID_DAP_COMMANDS", len(allow), MIN_COMMANDS),
            ("EVENT_KIND_TO_DAP_MAPPING", len(mapping), MIN_MAPPING),
            ("engine dispatch", len(engine), MIN_ENGINE),
            ("commandToCtResponseEventKind", len(response), MIN_RESPONSE),
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

    # RESPONSE — the fourth table. See the header: the source set is the
    # traffic that can actually reach `receiveResponse`.
    response_source = mapping & engine
    response_residue = sorted(response_source - response)
    unexpected = sorted(set(response_residue) - response_residue_expected)
    vanished = sorted(response_residue_expected - set(response_residue))

    if unexpected:
        status = 1
        fail(
            f"{len(unexpected)} command(s) a BackendService caller can send, and "
            f"the engine answers, have NO arm in commandToCtResponseEventKind:"
        )
        for c in unexpected:
            print(f"  {c}", file=sys.stderr)
        print(
            "\n  A response bearing one of these raises ValueError in\n"
            f"  {RESPONSE_NIM}, which ui_js.nim swallows as\n"
            '  "dap: ignoring response for unmapped command: …" — issue #690.\n'
            "  Add the arm, or name the command in RESPONSE_RESIDUE_NO_RESPONSE\n"
            "  (with the handler that proves the engine sends no response) in\n"
            "  this file.\n",
            file=sys.stderr,
        )

    if vanished:
        status = 1
        fail(
            f"{len(vanished)} RESPONSE residue entry/entries no longer apply:"
        )
        for c in vanished:
            print(
                f"  {c}  (gained an arm, lost its CtEventKind, or the engine "
                f"stopped dispatching it)",
                file=sys.stderr,
            )
        print(
            "\n  This is the good direction — delete the entry from\n"
            "  RESPONSE_RESIDUE_NO_RESPONSE / RESPONSE_RESIDUE_KNOWN_GAPS in the\n"
            "  same commit. The pin is an equality so that the known-gap set can\n"
            "  only shrink on purpose.\n",
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
        known_gaps = sorted(set(response_residue) & set(RESPONSE_RESIDUE_KNOWN_GAPS))
        print(
            f"    Every sendable command the engine answers has a response arm, "
            f"except {len(response_residue)} named ones"
        )
        print(
            f"    — of which {len(known_gaps)} are KNOWN GAPS that still log "
            f"#690's line. That number must only fall."
        )
    return status


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""PLAT-54 — the mutation harness for the Agent Activity pane on the terminal
and in the GPUI window (codetracer-pm `spec/DeepReview/DeepReview-GUI.md`
§2.1, Agent-Activity-Panel AA-2 / AA-3): the words and decisions the
desktop's panel used to make in its render procs (`agent_activity_text`),
the rows every native front-end draws (`agent_activity_feed`), the live
session's projection (`agent_activity_vm`), the native host and its file
readers and ACP worker (`viewmodel/host/native_agent_host`,
`agent_session_files`, `agent_live_worker`), the terminal's painter,
runtime, session and VCS pane, the GPUI leaf and window, the vocabulary's
review view, and the desktop's view over the shared words.

Each arm plants ONE defect; REBUILDS the shipped `codetracer-tui` /
`codetracer-gpui` when the defect is compiled into a binary an arm is graded
through; runs the suites that must catch it; and requires RED — with the
failure the first run recorded (`plat54-agent-activity-mutation-because.json`,
derived with `--derive`).

The discipline is PLAT-70 Part I's harness's (`ci/test/run-plat70i-fit-
mutations.py`), clause for clause: committed control digests over subjects
AND suites (§16c), a needle scan that gates re-recording (§39a), `because`
derived from a run, rc 124 is a hang (§1), per-arm restore verification, and
`ci/lib/harness_guard.py`'s argument rule before anything is touched.

The builds run `$PLAT54_BUILD_TUI` / `$PLAT54_BUILD_GPUI` when set, else
`just build-tui` / `just build-gpui`. Every Agent Activity suite drives the
AA suites' ACP replay agent (`node` must be on PATH) and the `calc`
recording through a real `replay-server` (`REPLAY_SERVER_BIN`).

Usage:
    run-plat54-agent-activity-mutations.py [--only X1,F1] [--derive]
    run-plat54-agent-activity-mutations.py --needle-scan
    run-plat54-agent-activity-mutations.py --record-control-hashes
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
HERE = Path(__file__).resolve().parent
CONTROL = HERE / "plat54-agent-activity-mutation-control.sha256"
BECAUSE = HERE / "plat54-agent-activity-mutation-because.json"
NIMCACHE = Path(os.environ.get("CT_NIM_CACHE_ROOT",
                               os.environ.get("TMPDIR", "/tmp"))) / \
    "plat54-mutations"
BIN = REPO / "build/bin/codetracer-tui"
GPUI_BIN = REPO / "build/bin/codetracer-gpui"
TIMEOUT = 3600

# Subjects.
TEXT = "src/frontend/viewmodel/viewmodels/agent_activity_text.nim"
FEED = "src/frontend/viewmodel/viewmodels/agent_activity_feed.nim"
VM = "src/frontend/viewmodel/viewmodels/agent_activity_vm.nim"
FILES = "src/frontend/viewmodel/host/agent_session_files.nim"
HOST = "src/frontend/viewmodel/host/native_agent_host.nim"
WORKER = "src/frontend/viewmodel/host/agent_live_worker.nim"
TUI_PANE = "src/frontend/tui/app/views/agent_activity_pane.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
SHELL = "src/frontend/tui/app/views/shell.nim"
PROFILE = "src/frontend/tui/app/layout/profile.nim"
TUI_SESSION = "src/frontend/tui/host/tui_session.nim"
VCS_PANE = "src/frontend/tui/app/views/vcs_pane.nim"
VCS_SOURCE = "src/frontend/tui/host/vcs_source.nim"
GPUI_LEAF = "src/frontend/gpui/agent_activity_leaf.nim"
GPUI_MAIN = "src/frontend/gpui/main.nim"
VOCAB = "src/frontend/view_vocabulary/pane_views.nim"
DESKTOP = "src/frontend/viewmodel/views/isonim_agent_activity_view.nim"

# Suites.
VMU = "src/frontend/viewmodel/tests/unit/test_plat54_agent_activity.nim"
TBL = "src/frontend/tui/tests/test_plat54_agent_activity.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat54_agent_activity_pty.nim"
PLAN = "src/frontend/gpui/tests/test_plat54_gpui_agent_activity.nim"

SUBJECTS = [TEXT, FEED, VM, FILES, HOST, WORKER, TUI_PANE, RUNTIME, SHELL,
            PROFILE, TUI_SESSION, VCS_PANE, VCS_SOURCE, GPUI_LEAF, GPUI_MAIN,
            VOCAB, DESKTOP]
SUITES = [VMU, TBL, PTY, PLAN]

TBL_REVIEW = "*::a recorded session: evidence cards, a click loads each dataset"
TBL_RUN = "*::a ct test run: a summary, a drill-down, a real recording"
TBL_LIVE = "*::a live session: rows arrive, the tab agrees, the reader stays put"
PLAN_REVIEW = "*::a recorded session: the cards, and a click loads each dataset"
PLAN_RUN = "*::a ct test run: the card opens, a recording opens as a tab"
PLAN_LIVE = "*::a live session: rows arrive over ACP, the tab and the pane agree"

# (id, [(subject, find, replace), ...], [(suite, filter), ...], what it breaks)
ARMS = [
    # ---- the words, decided once (moved out of the desktop's view) ---------
    ("X1", [(TEXT, "    thoughtDuration(message.duration)",
             "    thinkingLabel(message.createdAt, message.thinkingEndedAt)")],
     [(VMU, None)],
     "a finished turn's header is not \"Thought for <duration>\""),
    ("X2", [(TEXT, "    added += max(0, count - o.getOrDefault(line, 0))",
             "    added += count")],
     [(VMU, None)],
     "a changed file's +N counts every line, not the lines it gained"),
    ("X3", [(TEXT, "      result.text = lastParagraph", "      discard")],
     [(VMU, None)],
     "a finished turn promotes its whole text, not its last paragraph"),
    ("X4", [(TEXT, "  elif summary.failed > 0 or summary.errored > 0: trsFailed",
             "  elif false: trsFailed")],
     [(VMU, None), (PLAN, PLAN_RUN)],
     "AA-2: a run with a failed test reads as passed"),
    ("X5", [(TEXT, "    of edsReady: ecReady", "    of edsReady: ecReading")],
     [(VMU, None)],
     "AA-3: a card whose dataset was read says it is still reading"),
    # ---- the rows ------------------------------------------------------------
    ("F1", [(FEED, "  if call.canOpenEvidence():", "  if true:")],
     [(VMU, None), (TBL, TBL_REVIEW)],
     "AA-3: a card with nothing to open still offers [Open review]"),
    ("F2", [(FEED, "    if row.hasRecording:", "    if true:")],
     [(VMU, None), (TBL, TBL_RUN)],
     "AA-2: a test with no recording offers a drill-down that fails"),
    ("F3", [(FEED, "    if runIndex >= 0:", "    if false:")],
     [(VMU, None)],
     "AA-2: a `ct test` run is shown as the runner's raw NDJSON"),
    ("F4", [(FEED, "  let collapsed = collapsedByDefault xor vm.isThoughtToggled(message.id)",
             "  let collapsed = collapsedByDefault")],
     [(VMU, None)],
     "a press on a turn's header does not open it"),
    ("F5", [(FEED, "        if s.button > 0 and used > leadCells and m(rest) <= w - leadCells:",
             "        if false:")],
     [(TBL, TBL_REVIEW)],
     "a button is broken across two lines (no press reads it whole)"),
    ("F6", [(FEED, "  elif s.anchorKey.len > 0:", "  elif false:")],
     [(VMU, None)],
     "deliverable 3: rows arriving above move the reader off their line"),
    ("F7", [(FEED, "  s.follow = s.top >= last", "  s.follow = true")],
     [(VMU, None), (TBL, TBL_LIVE)],
     "deliverable 3: a reader who scrolled up is pulled back to the end"),
    ("F8", [(FEED, "    result.handled = vm.openTestRecording(row.anchorId, row.testId, topNewTab)",
             "    result.handled = vm.openTestRecording(row.anchorId, row.testId, topCurrentTab)")],
     [(VMU, None), (TBL, TBL_RUN)],
     "AA-2: Open in new tab opens in the current tab"),
    # ---- the live session's projection --------------------------------------
    ("V1", [(VM, "    toolName: event.toolName,", "    toolName: \"\",")],
     [(PLAN, PLAN_LIVE)],
     "AA-3: a live handoff is a generic line (the tool identity is dropped)"),
    ("V2", [(VM, "  session.lifecycle in {aslConnecting, aslRunning}",
             "  session.lifecycle in {aslConnecting}")],
     [(VMU, None)],
     "a running agent's pane does not say it is working"),
    # ---- the native host and its readers --------------------------------------
    ("H1", [(HOST, "                                     readDatasetShape(request.datasetPath))",
             "                                     EvidenceDataset(state: edsUnknown))")],
     [(TBL, TBL_REVIEW)],
     "AA-3: a card's dataset is never read (no shape, no affordance)"),
    ("H2", [(HOST, "        let read = readReviewDataset(request.datasetPath)",
             "        let read = readReviewDataset(\"\")")],
     [(TBL, TBL_REVIEW)],
     "AA-3: Open review reads no dataset (no review entered)"),
    ("H3", [(HOST, "      role: aamrUser, createdAt: epochTime() * 1000.0))",
             "      role: aamrAgent, createdAt: epochTime() * 1000.0))")],
     [(TBL, TBL_LIVE)],
     "the user's own prompt is shown as the agent's"),
    ("H4", [(HOST, "  h.vm.isLoading.val = session.agentSessionRunning()",
             "  h.vm.isLoading.val = true")],
     [(TBL, TBL_LIVE)],
     "the pane says the agent works while the tab says it is done"),
    ("H5", [(HOST, "    state.sessions.add session", "    discard session")],
     [(TBL, TBL_LIVE)],
     "a live session is not in the store the session tab reads"),
    ("W1", [(WORKER, "              send(slot, %*{\"t\": \"event\", \"event\": event.toJson()})",
             "              discard event")],
     [(TBL, TBL_LIVE)],
     "the agent's updates never reach the window (nothing arrives)"),
    ("S1", [(FILES, "    fileCount: (if files != nil and files.kind == JArray: files.len else: 0),",
             "    fileCount: 0,")],
     [(TBL, TBL_REVIEW)],
     "AA-3: a card names a dataset's shape wrongly (0 files)"),
    ("S2", [(FILES, "        toolName: e{\"toolName\"}.getStr(\"\"),",
             "        toolName: \"\",")],
     [(TBL, TBL_REVIEW)],
     "RV-6: a review's session loses its tool calls (no evidence cards)"),
    # ---- the terminal ---------------------------------------------------------
    ("T1", [(TUI_PANE, "    if s.button > 0 and col >= at and col < at + w:",
             "    if s.button > 0 and col >= at + w:")],
     [(TBL, TBL_REVIEW)],
     "a press on a button is read as a press on its row"),
    ("T2", [(PROFILE, "     paneAgentActivity},", "     },"),
            (SHELL, "  elif region.pane == paneAgentActivity and model.agent.loaded:",
             "  elif false:")],
     [(PTY, None)],
     "the terminal draws the report leaf, not the pane"),
    ("T3", [(RUNTIME, "    if at.found and at.region.pane == paneAgentActivity and",
             "    if false and")],
     [(TBL, TBL_LIVE)],
     "the wheel does not scroll the pane"),
    ("T4", [(RUNTIME, "  if mode == omAgent:", "  if false:")],
     [(TBL, TBL_LIVE)],
     "`/ai <prompt>` does not reach the agent"),
    ("T5", [(RUNTIME, "                                    (if t.kind == atButton: t.button else: -1))",
             "                                    -1)")],
     [(TBL, TBL_REVIEW)],
     "a button's press runs the row's action instead"),
    ("T6", [(TUI_SESSION, "  result.working = host.vm.isLoading.val",
             "  result.working = false")],
     [(TBL, TBL_LIVE)],
     "the prompt's control says Send while the agent works"),
    ("T7", [(TUI_SESSION, "  let polled = s.agent.poll()", "  let polled = false")],
     [(TBL, TBL_LIVE)],
     "the loop never applies a live agent's updates"),
    ("T8", [(VCS_SOURCE, "    result.review = true", "    result.review = false")],
     [(TBL, TBL_REVIEW), (PTY, None)],
     "the VCS pane does not show the review an evidence card entered"),
    ("T9", [(VCS_PANE, "  if model.review:", "  if false:")],
     [(PTY, None)],
     "the terminal's VCS pane paints the working tree over a review"),
    # ---- GPUI -------------------------------------------------------------------
    ("G1", [(GPUI_LEAF, "    if s.button > 0 and x >= at and x < at + w:",
             "    if s.button > 0 and x >= at + w:")],
     [(PLAN, PLAN_REVIEW)],
     "a press on a GPUI button is read as a press on its row"),
    ("G2", [(GPUI_MAIN, "  if mode == omAgent:", "  if false:")],
     [(PLAN, PLAN_LIVE)],
     "`/ai <prompt>` does not reach the GPUI window's agent"),
    ("G3", [(GPUI_MAIN, "        while agentLive() and epochTime() < deadline:",
             "        while false:")],
     [(PLAN, PLAN_LIVE)],
     "the window's wait does not apply the agent's updates"),
    ("G4", [(GPUI_MAIN, "      openRecordingInTab(rr, request.tracePath)",
             "      discard request")],
     [(PLAN, PLAN_RUN)],
     "AA-2: a recording is not opened as a session tab"),
    ("G5", [(VOCAB, "  if vm.deepReviewMode.val:", "  if false:")],
     [(PLAN, PLAN_REVIEW)],
     "the GPUI VCS pane does not show the review an evidence card entered"),
    # ---- the desktop over the shared words ---------------------------------------
    ("D1", [(DESKTOP, "  let modifier = $evidenceCardState(call)",
             "  let modifier = \"ready\"")],
     [(VMU, None)],
     "AA-3: the desktop's card class disagrees with the native rows"),
    ("D2", [(DESKTOP, "          text testRunTitle(summary)",
             "          text summaryText(summary)")],
     [(VMU, None)],
     "AA-2: the desktop's run card names itself differently"),
]

DECLARED_SURVIVORS = set()

IN_BINARY = {TEXT, FEED, VM, FILES, HOST, WORKER, TUI_PANE, RUNTIME, SHELL,
             PROFILE, TUI_SESSION, VCS_PANE, VCS_SOURCE}
  # Subjects compiled into `codetracer-tui`.
IN_GPUI = {TEXT, FEED, VM, FILES, HOST, WORKER, GPUI_LEAF, GPUI_MAIN, VOCAB}
  # Subjects compiled into `codetracer-gpui`.
IN_DESKTOP = set()
PTY_SUITES = {PTY}
GPUI_SUITES = {PLAN}
DESKTOP_SUITES = set()


def path_of(rel):
    return REPO / rel


def sha_path(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def sha(rel):
    return sha_path(path_of(rel))


def lane_flags(lane):
    return subprocess.run(
        ["bash", "-c", ". ci/lib/test-lane-files.sh >/dev/null 2>&1 && "
                       f"test_lane_extra_flags {lane}"],
        cwd=REPO, capture_output=True, text=True, check=True).stdout.split()


def suite_flags(suite):
    if suite == PTY:
        return lane_flags("tui-real-terminal")
    if suite.startswith("src/frontend/tui/"):
        return lane_flags("tui")
    if suite.startswith("src/frontend/gpui/"):
        return lane_flags("gpui-shell") + ["--path:src/frontend/viewmodel"]
    return ["--path:src/frontend/viewmodel"]


def needle_scan():
    ok = True
    for arm_id, edits, *_ in ARMS:
        for rel, find, _ in edits:
            text = path_of(rel).read_text()
            n = text.count(find)
            if n != 1:
                print(f"  NEEDLE FAIL {arm_id}: {n} occurrence(s) in {rel}")
                ok = False
                continue
            end = text.index(find) + len(find)
            if end < len(text) and text[end] not in "\r\n":
                print(f"  NEEDLE FAIL {arm_id}: does not end at a line end")
                ok = False
    print(f"needle scan: {len(ARMS)} arm(s), "
          f"{'every find occurs exactly once' if ok else 'FAILED'}")
    return ok


def record_controls():
    if not needle_scan():
        print("REFUSED: re-recording now would certify an unaimed arm (§39a).")
        return 1
    with open(CONTROL, "w") as f:
        f.write("# Control digests for run-plat54-agent-activity-mutations.py — the\n"
                "# subjects AND the suites the arms are graded by (§16c).\n"
                "# Refreshed with --record-control-hashes, gated by the\n"
                "# needle scan (§39a).\n")
        for rel in SUBJECTS + SUITES:
            f.write(f"{sha(rel)}  {rel}\n")
    print(f"recorded {len(SUBJECTS) + len(SUITES)} control digests")
    return 0


def controls_match():
    if not CONTROL.exists():
        print("NO CONTROL DIGESTS — run --record-control-hashes first.")
        return False
    ok = True
    for line in CONTROL.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        digest, rel = line.split("  ", 1)
        if sha(rel) != digest:
            print(f"CONTROL DIGEST MOVED: {rel}")
            ok = False
    return ok


def build_with(env_var, recipe):
    cmd = os.environ.get(env_var)
    argv = ["bash", "-c", cmd] if cmd else ["just", recipe]
    p = subprocess.run(argv, cwd=REPO, capture_output=True, text=True,
                       timeout=TIMEOUT)
    if p.returncode != 0:
        print((p.stdout + p.stderr)[-2000:])
    return p.returncode == 0


def build_binary():
    return build_with("PLAT54_BUILD_TUI", "build-tui")


def build_gpui():
    return build_with("PLAT54_BUILD_GPUI", "build-gpui")


def build_desktop():
    return build_with("PLAT54_BUILD_DESKTOP", "build-once")


def portable_cause(line):
    """A pty suite's wait names its condition and then snapshots the screen;
    the recorded cause keeps the condition and drops the snapshot."""
    head, sep, rest = line.partition("; status:")
    if not sep:
        return line
    tail = re.search(r" \[\w+\]$", rest)
    return head + (tail.group(0) if tail else "")


def run_spec(suite):
    """The Electron spec: GREEN on rc 0, else RED on its first expectation."""
    cmd = os.environ.get("PLAT54_DESKTOP_TEST")
    argv = ["bash", "-c", cmd] if cmd else \
        ["npx", "playwright", "test", suite.split("src/tests/gui/", 1)[1],
         "--reporter=line"]
    cwd = REPO if cmd else REPO / "src/tests/gui"
    try:
        p = subprocess.run(argv, cwd=cwd, capture_output=True, text=True,
                           timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return "HUNG", []
    out = (p.stdout or "") + (p.stderr or "")
    if p.returncode == 0:
        return ("GREEN", []) if " passed" in out else ("RAN-NOTHING", [])
    plain = re.sub(r"\x1b\[[0-9;]*m", "", out)
    first = [ln.strip() for ln in plain.splitlines()
             if ln.strip().startswith("Error:")][:1]
    return "RED", first


def run_suite(suite, test_filter):
    if suite in DESKTOP_SUITES:
        return run_spec(suite)
    NIMCACHE.mkdir(parents=True, exist_ok=True)
    stem = Path(suite).stem
    env = dict(os.environ, CODETRACER_REPO_ROOT=str(REPO))
    cmd = ["nim", "c", "-r", "--hints:off", "--warnings:off",
           f"--nimcache:{NIMCACHE}/{stem}",
           f"-o:{NIMCACHE}/{stem}.out"] + suite_flags(suite) + [suite]
    if test_filter:
        cmd.append(test_filter)
    try:
        p = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True,
                           timeout=TIMEOUT, env=env)
    except subprocess.TimeoutExpired:
        return "HUNG", []
    out = (p.stdout or "") + (p.stderr or "")
    if p.returncode == 124:
        return "HUNG", []
    failures = [portable_cause(ln.strip().split("Check failed: ", 1)[1])
                for ln in out.splitlines() if "Check failed: " in ln]
    if p.returncode == 0:
        ran = out.count("[OK]")
        return ("GREEN", failures) if ran > 0 else ("RAN-NOTHING", [])
    # A base that does not hold together does not LOAD: the suite dies before
    # its first case, on the loader's own diagnostic — a kill by the
    # product's check, graded as one, on that line.
    refused = [ln.strip() for ln in out.splitlines()
               if "BaseRowError" in ln and "unhandled exception" in ln.lower()]
    if refused:
        return "RED", refused[:1]
    if not failures and "Error:" in out and "[FAILED]" not in out:
        return "DID-NOT-COMPILE", failures
    if not failures:
        failures = [portable_cause(ln.strip()) for ln in out.splitlines()
                    if "[FAILED]" in ln or "Unhandled exception" in ln][:1]
    return "RED", failures


def grade(suites):
    first, verdict = "", "GREEN"
    for s, flt in suites:
        v, f = run_suite(s, flt)
        if v in ("HUNG", "DID-NOT-COMPILE", "RAN-NOTHING"):
            return v, ""
        if v == "RED":
            verdict = "RED"
            if not first and f:
                first = f[0]
    return verdict, first


sys.path.insert(0, str(REPO / "ci" / "lib"))
from harness_guard import refuse_undeclared_arms  # noqa: E402


def main():
    # AN UNDECLARED ARM ID, OR AN EMPTY `--only=`, IS REFUSED before anything
    # is touched (`ci/lib/harness_guard.py`).
    refused = refuse_undeclared_arms(sys.argv[1:], globals())
    if refused:
        return refused
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--needle-scan", action="store_true")
    ap.add_argument("--derive", action="store_true")
    ap.add_argument("--record-control-hashes", action="store_true")
    a = ap.parse_args()
    os.chdir(REPO)
    if a.needle_scan:
        return 0 if needle_scan() else 1
    if a.record_control_hashes:
        return record_controls()
    if not needle_scan() or not controls_match():
        print("the tree is not at the control bytes; nothing was mutated.")
        return 3
    only = set(filter(None, a.only.split(",")))
    selected = [arm for arm in ARMS if not only or arm[0] in only]
    needs_binary = any(s in PTY_SUITES for arm in selected for s, _ in arm[2])
    needs_gpui = any(s in GPUI_SUITES for arm in selected for s, _ in arm[2])
    needs_desktop = any(s in DESKTOP_SUITES for arm in selected
                        for s, _ in arm[2])
    binary_digest = gpui_digest = None
    if needs_binary:
        if not build_binary():
            print("ABORT: the unmutated binary does not build.")
            return 1
        binary_digest = sha_path(BIN)
    if needs_gpui:
        if not build_gpui():
            print("ABORT: the unmutated GPUI binary does not build.")
            return 1
        gpui_digest = sha_path(GPUI_BIN)
    if needs_desktop and not build_desktop():
        print("ABORT: the unmutated desktop does not build.")
        return 1
    graded = sorted({(s, flt) for arm in selected for s, flt in arm[2]})
    for s, flt in graded:
        v, f = run_suite(s, flt)
        if v != "GREEN":
            print(f"ABORT: the baseline of {s} is {v}: {f[:1]}")
            return 1
    print(f"baseline GREEN ({len(graded)} suite run(s))")
    because = json.loads(BECAUSE.read_text()) if BECAUSE.exists() else {}
    digests = {rel: sha(rel) for rel in SUBJECTS}
    derived, bad = {}, []
    for arm_id, edits, suites, what in selected:
        files = sorted({rel for rel, _, _ in edits})
        backups = {}
        for rel in files:
            path = path_of(rel)
            backups[rel] = path.with_name(path.name + ".plat54bak")
            shutil.copy2(path, backups[rel])
        try:
            for rel, find, replace in edits:
                path = path_of(rel)
                path.write_text(path.read_text().replace(find, replace, 1))
            built = True
            if any(s in PTY_SUITES for s, _ in suites) and \
                    any(r in IN_BINARY for r in files):
                built = build_binary()
            if built and any(s in GPUI_SUITES for s, _ in suites) and \
                    any(r in IN_GPUI for r in files):
                built = build_gpui()
            if built and any(s in DESKTOP_SUITES for s, _ in suites) and \
                    any(r in IN_DESKTOP for r in files):
                built = build_desktop()
            verdict, first = grade(suites) if built else ("DID-NOT-COMPILE", "")
        finally:
            for rel in files:
                shutil.move(backups[rel], path_of(rel))
                if sha(rel) != digests[rel]:
                    print(f"ABORT: restore of {rel} failed after {arm_id}.")
                    return 1
        derived[arm_id] = first
        if arm_id in DECLARED_SURVIVORS:
            ok = verdict == "GREEN"
            mark = "SURVIVED (declared)" if ok else f"MISDIRECTED ({verdict})"
        elif verdict == "RED":
            want = because.get(arm_id)
            ok = a.derive or want is None or want == first
            mark = "KILLED" if ok else f"KILLED BY THE WRONG CHECK: {first!r}"
        else:
            ok = False
            mark = verdict if verdict != "GREEN" else "SURVIVED — NOT ENFORCED"
        print(f"  {arm_id:<4} {mark:<30} {what}", flush=True)
        if a.derive or not ok:
            print(f"       because: {first!r}")
        if not ok:
            bad.append(arm_id)
    if a.derive:
        merged = dict(because)
        merged.update({k: v for k, v in derived.items()
                       if k not in DECLARED_SURVIVORS})
        BECAUSE.write_text(json.dumps(merged, indent=2, sort_keys=True) + "\n")
        print(f"derived {len(derived)} because line(s)")
    if binary_digest is not None:
        if not build_binary() or sha_path(BIN) != binary_digest:
            print("FAIL: the binary rebuilt from the restored tree differs "
                  "from the one the run started with.")
            return 1
    if gpui_digest is not None:
        if not build_gpui() or sha_path(GPUI_BIN) != gpui_digest:
            print("FAIL: the GPUI binary rebuilt from the restored tree "
                  "differs from the one the run started with.")
            return 1
    if needs_desktop and not build_desktop():
        print("FAIL: the desktop does not rebuild from the restored tree.")
        return 1
    for rel in SUBJECTS:
        if sha(rel) != digests[rel]:
            print(f"FAIL: {rel} does not match its digest at exit.")
            return 1
    print(f"RESULT: {len(bad)} arm(s) not as required: {', '.join(bad) or '-'}")
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""PLAT-59 — the mutation harness for the Visual Replay panes on the terminal
and in the GPUI window (codetracer-pm `spec/GUI/Debugging-Features/
Visual-Replay.md` § The terminal and the GPUI window,
`spec/Front-Ends/CodeTracer-TUI-Graphics.md` §4–§6): the shared model
(`visual_replay_panes_vm`: one client, a picked pixel's history and shader, a
history row's navigation; `video_player_vm`: the scrubbers' coalescing and
release, the frame-scoped draw step, the shared labels; `frame_viewer_vm`: the
frame's draw range), the native producer (`native_visual_replay_host`: the
row order, the frame's headers, the history's POST), the terminal's pane,
runtime, host and tier-0 transmission, the GPUI leaf and window, the
vocabulary view and the desktop's client.

Each arm plants ONE defect; REBUILDS the shipped `codetracer-tui` /
`codetracer-gpui` when the defect is compiled into a binary an arm is graded
through; runs the suites that must catch it; and requires RED — with the
failure the first run recorded (`plat59-visual-replay-mutation-because.json`,
derived with `--derive`).

The discipline is PLAT-60's harness's (`run-plat60-low-level-code-mutations.py`),
clause for clause: committed control digests over subjects AND suites (§16c),
a needle scan that gates re-recording (§39a), `because` derived from a run,
rc 124 is a hang (§1), per-arm restore verification, one declared
behaviour-preserving survivor, and `ci/lib/harness_guard.py`'s argument rule
before anything is touched.

The builds run `$PLAT59_BUILD_TUI` / `$PLAT59_BUILD_GPUI` when set, else
`just build-tui` / `just build-gpui`; the suites compile with `$PLAT59_NIM`
when set, else `nim`. Every suite but the ViewModel's opens the real `gl_scene`
visual recording (`tui/tests/fixtures/visual_fixture`) with a real
`replay-server` and a real `ct_gfx_player`, as the lanes do. The desktop's
arm is graded by the Electron capture (`$PLAT59_DESKTOP_TEST`, else
`npx playwright test`).

Usage:
    run-plat59-visual-replay-mutations.py [--only V1,T1] [--derive]
    run-plat59-visual-replay-mutations.py --needle-scan
    run-plat59-visual-replay-mutations.py --record-control-hashes
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
CONTROL = HERE / "plat59-visual-replay-mutation-control.sha256"
BECAUSE = HERE / "plat59-visual-replay-mutation-because.json"
NIMCACHE = Path(os.environ.get("CT_NIM_CACHE_ROOT",
                               os.environ.get("TMPDIR", "/tmp"))) / \
    "plat59-mutations"
BIN = REPO / "build/bin/codetracer-tui"
GPUI_BIN = REPO / "build/bin/codetracer-gpui"
TIMEOUT = 3600

# Subjects.
PANES = "src/frontend/viewmodel/viewmodels/visual_replay_panes_vm.nim"
PLAYER = "src/frontend/viewmodel/viewmodels/video_player_vm.nim"
FRAME = "src/frontend/viewmodel/viewmodels/frame_viewer_vm.nim"
HISTORY = "src/frontend/viewmodel/viewmodels/pixel_history_vm.nim"
CLIENT = "src/frontend/viewmodel/viewmodels/visual_replay_client.nim"
PRODUCER = "src/frontend/viewmodel/host/native_visual_replay_host.nim"
OPEN = "src/frontend/tui/host/native_host.nim"
CHANNEL = "src/frontend/viewmodel/backend/stdio_backend.nim"
TUI_PANE = "src/frontend/tui/app/views/frame_viewer.nim"
TUI_PANES = "src/frontend/tui/app/views/visual_replay_panes.nim"
BINDING = "src/frontend/tui/app/frame_viewer_binding.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"
HOST = "src/frontend/tui/host/tui_session.nim"
FRAME_IMAGE = "src/frontend/tui/host/frame_image.nim"
GPUI_LEAF = "src/frontend/gpui/visual_replay_leaf.nim"
GPUI_MAIN = "src/frontend/gpui/main.nim"
VOCAB = "src/frontend/view_vocabulary/pane_views.nim"
FACTORY = "src/frontend/ui/visual_replay_client_factory.nim"

# Suites.
VMU = "src/frontend/viewmodel/tests/unit/test_plat59_visual_replay.nim"
TBL = "src/frontend/tui/tests/test_plat59_visual_replay.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat59_visual_replay_pty.nim"
PLAN = "src/frontend/gpui/tests/test_plat59_gpui_visual_replay.nim"
REFUSAL = "src/frontend/tui/tests/test_container_version_refusal.nim"
SPEC = "src/tests/gui/tests/frame-viewer/plat59-visual-replay-capture.spec.ts"

SUBJECTS = [PANES, PLAYER, FRAME, HISTORY, CLIENT, PRODUCER, OPEN, CHANNEL, TUI_PANE,
            TUI_PANES, BINDING, RUNTIME, HOST, FRAME_IMAGE, GPUI_LEAF,
            GPUI_MAIN, VOCAB, FACTORY]
SUITES = [VMU, TBL, PTY, PLAN, SPEC, REFUSAL]

TBL_REFUSED = "*::a recording the engine refuses opens with its graphics, and says why"
# The terminal suite's other cases are ONE scenario over one session, in this
# order: a case starts from the state the cases before it left (the Video
# Player's tab shown and focused by FRAMES, the pixel PICK commits, ...). A
# filter naming one such case alone runs it from a fresh session, where it
# cannot pass: NAV finds no history rows to press (`hs.listTop >= 0` fails,
# then `entries[n - 1]` raises), and SCRUB, DRAW, PICK and TIER0 find the
# Video Player's tab not shown. Measured at 51f358391: those five RED alone,
# the whole binary GREEN. So a scenario case is graded together with the
# cases that precede it (`std/unittest` takes several name filters and runs
# the matching tests in suite order).
TBL_SCENARIO = [
    "*::the panes are added as the desktop adds them, additively",
    "*::the frame at three positions is the program's, and the desktop's",
    "*::the scrubber holds, follows the pointer and settles on the release",
    "*::the nested draw-call scrubber shows a frame's draw calls",
    "*::the picker's magnifier picks a source pixel and its history loads",
    "*::a history row navigates: the Video Player shows its draw call",
    "*::shader debug shows the fragment and the shader's source",
    "*::at tier 0 the frame is transmitted over the cells the pane reserves",
    "*::the vocabulary's Video Player view says the shared words",
    "*::the desktop's keys, scoped to the Video Player",
]


def through(case):
    """The scenario's filters from its first case through `case`."""
    return tuple(TBL_SCENARIO[:TBL_SCENARIO.index(case) + 1])


TBL_ADD = through(TBL_SCENARIO[0])
TBL_FRAMES = through(TBL_SCENARIO[1])
TBL_SCRUB = through(TBL_SCENARIO[2])
TBL_DRAW = through(TBL_SCENARIO[3])
TBL_PICK = through(TBL_SCENARIO[4])
TBL_NAV = through(TBL_SCENARIO[5])
TBL_TIER0 = through(TBL_SCENARIO[7])
TBL_VOCAB = through(TBL_SCENARIO[8])
TBL_KEYS = through(TBL_SCENARIO[9])
PLAN_FRAMES = "*::the frame at three positions: the program's pixels, the desktop's"
PLAN_DRAW = "*::the nested draw-call scrubber shows a frame's draw calls"
PLAN_PICK = "*::the picker's loupe, a pick, the pixel's history and its navigation"
PLAN_KEYS = "*::the desktop's keys on the focused Video Player"

# (id, [(subject, find, replace), ...], [(suite, filter), ...], what it breaks)
ARMS = [
    # ---- the shared model --------------------------------------------------
    ("V1", [(PLAYER, "  let due = g.requested < 0 or nowMs - g.lastRequestMs >= ScrubCoalesceMs",
             "  let due = true")],
     [(VMU, None)],
     "a drag asks the player on every event: nothing is coalesced"),
    ("V2", [(PLAYER, "  if position != g.requested and (release or due):",
             "  if position != g.requested and due:")],
     [(VMU, None)],
     "a release inside the coalescing window does not settle its frame"),
    ("V3", [(PLAYER, "  if before.resumePlaying:", "  if false:")],
     [(VMU, None), (TBL, TBL_SCRUB)],
     "a drag while playing does not resume playback on the release"),
    ("V4", [(PLAYER, "    if scrubPending(g, nowMs):", "    if false:")],
     [(VMU, None)],
     "a held drag that stops inside the window never lands"),
    ("V5", [(PLAYER, "    of scrubDraw: vm.frameVm.frameDrawCount.val",
             "    of scrubDraw: 0")],
     [(VMU, None)],
     "the draw-call scrubber is not clamped to the frame's draw calls"),
    ("V6", [(PLAYER, "        vm.frameVm.loadDrawInFrame(0, frame + 1)",
             "        vm.frameVm.loadDrawInFrame(0)")],
     [(VMU, None)],
     "a draw step past a frame's last draw stays in the frame"),
    ("V7", [(PANES, "  vm.history.client = client", "  discard")],
     [(VMU, None)],
     "the pixel history keeps its own (inactive) client"),
    ("V8", [(PANES, "        history.loadPixelHistory(x, y, f)", "        discard")],
     [(VMU, None), (TBL, TBL_PICK)],
     "a picked pixel loads no history"),
    ("V9", [(HISTORY, "      vm.onEntryActivated(vm.entries.val[index])",
             "      discard")],
     [(VMU, None), (TBL, TBL_NAV)],
     "a history row's click does not show its draw call"),
    ("V10", [(FRAME, "  if frame.frameDrawCount > 0 and frame.frameDrawStart >= 0:",
              "  if false:")],
     [(VMU, None), (TBL, TBL_DRAW)],
     "the frame's draw calls are never known: no draw-call scrubber"),
    ("V11", [(PLAYER, '  if total > 0: "Frame " & $at & " / " & $(total - 1)',
              '  if total > 0: "Frame " & $at & " / " & $total')],
     [(TBL, TBL_FRAMES), (PTY, None)],
     "the frame label counts frames instead of naming the last one"),
    ("V12", [(PLAYER, "  discard vm.scrubRevision.val", "")],
     [(VMU, None)],
     "the desktop's frame label freezes on the frame a drag pressed"),
    ("C1", [(CLIENT, "        else: postJson(pixelHistoryUrl(baseUrl, x, y, frame),\n"
                     "                       pixelHistoryRequestToJson(x, y, frame))",
             "        else: getJson(pixelHistoryUrl(baseUrl, x, y, frame))")],
     [(VMU, None)],
     "the JSON client asks for a pixel history with a GET the player refuses"),
    # ---- the native producer -----------------------------------------------
    ("P1", [(PRODUCER, '  if a.header("x-row-order") == "bottom-up":', "  if false:")],
     [(TBL, TBL_FRAMES)],
     "a GL frame is drawn upside down"),
    ("P2", [(PRODUCER, '  result.frameDrawCount = a.headerInt("x-frame-draw-count", 0)',
             "  result.frameDrawCount = 0")],
     [(TBL, TBL_DRAW)],
     "the frame's draw calls are dropped from the player's answer"),
    ("P3", [(PRODUCER, "      h.pending[h.submit(hjPost, pixelHistoryUrl(base, x, y, frame),",
             "      h.pending[h.submit(hjGet, pixelHistoryUrl(base, x, y, frame),")],
     [(TBL, TBL_PICK)],
     "the pixel history is asked for with a GET the player refuses"),
    # ---- a recording the engine refuses --------------------------------------
    ("R1", [(OPEN, "    if not recordingHasGraphics(resolved):\n      raise",
             "    if true:\n      raise")],
     [(TBL, TBL_REFUSED)],
     "a recording with graphics does not open when the engine refuses it"),
    ("R2", [(OPEN, "    if not recordingHasGraphics(resolved):\n      raise",
             "    if false:\n      raise")],
     [(REFUSAL, None)],
     "a recording without graphics opens to nothing instead of being refused"),
    ("R3", [(HOST, "  if s.ended and not s.refused:\n    return\n  if refusal.len > 0:",
             "  if s.ended:\n    return\n  if refusal.len > 0:")],
     [(TBL, TBL_REFUSED)],
     "a refused recording gets no player and no panes"),
    ("R4", [(HOST, "    rt.noteEngineRefusal(sessionRefusedWords(refusal))",
             "    discard")],
     [(TBL, TBL_REFUSED)],
     "the terminal does not say why the debugger's panes are empty"),
    ("R5", [(CHANNEL, "  DapStdioBackend(closed: true, refusal: refusal)",
             "  DapStdioBackend(closed: true)")],
     [(TBL, TBL_REFUSED)],
     "the session forgets the engine's sentence"),
    # ---- the terminal ------------------------------------------------------
    ("T1", [(TUI_PANE, "  model.pane and area.width >= 2 and area.height >= 3",
             "  false")],
     [(PTY, None)],
     "the Video Player draws no transport row"),
    ("T2", [(TUI_PANE, "  model.pane and model.drawCount > 1 and area.width >= 2 and area.height >= 5",
             "  false")],
     [(TBL, TBL_DRAW)],
     "the Video Player draws no draw-call scrubber"),
    ("T3", [(TUI_PANE, "    model.capability.protocol in {ImageProtocol.ipKitty, ImageProtocol.ipITerm2}",
             "    false")],
     [(TBL, TBL_TIER0)],
     "a tier-0 terminal reserves no cells for the frame"),
    ("T4", [(FRAME_IMAGE, "    body.add kittyPlaceFrame(rect)", "    discard")],
     [(TBL, TBL_TIER0)],
     "the Kitty frame is transmitted and never placed"),
    ("T5", [(RUNTIME, "  discard rt.actOnVisual(VisualAct(kind: vaPickPixel, x: x, y: y), outcome)",
             "  discard")],
     [(TBL, TBL_PICK)],
     "the magnifier's Enter commits no pixel"),
    ("T6", [(RUNTIME, "  if t.kind != vtHistoryRow:", "  if true:")],
     [(TBL, TBL_NAV)],
     "a press on a history row does nothing"),
    ("T7", [(RUNTIME, "  if not m.pane or not (m.scrubbing or m.drawScrubbing):",
             "  if true:")],
     [(TBL, TBL_SCRUB)],
     "a held scrubber does not follow the pointer"),
    ("T8", [(RUNTIME, '  key in ["Space", "k", "K", "j", "J", "l", "L", "Left", "Right",',
             '  key in ["k", "K", "j", "J", "l", "L", "Left", "Right",')],
     # The scrubber case's Space pauses on a session that is playing; the
     # pty suite's Space is skipped when playback already ended by itself, so
     # alone it let this arm survive (measured at 258f46856).
     [(TBL, TBL_SCRUB), (PTY, None)],
     "Space is not the Video Player's"),
    ("T9", [(RUNTIME, "  if on:", "  if false:")],
     [(TBL, TBL_ADD), (PTY, None)],
     "the Visual Replay panes are never added to the layout"),
    ("T10", [(HOST, "    panes.player.releaseScrub(act.axis, act.position, act.nowMs)",
              "    discard")],
     [(TBL, TBL_SCRUB)],
     "the terminal's scrubber release is dropped"),
    ("T11", [(BINDING, "    result.raster = initRgbaImage(pic.width, pic.height, bytes)",
              "    result.raster = initRgbaImage(1, 1, @[0'u8, 0, 0, 255])")],
     [(TBL, TBL_FRAMES)],
     "the pane paints a raster that is not the frame"),
    # ---- the GPUI window ---------------------------------------------------
    ("G1", [(GPUI_LEAF, "    discard r.setImageRgba(image, pic.pixels, pic.width, pic.height)",
             "    discard")],
     [(PLAN, PLAN_FRAMES)],
     "the GPUI frame element holds no pixels"),
    ("G2", [(GPUI_LEAF, "  if p.pickerState.val == PickerActive and st.loupe.isSome and",
             "  if false and")],
     [(PLAN, PLAN_PICK)],
     "GPUI draws no loupe"),
    ("G3", [(GPUI_LEAF, "  if lay.drawTrack.w > 0:", "  if false:")],
     [(PLAN, PLAN_DRAW)],
     "GPUI draws no draw-call scrubber"),
    ("G4", [(GPUI_MAIN, "    if hit.kind == gvHistoryRow:", "    if false:")],
     [(PLAN, PLAN_PICK)],
     "a GPUI press on a history row does nothing"),
    ("G6", [(GPUI_MAIN, "  if pane in gPanesArmed:\n    return", "")],
     [(PLAN, PLAN_KEYS)],
     "every key in the window runs twice: a press of Right steps two frames"),
    ("G5", [(GPUI_MAIN, '      of "end": action = some(VpaJumpEnd)',
             '      of "end": action = none(VideoPlayerAction)')],
     [(PLAN, PLAN_FRAMES)],
     "End is not the GPUI Video Player's"),
    ("W1", [(VOCAB, '  children.add viewText("videoPlayer.frame", title)',
             "  discard title")],
     [(TBL, TBL_VOCAB)],
     "the vocabulary's Video Player view names no frame"),
    # ---- the desktop -------------------------------------------------------
    ("D1", [(FACTORY, '      if ((response.headers.get("x-row-order") || "") === "bottom-up") {',
             "      if (false) {")],
     [(SPEC, None)],
     "the desktop draws GL frames upside down"),
    # ---- the declared survivor ---------------------------------------------
    ("Z1", [(GPUI_LEAF, "  VisualButtonGapPx = 6", "  VisualButtonGapPx = 7")],
     [(PLAN, PLAN_KEYS)],
     "behaviour-preserving: the DECLARED SURVIVOR (the GPUI transport's gap)"),
]

DECLARED_SURVIVORS = {"Z1"}

IN_BINARY = {PANES, PLAYER, FRAME, HISTORY, CLIENT, PRODUCER, TUI_PANE,
             TUI_PANES, BINDING, RUNTIME, HOST, FRAME_IMAGE, VOCAB}
IN_GPUI = {PANES, PLAYER, FRAME, HISTORY, CLIENT, PRODUCER, GPUI_LEAF,
           GPUI_MAIN, VOCAB}
IN_DESKTOP = {FACTORY}
  # The desktop's spec runs the desktop `just build-once` built — neither
  # `$PLAT59_DESKTOP_TEST` (the capture recipe) nor `npx playwright test`
  # compiles the renderer — so an arm in the desktop's client is graded
  # after a `build-once` of the mutated tree. Without it D1 graded the
  # unmutated desktop and survived (measured at 258f46856).
PTY_SUITES = {PTY}
GPUI_SUITES = {PLAN}
DESKTOP_SUITES = {SPEC}
RUST_SUITES = set()


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
        f.write("# Control digests for run-plat59-low-level-code-mutations.py —\n"
                "# the subjects AND the suites the arms are graded by (§16c).\n"
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
    return build_with("PLAT59_BUILD_TUI", "build-tui")


def build_gpui():
    return build_with("PLAT59_BUILD_GPUI", "build-gpui")


def build_desktop():
    return build_with("PLAT59_BUILD_DESKTOP", "build-once")


def without_local_paths(line):
    """The line with this checkout's root and the visual-replay fixture's
    directory written as `<repo>` and `<fixture>`. A GPUI run that fails
    names its command line, fixture path included, so a cause recorded
    verbatim held one checkout's absolute path: it matched only in the
    checkout it was derived in, and put a home directory into the tree
    (G5, 2026-11-11)."""
    fixture = os.environ.get("CODETRACER_VISUAL_REPLAY_FIXTURE", "")
    if fixture:
        line = line.replace(str(Path(fixture).resolve()), "<fixture>")
        line = line.replace(fixture, "<fixture>")
    return line.replace(str(REPO), "<repo>")


def portable_cause(line):
    """A pty suite's wait names its condition and then snapshots the screen;
    the recorded cause keeps the condition and drops the snapshot, and
    names no local path (`without_local_paths`)."""
    line = without_local_paths(line)
    head, sep, _rest = line.partition("; screen:")
    if sep:
        return head
    head, sep, rest = line.partition("; status:")
    if not sep:
        return line
    tail = re.search(r" \[\w+\]$", rest)
    return head + (tail.group(0) if tail else "")


def run_spec(suite):
    """The Electron spec: GREEN on rc 0, else RED on its first expectation."""
    cmd = os.environ.get("PLAT59_DESKTOP_TEST")
    argv = ["bash", "-c", cmd] if cmd else \
        ["npx", "playwright", "test", suite.split("src/tests/gui/", 1)[1],
         "--reporter=line"]
    cwd = REPO if cmd else REPO / "src/tests/gui"
    # The spec writes what it read to `$PLAT59_ANSWERS_OUT`, by default the
    # committed reference the native suites assert against: a graded run (a
    # mutated desktop among them) writes a scratch copy instead.
    NIMCACHE.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env.setdefault("PLAT59_ANSWERS_OUT",
                   str(NIMCACHE / "plat59-visual-replay.electron.json"))
    try:
        p = subprocess.run(argv, cwd=cwd, capture_output=True, text=True,
                           timeout=TIMEOUT, env=env)
    except subprocess.TimeoutExpired:
        return "HUNG", []
    out = (p.stdout or "") + (p.stderr or "")
    if p.returncode == 0:
        return ("GREEN", []) if " passed" in out else ("RAN-NOTHING", [])
    plain = re.sub(r"\x1b\[[0-9;]*m", "", out)
    first = [without_local_paths(ln.strip()) for ln in plain.splitlines()
             if ln.strip().startswith("Error:")][:1]
    return "RED", first


def run_rust(suite):
    """The engine's unit test: GREEN on rc 0, else RED on its first panic."""
    cmd = os.environ.get("PLAT59_RUST_TEST")
    argv = ["bash", "-c", cmd] if cmd else \
        ["cargo", "test", "--lib", suite.split("#", 1)[1]]
    cwd = REPO if cmd else REPO / "src/db-backend"
    try:
        p = subprocess.run(argv, cwd=cwd, capture_output=True, text=True,
                           timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return "HUNG", []
    out = (p.stdout or "") + (p.stderr or "")
    if p.returncode == 0:
        return ("GREEN", []) if " passed" in out else ("RAN-NOTHING", [])
    first = [ln.strip() for ln in out.splitlines()
             if ln.strip().startswith(("left:", "assertion"))][:1]
    if not first and "error[" in out:
        return "DID-NOT-COMPILE", []
    return "RED", first


def case_filters(test_filter):
    """An arm's filter as `std/unittest` arguments: none, one test name, or
    a scenario's names (`through`)."""
    if not test_filter:
        return ()
    if isinstance(test_filter, str):
        return (test_filter,)
    return tuple(test_filter)


def run_suite(suite, test_filter):
    if suite in RUST_SUITES:
        return run_rust(suite)
    if suite in DESKTOP_SUITES:
        return run_spec(suite)
    NIMCACHE.mkdir(parents=True, exist_ok=True)
    stem = Path(suite).stem
    env = dict(os.environ, CODETRACER_REPO_ROOT=str(REPO))
    cmd = [os.environ.get("PLAT59_NIM", "nim"), "c", "-r", "--hints:off",
           "--warnings:off",
           f"--nimcache:{NIMCACHE}/{stem}",
           f"-o:{NIMCACHE}/{stem}.out"] + suite_flags(suite) + [suite]
    cmd.extend(case_filters(test_filter))
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
    # `nim c -r` says this only when the compiled suite RAN and exited
    # non-zero; a compile error never reaches it. Without the distinction a
    # suite that dies outside any test (an unhandled exception from the
    # scenario's own `open()`, a nil read) was graded DID-NOT-COMPILE —
    # measured at 258f46856: R1's refused open and G2's missing loupe.
    ran_binary = "Error: execution of an external program failed" in out
    if p.returncode == 0:
        # §37's floor: every case a filter names must have run (a name that
        # matches nothing exits 0); an unfiltered run, at least one.
        ran = out.count("[OK]")
        floor = max(1, len(case_filters(test_filter)))
        return ("GREEN", failures) if ran >= floor else ("RAN-NOTHING", [])
    if not failures and not ran_binary and "Error:" in out and \
            "[FAILED]" not in out:
        return "DID-NOT-COMPILE", failures
    if not failures:
        failures = [portable_cause(ln.strip()) for ln in out.splitlines()
                    if "[FAILED]" in ln or "Unhandled exception" in ln][:1]
    if not failures:
        failures = [died_outside_a_test(out)]
    return "RED", failures


def died_outside_a_test(out):
    """The cause of a suite that died outside any test: the unhandled
    exception's type (its message carries pids and paths, and may span
    lines; Nim ends it with `[Type]`), or the signal's line."""
    lines = out.splitlines()
    for i, ln in enumerate(lines):
        if ln.startswith("Error: unhandled exception: "):
            for tail in lines[i:]:
                m = re.search(r" \[(\w+)\]$", tail.rstrip())
                if m:
                    return f"Error: unhandled exception: … [{m.group(1)}]"
            return "Error: unhandled exception"
        if ln.startswith("SIG"):
            return ln.strip()
    return "the suite exited non-zero outside any test"


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
    graded = sorted({(s, case_filters(flt)) for arm in selected
                     for s, flt in arm[2]})
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
            backups[rel] = path.with_name(path.name + ".plat59bak")
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

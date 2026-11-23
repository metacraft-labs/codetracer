#!/usr/bin/env python3
"""Installed plugins in the GPUI window (Extensibility-Model.md §11) — the
mutation harness for the window's door to its plugins (`host/gpui_plugins`),
the shared session-plugins module it uses (`tui/host/plugin_processes`) and a
contributed leaf's drawing (`app/leaves`).

Each arm plants ONE defect and must be killed by the case that asserts it in
`test_gpui_plugins_host.nim`, which drives REAL plugin processes installed as
a component and draws through the real isonim-gpui shim. The engine —
committed control digests over subjects AND suites, the needle scan gating a
re-record, `because` derived from a run and then required, rc 124 a hang,
per-arm restore verification — is `tui/tests/plat71_mutation_engine.py`.

`main.nim`'s glue (the pump on the window's tick, the omnibar, the footer, the
key hooks) is graded by the window lane's record
(`test_gpui_plugins_window.nim`), which a mutation can only reach by
re-taking the capture on a compositor; it has no arm here.

Usage:
    run-gpui-plugins-mutations.py [--only ID,ID] [--derive]
    run-gpui-plugins-mutations.py --needle-scan
    run-gpui-plugins-mutations.py --record-control-hashes
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "tui" / "tests"))
from plat71_mutation_engine import Harness  # noqa: E402

DOOR = "src/frontend/gpui/host/gpui_plugins.nim"
SHARED = "src/frontend/tui/host/plugin_processes.nim"
LEAVES = "src/frontend/gpui/app/leaves.nim"
CLICKS = "src/frontend/gpui/window_clicks.nim"
PANES = "src/frontend/tui/host/plugin_panes.nim"

SUITE = "src/frontend/gpui/tests/test_gpui_plugins_host.nim"

SUBJECTS = [DOOR, SHARED, LEAVES, CLICKS, PANES]
SUITES = [SUITE]
IN_BINARY = set()

S = "GPUI: the window's plugins (host/gpui_plugins)::"
SAFE = S + "--no-extensions and CODETRACER_NO_EXTENSIONS start no plugin process"
CONSENT = S + ("installing is not accepting; granted, one process runs both, "
               "and the omnibar lists them")
MOVE = S + "a plugin's relayed step arrives as the window's own control"
LEAF = S + "a contributed leaf draws its plugin's view through the GPUI binding"
KEYS = S + ("keys: the layer takes Escape, the user's row beats the plugin "
            "pass, the chord recovers")
HOLDER = S + ("a plugin killed while it holds the keyboard: its layer goes at "
              "once, the next key is the window's")
PLACED = S + "Show pane places a plugin's pane as a tab beside the Variables stack"
VIEWKEY = S + ("a key on a focused plugin pane goes to its view, and the "
               "plugin answers it")
MARKS = S + "the editor's plugin decorations and markers, from what the plugins pushed"
PRESS = S + ("a press on a plugin pane's row activates it, and the plugin "
             "answers it")
DRAWN = S + ("the editor draws a plugin's marker in the mark column and its "
             "decoration after the code")

ARMS = [
    ("G1", [(DOOR, '  if k == "esc": "escape" else: k', "  k")],
     [(SUITE, KEYS)],
     "§11.7.6: the window's `Esc` is not the manifests' `escape`; a layer "
     "binding Escape never sees it"),
    ("G2", [(DOOR, "  if not route.found and not userBound:",
             "  if not route.found:")],
     [(SUITE, KEYS)],
     "§11.7.2: the plugin pass runs even when the user's layer has a row"),
    ("G3", [(DOOR, '    ("stepForward", "next"), ("stepIn", "step-in"), '
                   '("stepOut", "step-out"),',
             '    ("stepForward", "step-in"), ("stepIn", "next"), '
             '("stepOut", "step-out"),')],
     [(SUITE, MOVE)],
     "a plugin's step forward runs as the window's step in"),
    ("G4", [(DOOR, '  if pluginKeyName(canonical) != "escape": return false',
             "  discard")],
     [(SUITE, KEYS)],
     "§11.7.6: any three keys open the recovery dialog"),
    ("G5", [(LEAVES, "  r.appendChild(body, renderGpui(r, view).root)",
             "  discard renderGpui(r, view)")],
     [(SUITE, LEAF)],
     "a contributed leaf draws its title and not its plugin's view"),
    ("G6", [(SHARED, "    result.incl pane.id", "    discard pane")],
     [(SUITE, LEAF)],
     "a running plugin's pane is classified as from an extension that is "
     "not loaded"),
    ("G7", [(DOOR, "  if layer.len > 0: parts.add layer",
             "  if layer.len > 0 and statusNote.len == 0: parts.add layer")],
     [(SUITE, KEYS)],
     "§11.7.3: a note on the footer hides which plugin holds the keyboard"),
    ("G8", [(SHARED, '  for id in p.awaitingConsent:\n'
                     '    for (verb, title) in [("review", "Review"), ("grant", "Grant")]:',
             '  for id in newSeq[string]():\n'
             '    for (verb, title) in [("review", "Review"), ("grant", "Grant")]:')],
     [(SUITE, CONSENT)],
     "a plugin waiting for consent has no Grant entry in the omnibar"),
    ("G9", [(SHARED, '  noExtensionsFlag or getEnv("CODETRACER_NO_EXTENSIONS")'
                     '.strip.toLowerAscii in',
             '  noExtensionsFlag or false and getEnv("CODETRACER_NO_EXTENSIONS")'
             '.strip.toLowerAscii in')],
     [(SUITE, SAFE)],
     "§11.7.6: CODETRACER_NO_EXTENSIONS is ignored; safe mode starts plugins"),
    ("G10", [(DOOR, "  if not p.isNil:\n    let items = p.statusText",
              "  if statusNote.len == 0 and not p.isNil:\n    let items = p.statusText")],
     [(SUITE, KEYS)],
     "a note on the footer hides the plugins' status items"),
    ("G11", [(DOOR, "    if s.isNil or s.breaker != bsOpen: continue",
              "    if s.isNil: continue")],
     [(SUITE, HOLDER)],
     "§11.7.5: a re-enabled plugin still offers its fault's Re-enable"),
    ("G12", [(DOOR, "    p.consentPaletteEntries(GpuiPluginsTargetPrefix) & p.faultEntries",
              "    p.consentPaletteEntries(GpuiPluginsTargetPrefix)")],
     [(SUITE, HOLDER)],
     "§11.7.5: a stopped plugin's Re-enable, Disable and Show log are not in "
     "the omnibar"),
    ("G13", [(DOOR, "      return cmdAddContributedPane(id, title, after = some(builtinRef(a)))",
              "      return cmdAddContributedPane(id, title)")],
     [(SUITE, PLACED)],
     "Show pane docks a plugin's pane into the root row, too narrow to show"),
    ("G14", [(DOOR, "  if panes.isNil: @[] else: panes.markersFor(document)",
              "  if panes.isNil: @[] else: panes.decorationsFor(document)")],
     [(SUITE, MARKS)],
     "§11.4.4: the editor's gutter markers are read from the decorations"),
    ("G15", [(LEAVES, "      elif hasGutterMark(pluginMarks):",
              "      elif false:")],
     [(SUITE, DRAWN)],
     "§11.4.4: a plugin's marker is never drawn in the mark column"),
    ("G16", [(DOOR, "    if d.line == line and d.text.len > 0:",
              "    if d.text.len > 0:")],
     [(SUITE, MARKS)],
     "the footer repeats a plugin's decoration from any line, not the "
     "execution line"),
    ("G17", [(LEAVES, '      decorations.add m.glyph & " " & m.text',
              "      discard")],
     [(SUITE, DRAWN)],
     "§11.4.4: a plugin's decoration is never drawn after the code"),
    ("G18", [(DOOR, "  panes.paneKey(focusedPane, k)", "  false")],
     [(SUITE, VIEWKEY)],
     "§11.4.4: a focused plugin pane's keys never reach its view; no "
     "view-event is sent"),
    ("G19", [(CLICKS, "    if ctx.startsWith(PluginContextPrefix):",
              "    if false:")],
     [(SUITE, PRESS)],
     "§11.4.4: a plugin pane's rows are never wired; a press on one reports "
     "nothing"),
    ("G20", [(DOOR, "  panes.paneClickNode(pane, node, index)", "  false")],
     [(SUITE, PRESS)],
     "§11.4.4: a press on a plugin pane's row never reaches its view; no "
     "view-event is sent"),
    ("G21", [(PANES, "    if count >= 0 and option >= count: return false",
              "    discard")],
     [(SUITE, PRESS)],
     "a press naming an option past the list's end is sent to the plugin as "
     "an activation"),
]


HARNESS = Harness("gpui-plugins", HERE, SUBJECTS, SUITES, ARMS, IN_BINARY)

if __name__ == "__main__":
    sys.exit(HARNESS.main(sys.argv[1:], globals()))

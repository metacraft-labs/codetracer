#!/usr/bin/env python3
"""Plugin panes docked in the terminal, `view-event`, and plugin decorations
(Extensibility-Model.md §6, §10 decision 2, §11.4.4) — the mutation harness.

Each arm plants ONE defect and must be killed by the case that asserts its
absence:

  * a contributed region mistaken for a built-in pane (the projection puts an
    extension's leaf in `regions`, where its `pane` reads `paneEditor`);
  * an unknown contributed pane decoding to nothing (the decoder drops the id,
    placed or docked, so the slot is gone instead of reported);
  * the zero-value trap in `activate` (selecting the editor selects an
    extension's tab);
  * a `view-event` not sent (a key or click on a plugin pane acts locally and
    the plugin never hears of it — killed on the shipped binary, where only
    the plugin process can draw the `(activated)` mark);
  * a decoration not drawn on the source pane;
  * a plugin pane's drag carrying the wrong identity (the dragged pane named
    by its zero value, the editor);
  * a drop target anchored on the zero value of an extension's first tab;
  * a docked plugin pane shown open but not painted;
  * a closed plugin pane not remembered across sessions;
  * a declared marker not drawn in the gutter.

The engine — committed control digests over subjects AND suites, the needle
scan gating a re-record, `because` derived from a run and then required, rc
124 a hang, per-arm restore verification — is `plat71_mutation_engine.py`.

Usage:
    run-plat81-plugin-panes-mutations.py [--only ID,ID] [--derive]
    run-plat81-plugin-panes-mutations.py --needle-scan
    run-plat81-plugin-panes-mutations.py --record-control-hashes
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from plat71_mutation_engine import Harness  # noqa: E402

PROJECT = "src/frontend/tui/app/layout/project.nim"
MODEL = "src/frontend/headless_app/layout_model.nim"
PANES = "src/frontend/tui/host/plugin_panes.nim"
SHELL = "src/frontend/tui/app/views/shell.nim"
INTERACTION = "src/frontend/headless_app/layout_interaction.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"

LAYOUT = "src/frontend/tui/app/tests/test_contributed_pane_layout.nim"
ALGEBRA = "src/frontend/viewmodel/tests/unit/test_layout_contributed_identity.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_plat81_plugin_panes_pty.nim"

SUBJECTS = [PROJECT, MODEL, PANES, SHELL, INTERACTION, RUNTIME]
SUITES = [LAYOUT, ALGEBRA, PTY]
IN_BINARY = {PANES, RUNTIME}

REGION = "*::no built-in region is a contributed pane, and the two lists partition the area"
UNKNOWN = "*::an unknown contributed pane decodes to a typed slot, placed or docked"
DOCKED = "*::dock, save, restore: the slot, title and neighbour come back"
TRAP = "*::activating the editor never selects a contributed tab ahead of it"
EVENT = "*::Enter and a click on a flame row round-trip through view-event"
DECO = "*::a decoration is drawn on its line of the source pane"
DRAG = "*::a plugin tab is picked up, dragged and dropped through the gesture machine"
ANCHOR = "*::a drop beside a plugin pane names the plugin pane, never the editor"
OPEN = "*::a click on a docked plugin pane's label docks it open, and paints it"
CLOSED = "*::a plugin pane the user closed stays closed in later sessions, and Show pane brings it back"
MARKER = "*::a plugin's marker is a glyph in the gutter's mark column"

ARMS = [
    ("P1", [(PROJECT, "      if n.isContributed:\n"
                      "        # AN EXTENSION'S PANE GETS ITS OWN REGION TYPE, IN ITS OWN LIST — see",
             "      if false:\n"
             "        # AN EXTENSION'S PANE GETS ITS OWN REGION TYPE, IN ITS OWN LIST — see")],
     [(LAYOUT, REGION)],
     "a contributed region is projected as a built-in pane (paneEditor)"),
    ("P2", [(MODEL, "      result.contributedPane = id",
             "      discard id")],
     [(ALGEBRA, UNKNOWN)],
     "an unknown contributed leaf decodes to nothing (the id dropped)"),
    ("P3", [(MODEL, "      contributedPane: contributedId,",
             "      contributedPane: \"\",")],
     [(ALGEBRA, DOCKED)],
     "a docked contributed pane decodes to nothing (the id dropped)"),
    ("P4", [(MODEL, "    return node.matches(r)",
             "    return node.pane == r.builtin")],
     [(ALGEBRA, TRAP)],
     "activate compares the zero value and selects an extension's tab"),
    ("P5", [(PANES, "  pp.plugins.sup.viewEvent(id, eventFor(n, t))",
             "  discard eventFor(n, t)")],
     [(PTY, EVENT)],
     "a key or click on a plugin pane sends no view-event"),
    ("P6", [(SHELL, "      paintSourceDecorations(g, under, model, screen)",
             "      discard screen")],
     [(LAYOUT, DECO)],
     "a plugin's decoration is not drawn on the source pane"),
    ("P7", [(INTERACTION, "              sourceContributed: idPart(source), origin: origin, hover: hover)",
             "              sourceContributed: \"\", origin: origin, hover: hover)")],
     [(LAYOUT, DRAG)],
     "a dragged plugin pane is carried as its zero value (the editor)"),
    ("P8", [(INTERACTION, "    let anchor = paneRefOf(parent.children[0])",
             "    let anchor = builtinRef(parent.children[0].pane)")],
     [(LAYOUT, ANCHOR)],
     "a drop into a stack whose first tab is a plugin pane names the editor"),
    ("P9", [(SHELL, "    if geometry.openDockContributed.len > 0:",
             "    if false:")],
     [(LAYOUT, OPEN)],
     "a docked plugin pane shown open is not painted from its plugin's tree"),
    ("P10", [(RUNTIME, "        rt.plugins.setPaneClosed(id, true)",
              "        discard id")],
     [(PTY, CLOSED)],
     "a plugin pane the user closed is placed again in the next session"),
    ("P11", [(SHELL, "      paintSourceMarkers(g, under, model, screen)",
              "      discard model")],
     [(LAYOUT, MARKER)],
     "a declared marker is not drawn in the gutter"),
]


HARNESS = Harness("plat81-plugin-panes", Path(__file__).resolve().parent,
                  SUBJECTS, SUITES, ARMS, IN_BINARY)

if __name__ == "__main__":
    sys.exit(HARNESS.main(sys.argv[1:], globals()))

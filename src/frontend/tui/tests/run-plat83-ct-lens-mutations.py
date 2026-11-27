#!/usr/bin/env python3
"""The `ct-lens` plugin package (`src/plugins/ct-lens/`) — the mutation
harness for its two plugins: line history through a child `git`, and changed
values turned into watches through the action relay.

Each arm plants ONE defect in the package and must be killed by the case that
asserts the behaviour, in `test_ct_lens_plugins.nim`, which runs the REAL
package under the real `Supervisor`. The engine — committed control digests
over subjects AND suites, the needle scan gating a re-record, `because`
derived from a run and then required, rc 124 a hang, per-arm restore
verification — is `plat71_mutation_engine.py`.

The package's sources are compiled into the PLUGIN EXECUTABLE, which the suite
rebuilds itself: `ct_lens_fixture.buildLensExecutable` rebuilds whenever a
source's bytes differ from the ones it was built from, which a mutation's do.
M10 and M11 are in the TERMINAL, two defects the package's author met in the
host: the closures that activated a package's plugins all naming its last one
(fixed by the host's author while this package was written) and status items
hidden by any note.
They are graded on the shipped binary over a pty, rebuilt per arm.

Usage:
    run-plat83-ct-lens-mutations.py [--only ID,ID] [--derive]
    run-plat83-ct-lens-mutations.py --needle-scan
    run-plat83-ct-lens-mutations.py --record-control-hashes
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from plat71_mutation_engine import Harness  # noqa: E402

LENS = "src/plugins/ct-lens/ct_lens_plugins.nim"
WATCH = "src/plugins/ct-lens/lens_watch.nim"
SDK = "src/plugin_sdk/codetracer_plugin_sdk.nim"

PROCS = "src/frontend/host/plugin_processes.nim"
RUNTIME = "src/frontend/tui/app/runtime.nim"

SUITE = "src/frontend/viewmodel/tests/unit/test_ct_lens_plugins.nim"
PTY = "src/frontend/tui/tests/real_terminal/test_ct_lens_plugins_pty.nim"

SUBJECTS = [LENS, WATCH, SDK, PROCS, RUNTIME]
SUITES = [SUITE, PTY]
IN_BINARY = {PROCS, RUNTIME}

FUNCTION = "*::the commits that changed the function the debugger stopped in, newest first"
SLOW = "*::a slow git does not hold the sibling plugin"
DEADLINE = "*::a git past its deadline is killed and the history says so"
CHANGED = "*::what the step changed, before and after, with the command enabled for it"
WATCHES = "*::the command adds the changed values as watches in the core State ViewModel"
NOTHING = "*::a step that changed nothing disables the command, with the reason"
VISUAL = "*::its visualiser reaches the presenter at the plugin tier"
DECORATE = "*::the commit that last changed the function decorates its first line"
PANE_JUMP = "*::a call activated in its docked pane is a jump, without the mode"
NEXT_SESSION = "*::plugins granted in an earlier session start by themselves in the next"
STATUS_ITEM = ("*::installed and granted, one process runs history and watch; "
               "history follows the debugger through git")
F7_WATCH = ("*::F7 watches what the step changed; "
            "the plugin's visualiser renders Python's None")

ARMS = [
    ("M1", [(LENS, "  if st.path == result.file and st.functionFirst > 0 and",
             "  if false and st.functionFirst > 0 and")],
     [(SUITE, FUNCTION)],
     "the stop's function range is ignored; only the line is asked about"),
    ("M2", [(SDK, "  let inTime = await p.own(withTimeout(exited, max(1, timeoutMs)))",
             "  let inTime = await p.own(withTimeout(exited, high(int32)))")],
     [(SUITE, DEADLINE)],
     "a tool past its deadline is left running"),
    ("M3", [(SDK, "    let body = toolBody(p, run, env, workingDir, timeoutMs, maxOutput)",
             "    let body = toolBody(p, run, env, workingDir, timeoutMs, maxOutput)\n"
             "    while not body.finished: asyncdispatch.poll(5)")],
     [(SUITE, SLOW)],
     "the handler waits for the tool, holding the sibling plugin"),
    ("M4", [(WATCH, "  p.pushEnablement(\"watch.add-changed\", pending.len > 0, reason)",
             "  p.pushEnablement(\"watch.add-changed\", true, reason)")],
     [(SUITE, NOTHING)],
     "the command stays enabled when the step changed nothing"),
    ("M5", [(WATCH, "  let have = watched.toHashSet",
             "  let have = initHashSet[string]()")],
     [(SUITE, WATCHES)],
     "values already watched are offered again"),
    ("M6", [(WATCH, "      p.relay(\"state\", \"addWatch\", %*{\"expression\": path})",
             "      discard path")],
     [(SUITE, WATCHES)],
     "the command does not reach the core State ViewModel"),
    ("M7", [(WATCH, "  p.pushContext(\"hasChanges\", %(pending.len > 0))",
             "  p.pushContext(\"hasChanges\", %false)")],
     [(SUITE, CHANGED)],
     "the binding's context key never holds, so the key is never live"),
    ("M8", [(SDK, "          if not run.finished.finished:\n            run.finished.complete(run)",
             "          discard")],
     [(SUITE, FUNCTION)],
     "a finished tool run is never handed back; the history never arrives"),
    ("M9", [(WATCH, "  p.publish(\"visualisers\", %*[",
             "  p.publish(\"visualisers-unpublished\", %*[")],
     [(SUITE, VISUAL)],
     "the visualisers go out under a name the host does not read"),
    ("M12", [(LENS, "    if not h.running and h.message.len == 0 and h.rows.len > 0:",
              "    if false:")],
     [(SUITE, DECORATE)],
     "the history decorates no line"),
    ("M13", [(LENS, "    if surface != \"calls\" or event{\"transition\"}.getStr(\"\") != \"trActivate\":",
              "    if true:")],
     [(SUITE, PANE_JUMP)],
     "a call activated in the docked pane is ignored"),
    ("M10", [(PROCS, "      p.host.register(pp.text, lp.installed.manifestPath,\n"
                     "                      activationFor(p, id))",
              "      let sup = p.sup\n"
              "      p.host.register(pp.text, lp.installed.manifestPath,\n"
              "        proc(ctx: PluginContext) =\n"
              "          p.toStart.add id\n"
              "          ctx.onPluginCleanup(proc() = sup.deactivate(id)))")],
     [(PTY, NEXT_SESSION)],
     "the terminal: activation closures made in the loop share one id"),
    ("M11", [(RUNTIME, "      model.status.notification.add \"  \" & pluginStatus",
              "      discard")],
     # Re-aimed 2026-11-27: STATUS_ITEM alone no longer notices. Since the
     # source decoration was mirrored onto the status line (a decoration on
     # the execution line is appended to the note as `<plugin>: <text>`), the
     # history status item `history: <hash>` is also a substring of that
     # decoration note, so the case reads green with the status items hidden.
     # The watch plugin's status item (`changed: ...`), which F7_WATCH reads
     # after every `next`, has no such second route and goes red.
     [(PTY, STATUS_ITEM), (PTY, F7_WATCH)],
     "the terminal: a note hides the plugins' status items"),
]


HARNESS = Harness("plat83-ct-lens", Path(__file__).resolve().parent,
                  SUBJECTS, SUITES, ARMS, IN_BINARY)

if __name__ == "__main__":
    sys.exit(HARNESS.main(sys.argv[1:], globals()))

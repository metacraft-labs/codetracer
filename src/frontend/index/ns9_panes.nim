## The Electron host's answer to `CODETRACER::ns9-panes`.
##
## NS9's Test Results and Constraints panes are fed by one message, and this is
## the desktop half of it; `ui/web_entry_surface.installTemplatePaneHost` is
## the browser's. The renderer's handlers (`ui_js.onNs9PanesCatalog` /
## `onNs9PanesConstraints`) cannot tell which replied, which is the property
## `Planned-Features/Noir-Studio.md` §3 asks for: "the web is a build of the
## product and not a fork of it".
##
## ## Two producers, and only one of them is a subprocess
##
##   * THE TEST CATALOG is produced IN PROCESS by
##     `ct_test/frameworks/noir_nargo.noirProjectCatalog` — the same provider
##     `ct test discover` uses, called directly. There is no `ct test`
##     subprocess to spawn, no JSON to round-trip and no second discovery
##     implementation; the browser calls the same parser through
##     `noir_test_syntax.noirCatalogFromSources`, and
##     `ci/test/noir-template-toolchain.sh` compares its selectors against
##     `nargo test`'s own names.
##
##   * THE CONSTRAINT COUNTS need `nargo info --json`, which is a subprocess.
##     It is run with a timeout and its failure is reported as a SENTENCE
##     rather than as an empty pane: a project that has never compiled, a
##     `nargo` that is not on PATH and a workspace with several packages are
##     three different answers and a user can act on each of them.
##
## ## Why this is Noir-only today, and says so
##
## `Content.Constraints` is not a Noir pane — it is CodeTracer's, and
## `GUI/Debugging-Features/Generated-Code-Listing.md` names Noir as "the first
## consumer" of a producer other languages will have too. What is Noir-specific
## is the PRODUCER, and a project with no `Nargo.toml` gets a stated absence
## rather than a pane that spins.

import std/[asyncjs, json, jsffi, os, strutils]

import electron_vars
import ../lib/[jslib, electron_lib]
import ../../common/[ct_logging, noir_constraints]
import ../../ct_test/contracts
# `noir_test_syntax`, NOT `noir_nargo`: the provider imports `process_exec`
# and `native_m11_common`, which are C-backend modules — importing it here
# fails the index build with `undeclared identifier: 'copyMem'` out of
# `std/endians`, which is `std/osproc` arriving on the JS backend. The pure
# half is exactly what this file needs, and it is the same half the browser
# calls, so using it is not a workaround: it is the reason the split exists.
import ../../ct_test/frameworks/noir_test_syntax
# The folder → catalog / absence rule, shared with the native hosts
# (`GUI/Core-Panes/Test-Results-Pane.md` §8.2).
import ../viewmodel/viewmodels/test_catalog_answer
# The one sentence every pane shows for a session with no project folder
# (Files and VCS say it too; `viewmodels/no_project_folder`).
from ../viewmodel/viewmodels/no_project_folder import NoProjectFolderText
# Test-Results-Pane.md §9.3: the folder's `replay-open-in`, sent with its
# tests.
from ./replay_open_in import replayOpenInFor
# PLAT-62: the Constraints pane's measurement rule, shared with the native
# hosts.
import ../viewmodel/viewmodels/constraints_answer

# ---------------------------------------------------------------------------
# The node side, and the one rule it has: CROSS THE BOUNDARY AS `cstring`.
#
# On the JS backend a Nim `string` is NOT a JavaScript string — it is an array
# of UTF-8 byte values — while `cstring` IS one. These helpers used to take
# and fill Nim `string`s from `importjs` / `{.emit.}` code, so node was handed
# a byte array where it expected a path: `fs.existsSync([47, 116, …])` answers
# false, and the desktop host told EVERY Noir project "This project has no
# Nargo.toml". The Test Results pane on the desktop therefore never had a
# catalog (measured 2026-10-21 in a real Electron window over a crate with a
# `Nargo.toml`, `src/tests/gui/tests/test-results-pane/
# desktop_suite_run_verdicts.spec.ts`). Every value now crosses as `cstring`
# and is converted with `$` / `cstring(...)` on the Nim side, where the
# conversion is defined.
# ---------------------------------------------------------------------------

proc nodeFileExists(path: cstring): bool {.importjs:
  "(function (p) { try { return require('fs').existsSync(p); } " &
  "catch (e) { return false; } })(#)".}
  ## `std/os`'s `fileExists` is a C-backend proc; the index is a node program
  ## and asks node.

proc fileExistsIn(projectRoot, name: string): bool =
  ## Whether `<projectRoot>/<name>` exists. Joined here rather than with
  ## `std/os` (a C-backend module); a doubled separator — `startOptions.folder`
  ## ends in one — is harmless to node.
  nodeFileExists(cstring(projectRoot & "/" & name))

proc nodeNoirSources(projectRoot: cstring): seq[JsObject] {.importjs: """
  (function (root) {
    const out = [];
    try {
      const fs = require('fs');
      const path = require('path');
      const walk = (dir) => {
        let entries = [];
        try { entries = fs.readdirSync(dir, { withFileTypes: true }); }
        catch (e) { return; }
        for (const entry of entries) {
          const full = path.join(dir, entry.name);
          if (entry.isDirectory()) { walk(full); continue; }
          if (!entry.name.endsWith('.nr')) continue;
          let content = '';
          try { content = fs.readFileSync(full, 'utf8'); }
          catch (e) { continue; }
          const rel = path.relative(root, full).split(path.sep).join('/');
          out.push({ path: rel, content: content });
        }
      };
      walk(path.join(root, 'src'));
    } catch (e) {}
    return out;
  })(#)""".}
  ## Every readable `.nr` under `<root>/src`, as `{path, content}` objects
  ## whose fields are JavaScript strings — `cstring`s on the Nim side.

proc noirSourcesUnder(projectRoot: string): seq[NoirSourceFile] =
  ## Every `.nr` under `src/`, read, and named by its project-relative path.
  ##
  ## This is `noir_nargo.noirFiles` + `readSourceGuarded` done with node's
  ## `fs` instead of `std/os`, because the index process is a node program.
  ## What it deliberately does NOT reimplement is the part that could drift:
  ## which declarations are tests, what their selectors are, and which files
  ## count — all of that is `noirCatalogFromSources`, shared with the browser
  ## and with `ct test`.
  ##
  ## Unreadable files are skipped rather than aborting the walk, per
  ## `docs/ct-test-provider-guide.md`: one bad file must not cost a workspace
  ## its whole catalog.
  for entry in nodeNoirSources(cstring(projectRoot)):
    result.add NoirSourceFile(path: $entry.path.to(cstring),
                              content: $entry.content.to(cstring))

proc nodeReadText(path: cstring): cstring {.importjs: """
  (function (p) {
    try { return require('fs').readFileSync(p, 'utf8'); }
    catch (e) { return ''; }
  })(#)""".}
  ## The text of `path`, "" when it cannot be read.

proc nodeNargoInfo(projectRoot: cstring; args: JsObject): JsObject {.importjs: """
  (function (root, args) {
    try {
      const cp = require('child_process');
      const res = cp.spawnSync('nargo', args, {
        cwd: root, encoding: 'utf8', timeout: 60000,
        maxBuffer: 8 * 1024 * 1024 });
      if (res.error) {
        return { failed: true, message: String(res.error.message), output: '' };
      }
      if (res.status !== 0) {
        return { failed: true, output: '',
                 message: (res.stderr || '').toString().trim().slice(0, 400) ||
                   ('nargo info exited with status ' + res.status) };
      }
      return { failed: false, message: '', output: (res.stdout || '').toString() };
    } catch (e) {
      return { failed: true, output: '', message: String((e && e.message) || e) };
    }
  })(#, #)""".}
  ## `nargo` with `args` run in `root`, as `{failed, message, output}` with
  ## JavaScript-string fields.

proc nargoInfoAnswer(projectRoot: string): ConstraintsAnswer =
  ## The project's measurement (`NargoInfoArgs`), through the shared rule
  ## (`constraints_answer`) the terminal and the GPUI window answer their own
  ## pane with: every failure is a sentence, never an empty report.
  let hasMarker = projectRoot.len > 0 and
                  fileExistsIn(projectRoot, NoirProjectMarker)
  if absenceBeforeRun(projectRoot, hasMarker).len > 0:
    return constraintsAnswer(projectRoot, hasMarker, NargoInfoRun())
  var args: seq[cstring] = @[]
  for arg in NargoInfoArgs:
    args.add cstring(arg)
  let answer = nodeNargoInfo(cstring(projectRoot), args.toJs)
  var run = NargoInfoRun(started: true)
  if answer.failed.to(bool):
    let message = $answer.message.to(cstring)
    if answer.output.to(cstring).len == 0 and message.contains("ENOENT"):
      run.missing = true
    run.exitCode = 1
    run.message = message
  else:
    run.output = $answer.output.to(cstring)
  constraintsAnswer(projectRoot, hasMarker, run)

proc sourcesJson(files: seq[NoirSourceFile]): string =
  ## The sources the Constraints rows are placed against, for the renderer
  ## (`ui_js.onNs9PanesConstraints` → `ConstraintsVM.setSources`).
  var arr = newJArray()
  for f in files:
    arr.add %*{"path": f.path, "content": f.content}
  $arr

proc onNs9Panes*(sender: js, response: jsobject(folder=cstring)) =
  ## Answer both halves. Sent unconditionally rather than lazily: the panes are
  ## visible in edit mode, so an answer neither of them can use is still an
  ## answer they must show instead of staying blank.
  ##
  ## A tab holding a recording asks only about the circuit (`only:
  ## "constraints"`, `ui/constraints.askToMeasure`), the first time it shows the
  ## pane: it is not a test session, and its Test Results must not change.
  let folder = $response.folder
  let onlyField = response.toJs["only"]
  let onlyConstraints = not onlyField.isUndefined and not onlyField.isNull and
                        $onlyField.to(cstring) == ConstraintsOnlyAsk

  # `tab` is the asking renderer tab, echoed on both answers so each reaches
  # that tab's panes (`ui_js.ns9PanesTarget`); undefined from a sender that
  # names none.
  let tab = response.toJs["tab"]

  if not onlyConstraints:
    # THE ANSWER IS THE SHARED RULE's (`test_catalog_answer`), which the
    # terminal and the GPUI window answer their own pane with; this host only
    # says whether the marker exists and reads the sources, with node's `fs`.
    let answer = testCatalogAnswer(folder,
      folder.len > 0 and fileExistsIn(folder, NoirProjectMarker),
      proc(): seq[NoirSourceFile] = noirSourcesUnder(folder))
    var catalogJson = ""
    let catalogAbsence = answer.absence
    if answer.hasCatalog:
      catalogJson = pretty(answer.catalog.toJson())
    mainWindow.webContents.send "CODETRACER::ns9-panes-catalog", js{
      catalog: cstring(catalogJson),
      absence: cstring(catalogAbsence),
      replayOpenIn: cstring($replayOpenInFor(folder)),
      tab: tab
    }

  let measured = nargoInfoAnswer(folder)
  # PLAT-62: the sources the rows are placed against, read where the circuit
  # was measured.
  let sources =
    if measured.hasReport: sourcesJson(noirSourcesUnder(folder)) else: "[]"
  mainWindow.webContents.send "CODETRACER::ns9-panes-constraints", js{
    # `nargo info`'s own JSON, parsed by the renderer with the parser every
    # host uses; empty with the reason when there is no report.
    info: cstring(measured.infoJson),
    # The printed opcodes and the compiled program that places them, joined
    # by the renderer with the same procs the native hosts use
    # (`constraints_listing`).
    listing: cstring(measured.listing),
    artefact: (if measured.hasReport:
                 nodeReadText(cstring(artefactPathUnder(folder,
                                                        measured.report.package)))
               else: cstring""),
    provenance: cstring(NargoInfoProvenance),
    absence: cstring(measured.absence),
    sources: cstring(sources),
    tab: tab
  }
  debugPrint "ns9-panes: answered for ", folder

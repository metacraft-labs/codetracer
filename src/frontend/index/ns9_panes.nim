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

proc nodeFileExists(path: string): bool {.importjs:
  "(function (p) { try { return require('fs').existsSync(p); } " &
  "catch (e) { return false; } })(#)".}
  ## `std/os`'s `fileExists` is a C-backend proc; the index is a node program
  ## and asks node.

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
  var collected: seq[NoirSourceFile] = @[]
  {.emit: """
  try {
    const fs = require('fs');
    const path = require('path');
    const root = `projectRoot`;
    const srcDir = path.join(root, 'src');
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
        `collected`.push({ path: rel, content: content });
      }
    };
    walk(srcDir);
  } catch (e) {}
  """.}
  collected

proc nargoInfoJson(projectRoot: string): tuple[info, absence: string] =
  ## `nargo info --json` for one project root.
  ##
  ## Every failure is a sentence. The one thing this must never do is return
  ## an empty string with an empty reason, because the pane renders that as
  ## "no circuit" — a claim about the project rather than about the attempt.
  if projectRoot.len == 0:
    return ("", "No project folder is open.")
  if not nodeFileExists(projectRoot & "/" & NoirProjectMarker):
    return ("", "This project has no " & NoirProjectMarker &
                ", so it is not a Noir crate and has no circuit to measure. " &
                "Constraint counts are produced per language; Noir is the " &
                "first producer CodeTracer has.")
  var output = cstring""
  var failed = false
  var message = ""
  {.emit: """
  try {
    const cp = require('child_process');
    const res = cp.spawnSync('nargo', ['info', '--json'], {
      cwd: `projectRoot`, encoding: 'utf8', timeout: 60000,
      maxBuffer: 8 * 1024 * 1024 });
    if (res.error) { `failed` = true; `message` = String(res.error.message); }
    else if (res.status !== 0) {
      `failed` = true;
      `message` = (res.stderr || '').toString().trim().slice(0, 400) ||
        ('nargo info exited with status ' + res.status);
    } else { `output` = (res.stdout || '').toString(); }
  } catch (e) {
    `failed` = true;
    `message` = String((e && e.message) || e);
  }
  """.}
  if failed:
    if message.contains("ENOENT"):
      return ("", "`nargo` is not on this machine's PATH, so the circuit " &
                  "cannot be measured. Install the Noir toolchain to see " &
                  "constraint counts.")
    return ("", "nargo info could not measure this project: " & message)
  ($output, "")

proc onNs9Panes*(sender: js, response: jsobject(folder=cstring)) =
  ## Answer both halves. Sent unconditionally rather than lazily: the panes are
  ## visible in edit mode, so an answer neither of them can use is still an
  ## answer they must show instead of staying blank.
  let folder = $response.folder

  var catalogJson = ""
  var catalogAbsence = ""
  if folder.len == 0:
    catalogAbsence = "No project folder is open."
  elif not nodeFileExists(folder & "/" & NoirProjectMarker):
    catalogAbsence =
      "This project has no " & NoirProjectMarker & ", so CodeTracer has no " &
      "test provider for it yet. Noir is the first language wired into this " &
      "pane; the `ct test` framework already has providers for many more."
  else:
    try:
      let catalogNode = noirCatalogFromSources(noirSourcesUnder(folder)).toJson()
      catalogJson = pretty(catalogNode)
    except CatchableError:
      catalogAbsence = "Test discovery failed for this project: " &
        getCurrentExceptionMsg()

  mainWindow.webContents.send "CODETRACER::ns9-panes-catalog", js{
    catalog: cstring(catalogJson),
    absence: cstring(catalogAbsence)
  }

  let (info, absence) = nargoInfoJson(folder)
  mainWindow.webContents.send "CODETRACER::ns9-panes-constraints", js{
    info: cstring(info),
    provenance: cstring("nargo info --json, run just now"),
    absence: cstring(absence)
  }
  debugPrint "ns9-panes: answered for ", folder

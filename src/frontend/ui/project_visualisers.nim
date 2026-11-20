## ui/project_visualisers.nim — the desktop reads the recording's checkout's
## per-type visualisers when a trace opens, and installs them on the one door
## every desktop value surface renders through (`presented_value`).
##
## PLAT-12 built `setActiveVisualisers` and left it uncalled: the desktop
## rendered every value with the built-in table whatever the checkout
## declared. This is its caller.
##
## ## WHAT IS READ, AND HOW IT IS CONTAINED
##
## The DECLARATIVE files only (`visualisers.toml`), at the checkout root
## (`trace.workdir`), through the same pure loader the native front-ends use
## (`project_definitions.loadProjectDefinitions`, then
## `value_visualisers.visualisersFor`). An executable definition is never read
## here — the renderer holds no trust ledger, and §2.3's grant is the native
## host's decision, made where the ledger lives.
##
## The read is contained the way `ct/launch/project_definitions_dir` contains
## it, in node's words: the checkout and the candidate are both resolved
## (`fs.realpathSync`), and the file is read only when its resolved path is
## exactly `<resolved checkout>/.codetracer/visualisers.toml` — a symlink
## anywhere in between makes the two differ and the file is not read. The
## size is taken from a `stat` before the read, against the loader's own
## `MaxDefinitionBytes`.

import std/jsffi

import ../../common/project_definitions
import ../../common/value_presentation
import ../../common/value_visualisers
import ./presented_value

type
  ContainedRead* = object
    present*: bool
    text*: string
    refusal*: string
      ## Why the file was not read although it exists.

proc nodeReadContained(root, rel: cstring; maxBytes: int): JsObject {.importjs:
  """(function(root, rel, maxBytes) {
  if (typeof require !== 'function') return {present: false, text: '', refusal: ''};
  const fs = require('fs'), path = require('path');
  let realRoot;
  try { realRoot = fs.realpathSync(root); }
  catch (e) { return {present: false, text: '', refusal: ''}; }
  const expected = path.join(realRoot, rel);
  if (!fs.existsSync(path.join(root, rel))) return {present: false, text: '', refusal: ''};
  let real;
  try { real = fs.realpathSync(path.join(root, rel)); }
  catch (e) { return {present: true, text: '', refusal: 'it does not resolve'}; }
  if (real !== expected)
    return {present: true, text: '', refusal: 'it resolves to ' + real + ', outside the checkout'};
  const st = fs.lstatSync(real);
  if (!st.isFile()) return {present: true, text: '', refusal: 'it is not a file'};
  if (st.size > maxBytes)
    return {present: true, text: '', refusal: st.size + ' bytes; the bound is ' + maxBytes};
  try { return {present: true, text: fs.readFileSync(real, 'utf8'), refusal: ''}; }
  catch (e) { return {present: true, text: '', refusal: String(e && e.message)}; }
})(#, #, #)""".}

proc readContained*(root, rel: string): ContainedRead =
  ## `<root>/<rel>`, read only when it is exactly where it says it is.
  let r = nodeReadContained(cstring(root), cstring(rel), MaxDefinitionBytes)
  ContainedRead(present: r["present"].to(bool),
                text: $r["text"].to(cstring),
                refusal: $r["refusal"].to(cstring))

proc visualisersFromText*(text: string): tuple[visualisers: seq[Visualiser],
                                                problems: seq[string]] =
  ## A checkout's `visualisers.toml`, as the desktop's tier: the loader the
  ## native hosts use, over the text the renderer read.
  let loaded = loadProjectDefinitions([DefinitionFile(kind: dfkVisualisers,
    origin: doProject, scope: "",
    path: ProjectDefinitionDir & "/" & definitionFileName(dfkVisualisers),
    text: text)])
  result.visualisers = visualisersFor(loaded)
  for p in loaded.problems: result.problems.add render(p)

proc installProjectVisualisers*(workdir: string): seq[string] =
  ## Read `workdir`'s declared visualisers and install them on the desktop's
  ## value door. ALWAYS installs — `@[]` for a checkout that declares none, a
  ## refusal, or no checkout at all — so a session never renders with the
  ## previous session's rules. Answers what a log should say ("" lines none).
  if workdir.len == 0:
    setActiveVisualisers(@[])
    return
  let rel = ProjectDefinitionDir & "/" & definitionFileName(dfkVisualisers)
  let read = readContained(workdir, rel)
  if not read.present:
    setActiveVisualisers(@[])
    return
  if read.refusal.len > 0:
    setActiveVisualisers(@[])
    return @[rel & " was not read: " & read.refusal]
  let (visualisers, problems) = visualisersFromText(read.text)
  setActiveVisualisers(visualisers)
  result = problems

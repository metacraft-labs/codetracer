## value_provenance_dom_test.nim — the desktop's "which visualiser rendered
## this?" affordance, DRIVEN rather than compile-checked.
##
## PLAT-12's bound 6: `ui/value.nim` puts a value's provenance on its value
## span's `title`, and until this suite nothing opened a DOM and read the
## attribute. Here the desktop's own pieces run end to end over a real
## checkout on disk:
##
##   * `ui/project_visualisers.installProjectVisualisers` reads a real
##     `.codetracer/visualisers.toml` from a real temporary directory through
##     node's `fs`, the way `ui_js.onTraceLoaded` calls it with the trace's
##     `workdir`;
##   * `ui/value.ValueComponent.renderValueDom` renders a recorded value into
##     jsdom's DOM through the door `presented_value` holds;
##   * the suite reads the value span's text and `title` back out of the DOM.
##
## NO MOCKS of anything under test. `legacy_loop_dom_bootstrap` supplies the
## two module-initialisation globals the renderer's import graph touches
## (Monaco's model constructor and `AnsiUp`), which this suite never uses.
##
## Lane: `renderer-dom` — the browser target, run by `jsdom-run.mjs` over a
## real DOM. Without `-d:nodejs` `std/unittest` cannot set the exit status, so
## this suite sets it.

import std/[jsffi, dom, strutils]
import ./legacy_loop_dom_bootstrap

import ../types
import ../js_assoc
import ../ui/[value, presented_value, project_visualisers]

var checks = 0
var failedChecks = 0

template ck(cond: untyped) =
  inc checks
  if not cond:
    inc failedChecks
    echo "[FAILED] ", astToStr(cond)

proc tempCheckout(name: cstring): cstring {.importjs: """(function(n) {
  const fs = require('fs'), os = require('os'), path = require('path');
  return fs.mkdtempSync(path.join(os.tmpdir(), 'ct-provenance-' + n + '-'));
})(#)""".}
proc writeAt(root, rel, text: cstring) {.importjs: """(function(r, rel, t) {
  const fs = require('fs'), path = require('path');
  fs.mkdirSync(path.dirname(path.join(r, rel)), {recursive: true});
  fs.writeFileSync(path.join(r, rel), t);
})(#, #, #)""".}
proc symlinkAt(target, root, rel: cstring) {.importjs: """(function(t, r, rel) {
  const fs = require('fs'), path = require('path');
  fs.mkdirSync(path.dirname(path.join(r, rel)), {recursive: true});
  fs.symlinkSync(t, path.join(r, rel));
})(#, #, #)""".}
proc removeTree(root: cstring) {.importjs:
  "require('fs').rmSync(#, {recursive: true, force: true})".}

const Declared = """
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Meters"
summary = "a distance"
"""

proc meters(): Value =
  Value(kind: Int, i: "42", typ: Type(kind: Int, langType: "Meters"))

proc rendered(v: Value): tuple[text, title: string] =
  ## Render `v` the way the State pane does, into jsdom, and read the value
  ## span back.
  let component = ValueComponent(
    expanded: JsAssoc[cstring, bool]{},
    charts: JsAssoc[cstring, ChartComponent]{},
    showInline: JsAssoc[cstring, bool]{},
    baseExpression: cstring"d",
    baseValue: v,
    nameWidth: 40,
    valueWidth: 80,
    stateID: -1)
  let node = component.renderValueDom()
  document.body.innerHTML = cstring""
  document.body.appendChild(node)
  let span = document.querySelector(cstring".value-expanded-text")
  if span.isNil:
    return ("", "")
  let title = span.getAttribute(cstring"title")
  ($span.textContent, if title.isNil: "" else: $title)

block declared:
  # A checkout declaring a visualiser for `Meters`: the desktop reads it and
  # the value span says so — in its text AND in its title.
  let root = tempCheckout("declared")
  writeAt(root, ".codetracer/visualisers.toml", Declared)
  let notes = installProjectVisualisers($root)
  ck notes.len == 0
  ck activeVisualiserCount() == 1
  let (text, title) = rendered(meters())
  echo "declared: text='", text, "' title='", title, "'"
  ck text == "a distance"
  ck title.contains("project:.codetracer/visualisers.toml#0")
  removeTree(root)

block negativeControl:
  # THE CONTROL: the same value from a checkout that declares nothing renders
  # with the built-ins, and the title says THAT. A title that named the
  # project rule whatever was loaded would pass the case above.
  let root = tempCheckout("none")
  let notes = installProjectVisualisers($root)
  ck notes.len == 0
  ck activeVisualiserCount() == 0
  let (text, title) = rendered(meters())
  echo "none: text='", text, "' title='", title, "'"
  ck text == "42"
  ck title.contains("builtin")
  ck not title.contains("project:")
  removeTree(root)

block symlinkRefused:
  # A definition that is a symlink to a file outside the checkout is NOT read:
  # the desktop installs no rule and says why.
  let outside = tempCheckout("outside")
  writeAt(outside, "elsewhere.toml", Declared)
  let root = tempCheckout("symlink")
  symlinkAt(cstring($outside & "/elsewhere.toml"), root,
            ".codetracer/visualisers.toml")
  let notes = installProjectVisualisers($root)
  ck notes.len == 1
  ck notes.len == 1 and notes[0].contains("was not read")
  ck activeVisualiserCount() == 0
  let (text, _) = rendered(meters())
  ck text == "42"
  removeTree(root)
  removeTree(outside)

block sessionSwitch:
  # A second recording from a checkout with no definitions must not keep the
  # first one's rules: `installProjectVisualisers` always installs.
  let first = tempCheckout("first")
  writeAt(first, ".codetracer/visualisers.toml", Declared)
  discard installProjectVisualisers($first)
  ck activeVisualiserCount() == 1
  discard installProjectVisualisers("")
  ck activeVisualiserCount() == 0
  removeTree(first)

echo "CHECKS: ", checks
# The lane runner (ci/lib/run-nim-test-lane.sh) counts `[OK]` and `[FAILED]`
# lines; a suite that prints neither on success reads as one that ran nothing.
if failedChecks > 0:
  {.emit: "process.exitCode = 1;".}
else:
  echo "[OK] value_provenance_dom_test: all ", checks, " checks"

## review_deleted_line_tokens_dom_test.nim
##
## The deleted-line token repaint of the review's diff editor
## (`ui/review_diff_editor.scheduleReviewDeletedLineTokens`) asks its owner
## for the editor and the original model on EVERY attempt. Its attempts run
## for up to 3 s, and in that window the diff tab may dispose its editor
## (`resetEditor`) and create another (`initEditor`). A repaint that kept the
## first editor and model would force tokenization of a disposed model, and
## Monaco answers that with "Model is disposed!" from `getLineCount`, inside
## a timer where nothing catches it.
##
## Lane: `renderer-dom` (`nim js -d:ctRenderer`, run by `jsdom-run.mjs`).
## Without `-d:nodejs` `std/unittest` cannot set the exit status, and the
## cases are asynchronous (the repaint retries every 150 ms), so this suite
## reports `[OK]` / `[FAILED]` itself and sets `process.exitCode`.
##
## Why fakes: the diff editor and its models are stand-ins, not Monaco.
## Monaco does not load under node (it needs a browser's layout and its AMD
## loader), and what is under test is the retry chain's choice of WHICH
## editor and model it touches, not Monaco's tokenizer. The fakes model the
## three Monaco behaviours the chain depends on, each as Monaco documents it
## (https://microsoft.github.io/monaco-editor/typedoc/interfaces/editor.ITextModel.html):
## a disposed model reports `isDisposed()` and throws "Model is disposed!"
## from `getLineCount`; `tokenization.forceTokenization` tokenizes; and the
## diff editor rebuilds its deleted-line zones when `ignoreTrimWhitespace`
## changes, which the fake shows by colouring the zone. The deleted-line
## zone itself is real DOM (jsdom), read by the real
## `udDeletedLineTokenClasses`.
##
## Two layers are driven. The helper, through an owner that answers its two
## fields; and the diff tab's OWN call site,
## `unified_diff.scheduleDeletedLineTokens`, through a real
## `UnifiedDiffComponent` whose `diffEditor` / `originalModel` fields
## the case swaps as `resetEditor` + `initEditor` do. The helper's cases
## cannot see a call site that reads the fields ONCE and hands the helper a
## getter over that captured pair: the helper would still ask on every
## attempt, and be answered the first editor every time. The component cases
## fail on exactly that call site.
##
## `legacy_loop_dom_bootstrap` comes first because `ui/unified_diff`
## pulls in the legacy UI tree, whose import-time Monaco models it stands in
## for (it says why); nothing here reaches those models.

import ./legacy_loop_dom_bootstrap
import std/jsffi

import ../types
import ../ui/review_diff_editor
import ../ui/unified_diff

proc makeFakeModel(name: cstring): js {.importjs: """
  (function(name) {
    var m = {
      name: name, disposed: false, linesAskedAfterDispose: 0, forced: 0,
      isDisposed: function() { return this.disposed; },
      dispose: function() { this.disposed = true; },
      getLineCount: function() {
        if (this.disposed) {
          this.linesAskedAfterDispose += 1;
          throw new Error('Model is disposed!');
        }
        return 3;
      }
    };
    m.tokenization = { forceTokenization: function() { m.forced += 1; } };
    return m;
  })(#)""".}

proc makeFakeDiffEditor(hostId: cstring): js {.importjs: """
  (function(hostId) {
    return {
      rebuilds: 0,
      updateOptions: function(o) {
        if (o && o.ignoreTrimWhitespace === false) {
          // The rebuilt zone is coloured: two token classes.
          this.rebuilds += 1;
          var host = document.getElementById(hostId);
          var zone = host && host.querySelector('.view-lines.line-delete');
          if (zone) { zone.innerHTML = '<span class="mtk1">let</span><span class="mtk23">y</span>'; }
        }
      }
    };
  })(#)""".}

proc makeHost(hostId: cstring) {.importjs: """
  (function(hostId) {
    var old = document.getElementById(hostId);
    if (old) { old.remove(); }
    var host = document.createElement('div');
    host.id = hostId;
    document.body.appendChild(host);
  })(#)""".}

proc addMonochromeDeletedZone(hostId: cstring) {.importjs: """
  (function(hostId) {
    var zone = document.createElement('div');
    zone.className = 'view-lines line-delete';
    zone.innerHTML = '<span class="mtk1">  let y = x * 2;</span>';
    document.getElementById(hostId).appendChild(zone);
  })(#)""".}

proc jsSetTimeout(callback: proc(); ms: int) {.importjs: "setTimeout(#, #)".}
proc after(ms: int; callback: proc()) = jsSetTimeout(callback, ms)
proc intField(o: js; name: cstring): int {.importjs: "(#[#] | 0)".}
proc lastUncaught(): cstring {.importjs: "(globalThis.rdltUncaught || '')".}
proc clearUncaught() {.importjs: "(globalThis.rdltUncaught = '')".}

# A throw inside the repaint's timer is what the defect looks like, and node
# would otherwise end the run on it before any case could report. Any
# uncaught error fails the run, whichever case it came from.
{.emit: """
process.on('uncaughtException', function(e) {
  globalThis.rdltUncaught = String(e && e.message || e);
  console.log("  [FAILED] uncaught: " + globalThis.rdltUncaught);
  process.exitCode = 1;
});
""".}

var failed = 0
var cases: seq[proc(done: proc())]

proc check(name: string; ok: bool; detail = "") =
  if ok:
    echo "  [OK] ", name
  else:
    inc failed
    echo "  [FAILED] ", name, (if detail.len > 0: ": " & detail else: "")

type Owner = ref object
  ## The diff tab's two fields, as `UnifiedDiffComponent` holds them.
  diffEditor, originalModel: js

proc refsOf(owner: Owner): proc(): ReviewDiffEditorRefs =
  result = proc(): ReviewDiffEditorRefs = (owner.diffEditor, owner.originalModel)

cases.add proc(done: proc()) =
  # resetEditor + initEditor between the first attempt and the second.
  const host = cstring"rdlt-reinit"
  makeHost(host)
  clearUncaught()
  let first = makeFakeModel("first")
  let owner = Owner(diffEditor: makeFakeDiffEditor(host), originalModel: first)
  scheduleReviewDeletedLineTokens(owner.refsOf, host, 0)
  after(20, proc() =
    # resetEditor: dispose, then clear.
    udDisposeModel(first)
    owner.diffEditor = nil
    owner.originalModel = nil
    # initEditor: a new editor and model, whose diff renders a deleted line.
    let second = makeFakeModel("second")
    let editor = makeFakeDiffEditor(host)
    owner.diffEditor = editor
    owner.originalModel = second
    addMonochromeDeletedZone(host)
    after(700, proc() =
      check "a re-initialised editor: the disposed model is never asked for its lines",
        first.intField("linesAskedAfterDispose") == 0,
        "asked " & $first.intField("linesAskedAfterDispose") & " time(s)"
      check "a re-initialised editor: nothing throws in the retry timer",
        lastUncaught().len == 0, $lastUncaught()
      check "a re-initialised editor: the retry repaints the NEW editor's zone",
        second.intField("forced") >= 1 and editor.intField("rebuilds") >= 1,
        "forced " & $second.intField("forced") & ", rebuilds " &
          $editor.intField("rebuilds")
      done()))

cases.add proc(done: proc()) =
  # resetEditor alone: the owner holds nothing, so the chain ends.
  const host = cstring"rdlt-reset"
  makeHost(host)
  clearUncaught()
  let model = makeFakeModel("only")
  let owner = Owner(diffEditor: makeFakeDiffEditor(host), originalModel: model)
  scheduleReviewDeletedLineTokens(owner.refsOf, host, 0)
  after(20, proc() =
    udDisposeModel(model)
    owner.diffEditor = nil
    owner.originalModel = nil
    addMonochromeDeletedZone(host)
    after(500, proc() =
      check "a reset editor: the chain ends without touching the disposed model",
        model.intField("linesAskedAfterDispose") == 0 and lastUncaught().len == 0,
        "asked " & $model.intField("linesAskedAfterDispose") & ", uncaught: " &
          $lastUncaught()
      done()))

cases.add proc(done: proc()) =
  # An owner that disposed the model but still holds it.
  const host = cstring"rdlt-held"
  makeHost(host)
  clearUncaught()
  let model = makeFakeModel("held")
  let owner = Owner(diffEditor: makeFakeDiffEditor(host), originalModel: model)
  scheduleReviewDeletedLineTokens(owner.refsOf, host, 0)
  after(20, proc() =
    udDisposeModel(model)
    addMonochromeDeletedZone(host)
    after(500, proc() =
      check "a disposed model still held: the chain ends without asking it",
        model.intField("linesAskedAfterDispose") == 0 and lastUncaught().len == 0,
        "asked " & $model.intField("linesAskedAfterDispose") & ", uncaught: " &
          $lastUncaught()
      done()))

cases.add proc(done: proc()) =
  # Positive control: the repaint does run on a live editor whose deleted
  # line is monochrome, and stops once it is coloured.
  const host = cstring"rdlt-live"
  makeHost(host)
  clearUncaught()
  addMonochromeDeletedZone(host)
  let model = makeFakeModel("live")
  let editor = makeFakeDiffEditor(host)
  let owner = Owner(diffEditor: editor, originalModel: model)
  scheduleReviewDeletedLineTokens(owner.refsOf, host, 0)
  after(500, proc() =
    check "a live editor: its monochrome deleted line is repainted once",
      model.intField("forced") == 1 and editor.intField("rebuilds") == 1,
      "forced " & $model.intField("forced") & ", rebuilds " &
        $editor.intField("rebuilds")
    done())

# The diff tab's own call site, `UnifiedDiffComponent.scheduleDeletedLineTokens`.
# Its host is the tab's editor host (`editorHostId`), as `initEditor`
# mounts it.

cases.add proc(done: proc()) =
  # The tab is re-initialised between the first attempt and the second: its
  # fields now hold a second editor and model, and only a call site that
  # reads them on each attempt repaints the second editor's deleted line.
  let tab = UnifiedDiffComponent(id: 9101)
  let host = cstring(editorHostId(tab.id))
  makeHost(host)
  clearUncaught()
  let first = makeFakeModel("tab-first")
  tab.diffEditor = makeFakeDiffEditor(host)
  tab.originalModel = first
  tab.scheduleDeletedLineTokens(attempt = 0)
  after(20, proc() =
    udDisposeModel(first)
    tab.diffEditor = nil
    tab.originalModel = nil
    let second = makeFakeModel("tab-second")
    let editor = makeFakeDiffEditor(host)
    tab.diffEditor = editor
    tab.originalModel = second
    addMonochromeDeletedZone(host)
    after(700, proc() =
      check "the diff tab's call site: a re-initialised tab's NEW editor is repainted",
        second.intField("forced") >= 1 and editor.intField("rebuilds") >= 1,
        "forced " & $second.intField("forced") & ", rebuilds " &
          $editor.intField("rebuilds")
      check "the diff tab's call site: the disposed model is never asked for its lines",
        first.intField("linesAskedAfterDispose") == 0 and lastUncaught().len == 0,
        "asked " & $first.intField("linesAskedAfterDispose") & ", uncaught: " &
          $lastUncaught()
      done()))

cases.add proc(done: proc()) =
  # A tab that is reset and never re-initialised: the chain ends.
  let tab = UnifiedDiffComponent(id: 9102)
  let host = cstring(editorHostId(tab.id))
  makeHost(host)
  clearUncaught()
  let model = makeFakeModel("tab-only")
  tab.diffEditor = makeFakeDiffEditor(host)
  tab.originalModel = model
  tab.scheduleDeletedLineTokens(attempt = 0)
  after(20, proc() =
    udDisposeModel(model)
    tab.diffEditor = nil
    tab.originalModel = nil
    addMonochromeDeletedZone(host)
    after(500, proc() =
      check "the diff tab's call site: a reset tab ends the chain untouched",
        model.intField("linesAskedAfterDispose") == 0 and lastUncaught().len == 0,
        "asked " & $model.intField("linesAskedAfterDispose") & ", uncaught: " &
          $lastUncaught()
      done()))

proc runFrom(i: int) =
  if i >= cases.len:
    echo (if failed == 0: "review deleted-line tokens: all cases passed"
          else: "review deleted-line tokens: " & $failed & " FAILED")
    if failed > 0:
      {.emit: "process.exitCode = 1;".}
    return
  cases[i](proc() = runFrom(i + 1))

echo "[Suite] the deleted-line repaint follows the diff tab's current editor"
runFrom(0)

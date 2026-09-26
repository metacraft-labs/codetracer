## frontend/view_vocabulary/cross_medium_script.nim — ONE view, and ONE set
## of scripted keyboard cases with their expected states, shared by every
## medium PLAT-3's cross-medium claim is measured on.
##
## ## WHY THE SCRIPT IS DATA
##
## "One view written once in the vocabulary renders and behaves equivalently
## on the terminal and the web" is measured in two processes that cannot be
## one: the terminal arm is C (isonim-tui links a pty, tree-sitter and a
## compositor), and the browser arm is JavaScript running inside Chromium.
## The two arms therefore cannot compare their states with each other
## directly. What they CAN do is run the same keys over the same view and meet
## the same expected values — so the keys and the values live here, once, and
## each arm replays them:
##
##   `src/frontend/tui/tests/test_view_vocabulary_cross_medium.nim`
##       the terminal (isonim-tui's widgets, read out of the widgets) AND
##       isonim's in-memory DOM, compared with each other after every step
##       and each against every expectation;
##   `src/frontend/tests/view_vocabulary_chromium_test.nim`
##       a real document in headless Chromium, keys delivered by Chromium's
##       own input pipeline, compared after every step with the in-memory
##       DOM running in the same page and against every expectation.
##
## The terminal and Chromium never meet, and they do not need to: each is
## held to the same expected value at every checkpoint, and each is compared
## in full, after every key, with the same third party.
##
## ## THE MODAL COMES FIRST, BECAUSE A BROWSER MAKES IT
##
## The view's `Modal` starts open, and in a document an open Modal is shown
## with `showModal()`, which makes everything outside it INERT — no other
## element can take focus, so no key reaches it. That is the entry's
## exclusivity, supplied by the medium, and the browser suite asserts it on
## its own. It also means every scripted case that drives some OTHER entry
## has to dismiss the Modal first, exactly as a reader would; `script`
## prepends that step (`withModalDismissed`), and the terminal arm runs the
## same step so the cases stay one set.
##
## Medium-free: nothing here imports a renderer.

import ../../common/view_vocabulary

type
  StepKind* = enum
    skKey       ## deliver a key to an entry
    skKeyHere   ## deliver a key to whatever holds focus — no re-focusing
    skExpect    ## the state must now read `fact = value`

  ScriptStep* = object
    case kind*: StepKind
    of skKey, skKeyHere:
      id*: string          ## the entry the key is aimed at (skKeyHere: the
                           ## one that should STILL hold focus)
      key*: Key
      ch*: string          ## `kChar` only
    of skExpect:
      fact*: string        ## `<id>.<field>`
      value*: string

  ScriptCase* = object
    name*: string
    steps*: seq[ScriptStep]

func key*(id: string; k: Key; ch = ""): ScriptStep =
  ScriptStep(kind: skKey, id: id, key: k, ch: ch)

func keyHere*(id: string; k: Key): ScriptStep =
  ## A key delivered WITHOUT focusing `id` first — to whatever holds focus
  ## after the previous key. The browser arm uses it to measure that a
  ## re-render keeps focus where the reader left it; every other arm, which
  ## has no focus to lose, delivers it to `id`.
  ScriptStep(kind: skKeyHere, id: id, key: k)

func expect*(fact, value: string): ScriptStep =
  ScriptStep(kind: skExpect, fact: fact, value: value)

const MarkdownSource* =
  "# Title\n\nSome **bold** text and `code`.\n\n- one\n- two\n\n" &
  "> quoted\n\n```nim\necho 1\n```\n\n---\n\n1. first\n2. [link](https://x.y)"
  ## Every construct the two Markdown parsers share, so their outlines are
  ## compared on something more than a heading and a sentence.

proc opt(id, label: string; disabled = false): ViewOption =
  ViewOption(id: id, label: label, disabled: disabled)

proc settingsPanel*(): ViewNode =
  ## The view. Written ONCE, in the vocabulary, and rendered on every medium.
  ##
  ## It carries all sixteen entries because "one view renders equivalently" is
  ## a stronger claim the more of the vocabulary the view uses, and because an
  ## entry left out of it would be an entry whose mapping table row nothing
  ## checks.
  viewCollapsible("panel", "Debug settings", @[
    viewText("title", "Settings"),
    viewButton("apply", "Apply"),
    viewCheckbox("wrap", "Wrap long values"),
    viewToggle("live", "Live update"),
    viewInput("filter", "abc"),
    viewSelect("lang", @[opt("rs", "Rust"), opt("py", "Python"),
                         opt("go", "Go")], selected = 0),
    # `beta` IS DISABLED, and that is not decoration. A list with no
    # unavailable member cannot show whether the media agree about SKIPPING
    # one, and the mutation that removes the skip from
    # `behaviour.nextEnabled` left the cross-medium suite fully green until
    # this option was marked — measured, in PLAT-3's falsification pass.
    viewList("recent", @[opt("a", "alpha"), opt("b", "beta", disabled = true),
                         opt("c", "gamma")]),
    viewTreeNode("state", "locals", @[
      viewTreeNode("state.x", "x"),
      viewTreeNode("state.p", "p", @[viewTreeNode("state.p.y", "y")])],
      expanded = true),
    viewTable("tbl", @["name", "value"],
              @[@["a", "1"], @["b", "2"], @["c", "3"]]),
    viewTabs("panes", @[opt("t1", "Source"), opt("t2", "State")]),
    viewMenu("ctx", @[opt("m1", "Copy"), opt("m2", "Paste")]),
    viewProgress("load", 40),
    viewImage("shot", "image/png", "screenshot of the state panel", 2048),
    viewMarkdown("doc", MarkdownSource),
    viewModal("dlg", "Confirm", @[viewText("dlgtext", "Are you sure?")])],
    expanded = true)

func withModalDismissed(steps: seq[ScriptStep]): seq[ScriptStep] =
  @[key("dlg", kEscape), expect("dlg.open", "false")] & steps

func scriptedCases*(): seq[ScriptCase] =
  ## The cases, each from a FRESH `settingsPanel()`. Their expected values are
  ## the vocabulary's contract, stated per step; every arm must meet all of
  ## them.
  @[
    ScriptCase(name: "Modal: Escape dismisses, and its body leaves the view",
      steps: @[
        expect("dlg.open", "true"), expect("dlgtext.text", "Are you sure?"),
        key("dlg", kEscape),
        expect("dlg.open", "false"), expect("dlgtext.text", "<absent>")]),
    ScriptCase(name: "Checkbox and Toggle", steps: withModalDismissed(@[
      expect("wrap.checked", "false"),
      key("wrap", kSpace), expect("wrap.checked", "true"),
      key("wrap", kEnter), expect("wrap.checked", "false"),
      key("live", kSpace), expect("live.checked", "true"),
      # A key OUTSIDE the contract changes nothing.
      key("wrap", kDown), expect("wrap.checked", "false")])),
    ScriptCase(name: "List: motion skips the unavailable member",
      steps: withModalDismissed(@[
      expect("recent.highlight", "0"),
      key("recent", kDown), expect("recent.highlight", "2"),
      key("recent", kUp), expect("recent.highlight", "0"),
      key("recent", kEnd), expect("recent.highlight", "2"),
      key("recent", kDown), expect("recent.highlight", "2"),   # no wrap
      key("recent", kHome), expect("recent.highlight", "0"),
      # Twice more WITHOUT re-focusing: the re-render must leave focus on
      # the list, or the second key would reach nothing.
      keyHere("recent", kEnd), expect("recent.highlight", "2"),
      keyHere("recent", kUp), expect("recent.highlight", "0")])),
    ScriptCase(name: "Tabs: Left and Right, stopping at both ends",
      steps: withModalDismissed(@[
      expect("panes.selected", "0"),
      key("panes", kDown), expect("panes.selected", "0"),
      # Space is not the Tabs' key. In a document it BUBBLES — through the
      # Collapsible the tab strip sits in, whose key it IS — and must not
      # collapse it: a listener acts only on keys aimed at its own element.
      key("panes", kSpace), expect("panes.selected", "0"),
      expect("panel.expanded", "true"),
      key("panes", kLeft), expect("panes.selected", "0"),      # first: stays
      key("panes", kRight), expect("panes.selected", "1"),
      key("panes", kRight), expect("panes.selected", "1"),     # last: stays
      key("panes", kHome), expect("panes.selected", "0"),
      key("panes", kEnd), expect("panes.selected", "1")])),
    ScriptCase(name: "Table: two dimensions, bounded in both",
      steps: withModalDismissed(@[
      expect("tbl.row", "0"), expect("tbl.column", "0"),
      key("tbl", kDown), expect("tbl.row", "1"),
      key("tbl", kRight), expect("tbl.column", "1"),
      key("tbl", kRight), expect("tbl.column", "1"),
      key("tbl", kEnd), expect("tbl.row", "2")])),
    ScriptCase(name: "Tree: the cursor indexes visible rows",
      steps: withModalDismissed(@[
      expect("state.cursor", "0"), expect("state.p.expanded", "false"),
      key("state", kDown), key("state", kDown),
      expect("state.cursor", "2"),
      key("state", kRight), expect("state.p.expanded", "true"),
      expect("state.p.y.expanded", "false"),
      key("state", kRight), expect("state.cursor", "3"),
      key("state", kLeft), expect("state.cursor", "2"),
      key("state", kLeft), expect("state.p.expanded", "false"),
      expect("state.p.y.expanded", "<absent>")])),
    ScriptCase(name: "Input: typing and deleting", steps: withModalDismissed(@[
      expect("filter.text", "abc"), expect("filter.cursor", "3"),
      key("filter", kLeft), expect("filter.cursor", "2"),
      key("filter", kChar, "Z"), expect("filter.text", "abZc"),
      expect("filter.cursor", "3"),
      key("filter", kBackspace), expect("filter.text", "abc"),
      key("filter", kHome), expect("filter.cursor", "0"),
      key("filter", kDelete), expect("filter.text", "bc"),
      # Up and Down are not the entry's: the caret stays. (A browser's own
      # text input moves the caret to the start and the end on them.)
      key("filter", kDown), expect("filter.cursor", "0"),
      key("filter", kEnd), expect("filter.cursor", "2"),
      key("filter", kUp), expect("filter.cursor", "2")])),
    ScriptCase(name: "Input: a combining mark joins the character before it",
      steps: withModalDismissed(@[
      # THE CARET COUNTS WHAT A READER SEES. `e` + U+0301 is ONE character on
      # both media measured — isonim-tui's InputWidget and Chromium's own
      # `<input>` — and, since 2026-09-26, in the vocabulary as every binding
      # drives it. Before, the vocabulary counted runes and this case could
      # not have been written: the terminal said 4 where the web said 5.
      key("filter", kEnd), expect("filter.cursor", "3"),
      key("filter", kChar, "e"), expect("filter.text", "abce"),
      expect("filter.cursor", "4"),
      key("filter", kChar, "\u0301"), expect("filter.text", "abce\u0301"),
      expect("filter.cursor", "4"),                 # joined, not advanced
      key("filter", kLeft), expect("filter.cursor", "3"),
      key("filter", kRight), expect("filter.cursor", "4"),
      key("filter", kBackspace), expect("filter.text", "abc"),  # all of it
      expect("filter.cursor", "3"),
      key("filter", kChar, "e"), key("filter", kChar, "\u0301"),
      key("filter", kHome), key("filter", kDelete),
      expect("filter.text", "bce\u0301"),
      key("filter", kEnd), expect("filter.cursor", "3"),
      key("filter", kLeft), key("filter", kDelete),
      expect("filter.text", "bc"), expect("filter.cursor", "2")])),
    ScriptCase(name: "Select: Escape does not commit what was passed over",
      steps: withModalDismissed(@[
      expect("lang.selected", "0"), expect("lang.open", "false"),
      # Down and End on the CLOSED select are not the entry's: nothing is
      # chosen. (A browser's own `<select>` commits the next option on Down
      # when closed — the web binding has to stop it, and the browser suite
      # found that it did not.)
      key("lang", kDown), expect("lang.selected", "0"),
      key("lang", kEnd), expect("lang.selected", "0"),
      expect("lang.open", "false"),
      key("lang", kEnter), expect("lang.open", "true"),
      key("lang", kDown), key("lang", kDown),
      expect("lang.highlight", "2"), expect("lang.selected", "0"),
      key("lang", kEscape), expect("lang.open", "false"),
      expect("lang.selected", "0"), expect("lang.highlight", "0"),
      key("lang", kEnter), key("lang", kDown), key("lang", kEnter),
      expect("lang.selected", "1"), expect("lang.open", "false")])),
    ScriptCase(name: "Menu: motion, running a command, and dismissal",
      steps: withModalDismissed(@[
      expect("ctx.open", "true"), expect("ctx.highlight", "0"),
      key("ctx", kDown), expect("ctx.highlight", "1"),
      key("ctx", kDown), expect("ctx.highlight", "1"),         # no wrap
      # ENTER RUNS THE COMMAND AND CLOSES THE MENU. Until 2026-09-26 no case
      # pressed Enter on the menu, and the terminal's hand-built composition
      # would have failed this step: it neither ran nor closed.
      key("ctx", kEnter), expect("ctx.open", "false"),
      # A closed menu answers nothing.
      key("ctx", kUp), expect("ctx.highlight", "1")])),
    ScriptCase(name: "Menu: Escape closes without running",
      steps: withModalDismissed(@[
      key("ctx", kEscape), expect("ctx.open", "false")])),
    ScriptCase(name: "Collapsible: collapsing removes its body",
      steps: withModalDismissed(@[
      expect("panel.expanded", "true"), expect("wrap.checked", "false"),
      key("panel", kSpace), expect("panel.expanded", "false"),
      expect("wrap.checked", "<absent>"),
      key("panel", kEnter), expect("panel.expanded", "true"),
      expect("wrap.checked", "false")])),
    ScriptCase(name: "a long mixed key script", steps: withModalDismissed(@[
      key("wrap", kSpace), key("recent", kDown), key("panes", kRight),
      key("tbl", kDown), key("state", kDown), key("filter", kLeft),
      key("live", kSpace), key("recent", kDown), key("state", kRight),
      key("tbl", kRight), key("lang", kEnter), key("lang", kDown),
      key("ctx", kDown), key("panes", kLeft), key("filter", kHome),
      key("lang", kEscape), key("state", kLeft), key("wrap", kEnter),
      key("recent", kHome), key("ctx", kEnter),
      expect("wrap.checked", "false"), expect("live.checked", "true"),
      expect("recent.highlight", "0"), expect("panes.selected", "0"),
      expect("tbl.row", "1"), expect("tbl.column", "1"),
      expect("state.cursor", "0"), expect("filter.cursor", "0"),
      expect("lang.selected", "0"), expect("lang.open", "false"),
      expect("ctx.open", "false")]))]

func countSteps*(cases: seq[ScriptCase]; kind: StepKind): int =
  for c in cases:
    for s in c.steps:
      if s.kind == kind: inc result

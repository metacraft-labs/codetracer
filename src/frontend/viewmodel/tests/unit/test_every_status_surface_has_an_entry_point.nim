## Every surface the status shell can render has something that OPENS it.
##
## ## The defect this exists for
##
## Two finished features shipped with no way in.
##
## `views/isonim_status_view.nim` renders a **notification history** — the full
## newest-first list, per-entry dismiss buttons, per-entry action buttons, unit
## tested, with a storybook fixture — behind `model.showNotifications`. It also
## renders a **bug report form** — title field, description field, a disclosure
## line about attached logs, a send button rebound to `sendBugReportFromDom` so
## the DOM values are actually read, an IPC channel registered in
## `index/ipc_utils.nim` and a main-process handler in `index/online_sharing.nim`
## — behind `model.showBugReport`.
##
## Measured on `dev` before this suite:
##
##   * `showNotifications` had **no assignment anywhere in the tree**. Not one.
##     It sat at Nim's `bool` default and no code path could raise it.
##   * `showBugReport`'s ONLY assignment was `self.showBugReport = false`
##     (`ui/status.nim:94`), which closes the form after a successful send.
##
## Both were reachable in the pre-open-source history through two status-bar
## buttons, whose CALL SITE was already commented out at the open-sourcing
## commit; `df4d3ef2f` then deleted the two now-uncalled procs. `ClientAction`
## has carried `aNotifications` and `aReportProblem` throughout — live enum
## members, `nil` handlers, one commented-out menu entry between them.
##
## Nothing failed. Every test passed. The features were simply gone.
##
## ## Why the check is shaped this way
##
## THIS IS A CLASS, NOT TWO INSTANCES. The same shape — a complete surface
## behind a flag nothing sets — is this campaign's most-repeated defect, and a
## suite naming only today's two would go green the next time it happens. So the
## flags are DISCOVERED from the view that renders them, and the suite fails on
## a flag it has never heard of.
##
## What counts as an opener is deliberately narrow: an assignment that can make
## the flag TRUE. `= false` is not one, and that distinction is the entire
## finding for the bug report, which had exactly one assignment and it was
## `false`. A flag whose only writer closes it is a flag with no opener.
##
## And an opener alone is not enough — a toggle nothing calls is the same defect
## one layer up. So the two live `ClientAction`s must also be bound to handlers
## and NAMED IN THE MENU TREE, which is what makes them findable: `ui/menu.nim`'s
## `generateNameMap` feeds the command palette from that tree and
## `index/menu.nim` builds the native macOS menu from it, so one entry is three
## routes.
##
## ## What it cannot see
##
## A source scan. It reads text, so it can prove a menu entry and a handler are
## WRITTEN; it cannot prove clicking the entry paints the panel. The end-to-end
## claim belongs to a browser gate (`ci/test/menu-and-context-menu-in-browser.sh`
## drives the real menu), and this suite is the cheap always-on floor under it —
## the one that would have caught the original removal, because the original
## removal was visible in exactly this text.

import std/[os, strutils, unittest]

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 17

const
  StatusViewPath = "src/frontend/viewmodel/views/isonim_status_view.nim"
  StatusPath = "src/frontend/ui/status.nim"
  UiJsPath = "src/frontend/ui_js.nim"

const ExpectedSurfaceFlags = 2
  ## `showNotifications` and `showBugReport`. Pinned so an empty or halved
  ## discovery is a failure rather than a clean sweep — the scan below is the
  ## kind that reports "all 0 flags have openers" if its pattern ever stops
  ## matching.

proc readTree(path: string): string =
  ## Read a source file relative to the repository root.
  ##
  ## The lane runs from the root, and every sibling suite reads its subjects the
  ## same way (`test_every_mountable_pane_has_a_factory_arm.nim` reads
  ## `src/frontend/ui/layout.nim`). A missing file must be a loud failure and not
  ## an empty string that every `contains` below would then agree with.
  doAssert fileExists(path), "cannot read " & path & " — this suite must be " &
    "run from the repository root, and a silently empty subject would make " &
    "every assertion below vacuous"
  readFile(path)

proc surfaceFlags(viewSource: string): seq[string] =
  ## The status shell's surface flags, discovered from the view that renders
  ## them: every `model.show<X>` guarding a render branch.
  ##
  ## Discovered rather than listed, because a list is the thing that goes stale
  ## the day a third surface is added — which is precisely how the first two
  ## became unreachable without anything noticing.
  for line in viewSource.splitLines:
    let stripped = line.strip()
    if not stripped.startsWith("if model.show"):
      continue
    # `if model.showBugReport:` -> `showBugReport`
    let afterDot = stripped["if model.".len .. ^1]
    var name = ""
    for ch in afterDot:
      if ch in {'a'..'z', 'A'..'Z', '0'..'9'}: name.add ch
      else: break
    if name.len > 0 and name notin result:
      result.add name

proc namesLive(source: string; fragment: string): bool =
  ## Does an UNCOMMENTED line carry `fragment`?
  ##
  ## `contains` over the whole file is not this question, and the difference is
  ## the defect itself. `# element "Notifications", aNotifications, false` sat
  ## in `ui_js.nim` for the entire open-source history, and a plain
  ## `uiJs.contains("element \"Notifications\", aNotifications")` is TRUE of
  ## that line — the commented entry contains the live one as a substring. A
  ## check written that way passes over the exact world it was written to
  ## reject.
  ##
  ## Found by mutation: restoring the pre-fix world reddened the opener and the
  ## handler arms and left the menu arm green.
  for line in source.splitLines:
    let stripped = line.strip()
    if stripped.startsWith("#"):
      continue
    if stripped.contains(fragment):
      return true
  false

proc opensIt(sources: openArray[string]; flag: string): bool =
  ## Is there an assignment that can make `flag` TRUE?
  ##
  ## `= not <...>` (a toggle) or `= true`. Explicitly NOT `= false`: the bug
  ## report had exactly one assignment, it was `false`, and treating that as an
  ## opener is how this defect stayed invisible to any check that merely counted
  ## writers.
  for source in sources:
    for line in source.splitLines:
      let stripped = line.strip()
      if stripped.startsWith("#"):
        continue
      let eq = stripped.find(flag & " = ")
      if eq < 0:
        continue
      let rhs = stripped[eq + (flag & " = ").len .. ^1].strip()
      if rhs.startsWith("not ") or rhs.startsWith("true"):
        return true
  false

suite "every status surface has something that opens it":

  let view = readTree(StatusViewPath)
  let status = readTree(StatusPath)
  let uiJs = readTree(UiJsPath)
  let flags = surfaceFlags(view)

  test "the scan finds the surfaces it is supposed to grade":
    # Arm I: prove the instrument before judging the subject. A scan that
    # matched nothing would report every remaining claim as trivially true.
    counted flags.len == ExpectedSurfaceFlags
    counted "showNotifications" in flags
    counted "showBugReport" in flags

  test "every discovered surface flag has an opener":
    for flag in flags:
      counted opensIt([uiJs, status], flag)

  test "CONTROL: `= false` alone does not count as an opener":
    # The negative that gives the test above its meaning. This is the exact
    # pre-fix world for the bug report — one assignment, and it closes the
    # form — and the predicate must call it unopened.
    counted not opensIt(["  self.showBugReport = false"], "showBugReport")
    counted opensIt(["  self.showBugReport = true"], "showBugReport")
    counted opensIt(["  x.showBugReport = not x.showBugReport"], "showBugReport")
    # A commented-out opener is not an opener. The notification menu entry
    # spent the whole of the open-source history commented out.
    counted not opensIt(["  # self.showBugReport = true"], "showBugReport")

  test "the two actions are bound to handlers, by name":
    # By name and not by position: `actions` is a positional
    # `array[ClientAction, ClientActionHandler]` with a long run of `nil`s, and
    # `ui_js.nim` says editing that literal in place is "a silent off-by-one
    # away from binding a different action, and it would still compile".
    counted uiJs.contains("data.actions[ClientAction.aNotifications] =")
    counted uiJs.contains("data.actions[ClientAction.aReportProblem] =")

  test "the two actions are NAMED IN THE MENU, so a user can find them":
    # A handler nothing invokes is the same defect one layer up. The menu tree
    # is what `generateNameMap` turns into command-palette entries and what
    # `index/menu.nim` turns into the native macOS menu, so an entry here is
    # the affordance.
    # `namesLive`, never `contains`: a commented-out entry contains a live one
    # as a substring, and `# element "Notifications", aNotifications, false` is
    # exactly the world this arm exists to reject. See `namesLive`.
    counted namesLive(uiJs, "element \"Notifications\", aNotifications")
    counted namesLive(uiJs, "element \"Report a Problem...\", aReportProblem")

  test "CONTROL: a commented-out menu entry is not a menu entry":
    # The negative that gives the arm above its meaning, and it is the pre-fix
    # world verbatim — this line was in the tree throughout and reached nobody.
    counted not namesLive("  # element \"Notifications\", aNotifications, false",
                          "element \"Notifications\", aNotifications")
    counted namesLive("  element \"Notifications\", aNotifications",
                      "element \"Notifications\", aNotifications")

  test "the bug report is reachable on macOS AND everywhere else":
    # The Help folder is spelled twice on purpose: macOS owns its Help menu, so
    # the entry rides a `macfolder` there and a `macexclude_folder` elsewhere.
    # A single plain `folder "Help"` would give macOS two Help menus; only one
    # of the two spellings would leave a platform with no way in.
    counted uiJs.contains("macfolder \"Help\", \"help\":")
    counted uiJs.contains("macexclude_folder \"Help\":")

suite "status-entry-point suite self-check":

  test "status_entry_point_assertion_count_is_measured":
    check countedAssertions == ExpectedAssertions

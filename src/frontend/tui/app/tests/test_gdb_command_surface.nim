## test_gdb_command_surface.nim — CTUI-10, Tier 1, STRUCTURAL.
##
## ## What this suite is for
##
## CTUI-10: *"table-driven over **every** command and alias in §4.3: each is
## accepted, dispatches the expected action, and the spelled-out form and its
## alias produce identical state. Also asserts an unknown command produces a
## visible error. The published table is the test oracle, so a command
## documented and not implemented fails here rather than in a user's terminal."*
##
## ## THE ORACLE IS THE PUBLISHED DOCUMENT, PARSED
##
## §4.3's fenced block is READ, at run time, out of
## `codetracer-specs/Front-Ends/CodeTracer-TUI.md` and compared field by field
## against `app/commands/interpreter.Spec43Commands`. Nothing about the command
## set is transcribed into this file — that is CTUI-9's rule
## (`test_keymap_no_conflicts.nim` does the same for §4.2) and it is the one the
## campaign has been bitten by most: a hand-written copy of §4.3 here would have
## been written from the same reading that produced the implementation, and the
## two would agree about a misreading.
##
## A MISSING SPEC CHECKOUT IS A FAILURE, NOT A SKIP. The exception below names
## the path and the sibling.
##
## ## THE THREE CONTRACTS, AND WHICH CASE ASSERTS EACH
##
##   * **One dispatch path** — "the command form IS the key form", a value
##     equality of the whole `DispatchResult`; AND "every ViewModel action proc
##     is called from exactly one file", a structural walk over every `.nim`
##     under `app/` with two mutation arms.
##   * **An unknown command reports it** — "nothing this prompt can be handed
##     is silent": `message.len > 0` for all 16 published commands, all 11
##     aliases and 19 kinds of garbage.
##   * **Every command and alias accepted, alias ≡ name** — "every published
##     command is accepted, and its alias is the same invocation".
##
## ## WHY THE ViewModels ARE NIL, AND WHY THAT IS NOT A MOCK
##
## `Dispatcher`'s ViewModel fields are `nil` here. That is not a stand-in for a
## ViewModel: it is the state the type documents ("a field left nil answers
## `drUnavailable`, by name"), and it is the state a TUI is really in before a
## session is attached. What this suite asserts is the SHAPE of the dispatch —
## which action a command becomes, that the two spellings become the same call,
## that every failure is reported — none of which is a claim about a debugger.
##
## The claim about a debugger is `tests/test_value_origin_jump.nim`'s, which
## runs `:goto`, `:next`, `:origin` and `:print` through this very
## `dispatchAction` against a real `replay-server` on `noir_space_ship` and
## asserts the engine moved. Splitting it that way is forced: `app/tests/` is
## walked by `tests/test_tui_facade_boundary.nim` and may not reach
## `headless_session`, which is what opens a trace.
##
## The `CommandServices` closures below are the HOST, not a mock — the same
## category as CTUI-8's `EventPages` seam. In this suite the host is the suite,
## and each closure records what it was asked so the assertion is about what
## the interpreter dispatched rather than about what a fake returned.
##
## ## THE TWO MUTATION ARMS, AND WHAT EACH ONE MEASURED
##
## A comparison that cannot be made to fail is indistinguishable from one that
## is not reading its inputs. Both arms were RUN, on 2026-09-06:
##
##   1. **The oracle.** `(alias: s)` was changed to `(alias: z)` on §4.3's
##      `:step` line in `codetracer-specs/Front-Ends/CodeTracer-TUI.md` — the
##      PUBLISHED DOCUMENT ALONE, with no code touched — and this suite went
##      red in two cases, naming the row and the field: `row 0 (step): alias
##      spec ``z`` impl ``s```, and `byAlias == byName` for `:z`. Restored with
##      `git checkout`; the oracle is read at run time, so no rebuild was
##      involved in either direction.
##   2. **The structural walk.** `proc ctui10MutationArm(vm: DebugControlsVM) =
##      vm.stepForward()` was appended to `app/tui_app.nim` and the walk
##      reported `stepForward: expected only commands/interpreter.nim, found
##      commands/interpreter.nim|tui_app.nim`. That is the second dispatch path
##      CTUI-10's first contract forbids, caught by name.
##
## The in-file `callSitesIn` arms below are the third and cheapest kind: they
## keep the COUNTER honest (a declaration is not a call, a comment is not a
## call, a longer identifier ending in the name is not a call) without needing
## a tree to mutate.
##
## ## Templates, not procs, for anything that calls `check`

import std/[algorithm, os, strutils, unittest]

import ../commands/interpreter
import ../views/command_line

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 493

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

type
  SpecCommand = object
    ## One line of §4.3's fenced block, as the document writes it.
    name: string
    argument: string
    summary: string
    alias: string

const
  SpecSectionHeading = "### 4.3 GDB-Compatible Command Surface"
  SpecRelativePath = "codetracer-specs/Front-Ends/CodeTracer-TUI.md"

  ExpectedSpecCommands = 16
    ## §4.3's command count, counted from the document on 2026-09-06. Asserted
    ## so that a parser which stopped early — or a block that lost a line — is
    ## red here rather than quietly checking less.

  ExpectedAliases = 11
    ## How many of the sixteen §4.3 publishes an `(alias: …)` for. Counted
    ## from the document on 2026-09-06: the five without one are `tracepoint`,
    ## `goto`, `info threads`, `info registers` and `theme`.

  # The ViewModel action procs that MOVE A DEBUGGER, and every file each may be
  # called from — `|`-joined, in the sorted order the walk reports. This is
  # CTUI-10's first contract as a table.
  #
  # The names are the procs' own, and the walk below counts CALL SITES — an
  # identifier immediately followed by `(`, outside a comment, on a line that
  # does not declare it. So `d.controls.stepForward()` and
  # `publishInspectionCursor(d.calltrace, i)` are both counted, which is what
  # makes the rule about calls rather than about spelling.
  #
  # FIFTEEN OF THE SIXTEEN ROWS NAME EXACTLY ONE FILE. The sixteenth is
  # `seekTo`, and the reason is a NAME COLLISION rather than a second dispatch
  # path: CTUI-8's `app/input/timeline_keys.nim` has a private
  # `proc seekTo(tick: uint64): TimelineKeyResult` — a result constructor for a
  # pure key handler, which reaches no ViewModel and cannot. Listing both files
  # here, rather than matching on a qualified spelling the source does not use,
  # keeps the rule mechanical and puts the exception where a reader sees it.
  SingleSiteProcs = [
    ("stepForward", "commands/interpreter.nim"),
    ("stepBackward", "commands/interpreter.nim"),
    ("stepIn", "commands/interpreter.nim"),
    ("stepOut", "commands/interpreter.nim"),
    ("continueExecution", "commands/interpreter.nim"),
    ("reverseContinue", "commands/interpreter.nim"),
    ("reverseStepIn", "commands/interpreter.nim"),
    ("reverseStepOut", "commands/interpreter.nim"),
    ("addWatch", "commands/interpreter.nim"),
    ("publishInspectionCursor", "commands/interpreter.nim"),
    ("seekTo", "commands/interpreter.nim|input/timeline_keys.nim"),
    # CTUI-8's ONE seek. `interpreter.seekWithin` reaches `TimelineVM.seek`
    # through `timeline_binding.seekTo` rather than directly, which is why this
    # row names a different file from the ten above.
    ("seek", "timeline_binding.nim"),
    ("onShowOrigin", "origin_binding.nim"),
    ("applyChainResponse", "origin_binding.nim"),
    ("onCancelLoad", "origin_binding.nim"),
  ]

  ExpectedAppModules = 51
    ## Every `.nim` under `app/`, counted on 2026-09-06.

  ExpectedStyleLiterals = 121
  ExpectedStyledFiles = 18
    ## What `:theme`'s "nothing to switch" report MEANS, as two numbers:
    ## every colour this front-end paints is a `const CellStyle` literal, in 18
    ## files. Counted on 2026-09-06 and asserted, so the report stops being
    ## true — and this suite says so — the day a theme registry arrives.

  Garbage = [
    "", "   ", ":", "  :  ", ":teleport", ":nex", ":NEXT", ":n3xt",
    ":goto", ":goto twelve", ":frame -1", ":frame two", ":theme neon",
    ":info", ":info stack", ":origin", ":print", ":break", ":tracepoint",
  ]
    ## Everything a `:` prompt can be handed that is not a runnable command:
    ## empty, blank, a bare sigil, an unknown verb, a truncated verb, the right
    ## verb in the wrong case, a typo, six malformed arguments and four missing
    ## ones. Every one must be REPORTED.

# ---------------------------------------------------------------------------
# Reading §4.3 out of the specification
# ---------------------------------------------------------------------------

proc specPath(): string =
  ## Where the published block lives, resolved from THIS FILE rather than from
  ## the working directory, so the suite answers the same way however it is
  ## invoked. Same walk as `test_keymap_no_conflicts.specPath`.
  var dir = currentSourcePath().parentDir()
  for _ in 0 ..< 5:
    dir = dir.parentDir()
  dir.parentDir() / SpecRelativePath

proc parseAlias(comment: string): (string, string) =
  ## `(summary, alias)` from a §4.3 comment. `(alias: s)` is the document's own
  ## spelling and it is always last on the line.
  let open = comment.rfind("(alias:")
  if open < 0:
    return (comment.strip(), "")
  let close = comment.find(')', open)
  if close < 0:
    return (comment.strip(), "")
  let alias = comment[open + len("(alias:") ..< close].strip()
  (comment[0 ..< open].strip(), alias)

proc readSpecCommands(path: string): seq[SpecCommand] =
  ## Parse §4.3's fenced block.
  ##
  ## Raises rather than returning an empty sequence when the heading or the
  ## block is missing: an empty oracle would make every comparison below pass
  ## vacuously, which is the exact shape of failure this campaign's audit
  ## catalogues.
  if not fileExists(path):
    raise newException(IOError,
      "the §4.3 oracle is missing: " & path & " does not exist. This suite " &
      "reads the published GDB-compatible command surface out of the " &
      "codetracer-specs sibling checkout; clone it beside this repo (see " &
      "CLAUDE.md on the workspace layout) — there is nothing to configure " &
      "and nothing to skip.")
  let text = readFile(path)
  var inSection = false
  var inBlock = false
  result = @[]
  for line in text.splitLines():
    if not inSection:
      if line.strip() == SpecSectionHeading:
        inSection = true
      continue
    let trimmed = line.strip()
    if trimmed.startsWith("```"):
      if inBlock:
        break                                   # the block is over
      inBlock = true
      continue
    if trimmed.startsWith("### ") or trimmed.startsWith("## "):
      break
    if not inBlock or trimmed.len == 0 or trimmed[0] != ':':
      continue
    let hash = trimmed.find('#')
    if hash < 0:
      raise newException(IOError,
        "§4.3 line without a comment, which the block's shape does not " &
        "allow: " & trimmed)
    let left = trimmed[1 ..< hash].strip()
    let (summary, alias) = parseAlias(trimmed[hash + 1 .. ^1])
    var nameParts: seq[string] = @[]
    var argument = ""
    for token in left.splitWhitespace():
      if token.startsWith("<"):
        argument = token
      else:
        nameParts.add token
    result.add SpecCommand(name: nameParts.join(" "), argument: argument,
                           summary: summary, alias: alias)
  if result.len == 0:
    raise newException(IOError,
      "found " & SpecSectionHeading & " in " & path & " but parsed no " &
      "commands out of its fenced block. The oracle is empty, so every " &
      "comparison in this suite would pass without checking anything.")

# ---------------------------------------------------------------------------
# The structural walk over `app/`
# ---------------------------------------------------------------------------

proc stripComment(line: string): string =
  ## Everything before the first `#`.
  ##
  ## Naive with respect to `#` inside a string literal, and that is safe in ONE
  ## direction only: it can drop code, never invent it, so a call site hidden
  ## after a `#RRGGBB` literal would be UNDERCOUNTED. The mutation arm below is
  ## what keeps that honest — it plants a call and requires the count to move.
  let hash = line.find('#')
  if hash < 0: line else: line[0 ..< hash]

proc callSitesIn*(text: string; name: string): int =
  ## How many times `name(` is CALLED in `text`.
  ##
  ## A call is `name` immediately followed by `(`, with a non-identifier
  ## character before it, on a line that is not the declaration. Comments are
  ## stripped first.
  result = 0
  for rawLine in text.splitLines():
    let line = stripComment(rawLine)
    let trimmed = line.strip()
    if trimmed.startsWith("proc ") or trimmed.startsWith("func ") or
       trimmed.startsWith("template ") or trimmed.startsWith("method "):
      continue
    var at = 0
    while true:
      let found = line.find(name & "(", at)
      if found < 0:
        break
      at = found + name.len
      if found > 0:
        let before = line[found - 1]
        if before in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}:
          continue
      inc result

proc appRoot(): string =
  currentSourcePath().parentDir().parentDir()

proc appModules(): seq[string] =
  ## Every `.nim` under `app/`, repo-relative to `app/`, sorted.
  result = @[]
  for path in walkDirRec(appRoot(), relative = true):
    if path.endsWith(".nim"):
      result.add path.replace('\\', '/')
  result.sort()

# ---------------------------------------------------------------------------
# The dispatcher this suite drives
# ---------------------------------------------------------------------------

type
  ServiceLog = ref object
    ## What the host was asked to do. A `ref` so the closures below share one,
    ## which is what makes "the interpreter reached the seam" observable.
    breakpoints: seq[string]
    tracepoints: seq[TracepointRequest]
    themes: seq[string]
    quits: int

proc newServiceLog(): ServiceLog =
  ServiceLog(breakpoints: @[], tracepoints: @[], themes: @[], quits: 0)

proc wiredServices(log: ServiceLog): CommandServices =
  ## The host, wired. See this file's header on why these are not mocks.
  CommandServices(
    setBreakpoint: proc(path: string; line: int): bool =
      log.breakpoints.add path & ":" & $line
      true,
    runTracepoint: proc(request: TracepointRequest): int =
      log.tracepoints.add request
      3,
    threads: nil,
    registers: nil,
    setTheme: proc(name: string): bool =
      log.themes.add name
      true,
    quit: proc() =
      inc log.quits)

proc bareDispatcher(): Dispatcher =
  ## No ViewModels, no services. Every action must REPORT.
  Dispatcher()

proc sampleContext(): CommandContext =
  ## A position and a recording extent, as a value. Nothing here is fetched;
  ## the numbers are the caller's, which is what `CommandContext` is for.
  CommandContext(
    file: "/tmp/ctui10/shield.nr", line: 6, tick: 283, frameCount: 2,
    targets: initTimelineTargets(callBoundaries = @[9'u64, 18, 100, 262],
                                 mutations = @[],
                                 minTick = 0'u64, maxTick = 1314'u64),
    selectedVariable: "remaining_shield",
    functions: @[FunctionSite(name: "iterate_asteroids",
                              path: "/tmp/ctui10/shield.nr", line: 1)])

proc sampleArgumentFor(spec: CommandSpec): string =
  ## A VALID argument for a command §4.3 gives a placeholder, chosen so the
  ## parse succeeds. Derived from the placeholder rather than from the kind, so
  ## a command that grows an argument does not silently get an empty one.
  case spec.argument
  of "": ""
  of "<line|func>": "12"
  of "<expr>": "remaining_shield"
  of "<number>": "1"
  of "<tick>": "220"
  of "<var>": "remaining_shield"
  of "<dark|light>": "dark"
  else: "UNRECOGNISED-PLACEHOLDER-" & spec.argument

# ---------------------------------------------------------------------------

let published = readSpecCommands(specPath())

suite "CTUI-10: §4.3's command surface is the published one":

  test "§4.3 is read out of the published specification, not out of this file":
    checkpoint("oracle: " & specPath())
    ck fileExists(specPath())
    checkpoint("parsed commands: " & $published.len)
    ck published.len == ExpectedSpecCommands
    # Every parsed row carries a name and a summary. A parser that dropped the
    # comment would make the summary comparison below compare empty strings.
    var wellFormed = 0
    var aliased = 0
    for row in published:
      if row.name.len > 0 and row.summary.len > 0:
        inc wellFormed
      if row.alias.len > 0:
        inc aliased
    ck wellFormed == ExpectedSpecCommands
    checkpoint("commands with a published alias: " & $aliased)
    ck aliased == ExpectedAliases

  test "the implementation's table IS §4.3, row by row":
    ck Spec43Commands.len == published.len
    ck Spec43Commands.len == ExpectedSpecCommands
    var compared = 0
    var wrong: seq[string] = @[]
    for i, row in published:
      inc compared
      let spec = Spec43Commands[i]
      if spec.name != row.name:
        wrong.add "row " & $i & ": name spec `" & row.name & "` impl `" &
          spec.name & "`"
      if spec.alias != row.alias:
        wrong.add "row " & $i & " (" & row.name & "): alias spec `" &
          row.alias & "` impl `" & spec.alias & "`"
      if spec.argument != row.argument:
        wrong.add "row " & $i & " (" & row.name & "): argument spec `" &
          row.argument & "` impl `" & spec.argument & "`"
      if spec.summary != row.summary:
        wrong.add "row " & $i & " (" & row.name & "): summary spec `" &
          row.summary & "` impl `" & spec.summary & "`"
      let wantNeed = if row.argument.len > 0: anRequired else: anNone
      if spec.need != wantNeed:
        wrong.add "row " & $i & " (" & row.name & "): need " & $spec.need &
          " but §4.3 shows " & (if row.argument.len > 0: "an argument"
                                else: "none")
    if wrong.len > 0:
      for w in wrong:
        checkpoint(w)
    ck wrong.len == 0
    # THE SWEEP'S OWN SIZE, against its parameter rather than against a number
    # from a run.
    checkpoint("rows compared: " & $compared)
    ck compared == ExpectedSpecCommands
    ck compared == published.len
    # …and the enum covers the table exactly, in both directions, so a
    # seventeenth `CommandKind` with no §4.3 row is red here.
    var kinds: seq[string] = @[]
    for kind in CommandKind:
      kinds.add $kind
    var names: seq[string] = @[]
    for row in published:
      names.add row.name
    ck kinds.len == published.len
    ck kinds == names

  test "every published command is accepted; its alias is the same call":
    var accepted = 0
    var aliasPairs = 0
    for row in published:
      inc accepted
      let (found, kind, wasAlias) = lookupCommand(row.name)
      checkpoint("`" & row.name & "` -> " & $found & " " & $kind)
      ck found
      ck not wasAlias
      let spec = commandSpec(kind)
      let argument = sampleArgumentFor(spec)
      let line = ":" & row.name & (if argument.len > 0: " " & argument else: "")
      let byName = parseCommand(line)
      checkpoint(line & " -> " & $byName.status & " " & $byName.kind &
                 " arg `" & byName.argument & "` " & byName.message)
      ck byName.status == csOk
      ck byName.kind == kind
      ck byName.message.len == 0
      if row.alias.len == 0:
        continue
      inc aliasPairs
      let (aliasFound, aliasKind, aliasWas) = lookupCommand(row.alias)
      ck aliasFound
      ck aliasWas
      ck aliasKind == kind
      let aliasLine = ":" & row.alias &
        (if argument.len > 0: " " & argument else: "")
      let byAlias = parseCommand(aliasLine)
      checkpoint(aliasLine & " must equal " & line)
      # IDENTICAL STATE, as one value comparison rather than field by field —
      # see `CommandInvocation`'s own comment on why the typed spelling is not
      # in the value.
      ck byAlias == byName
    ck accepted == ExpectedSpecCommands
    ck aliasPairs == ExpectedAliases

  test "the command form IS the key form — one dispatch, not two":
    let d = bareDispatcher()
    let ctx = sampleContext()
    var bound = 0
    var unbound: seq[CommandKind] = @[]
    for row in published:
      let (_, kind, _) = lookupCommand(row.name)
      let spec = commandSpec(kind)
      let argument = sampleArgumentFor(spec)
      let (isBound, action) = keyActionFor(kind)
      if not isBound:
        unbound.add kind
        continue
      inc bound
      let viaCommand = runCommand(d, ctx,
        ":" & row.name & (if argument.len > 0: " " & argument else: ""))
      let viaKey = dispatchAction(d, ctx, action, argument)
      checkpoint(":" & row.name & " -> " & $viaCommand.dispatch.status & " " &
                 $viaCommand.dispatch.action & " | key " & $action & " -> " &
                 $viaKey.status & " " & $viaKey.action)
      # THE WHOLE RESULT, including its human-readable detail: a command that
      # reached a different arm would differ in the detail even where the
      # status and action matched.
      ck viaCommand.dispatch == viaKey
      ck viaCommand.dispatch.action == action
    checkpoint("§4.2-bound commands: " & $bound)
    ck bound == ExpectedSpecCommands - CommandOnlyKinds.len
    # …and the six §4.3-only commands are EXACTLY the ones `CommandOnlyKinds`
    # names, in both directions.
    unbound.sort(proc(a, b: CommandKind): int = cmp($a, $b))
    var declared = CommandOnlyKinds
    declared.sort(proc(a, b: CommandKind): int = cmp($a, $b))
    checkpoint("commands §4.2 binds no key to: " & $unbound)
    ck unbound == declared
    ck unbound.len == 6
    for kind in CommandOnlyKinds:
      let (isBound, action) = keyActionFor(kind)
      ck not isBound
      ck action == kaNone

  test "every ViewModel action proc is called from exactly one file":
    # THE STRUCTURAL HALF OF CONTRACT 1. A second dispatch path is, by
    # definition, a second file that calls one of these.
    let modules = appModules()
    checkpoint("modules under app/: " & $modules.len)
    # THE SIZE, not "more than none" — trap 4b: an existential control is
    # satisfied by one member of a set whose size is knowable, and this one is
    # (counted 2026-09-06). A walk that found one file would satisfy every
    # "called from exactly one file" row below for free.
    ck modules.len == ExpectedAppModules
    var sources: seq[(string, string)] = @[]
    for rel in modules:
      sources.add (rel, readFile(appRoot() / rel))
    ck sources.len == modules.len

    var procsChecked = 0
    var violations: seq[string] = @[]
    for entry in SingleSiteProcs:
      inc procsChecked
      var callers: seq[string] = @[]
      var total = 0
      for pair in sources:
        let n = callSitesIn(pair[1], entry[0])
        if n > 0:
          callers.add pair[0]
          total += n
      checkpoint(entry[0] & "( called from " & callers.join(", ") & " — " &
                 $total & " site(s)")
      if callers.join("|") != entry[1]:
        violations.add entry[0] & ": expected only " & entry[1] & ", found " &
          (if callers.len == 0: "NOTHING" else: callers.join("|"))
      # …and it is called at least once, so "exactly one file" is not
      # satisfied by a proc nobody calls.
      ck total > 0
    if violations.len > 0:
      for v in violations:
        checkpoint(v)
    ck violations.len == 0
    ck procsChecked == SingleSiteProcs.len
    ck procsChecked == 15

    # THE MUTATION ARM. A counter that cannot be made to move is
    # indistinguishable from one that is not reading the files.
    # The name is CONCATENATED rather than written whole, so this file does not
    # itself become a second call site of the very proc the walk above pins to
    # one. That is not cosmetic: written literally, the arm made the walk report
    # `tests/test_gdb_command_surface.nim` as a violation of its own rule.
    let planted = "proc somewhereElse(vm: DebugControlsVM) =\n" &
      "  vm.step" & "Forward()\n" &
      "  vm.step" & "Forward()\n"
    checkpoint("planted two calls: " & $callSitesIn(planted, "stepForward"))
    ck callSitesIn(planted, "stepForward") == 2
    # …and the DECLARATION is not a call, which is what stops the rule from
    # reporting every proc as its own second dispatch path.
    ck callSitesIn("proc step" & "Forward*(vm: DebugControlsVM) =\n  discard\n",
                   "stepForward") == 0
    # …nor is a mention inside a comment.
    ck callSitesIn("  # see vm.step" & "Forward() for the real one\n",
                   "stepForward") == 0
    # …nor is a longer identifier that merely ends with the name.
    ck callSitesIn("  vm.reallyStep" & "Forward()\n", "stepForward") == 0

  test "the six §4.3-only commands reach their seam, or report its absence":
    let ctx = sampleContext()
    let log = newServiceLog()
    var wired = bareDispatcher()
    wired.services = wiredServices(log)

    # `:tracepoint` COMPOSES CTUI-8's request and hands it to the sweep.
    let tp = runCommand(wired, ctx, ":tracepoint remaining_shield")
    checkpoint(":tracepoint -> " & $tp.dispatch.status & " " & tp.message)
    ck tp.dispatch.status == drDone
    ck tp.hasTracepoint
    ck tp.tracepoint.path == ctx.file
    ck tp.tracepoint.line == ctx.line
    ck tp.tracepoint.expression == "remaining_shield"
    ck log.tracepoints.len == 1
    ck log.tracepoints[0] == tp.tracepoint
    ck tp.message.contains("3 hit(s)")

    # `:theme` VALIDATES against §4.3's own `<dark|light>` before it dispatches.
    for name in ThemeNames:
      let themed = runCommand(wired, ctx, ":theme " & name)
      ck themed.dispatch.status == drDone
      ck themed.message == "theme " & name
    ck log.themes == @["dark", "light"]
    let badTheme = runCommand(wired, ctx, ":theme neon")
    ck badTheme.invocation.status == csBadArgument
    ck badTheme.message.contains("neon")
    ck log.themes.len == 2                       # the bad one did NOT dispatch

    # `:quit` is §4.2's `q`, so it goes through `dispatchAction`.
    let quit = runCommand(wired, ctx, ":quit")
    ck quit.dispatch.status == drDone
    ck quit.dispatch.action == kaQuit
    ck log.quits == 1
    ck runCommand(wired, ctx, ":q").dispatch == quit.dispatch
    ck log.quits == 2

    # `:break` resolves a NUMBER against the cursor's file and a NAME against
    # the recording's own functions.
    let byLine = runCommand(wired, ctx, ":break 12")
    ck byLine.dispatch.status == drDone
    ck log.breakpoints[^1] == ctx.file & ":12"
    let byName = runCommand(wired, ctx, ":break iterate_asteroids")
    ck byName.dispatch.status == drDone
    ck log.breakpoints[^1] == ctx.functions[0].path & ":" &
      $ctx.functions[0].line
    let byNothing = runCommand(wired, ctx, ":break no_such_function")
    ck byNothing.dispatch.status == drRejected
    ck byNothing.message.contains("no_such_function")
    ck log.breakpoints.len == 2                  # the refusal sent nothing

    # AND THE TWO §4.3 PUBLISHES THAT NOTHING IN THIS WORKSPACE IMPLEMENTS.
    # Accepted, dispatched, and REPORTED as unsupported — never silent, and
    # never a green pass over a stub. See `interpreter.nim`'s header table.
    let noTheme = runCommand(bareDispatcher(), ctx, ":theme dark")
    checkpoint(":theme with no host -> " & noTheme.message)
    ck noTheme.invocation.status == csOk
    ck noTheme.dispatch.status == drUnsupported
    ck noTheme.message == NoThemeSurfaceNote
    # …AND THE CLAIM IN THAT MESSAGE IS MEASURED, not asserted in prose. Every
    # style this front-end paints is a `const CellStyle` literal and nothing
    # under `app/` names `isonim-tui`'s `ThemeRegistry`, so there is genuinely
    # nothing for a theme to switch. Both numbers move the day a theme arrives,
    # which is when this arm should stop reading `unsupported`.
    var styleLiterals = 0
    var filesWithStyles = 0
    var themeReferences = 0
    for rel in appModules():
      let text = readFile(appRoot() / rel)
      let n = callSitesIn(text, "CellStyle")
      if n > 0:
        inc filesWithStyles
        styleLiterals += n
      themeReferences += callSitesIn(text, "ThemeRegistry")
    checkpoint($styleLiterals & " CellStyle literal(s) in " &
               $filesWithStyles & " file(s); " & $themeReferences &
               " ThemeRegistry reference(s)")
    ck styleLiterals == ExpectedStyleLiterals
    ck filesWithStyles == ExpectedStyledFiles
    ck themeReferences == 0
    let noRegs = runCommand(bareDispatcher(), ctx, ":info registers")
    checkpoint(":info registers -> " & noRegs.message)
    ck noRegs.invocation.status == csOk
    ck noRegs.invocation.kind == cmdInfoRegisters
    ck noRegs.dispatch.status == drUnsupported
    ck noRegs.message == NoRegisterSurfaceNote
    # §4.2's `m` — CTUI-7 measured that the engine has no `readMemory` arm —
    # is the third of the same shape, and it comes through the KEY path.
    let noMemory = dispatchAction(bareDispatcher(), ctx, kaViewMemoryDump)
    ck noMemory.status == drUnsupported
    ck noMemory.detail == NoMemorySurfaceNote

    # `:info threads` and `:print` and `:frame` with nothing wired: reported,
    # each naming what is missing.
    for line in [":info threads", ":print remaining_shield", ":frame 1"]:
      let out2 = runCommand(bareDispatcher(), ctx, line)
      checkpoint(line & " with nothing wired -> " & $out2.dispatch.status &
                 " " & out2.message)
      ck out2.invocation.status == csOk
      ck out2.dispatch.status == drUnavailable
      ck out2.message.len > 0

  test "an argument §4.3 requires is required, and its absence names it":
    let d = bareDispatcher()
    let ctx = sampleContext()
    var required = 0
    for row in published:
      if row.argument.len == 0:
        continue
      inc required
      let bare = parseCommand(":" & row.name)
      checkpoint(":" & row.name & " (no argument) -> " & $bare.status & " " &
                 bare.message)
      ck bare.status == csMissingArgument
      ck bare.message.contains(row.argument)
      ck bare.message.contains(row.name)
      # …and running it reports rather than dispatching.
      let out2 = runCommand(d, ctx, ":" & row.name)
      ck out2.dispatch.status == drRejected
      ck out2.message == bare.message
    checkpoint("commands with a required argument: " & $required)
    ck required == 7
    # THE POSITIVE TWIN: the ten with no placeholder accept a bare line.
    var bareOk = 0
    for row in published:
      if row.argument.len > 0:
        continue
      inc bareOk
      ck parseCommand(":" & row.name).status == csOk
    ck bareOk == ExpectedSpecCommands - required

  test "nothing this prompt can be handed is silent":
    # CONTRACT 2, over three populations: the published commands, their
    # aliases, and everything that is not a command at all.
    let d = bareDispatcher()
    let ctx = sampleContext()
    var examined = 0
    for row in published:
      let (_, kind, _) = lookupCommand(row.name)
      let argument = sampleArgumentFor(commandSpec(kind))
      for spelling in [row.name, row.alias]:
        if spelling.len == 0:
          continue
        inc examined
        let out2 = runCommand(d, ctx,
          ":" & spelling & (if argument.len > 0: " " & argument else: ""))
        if out2.message.len == 0:
          checkpoint("SILENT: :" & spelling)
        ck out2.message.len > 0
        ck describeOutcome(out2).len > 0
    ck examined == ExpectedSpecCommands + ExpectedAliases

    var garbageExamined = 0
    for line in Garbage:
      inc garbageExamined
      let out2 = runCommand(d, ctx, line)
      checkpoint("`" & line & "` -> " & $out2.invocation.status & ": " &
                 out2.message)
      ck out2.invocation.status != csOk
      ck out2.message.len > 0
      ck out2.dispatch.status == drRejected
      ck describeOutcome(out2).startsWith($out2.invocation.status)
    ck garbageExamined == Garbage.len
    ck garbageExamined == 19

    # An unknown VERB names the word the user typed, which is what makes the
    # report actionable rather than merely present.
    let unknown = parseCommand(":teleport 4")
    ck unknown.status == csUnknown
    ck unknown.message.contains("teleport")
    # …and a command spelled in the wrong case is UNKNOWN rather than accepted
    # — see `interpreter.nim`'s header on why there is no case folding and no
    # prefix matching.
    ck parseCommand(":NEXT").status == csUnknown
    ck parseCommand(":nex").status == csUnknown

  test "the `:` prompt keeps a history and completes from a value":
    var prompt = initCommandLineModel(pkCommand)
    ck prompt.open(pkCommand) == claOpened
    ck prompt.open
    ck prompt.buffer == ""
    for ch in ":next":
      discard prompt.insert($ch)
    ck prompt.buffer == ":next"
    ck prompt.cursorColumn() == 1 + prompt.buffer.len
    let (action, line) = prompt.submit()
    ck action == claSubmitted
    ck line == ":next"
    ck not prompt.open
    ck prompt.history == @[":next"]

    # A repeat MOVES the entry rather than growing the history.
    discard prompt.open(pkCommand)
    for ch in ":goto 220":
      discard prompt.insert($ch)
    discard prompt.submit()
    discard prompt.open(pkCommand)
    for ch in ":next":
      discard prompt.insert($ch)
    discard prompt.submit()
    ck prompt.history == @[":goto 220", ":next"]
    ck prompt.history.len == 2

    # …and a blank line is not history.
    discard prompt.open(pkCommand)
    discard prompt.insert("  ")
    discard prompt.submit()
    ck prompt.history.len == 2

    # BROWSING STASHES THE PARTIAL LINE, and `Down` past the newest restores it.
    discard prompt.open(pkCommand)
    for ch in ":br":
      discard prompt.insert($ch)
    ck prompt.historyPrev() == claHistoryMoved
    ck prompt.buffer == ":next"
    ck prompt.historyPrev() == claHistoryMoved
    ck prompt.buffer == ":goto 220"
    ck prompt.historyPrev() == claNoHistory
    ck prompt.buffer == ":goto 220"
    ck prompt.historyNext() == claHistoryMoved
    ck prompt.buffer == ":next"
    ck prompt.historyNext() == claHistoryMoved
    ck prompt.buffer == ":br"
    ck prompt.historyNext() == claNoHistory

    # COMPLETION TAKES CANDIDATES AS A VALUE — `commandNames()` is passed in,
    # never imported by the view. `re` matches the three `reverse-*` spellings
    # and cycles through them in sorted order.
    let names = commandNames()
    ck names.len == ExpectedSpecCommands + ExpectedAliases
    discard prompt.open(pkCommand)
    for ch in "reverse-":
      discard prompt.insert($ch)
    ck prompt.complete(names) == claCompleted
    ck prompt.completions == @["reverse-continue", "reverse-next",
                               "reverse-step"]
    ck prompt.buffer == "reverse-continue"
    ck prompt.complete(names) == claCompleted
    ck prompt.buffer == "reverse-next"
    ck prompt.complete(names) == claCompleted
    ck prompt.buffer == "reverse-step"
    ck prompt.complete(names) == claCompleted
    ck prompt.buffer == "reverse-continue"       # cycles
    ck prompt.completionHint().len > 0

    # An exact prefix with ONE candidate completes and does not cycle.
    discard prompt.open(pkCommand)
    for ch in "tra":
      discard prompt.insert($ch)
    ck prompt.complete(names) == claCompleted
    ck prompt.buffer == "tracepoint"
    ck prompt.completions == @["tracepoint"]
    ck prompt.completionHint() == ""

    # NO CANDIDATE IS REPORTED. `claNoCompletion` and a message, not silence.
    discard prompt.open(pkCommand)
    for ch in "zz":
      discard prompt.insert($ch)
    ck prompt.complete(names) == claNoCompletion
    ck prompt.message == NoCompletionText
    ck prompt.buffer == "zz"

    # The ARGUMENT completes from a different value through the same call.
    discard prompt.open(pkCommand)
    for ch in "break iter":
      discard prompt.insert($ch)
    ck prompt.complete(@["iterate_asteroids", "calculate_damage"]) ==
      claCompleted
    ck prompt.buffer == "break iterate_asteroids"

    # `Esc` drops the buffer and keeps the history; `Backspace` on an empty
    # buffer does NOT close the prompt.
    discard prompt.open(pkCommand)
    discard prompt.insert("x")
    ck prompt.cancel() == claCancelled
    ck not prompt.open
    ck prompt.history.len == 2
    discard prompt.open(pkCommand)
    ck prompt.backspace() == claEdited
    ck prompt.open
    ck prompt.buffer == ""

    # `applyKey` accepts BOTH spellings a token reaches a prompt in: the raw
    # byte the snapshot runtime frames and the canonical name `keymap.keyName`
    # produces.
    discard prompt.open(pkCommand)
    ck prompt.applyKey("n") == claEdited
    ck prompt.applyKey("\x7f") == claEdited
    ck prompt.buffer == ""
    ck prompt.applyKey("q") == claEdited
    ck prompt.applyKey("Backspace") == claEdited
    ck prompt.buffer == ""
    ck prompt.applyKey("\t", names) == claCompleted
    ck prompt.applyKey("\x1b") == claCancelled
    ck not prompt.open
    # A CLOSED prompt declines every key rather than swallowing it — which is
    # what keeps `Ctrl+c` reaching the quit binding.
    ck prompt.applyKey("n") == claUnhandled
    ck prompt.applyKey("\r") == claUnhandled

    # The three sigils are §4.2's three prompt keys, and the value IS the sigil.
    ck $pkCommand == ":"
    ck $pkSearchForward == "/"
    ck $pkSearchBackward == "?"
    var search = initCommandLineModel(pkSearchForward)
    discard search.open(pkSearchForward)
    for ch in "shield":
      discard search.insert($ch)
    ck search.promptText(40) == "/shield" & repeatGlyph(" ", 33)
    ck search.cursorColumn() == 7

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions

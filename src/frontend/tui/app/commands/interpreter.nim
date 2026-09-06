## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it. This module reaches `codetracer_embed` — the sanctioned facade
## — and never `viewmodel/*` directly. It reads no terminal and spawns nothing.
##
## app/commands/interpreter.nim — CTUI-10. CodeTracer-TUI.md §4.3's
## GDB-compatible command surface, AS DATA, and the ONE dispatch every action in
## this front-end goes through.
##
## ## THE TWO CONTRACTS, AND WHERE EACH ONE LIVES IN THIS FILE
##
## CTUI-10: *"Every command routes through the same action procs the keybindings
## use; there is no second dispatch path."* and *"An unknown command reports it;
## it never silently does nothing."*
##
## 1. **One dispatch.** `dispatchAction` takes a `keymap.KeyAction` — the very
##    type `keymap.resolve` answers with — and is the only place in `app/` that
##    names a `DebugControlsVM` action proc. A §4.3 command that §4.2 also binds
##    does not re-implement anything: `runCommand` looks its `KeyAction` up in
##    `keyActionFor` and calls `dispatchAction` with it, so `:next` and the `n`
##    key are the same call with the same argument.
##
##    `app/tests/test_gdb_command_surface.nim` asserts that STRUCTURALLY, three
##    ways: every §4.2-bound command's `CommandOutcome.dispatch` is equal to the
##    `DispatchResult` the key produces; the set of commands §4.2 does NOT bind
##    is exactly `CommandOnlyKinds`; and a walk over every `.nim` under `app/`
##    finds every call site of the eight `DebugControlsVM` action procs in THIS
##    FILE and nowhere else.
##
## 2. **Nothing is silent.** `CommandOutcome.message` is never empty — for a
##    command that ran, for one that was refused, for one whose argument was
##    wrong, and for a word that is not a command at all. `parseCommand`
##    classifies the failure (`csUnknown`, `csMissingArgument`, `csBadArgument`,
##    `csEmpty`) so the command line can say WHICH, and the suite asserts the
##    message is non-empty for every one of the sixteen published commands,
##    for all eleven aliases, and for nineteen kinds of garbage.
##
## ## §4.3 IS DATA, AND THE PUBLISHED BLOCK IS THE ORACLE
##
## `Spec43Commands` below is §4.3's fenced block transcribed into a `seq`, in
## the document's own order, carrying the document's own spelling, alias,
## argument placeholder and one-line summary VERBATIM. It is not the oracle —
## `app/tests/test_gdb_command_surface.nim` PARSES §4.3 out of
## `codetracer-specs/Front-Ends/CodeTracer-TUI.md` at run time and compares the
## two, exactly as CTUI-9's `test_keymap_no_conflicts.nim` does for §4.2. A
## hand-written copy in the test would have been written from the same reading
## that produced this table and the two would agree about a misreading.
##
## ## SIX COMMANDS §4.2 DOES NOT BIND, AND WHAT EACH ONE REACHES
##
## Ten of §4.3's sixteen commands are §4.2 actions under another spelling. The
## other six have no key, and each needs something no ViewModel owns, so each
## takes the seam this tree has used since CTUI-5 (the host wires a closure; a
## nil one is REPORTED, never silently skipped):
##
##   * `:tracepoint <expr>` composes CTUI-8's `TracepointRequest` and hands it
##     to `services.runTracepoint`. `ct/run-tracepoints` is a real post-hoc
##     sweep answering ticks — CTUI-8 measured it.
##   * `:frame <number>` reaches `call_stack_binding.publishInspectionCursor`
##     on `CalltraceVM`. A VM action proc; no seam needed.
##   * `:print <expr>` reaches `StateVM.addWatch`, and the engine EVALUATES
##     watch expressions inside `ct/load-locals` (`dap_handler.rs`'s
##     `l.is_watch` arm). Real, and asserted on `noir_space_ship`.
##   * `:info threads` reaches `services.threads` and CTUI-6's
##     `call_stack_binding.threadsFrom`. Real, and answers exactly ONE thread
##     on every recorder in this workspace (CTUI-6).
##   * `:info registers` reaches `services.registers`, and NOTHING IMPLEMENTS
##     IT: `dap_server.rs`'s `handle_request` has no register arm and no
##     ViewModel carries a register. See below.
##   * `:theme <dark|light>` reaches `services.setTheme`, and NOTHING
##     IMPLEMENTS IT: every style in `app/views/` is a `const CellStyle`
##     literal. See below.
##
## **`:info registers` and `:theme` are accepted, validated and dispatched, and
## then report that nothing is behind them.** A command §4.3 publishes must fail
## in `test_gdb_command_surface.nim` rather than in a user's terminal, and the
## honest failure of a capability nobody built is a REPORT, not a silent no-op
## and not a green assertion over a stub.
##
## THE TWO ARE NOT THE SAME KIND OF GAP, and saying so matters:
##
##   * `:info registers` is BLOCKED ON THE ENGINE — `dap_server.rs` has no
##     register arm and no ViewModel carries one. This is the shape CTUI-6 used
##     for the thread selector and CTUI-7 for the hex inspector, and nothing in
##     this repo closes it.
##   * `:theme` is UNBUILT HERE. `isonim-tui` DOES ship a theme registry
##     (`isonim_tui/theme/cascade.nim`: `ThemeRegistry`, `newThemeRegistry`,
##     `setTheme`, `subscribe`, with `textual-dark` / `textual-light` builtins,
##     described by `theme.nim` as "runtime theme switching"). What is missing
##     is that every style CTUI-3..CTUI-10 painted is a `const CellStyle`
##     literal, so there is nothing reading a registry to switch. That is a
##     REFACTOR THIS REPO OWNS across 18 files, deferred — not a capability the
##     workspace lacks.
##
## `:theme`'s claim is MEASURED rather than asserted in prose: the suite counts
## the `const CellStyle` literals under `app/` (121, in 18 files) and the
## references to `isonim-tui`'s `ThemeRegistry` (zero), as equalities — so the
## day either number moves, the run goes red and says the report has stopped
## being true.
##
## ## CASE, AND WHY THERE IS NO ABBREVIATION MATCHING
##
## Commands are matched CASE-SENSITIVELY and only against §4.3's own spelling
## and §4.3's own alias. GDB accepts unique prefixes (`ne` for `next`); §4.3
## publishes an explicit alias per command and nothing else, and inventing a
## prefix rule would make `:re` ambiguous between `reverse-step` and
## `reverse-next` — a class of error the published table does not have.

import std/[json, strutils]

import codetracer_embed

import ../call_stack_binding
import ../input/keymap
import ../origin_binding
import ../timeline_binding
import ../views/tracepoint_manager

# `timeline_binding` is exported because `CommandContext.targets` is CTUI-8's
# `TimelineTargets` — a caller cannot construct a context without it — and
# because `seekWithin` reaches `TimelineVM.seek` through CTUI-8's ONE
# `seekTo`, which is the fact `app/tests/test_gdb_command_surface.nim`'s
# single-call-site walk asserts.
export keymap, origin_binding, timeline_binding, tracepoint_manager

type
  CommandKind* = enum
    ## §4.3's sixteen commands, in the document's order. The string values are
    ## the spelling a user types after `:`.
    cmdStep = "step"
    cmdNext = "next"
    cmdReverseStep = "reverse-step"
    cmdReverseNext = "reverse-next"
    cmdContinue = "continue"
    cmdReverseContinue = "reverse-continue"
    cmdBreak = "break"
    cmdTracepoint = "tracepoint"
    cmdFrame = "frame"
    cmdGoto = "goto"
    cmdOrigin = "origin"
    cmdPrint = "print"
    cmdInfoThreads = "info threads"
    cmdInfoRegisters = "info registers"
    cmdTheme = "theme"
    cmdQuit = "quit"

  ArgumentNeed* = enum
    ## Whether §4.3's line shows an argument placeholder after the command.
    anNone = "none"
    anRequired = "required"

  CommandSpec* = object
    ## One line of §4.3, as data.
    kind*: CommandKind
    name*: string
      ## §4.3's spelling after the `:`, verbatim. For the two `info`
      ## commands this is the whole two-word phrase, because that is what the
      ## document publishes.
    alias*: string
      ## §4.3's `(alias: x)`, or "" where the document names none.
    argument*: string
      ## §4.3's own placeholder, verbatim — `<line|func>`, `<tick>`, `<expr>`,
      ## `<number>`, `<var>`, `<dark|light>` — or "".
    summary*: string
      ## §4.3's own comment, verbatim, WITHOUT the trailing `(alias: …)`.
    need*: ArgumentNeed

  CommandStatus* = enum
    ## What `parseCommand` made of the line. Every value but `csOk` carries a
    ## message; see this module's header on why none of them is silence.
    csOk = "ok"
    csEmpty = "empty"
    csUnknown = "unknown-command"
    csMissingArgument = "missing-argument"
    csBadArgument = "bad-argument"

  CommandInvocation* = object
    ## WHAT A LINE MEANS, with the typed spelling deliberately absent.
    ##
    ## `:next 3` and `:n 3` must be one thing, and CTUI-10 asks the suite to
    ## assert that "the spelled-out form and its alias produce identical
    ## state". Keeping the user's spelling in this value would make the two
    ## unequal by construction and the assertion would have to compare fields
    ## by hand — which is how such an assertion stops covering the field
    ## somebody adds next. The spelling lives in `message` when it matters,
    ## which is exactly when the command was NOT recognised.
    status*: CommandStatus
    kind*: CommandKind
    argument*: string
      ## Stripped. Empty for a command §4.3 gives no placeholder.
    message*: string
      ## Non-empty for every status but `csOk`.

  DispatchStatus* = enum
    ## What `dispatchAction` DID. Reported rather than inferred, for
    ## `modal_state`'s reason: "nothing happened" and "refused" are different
    ## answers and only one of them may make a status bar complain.
    drDone = "done"
      ## The action ran and the debugger (or the ViewModel) moved.
    drPaneLocal = "caller-owned"
      ## §4.2 binds it and it does not touch the SESSION: it acts on the
      ## focused pane (scrolling, expanding a node, moving focus, maximising)
      ## or on the caller's own modal state and prompt (`:`, `/`, `?`, `Esc`,
      ## `Enter`, `Backspace`, `i`, `Ctrl+p`, `n` / `N`). `keymap.nim`'s header
      ## states that delivering such an action is the caller's job — CTUI-9
      ## owns the modal machine and CTUI-11 will own the pane wiring — so this
      ## dispatch SAYS so rather than pretending to have done it.
    drUnavailable = "unavailable"
      ## The ViewModel is not wired, or it REFUSED — `canStepBackward` is
      ## false at tick 0, and a step that cannot succeed must not report done.
    drUnsupported = "unsupported"
      ## Nothing in this workspace implements it. `:info registers` and
      ## `:theme`; §4.2's `m` (View Memory Dump), which CTUI-7 measured has no
      ## `readMemory` arm and `address = -1` on every variable.
    drRejected = "rejected"
      ## The argument was missing, malformed or out of range.

  DispatchResult* = object
    status*: DispatchStatus
    action*: KeyAction
    detail*: string
      ## Always non-empty. What the status bar shows and what a failure names.

  FunctionSite* = object
    ## A named function and where it starts, as the HOST resolved it.
    ##
    ## `:break <func>` needs a `(path, line)` for a name, and no ViewModel in
    ## this layer owns that map: `ct/load-calltrace-section`'s rows carry a name
    ## and a tick, and turning a tick into a location is a seek. So the host
    ## resolves it — the same shape as CTUI-5's points, CTUI-6's frames and
    ## CTUI-8's event pages.
    name*: string
    path*: string
    line*: int

  CommandContext* = object
    ## The ambient facts a command needs about WHERE the debugger is. Values,
    ## read by the caller from the session it owns.
    file*: string
    line*: int
    tick*: uint64
    frameCount*: int
    targets*: TimelineTargets
      ## CTUI-8's `[`, `]`, `{`, `}` and `t <tick>` landing sites, and the
      ## recording's bounds — which is what `goto` clamps against and what
      ## `g``g` / `G` seek to.
    selectedVariable*: string
      ## What `o` and `:origin` with no argument act on: §4.2's "the
      ## variable/expression under cursor".
    functions*: seq[FunctionSite]

  CommandServices* = object
    ## The seams no ViewModel owns. Every field may be nil, and a nil one makes
    ## its command REPORT that it is not wired — see this module's header.
    setBreakpoint*: proc(path: string; line: int): bool {.closure.}
    runTracepoint*: proc(request: TracepointRequest): int {.closure.}
      ## Returns the number of hits the sweep answered.
    threads*: proc(): JsonNode {.closure.}
      ## The DAP `threads` response BODY, unmodified — CTUI-6's
      ## `call_stack_binding.threadsFrom` is what reads it.
    registers*: proc(): seq[(string, string)] {.closure.}
    setTheme*: proc(name: string): bool {.closure.}
    quit*: proc() {.closure.}

  Dispatcher* = object
    ## Everything an action can reach. A field left nil answers
    ## `drUnavailable`, by name, rather than crashing — a TUI that segfaulted
    ## on an unwired pane would lose the terminal it was restoring.
    controls*: DebugControlsVM
    timeline*: TimelineVM
    calltrace*: CalltraceVM
    state*: StateVM
    origin*: OriginChainVM
    originNav*: ref OriginNavigator
      ## §4.2's `o` / `O` walk, which is STATE and therefore cannot live in a
      ## stateless dispatch. A `ref` so `dispatchAction` — which takes the
      ## dispatcher by value, as every other caller wants — can advance it.
      ##
      ## Nil is legal and makes `o` report; a front-end that has not created a
      ## navigator has not enabled origin navigation.
    services*: CommandServices

  CommandOutcome* = object
    ## What running one line did, whole.
    invocation*: CommandInvocation
    dispatch*: DispatchResult
    message*: string
      ## NEVER EMPTY. See this module's header, contract 2.
    lines*: seq[string]
      ## Multi-line output — `:info threads`, `:info registers`.
    tracepoint*: TracepointRequest
    hasTracepoint*: bool
      ## True when `:tracepoint` composed a request the host should sweep.

const
  CommandPrefix* = ':'
    ## §4.2's "Open Command Prompt". Accepted at the head of a line and
    ## stripped, so `runCommand` takes what a `:` prompt hands it either way.

  ThemeNames* = ["dark", "light"]
    ## §4.3's `<dark|light>`, exactly.

  InfoVerb* = "info"
  InfoSubcommands* = ["threads", "registers"]

  NoThemeSurfaceNote* =
    "no theme registry is wired: every style in app/views/ is a `const " &
    "CellStyle` literal, so there is nothing for a theme to switch"
  NoRegisterSurfaceNote* =
    "no register surface exists in this workspace: dap_server.rs's " &
    "handle_request has no register arm and no ViewModel carries one"
  NoMemorySurfaceNote* =
    "no readMemory arm and address = -1 on every variable (CTUI-7)"

  Spec43Commands*: seq[CommandSpec] = @[
    CommandSpec(kind: cmdStep, name: "step", alias: "s", argument: "",
                need: anNone,
                summary: "Step into next instruction/source line"),
    CommandSpec(kind: cmdNext, name: "next", alias: "n", argument: "",
                need: anNone,
                summary: "Step over next instruction/source line"),
    CommandSpec(kind: cmdReverseStep, name: "reverse-step", alias: "rs",
                argument: "", need: anNone,
                summary: "Reverse step into previous instruction"),
    CommandSpec(kind: cmdReverseNext, name: "reverse-next", alias: "rn",
                argument: "", need: anNone,
                summary: "Reverse step over previous instruction"),
    CommandSpec(kind: cmdContinue, name: "continue", alias: "c", argument: "",
                need: anNone,
                summary: "Continue forward to next breakpoint"),
    CommandSpec(kind: cmdReverseContinue, name: "reverse-continue", alias: "rc",
                argument: "", need: anNone,
                summary: "Continue backward to previous breakpoint"),
    CommandSpec(kind: cmdBreak, name: "break", alias: "b",
                argument: "<line|func>", need: anRequired,
                summary: "Set breakpoint at line or function name"),
    CommandSpec(kind: cmdTracepoint, name: "tracepoint", alias: "",
                argument: "<expr>", need: anRequired,
                summary: "Set post-hoc tracepoint on expression or variable"),
    CommandSpec(kind: cmdFrame, name: "frame", alias: "f",
                argument: "<number>", need: anRequired,
                summary: "Switch active frame to frame index <number>"),
    CommandSpec(kind: cmdGoto, name: "goto", alias: "", argument: "<tick>",
                need: anRequired,
                summary: "Seek directly to time coordinate <tick>"),
    CommandSpec(kind: cmdOrigin, name: "origin", alias: "o", argument: "<var>",
                need: anRequired,
                summary: "Query where variable <var> was computed"),
    CommandSpec(kind: cmdPrint, name: "print", alias: "p", argument: "<expr>",
                need: anRequired,
                summary: "Evaluate and print expression in current context"),
    CommandSpec(kind: cmdInfoThreads, name: "info threads", alias: "",
                argument: "", need: anNone,
                summary: "List all recorded threads"),
    CommandSpec(kind: cmdInfoRegisters, name: "info registers", alias: "",
                argument: "", need: anNone,
                summary: "Display register values at current step"),
    CommandSpec(kind: cmdTheme, name: "theme", alias: "",
                argument: "<dark|light>", need: anRequired,
                summary: "Switch UI theme dynamically"),
    CommandSpec(kind: cmdQuit, name: "quit", alias: "q", argument: "",
                need: anNone, summary: "Exit CodeTracer TUI"),
  ]

  CommandOnlyKinds*: seq[CommandKind] = @[
    cmdTracepoint, cmdFrame, cmdPrint, cmdInfoThreads, cmdInfoRegisters,
    cmdTheme,
  ]
    ## The §4.3 commands §4.2 binds no key to. Named as a list rather than
    ## derived from `keyActionFor`'s `else` branch, so a seventh cannot appear
    ## by someone forgetting an arm: the suite asserts this list and
    ## `keyActionFor` agree in BOTH directions.

# ---------------------------------------------------------------------------
# The table, as queries
# ---------------------------------------------------------------------------

proc commandSpec*(kind: CommandKind): CommandSpec =
  ## §4.3's row for `kind`. Raises rather than returning a default: a kind with
  ## no row would make every message about it empty, which contract 2 forbids.
  for spec in Spec43Commands:
    if spec.kind == kind:
      return spec
  raise newException(KeyError, "no §4.3 row for command kind " & $kind)

proc commandNames*(): seq[string] =
  ## Every spelling a user may type, names and aliases, in §4.3's order.
  ## The completion source; see `app/views/command_line.nim`.
  result = @[]
  for spec in Spec43Commands:
    result.add spec.name
    if spec.alias.len > 0:
      result.add spec.alias

proc keyActionFor*(kind: CommandKind): (bool, KeyAction) =
  ## The §4.2 action this §4.3 command IS, when §4.2 binds one.
  ##
  ## THE JOIN BETWEEN THE TWO PUBLISHED TABLES, and the reason `runCommand`
  ## contains no stepping code of its own.
  case kind
  of cmdStep: (true, kaStepInto)
  of cmdNext: (true, kaStepOver)
  of cmdReverseStep: (true, kaReverseStepInto)
  of cmdReverseNext: (true, kaReverseStepOver)
  of cmdContinue: (true, kaContinue)
  of cmdReverseContinue: (true, kaReverseContinue)
  of cmdBreak: (true, kaToggleBreakpoint)
  of cmdGoto: (true, kaSeekToTick)
  of cmdOrigin: (true, kaValueOrigin)
  of cmdQuit: (true, kaQuit)
  of cmdTracepoint, cmdFrame, cmdPrint, cmdInfoThreads, cmdInfoRegisters,
     cmdTheme:
    (false, kaNone)

proc lookupCommand*(word: string): (bool, CommandKind, bool) =
  ## `(found, kind, wasAlias)` for one typed verb. Case-sensitive — see the
  ## module header.
  for spec in Spec43Commands:
    if spec.name == word:
      return (true, spec.kind, false)
    if spec.alias.len > 0 and spec.alias == word:
      return (true, spec.kind, true)
  (false, cmdStep, false)

# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

proc unknownMessage(word: string): string =
  "unknown command `" & word & "` — type :quit to exit, or press Ctrl+p for " &
    "the command palette"

proc parseCommand*(line: string): CommandInvocation =
  ## One `:` line into what it MEANS. Validates the argument, so a command that
  ## reaches `dispatchAction` has an argument that command can use.
  var text = line.strip()
  if text.len > 0 and text[0] == CommandPrefix:
    text = text[1 .. ^1].strip()
  if text.len == 0:
    return CommandInvocation(status: csEmpty, kind: cmdStep, argument: "",
                             message: "nothing to run")

  let fields = text.splitWhitespace()
  var verb = fields[0]
  var rest = fields[1 .. ^1]

  # `info` is the one two-word command §4.3 publishes, so the verb is two
  # fields there and one everywhere else. Handled BEFORE the lookup rather than
  # by a special case inside it, so `info` alone reports what it is missing.
  if verb == InfoVerb:
    if rest.len == 0:
      return CommandInvocation(
        status: csMissingArgument, kind: cmdInfoThreads, argument: "",
        message: "`info` needs a subcommand: " & InfoSubcommands.join(" or "))
    if rest[0] notin InfoSubcommands:
      return CommandInvocation(
        status: csBadArgument, kind: cmdInfoThreads, argument: rest[0],
        message: "`info " & rest[0] & "` is not a command — §4.3 publishes " &
          InfoSubcommands.join(" and "))
    verb = InfoVerb & " " & rest[0]
    rest = rest[1 .. ^1]

  let (found, kind, _) = lookupCommand(verb)
  if not found:
    return CommandInvocation(status: csUnknown, kind: cmdStep, argument: "",
                             message: unknownMessage(fields[0]))

  let spec = commandSpec(kind)
  let argument = rest.join(" ").strip()

  if spec.need == anRequired and argument.len == 0:
    return CommandInvocation(
      status: csMissingArgument, kind: kind, argument: "",
      message: ":" & spec.name & " needs " & spec.argument & " — " &
        spec.summary)

  # Per-command argument validation. Each rejection names the argument it was
  # given, so a mistyped tick is distinguishable from a tick out of range.
  case kind
  of cmdGoto:
    try:
      let tick = parseBiggestUInt(argument)
      return CommandInvocation(status: csOk, kind: kind,
                               argument: $tick, message: "")
    except ValueError:
      return CommandInvocation(
        status: csBadArgument, kind: kind, argument: argument,
        message: ":goto takes a tick, and `" & argument & "` is not a number")
  of cmdFrame:
    try:
      let index = parseInt(argument)
      if index < 0:
        return CommandInvocation(
          status: csBadArgument, kind: kind, argument: argument,
          message: ":frame takes a frame index and `" & argument &
            "` is negative")
      return CommandInvocation(status: csOk, kind: kind, argument: $index,
                               message: "")
    except ValueError:
      return CommandInvocation(
        status: csBadArgument, kind: kind, argument: argument,
        message: ":frame takes a frame index, and `" & argument &
          "` is not a number")
  of cmdTheme:
    if argument notin ThemeNames:
      return CommandInvocation(
        status: csBadArgument, kind: kind, argument: argument,
        message: ":theme takes " & ThemeNames.join(" or ") & ", not `" &
          argument & "`")
    return CommandInvocation(status: csOk, kind: kind, argument: argument,
                             message: "")
  else:
    discard

  CommandInvocation(status: csOk, kind: kind, argument: argument, message: "")

# ---------------------------------------------------------------------------
# THE DISPATCH
# ---------------------------------------------------------------------------

proc done(action: KeyAction; detail: string): DispatchResult =
  DispatchResult(status: drDone, action: action, detail: detail)

proc unavailable(action: KeyAction; detail: string): DispatchResult =
  DispatchResult(status: drUnavailable, action: action, detail: detail)

proc unsupported(action: KeyAction; detail: string): DispatchResult =
  DispatchResult(status: drUnsupported, action: action, detail: detail)

proc rejected(action: KeyAction; detail: string): DispatchResult =
  DispatchResult(status: drRejected, action: action, detail: detail)

proc paneLocal(action: KeyAction): DispatchResult =
  DispatchResult(status: drPaneLocal, action: action,
                 detail: "delivered to the focused pane")

proc seekWithin(d: Dispatcher; ctx: CommandContext; action: KeyAction;
                tick: uint64; what: string): DispatchResult =
  ## Every seek in this module, through CTUI-8's ONE seek.
  ##
  ## `timeline_binding.seekTo` is the only call site of `TimelineVM.seek` in
  ## `app/`, and this is the only call site of `seekTo` — so "exactly one goto
  ## per action" stays a property a test can count rather than a convention.
  if d.timeline.isNil:
    return unavailable(action, "no TimelineVM is wired, so " & what &
                       " has nothing to seek")
  let clamped = clampToBounds(tick, ctx.targets)
  seekTo(d.timeline, clamped)
  done(action, what & " to tick " & $clamped &
       (if clamped != tick: " (clamped from " & $tick & ")" else: ""))

proc stepWith(d: Dispatcher; action: KeyAction; forward: bool;
              what: string): DispatchResult =
  ## The eight §4.2 stepping actions, each through `DebugControlsVM`'s own
  ## action proc, with the VM's own `can*` memo consulted FIRST.
  ##
  ## The memo is what makes a refusal honest: `canStepBackward` is false at the
  ## start of a recording and on a live session, and a dispatch that called
  ## `stepBackward` anyway would report `drDone` for a move that the VM
  ## silently declined to make.
  if d.controls.isNil:
    return unavailable(action, "no DebugControlsVM is wired, so " & what &
                       " cannot reach the engine")
  let allowed =
    case action
    of kaContinue: d.controls.canContinue.val
    of kaReverseContinue: d.controls.canReverseContinue.val
    else:
      if forward: d.controls.canStepForward.val
      else: d.controls.canStepBackward.val
  if not allowed:
    return unavailable(action, what & " is not available here: " &
                       d.controls.statusText.val)
  case action
  of kaStepOver: d.controls.stepForward()
  of kaReverseStepOver: d.controls.stepBackward()
  of kaStepInto: d.controls.stepIn()
  of kaReverseStepInto: d.controls.reverseStepIn()
  of kaStepOut: d.controls.stepOut()
  of kaReverseStepOut: d.controls.reverseStepOut()
  of kaContinue: d.controls.continueExecution()
  of kaReverseContinue: d.controls.reverseContinue()
  else:
    return rejected(action, what & " is not a stepping action")
  done(action, what)

proc dispatchOrigin(d: Dispatcher; ctx: CommandContext;
                    action: KeyAction; argument: string): DispatchResult =
  ## §4.2's `o`, and §4.3's `:origin <var>`. THE HEADLINE FEATURE.
  ##
  ## THREE ARMS, IN ORDER, AND THE ORDER IS THE WHOLE DESIGN:
  ##
  ##   1. The navigator already answers for this (variable, tick) — so `o` is a
  ##      step DEEPER into a chain already in hand: advance and seek.
  ##   2. The ViewModel holds a chain for this variable and is no longer
  ##      loading — so the asynchronous query has LANDED: adopt it, advance and
  ##      seek.
  ##   3. Otherwise — issue `ct/originChain` and report the PENDING state.
  ##
  ## Arm 2 is what makes the asynchrony invisible to the caller: a host that
  ## pumps the `ct/updated-origin-chain` event into the ViewModel (see
  ## `origin_binding.applyOriginEvents`) and then RE-ENTERS THIS SAME DISPATCH
  ## completes the jump. There is no completion callback, no second entry point
  ## and no second seek — which is CTUI-10's first contract applied to the one
  ## action that is genuinely asynchronous.
  let variable = if argument.len > 0: argument else: ctx.selectedVariable
  if variable.len == 0:
    return rejected(action,
      "no variable selected — §4.2's `o` acts on the variable under the " &
      "cursor, and `:origin` takes one by name")
  if d.origin.isNil:
    return unavailable(action, "no OriginChainVM is wired")
  if d.originNav.isNil:
    return unavailable(action,
      "no origin navigator is wired, so there is nowhere to record the walk " &
      "`O` returns through")

  # ---- ARM 1: one hop deeper into the chain in hand ------------------------
  if d.originNav[].answersFor(variable, ctx.tick):
    let (moved, step) = d.originNav[].advance()
    if not moved:
      return unavailable(action, exhaustedNotification(d.originNav[]))
    let seeked = seekWithin(d, ctx, action, step.tick,
                            variable & " " & describeKind(step.kind) & " " &
                            step.sourceExpr.strip())
    if seeked.status != drDone:
      return seeked
    return done(action, originNotification(d.originNav[], oqReady))

  # ---- ARM 2: the asynchronous answer has landed ---------------------------
  let held = d.origin.activeChain.val
  if not d.origin.loading.val and held.isSome and
     held.get().queryVariable == variable:
    d.originNav[].adopt(held.get(), variable, ctx.tick)
    let (moved, step) = d.originNav[].advance()
    if not moved:
      return unavailable(action, exhaustedNotification(d.originNav[]))
    let seeked = seekWithin(d, ctx, action, step.tick,
                            variable & " " & describeKind(step.kind) & " " &
                            step.sourceExpr.strip())
    if seeked.status != drDone:
      return seeked
    return done(action, originNotification(d.originNav[], oqReady))

  # ---- ARM 3: ask, and say that we are asking ------------------------------
  beginOriginQuery(d.origin, variable,
                   Location(file: ctx.file, line: ctx.line), -1)
  done(action, OriginPendingText & " " & variable)

proc dispatchReverseOrigin(d: Dispatcher; ctx: CommandContext;
                           action: KeyAction): DispatchResult =
  ## §4.2's `O`. Back the way `o` came — see `origin_binding.nim`'s header on
  ## why that is the only reading under which the two keys are inverses.
  if d.originNav.isNil:
    return unavailable(action, "no origin navigator is wired")
  let (moved, tick) = d.originNav[].retreat()
  if not moved:
    return unavailable(action, OriginAtQueryText)
  let seeked = seekWithin(d, ctx, action, tick, "back along the origin chain")
  if seeked.status != drDone:
    return seeked
  done(action, originNotification(d.originNav[], oqReady))

proc dispatchAction*(d: Dispatcher; ctx: CommandContext; action: KeyAction;
                     argument = ""): DispatchResult =
  ## THE ONE DISPATCH. Every §4.2 keybinding and every §4.3 command that §4.2
  ## also binds arrives here, and this is the only proc under `app/` that names
  ## a `DebugControlsVM` action proc.
  ##
  ## Total over `KeyAction` by construction: the `case` has no `else`, so a
  ## member added to §4.2 tomorrow fails to compile here rather than falling
  ## through into silence.
  case action
  of kaNone:
    rejected(action, "nothing to dispatch")

  # ---- §4.2 Omniscient Stepping -----------------------------------------
  of kaStepOver: stepWith(d, action, true, "step over")
  of kaReverseStepOver: stepWith(d, action, false, "reverse step over")
  of kaStepInto: stepWith(d, action, true, "step into")
  of kaReverseStepInto: stepWith(d, action, false, "reverse step into")
  of kaStepOut: stepWith(d, action, true, "step out")
  of kaReverseStepOut: stepWith(d, action, false, "reverse step out")
  of kaContinue: stepWith(d, action, true, "continue")
  of kaReverseContinue: stepWith(d, action, false, "reverse continue")

  # ---- §4.2 Time-Travel Seeking -----------------------------------------
  of kaPrevCall:
    let (found, tick) = prevBefore(ctx.targets.callBoundaries, ctx.tick)
    if not found:
      unavailable(action, "no recorded call before tick " & $ctx.tick)
    else:
      seekWithin(d, ctx, action, tick, "previous call")
  of kaNextCall:
    let (found, tick) = nextAfter(ctx.targets.callBoundaries, ctx.tick)
    if not found:
      unavailable(action, "no recorded call after tick " & $ctx.tick)
    else:
      seekWithin(d, ctx, action, tick, "next call")
  of kaPrevMutation:
    let (found, tick) = prevBefore(ctx.targets.mutations, ctx.tick)
    if not found:
      unavailable(action, "no recorded mutation before tick " & $ctx.tick)
    else:
      seekWithin(d, ctx, action, tick, "previous mutation")
  of kaNextMutation:
    let (found, tick) = nextAfter(ctx.targets.mutations, ctx.tick)
    if not found:
      unavailable(action, "no recorded mutation after tick " & $ctx.tick)
    else:
      seekWithin(d, ctx, action, tick, "next mutation")
  of kaJumpToStart:
    seekWithin(d, ctx, action, ctx.targets.minTick, "start of the recording")
  of kaJumpToEnd:
    seekWithin(d, ctx, action, ctx.targets.maxTick, "end of the recording")
  of kaSeekToTick:
    if argument.len == 0:
      rejected(action, "seek to tick needs a tick")
    else:
      try:
        seekWithin(d, ctx, action, uint64(parseBiggestUInt(argument)), "goto")
      except ValueError:
        rejected(action, "`" & argument & "` is not a tick")

  # ---- §4.2 Value Origin Tracking ---------------------------------------
  of kaValueOrigin:
    dispatchOrigin(d, ctx, action, argument)
  of kaReverseOrigin:
    dispatchReverseOrigin(d, ctx, action)

  # ---- §4.2 Pane Navigation, Source Navigation, Variables Tree -----------
  # Every one of these acts on the FOCUSED PANE, not on the session. Delivering
  # it there is the pane wiring's job (CTUI-11) — `keymap.nim`'s header records
  # that, and `drPaneLocal` is this dispatch saying so.
  of kaFocusNextPane, kaFocusPrevPane, kaFocusLeft, kaFocusDown, kaFocusUp,
     kaFocusRight, kaSelectCallStack, kaSelectSource, kaSelectVariables,
     kaSelectTimeline, kaMaximizePane, kaScrollLineDown, kaScrollLineUp,
     kaHalfPageUp, kaHalfPageDown, kaCenterOnPointer, kaExpandNode,
     kaCollapseNode, kaToggleHexDec:
    paneLocal(action)

  # ---- The MODE and the PROMPT, which are CTUI-9's and this module's views' -
  # `:`, `/`, `?`, `Ctrl+p`, `Esc`, `Enter`, `Backspace` and `i` change the
  # modal state (`app/input/modal_state.applyModalEvent`) and the prompt
  # (`app/views/command_line.nim`); `n` / `N` walk `app/views/search.nim`'s
  # match ring. None of them reaches a ViewModel, and a dispatch that claimed
  # to have opened a prompt it does not own would be the second dispatch path
  # this module exists to prevent.
  of kaCommandPalette, kaSearchForward, kaSearchBackward, kaNextMatch,
     kaPrevMatch, kaOpenCommandPrompt, kaReturnToNormal, kaEnterInspect,
     kaCommitPrompt, kaPromptBackspace:
    paneLocal(action)

  of kaViewMemoryDump:
    unsupported(action, NoMemorySurfaceNote)

  of kaToggleBreakpoint:
    # §4.2's `F9` / `Space` and §4.3's `:break` are the same action. The line
    # comes from the argument when there is one and from the cursor when there
    # is not, which is exactly the difference between the two spellings.
    var path = ctx.file
    var line = ctx.line
    if argument.len > 0:
      var resolved = false
      try:
        line = parseInt(argument)
        resolved = true
      except ValueError:
        for site in ctx.functions:
          if site.name == argument:
            path = site.path
            line = site.line
            resolved = true
            break
      if not resolved:
        return rejected(action,
          "`" & argument & "` is neither a line number nor a recorded " &
          "function in this trace")
    if path.len == 0 or line <= 0:
      return rejected(action, "no line to place a breakpoint on")
    if d.services.setBreakpoint.isNil:
      return unavailable(action,
        "no breakpoint service is wired, so " & path & ":" & $line &
        " was not sent to the engine")
    if d.services.setBreakpoint(path, line):
      done(action, "breakpoint at " & path & ":" & $line)
    else:
      unavailable(action, "the engine refused a breakpoint at " & path & ":" &
                  $line)

  of kaQuit:
    if d.services.quit.isNil:
      unavailable(action, "no quit service is wired")
    else:
      d.services.quit()
      done(action, "quit")

# ---------------------------------------------------------------------------
# The six §4.3-only commands
# ---------------------------------------------------------------------------

proc dispatchTracepoint(d: Dispatcher; ctx: CommandContext;
                        expression: string;
                        outcome: var CommandOutcome): DispatchResult =
  if ctx.file.len == 0 or ctx.line <= 0:
    return rejected(kaNone, "no source position to place a tracepoint on")
  let draft = initTracepointDraft(path = ctx.file, line = ctx.line,
                                  expression = expression)
  if not draft.isComplete():
    return rejected(kaNone,
      "a tracepoint needs a path, a line and an expression — CTUI-8's " &
      "`isComplete` refused this draft")
  outcome.tracepoint = requestFor(draft)
  outcome.hasTracepoint = true
  if d.services.runTracepoint.isNil:
    return unavailable(kaNone,
      "composed a tracepoint on `" & expression & "` at " & ctx.file & ":" &
      $ctx.line & ", but no sweep service is wired to run it")
  let hits = d.services.runTracepoint(outcome.tracepoint)
  done(kaNone, "tracepoint `" & expression & "` at " & ctx.file & ":" &
       $ctx.line & " — " & $hits & " hit(s)")

proc dispatchFrame(d: Dispatcher; ctx: CommandContext;
                   index: int): DispatchResult =
  if d.calltrace.isNil:
    return unavailable(kaNone, "no CalltraceVM is wired")
  if ctx.frameCount <= 0:
    return unavailable(kaNone, "no stack is loaded, so there is no frame " &
                       $index)
  if index >= ctx.frameCount:
    return rejected(kaNone, "frame " & $index & " is out of range: the stack " &
                    "has " & $ctx.frameCount & " frame(s)")
  publishInspectionCursor(d.calltrace, index)
  done(kaNone, "frame " & $index)

proc dispatchPrint(d: Dispatcher; expression: string): DispatchResult =
  ## `:print <expr>`. `StateVM.addWatch` is a REAL evaluator: the engine
  ## evaluates every watch expression inside `ct/load-locals`
  ## (`dap_handler.rs`'s `l.is_watch` arm) and answers it as a variable row.
  ## So the value appears in the variables pane on the next locals load, and
  ## the caller reads it there rather than from a second wire call.
  if d.state.isNil:
    return unavailable(kaNone, "no StateVM is wired")
  d.state.addWatch(expression)
  done(kaNone, "watching `" & expression &
       "` — its value appears with the next locals load")

proc dispatchInfoThreads(d: Dispatcher;
                         outcome: var CommandOutcome): DispatchResult =
  if d.services.threads.isNil:
    return unavailable(kaNone,
      "no threads service is wired, so DAP `threads` was not sent")
  let body = d.services.threads()
  let threads = threadsFrom(body)
  outcome.lines = @[]
  for t in threads:
    outcome.lines.add "  " & $t.id & "  " & t.name
  if threads.len == 0:
    return unavailable(kaNone, "the engine reported no threads")
  done(kaNone, $threads.len & " recorded thread(s)")

proc dispatchInfoRegisters(d: Dispatcher;
                           outcome: var CommandOutcome): DispatchResult =
  if d.services.registers.isNil:
    return unsupported(kaNone, NoRegisterSurfaceNote)
  let regs = d.services.registers()
  outcome.lines = @[]
  for r in regs:
    outcome.lines.add "  " & r[0] & " = " & r[1]
  if regs.len == 0:
    return unavailable(kaNone, "the engine reported no registers")
  done(kaNone, $regs.len & " register(s)")

proc dispatchTheme(d: Dispatcher; name: string): DispatchResult =
  if d.services.setTheme.isNil:
    return unsupported(kaNone, NoThemeSurfaceNote)
  if d.services.setTheme(name):
    done(kaNone, "theme " & name)
  else:
    unavailable(kaNone, "the host refused the theme `" & name & "`")

# ---------------------------------------------------------------------------
# Running a line
# ---------------------------------------------------------------------------

proc runCommand*(d: Dispatcher; ctx: CommandContext;
                 line: string): CommandOutcome =
  ## §4.3, end to end. Parses, dispatches, and REPORTS — always.
  ##
  ## A command §4.2 binds does not appear below at all: it is looked up in
  ## `keyActionFor` and handed to `dispatchAction`, so the command form and the
  ## key form are one call. That is contract 1, and it is why this proc has ten
  ## fewer arms than §4.3 has commands.
  result = CommandOutcome(invocation: parseCommand(line),
                          dispatch: DispatchResult(), message: "", lines: @[],
                          tracepoint: TracepointRequest(),
                          hasTracepoint: false)
  if result.invocation.status != csOk:
    result.dispatch = rejected(kaNone, result.invocation.message)
    result.message = result.invocation.message
    return

  let kind = result.invocation.kind
  let argument = result.invocation.argument
  let (bound, action) = keyActionFor(kind)
  if bound:
    result.dispatch = dispatchAction(d, ctx, action, argument)
  else:
    result.dispatch =
      case kind
      of cmdTracepoint: dispatchTracepoint(d, ctx, argument, result)
      of cmdFrame: dispatchFrame(d, ctx, parseInt(argument))
      of cmdPrint: dispatchPrint(d, argument)
      of cmdInfoThreads: dispatchInfoThreads(d, result)
      of cmdInfoRegisters: dispatchInfoRegisters(d, result)
      of cmdTheme: dispatchTheme(d, argument)
      else:
        rejected(kaNone, "`" & $kind & "` is in CommandOnlyKinds but has no " &
                 "arm here — that is a defect in this file, not in the input")
  result.message = result.dispatch.detail

proc describeOutcome*(outcome: CommandOutcome): string =
  ## One line for the §3.3.6 notification area: the status and the detail.
  ## Used by `app/views/command_line.nim`, and by any caller that wants the
  ## failure kind visible rather than only its prose.
  case outcome.invocation.status
  of csOk:
    (if outcome.dispatch.status == drDone: ""
     else: $outcome.dispatch.status & ": ") & outcome.message
  else:
    $outcome.invocation.status & ": " & outcome.message

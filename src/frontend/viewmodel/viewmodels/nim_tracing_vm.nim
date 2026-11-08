## viewmodels/nim_tracing_vm.nim — tracing Nim's compile-time code from the
## editor: a macro's expansion, a `static:` block, a constant's initializer,
## and a NimScript file's evaluation, each producing a recording that opens
## in a new session tab.
##
## Spec: codetracer-pm `spec/Planned-Features/Nim-Compile-Time-Tracing-
## Milestones.md` (M6 `nim e --trace`, M9–M11 the language-server path and
## the desktop's action); `spec/GUI/Multi-Window-Tab-Management.md` "Which
## tab a replay opens in".
##
## Owns, for every front-end:
##
##   * WHICH ACTIONS THE CARET OFFERS — `availableNimTraceActions`, a pure
##     function of the document's lines and the caret. The static-block and
##     constant entries rest on a textual reading of the lines around the
##     caret (the compiler's query is authoritative; a false offer costs one
##     "not a static block" answer, a missing one hides the action);
##   * THE REQUEST — the operation each action is, the LSP command and
##     arguments the desktop's language-server route sends, the nimsuggest
##     query the native route types, the `nim e --trace` command line for an
##     evaluation — with ONE place deciding the line base
##     (`wirePositionOf`);
##   * ITS PROGRESS AND FAILURE as state a pane or a status line shows
##     (`NimTracingVM`): running, done with a recording, or failed — no
##     language server, not available here, not a macro call, not a static
##     block, a compile error, no recording produced;
##   * WHERE THE RECORDING OPENS — a new session tab, always
##     (`nimTracePlacement`): a trace of compile-time code is a second
##     recording to compare with the first, never a replacement of it.
##
## Refuses to own: running anything. The desktop sends the LSP request
## through its router (`ui/trace_macro`, `ui/trace_static`); the native
## front-ends run nimsuggest and `nim e` through `host/native_nim_tracer`.
##
## Pure: C and JavaScript backends.

import std/strutils

import ./trace_open

export trace_open

type
  NimTraceAction* = enum
    ntaMacro = "macro"
      ## The macro call at the caret, expanded under the tracer
      ## (nimsuggest's `traceExpand`, LSP `nim/traceExpandMacro`).
    ntaStaticBlock = "static-block"
      ## The `static:` block, `static(expr)` or `{.compileTime.}` proc body
      ## at the caret (nimsuggest's `tracestatic`, LSP
      ## `nim/traceStaticBlock`).
    ntaConstant = "constant"
      ## The `const` initializer at the caret — the same compiler entry
      ## point as a static block (`evalConstExprAux`), offered by its own
      ## name because that is how a reader of the code calls it.
    ntaEval = "eval"
      ## The whole NimScript file, run by `nim e --trace:<out>` (M6): a
      ## compile-time evaluation outside any macro or `static:` block.

  NimTracePhase* = enum
    ntpIdle = "idle"
    ntpRunning = "running"
    ntpDone = "done"
    ntpFailed = "failed"

  NimTraceFailure* = enum
    ntfNone = "none"
    ntfNoLanguageServer = "no-language-server"
      ## Neither the language server (desktop) nor nimsuggest / `nim`
      ## (native) is there to ask.
    ntfNotAvailable = "not-available"
      ## The caret is not on something this action traces (the offer's own
      ## answer, before anything is sent).
    ntfNotAMacro = "not-a-macro"
    ntfNotAStaticBlock = "not-a-static-block"
    ntfCompileError = "compile-error"
    ntfNoRecording = "no-recording"
      ## The tool answered, but named no recording, or one that is not there.
    ntfBusy = "busy"
      ## A trace is already running.

  NimTraceRequest* = object
    action*: NimTraceAction
    path*: string
      ## The source file, absolute.
    line*: int
      ## The caret's line, 1-based — the editor's numbering.
    column*: int
      ## The caret's column, 1-based.

  NimTracingVM* = ref object
    ## One editor's trace, in flight or settled.
    phase*: NimTracePhase
    request*: NimTraceRequest
    failure*: NimTraceFailure
    message*: string
      ## What the status line says now.
    tracePath*: string
      ## The recording the compiler wrote, once done.
    changed*: bool
      ## The state moved since the front-end last painted it.

const
  TraceMacroOperation* = "editor.trace-macro-at-cursor"
  TraceStaticBlockOperation* = "editor.trace-static-block-at-cursor"
  TraceConstantOperation* = "editor.trace-constant-at-cursor"
  TraceEvalOperation* = "editor.trace-eval"
  NimTraceOperations = [TraceMacroOperation, TraceStaticBlockOperation,
                         TraceConstantOperation, TraceEvalOperation]
    ## In `NimTraceAction` order.

  TraceMacroLabel = "Trace Macro Execution"
  TraceStaticBlockLabel = "Trace Static Block Execution"
    ## The desktop's two context-menu labels, unchanged.
  TraceConstantLabel = "Trace Constant Initializer"
  TraceEvalLabel = "Trace NimScript Evaluation"
  NimTraceLabels = [TraceMacroLabel, TraceStaticBlockLabel,
                     TraceConstantLabel, TraceEvalLabel]

  NimTracePaletteLabels* = ["Nim: Trace Macro at Cursor",
                            "Nim: Trace Static Block at Cursor",
                            "Nim: Trace Constant at Cursor",
                            "Nim: Trace NimScript Evaluation"]

  TraceMacroLspCommand = "nim/traceExpandMacro"
  TraceStaticLspCommand = "nim/traceStaticBlock"

  StaticScanLines = 200
    ## How far above the caret the offer looks for the construct enclosing
    ## it. A `static:` block or a `const` section longer than this is not
    ## offered from its far end.

  RoutineKeywords = ["proc", "func", "method", "iterator", "converter",
                     "template", "macro"]
  OtherTopLevel = ["type", "import", "from", "include", "export", "var",
                   "let", "when", "block", "if", "for", "while", "case"]

func nimTraceActionOfOperation*(operation: string): tuple[found: bool;
                                                  action: NimTraceAction] =
  for a in NimTraceAction:
    if NimTraceOperations[ord(a)] == operation:
      return (true, a)
  (false, ntaMacro)

func nimTraceOperationOf*(action: NimTraceAction): string =
  NimTraceOperations[ord(action)]

func nimTraceLabelOf*(action: NimTraceAction): string =
  NimTraceLabels[ord(action)]

func nimTracePaletteLabelOf*(action: NimTraceAction): string =
  NimTracePaletteLabels[ord(action)]

# ---------------------------------------------------------------------------
# The offer
# ---------------------------------------------------------------------------

func extractFilenameOf*(path: string): string =
  let at = max(path.rfind('/'), path.rfind('\\'))
  if at < 0: path else: path[at + 1 .. ^1]

func isNimScript(path: string): bool =
  path.toLowerAscii.endsWith(".nims")

func isNimSource*(path: string): bool =
  ## A `.nim` file, or a NimScript one: both hold compile-time code.
  let p = path.toLowerAscii
  p.endsWith(".nim") or p.endsWith(".nims")

func indentOf(line: string): int =
  for c in line:
    if c == ' ': inc result
    elif c == '\t': result += 2
    else: break

func codeOf(line: string): string =
  ## The line without its comment and surrounding blanks. A `#` inside a
  ## string literal is taken for a comment; the offer only reads keywords
  ## at the start of a line and a few tokens, so that costs nothing it uses.
  var inStr = false
  var cut = line.len
  for i, c in line:
    if c == '"': inStr = not inStr
    elif c == '#' and not inStr:
      cut = i
      break
  line[0 ..< cut].strip

func firstWord(code: string): string =
  var i = 0
  while i < code.len and (code[i].isAlphaNumeric or code[i] == '_'):
    inc i
  code[0 ..< i]

func isRoutineLine(code: string): bool =
  firstWord(code) in RoutineKeywords

func hasCompileTimePragma(code: string): bool =
  let c = code.replace(" ", "")
  "{.compileTime" in c or ",compileTime" in c

func opensStaticBlock(code: string): bool =
  ## `static:` (the block) — not `static[T]` or `static(expr)`.
  code.startsWith("static:") or code == "static :"

func hasStaticExpr(code: string): bool =
  "static(" in code.replace(" ", "")

func opensConst(code: string): bool =
  firstWord(code) == "const"

type
  CaretContext = enum
    ccNone, ccStatic, ccConstant

  TracedConstruct = object
    context: CaretContext
    line: int
      ## The 1-based line the compiler's query matches for it: the compiler
      ## installs the tracer on the evaluation whose node starts on the
      ## requested line (`vm.evalConstExprAux`), and a `static:` block's node
      ## starts at its FIRST STATEMENT, not at the `static:` keyword —
      ## measured with codetracer-nim's nimsuggest: `tracestatic` on the
      ## keyword's line answers no recording, on the statement's line it
      ## answers one.

func firstCodeLineAfter(lines: openArray[string]; line: int): int =
  ## The first non-blank line below the 1-based `line`, or `line`.
  for ln in line + 1 .. lines.len:
    if codeOf(lines[ln - 1]).len > 0:
      return ln
  line

func constructAt(lines: openArray[string]; line: int): TracedConstruct =
  ## What compile-time construct encloses the 1-based `line`, reading the
  ## caret's own line and then the lines above it whose indentation is
  ## SMALLER than everything read so far — the lines that can enclose it.
  ##
  ## `{.compileTime.}` routines are NOT offered: their bodies run when a
  ## compile-time evaluation calls them, and the compiler's query matches
  ## the evaluation by the line it starts on, so a caret in the body names
  ## nothing it can trace (measured: `tracestatic` on such a body answers no
  ## recording). A `{.compileTime.}` VARIABLE's initializer is an evaluation
  ## of its own and is offered.
  if line < 1 or line > lines.len:
    return TracedConstruct()
  let own = codeOf(lines[line - 1])
  if own.len == 0:
    # A blank line (or a comment) is in nothing a reader could point at.
    return TracedConstruct()
  # THE CARET'S OWN LINE first: a construct that starts here is the one.
  if opensStaticBlock(own):
    return TracedConstruct(context: ccStatic,
                           line: firstCodeLineAfter(lines, line))
  if isRoutineLine(own):
    # A routine's signature is not an evaluation, whatever encloses it.
    return TracedConstruct()
  if hasStaticExpr(own) or hasCompileTimePragma(own):
    return TracedConstruct(context: ccStatic, line: line)
  if opensConst(own):
    let rest = own[min(own.len, 5) .. ^1].strip
    # `const x = expr` is its own evaluation; a bare `const` opens a
    # section whose first entry is.
    return TracedConstruct(context: ccConstant,
                           line: (if rest.len > 0: line
                                  else: firstCodeLineAfter(lines, line)))
  var limit = indentOf(lines[line - 1])
  var inner = line
    ## The enclosing line read just before the current one: a const
    ## section's entry, once the section is found.
  var scanned = 0
  var ln = line - 1
  while ln >= 1 and scanned < StaticScanLines:
    inc scanned
    let raw = lines[ln - 1]
    let code = codeOf(raw)
    let at = ln
    dec ln
    if code.len == 0:
      continue
    let indent = indentOf(raw)
    if indent >= limit:
      continue
    limit = indent
    if opensStaticBlock(code):
      return TracedConstruct(context: ccStatic,
                             line: firstCodeLineAfter(lines, at))
    if opensConst(code):
      let rest = code[min(code.len, 5) .. ^1].strip
      return TracedConstruct(context: ccConstant,
                             line: (if rest.len > 0: at else: inner))
    if isRoutineLine(code) or indent == 0:
      # An ordinary routine, or a top-level statement that is none of the
      # above, encloses the caret: it runs at run time.
      return TracedConstruct()
    inner = at
  TracedConstruct()

func caretContext(lines: openArray[string]; line: int): CaretContext =
  constructAt(lines, line).context

func nimTraceTargetLine(action: NimTraceAction; lines: openArray[string];
                         line: int): int =
  ## The 1-based line a request for `action` at the caret's `line` names:
  ## for a static block or a constant, the line its evaluation starts on
  ## (`TracedConstruct.line`); for a macro call and an evaluation, the
  ## caret's.
  if action in {ntaStaticBlock, ntaConstant}:
    let c = constructAt(lines, line)
    if c.context != ccNone and c.line > 0:
      return c.line
  line

func availableNimTraceActions*(path: string; lines: openArray[string];
                               line, column: int): set[NimTraceAction] =
  ## The actions the caret at 1-based `line` of `path` offers.
  ##
  ##   * MACRO on any non-blank line of a Nim file: whether the word there
  ##     is a macro call is the compiler's to say, and it says it when asked;
  ##   * STATIC BLOCK inside a `static:` block, on a `static(expr)` or a
  ##     `{.compileTime.}` variable — NOT on a routine's line;
  ##   * CONSTANT inside a `const` declaration or section;
  ##   * EVAL anywhere in a NimScript (`.nims`) file.
  if not isNimSource(path):
    return {}
  if isNimScript(path):
    result.incl ntaEval
  if line >= 1 and line <= lines.len and codeOf(lines[line - 1]).len > 0:
    result.incl ntaMacro
  case caretContext(lines, line)
  of ccStatic: result.incl ntaStaticBlock
  of ccConstant: result.incl ntaConstant
  of ccNone: discard

func unavailableReason*(action: NimTraceAction; path: string;
                        line: int): string =
  ## Why `action` is inert at the caret — the status line's words.
  let where = extractFilenameOf(path) & ":" & $line
  if not isNimSource(path):
    return nimTraceLabelOf(action) & " works in Nim files; " &
           (if path.len == 0: "the editor has no file" else: path & " is not one")
  case action
  of ntaMacro:
    "Trace Macro Execution needs a macro call; " & where & " is blank"
  of ntaStaticBlock:
    "Trace Static Block Execution works inside a static: block or on a " &
      "static(expr); " & where & " is neither"
  of ntaConstant:
    "Trace Constant Initializer works inside a const declaration; " &
      where & " is not in one"
  of ntaEval:
    "Trace NimScript Evaluation runs a .nims file; " &
      extractFilenameOf(path) & " is not one"

# ---------------------------------------------------------------------------
# The request
# ---------------------------------------------------------------------------

func wirePositionOf*(request: NimTraceRequest): tuple[line, character: int] =
  ## THE LINE BASE, decided once: the editor's 1-based caret as the
  ## zero-based LSP position every route starts from. The desktop sends it
  ## as is; the native route types `line + 1` to nimsuggest, which numbers
  ## lines from 1 and columns from 0 (as the language server does when it
  ## forwards the same request, `routes.traceStaticBlock`).
  (line: max(0, request.line - 1), character: max(0, request.column - 1))

func lspCommandOf*(action: NimTraceAction): string =
  ## The `workspace/executeCommand` the language server answers, or "" for
  ## an evaluation (the language server runs no NimScript).
  case action
  of ntaMacro: TraceMacroLspCommand
  of ntaStaticBlock, ntaConstant: TraceStaticLspCommand
  of ntaEval: ""

func fileUriOf*(path: string): string =
  "file://" & path

func nimsuggestCommandOf*(request: NimTraceRequest): string =
  ## The line typed to `nimsuggest --stdin`: `traceExpand` or `tracestatic`
  ## at the caret, line 1-based, column 0-based.
  let at = wirePositionOf(request)
  let verb = if request.action == ntaMacro: "traceExpand" else: "tracestatic"
  verb & " " & request.path & ":" & $(at.line + 1) & ":" & $at.character

func evalArgumentsOf*(request: NimTraceRequest; output: string;
                      options: openArray[string] = []): seq[string] =
  ## `nim e --trace:<output> [options] <file>` — M6's evaluation, recorded.
  ## Options go before the file: after it they would be the script's own.
  result = @["e", "--hints:off", "--trace:" & output]
  result.add options
  result.add request.path

func nimsuggestTracePath*(output: string): string =
  ## The recording a `traceExpand` / `tracestatic` answer names: the
  ## `doc` column of its first result line (nimsuggest's tab-separated
  ## `Suggest`, the doc quoted), "" when none does.
  for raw in output.splitLines():
    # `--stdin` prompts with "> " before each command, on the line its
    # answer then starts.
    var line = raw
    while line.startsWith("> "):
      line = line[2 .. ^1]
    let fields = line.split('\t')
    if fields.len >= 8 and fields[0] in ["traceExpand", "traceStatic"]:
      var doc = fields[7]
      if doc.len >= 2 and doc[0] == '"' and doc[^1] == '"':
        doc = doc[1 .. ^2]
      doc = doc.replace("\\\\", "\\").replace("\\\"", "\"")
      if doc.len > 0:
        return doc
  ""

func nimsuggestAnswered*(output: string): bool =
  ## Whether nimsuggest has printed its answer to the trace query (the
  ## result line, with or without a recording in it).
  for raw in output.splitLines():
    var line = raw
    while line.startsWith("> "):
      line = line[2 .. ^1]
    if line.startsWith("traceExpand\t") or line.startsWith("traceStatic\t"):
      return true
  false

func nimTracePlacement*(): TraceOpenPolicy =
  ## A trace of compile-time code opens in a NEW session tab — the default
  ## of "Which tab a replay opens in", without the setting's alternative:
  ## nothing about the session in the current tab is a previous run of the
  ## same trace, so replacing it would only lose it.
  topNewTab

func traceOpenRequestOf*(tracePath: string): TraceOpenRequest =
  TraceOpenRequest(tracePath: tracePath, policy: nimTracePlacement())

# ---------------------------------------------------------------------------
# Failures, as the tools word them
# ---------------------------------------------------------------------------

func classifyFailure(action: NimTraceAction; message: string): NimTraceFailure =
  ## The language server's (or the compiler's) refusal, read: the words
  ## `routes.traceExpandMacro` / `routes.traceStaticBlock` raise, and the
  ## compiler's `Error:` lines.
  let m = message.toLowerAscii
  if "nimsuggest is not available" in m or "not connected" in m or
     "no nimsuggest" in m:
    return ntfNoLanguageServer
  if "error:" in m:
    return ntfCompileError
  if "no trace result" in m or "not a macro" in m or
     "not a static" in m or "compiletime" in m:
    return (if action == ntaMacro: ntfNotAMacro else: ntfNotAStaticBlock)
  if "empty trace path" in m:
    return ntfNoRecording
  ntfCompileError

func failureText(action: NimTraceAction; failure: NimTraceFailure;
                  detail = ""): string =
  case failure
  of ntfNone: ""
  of ntfNoLanguageServer:
    nimTraceLabelOf(action) & ": " &
      (if detail.len > 0: detail
       else: "no Nim language server is running to trace with")
  of ntfNotAvailable: detail
  of ntfNotAMacro: "No macro call found at this position."
  of ntfNotAStaticBlock:
    "No static block / const / compileTime body found at this position."
  of ntfCompileError:
    nimTraceLabelOf(action) & " failed" & (if detail.len > 0: ": " & detail else: "")
  of ntfNoRecording:
    nimTraceLabelOf(action) & " produced no recording" &
      (if detail.len > 0: ": " & detail else: "")
  of ntfBusy:
    "a Nim trace is already running"

# ---------------------------------------------------------------------------
# The state
# ---------------------------------------------------------------------------

proc newNimTracingVM*(): NimTracingVM =
  NimTracingVM(phase: ntpIdle)

func running*(vm: NimTracingVM): bool =
  not vm.isNil and vm.phase == ntpRunning

func progressText(action: NimTraceAction): string =
  case action
  of ntaMacro: "Tracing macro expansion..."
  of ntaStaticBlock: "Tracing static block execution..."
  of ntaConstant: "Tracing constant initializer..."
  of ntaEval: "Tracing NimScript evaluation..."

proc fail*(vm: NimTracingVM; failure: NimTraceFailure; detail = "") =
  vm.phase = ntpFailed
  vm.failure = failure
  vm.message = failureText(vm.request.action, failure, detail)
  vm.changed = true

proc begin*(vm: NimTracingVM; request: NimTraceRequest;
            lines: openArray[string]): bool =
  ## Start `request` — or refuse it, saying why, when the caret does not
  ## offer it or a trace is already running. True when it started: the
  ## front-end now sends it.
  if vm.running:
    vm.message = failureText(request.action, ntfBusy)
    vm.changed = true
    return false
  vm.request = request
  vm.tracePath = ""
  vm.failure = ntfNone
  if request.action notin availableNimTraceActions(request.path, lines,
                                                   request.line,
                                                   request.column):
    vm.fail(ntfNotAvailable, unavailableReason(request.action, request.path,
                                               request.line))
    return false
  # THE LINE THE COMPILER MATCHES, not the caret's (`nimTraceTargetLine`);
  # the column is the start of that line's code.
  let target = nimTraceTargetLine(request.action, lines, request.line)
  if target != request.line and target >= 1 and target <= lines.len:
    vm.request.line = target
    vm.request.column = indentOf(lines[target - 1]) + 1
  vm.phase = ntpRunning
  vm.message = progressText(request.action)
  vm.changed = true
  true

proc succeed*(vm: NimTracingVM; tracePath: string) =
  ## The compiler wrote `tracePath`; the front-end opens it
  ## (`traceOpenRequestOf`).
  if tracePath.len == 0:
    vm.fail(ntfNoRecording)
    return
  vm.phase = ntpDone
  vm.tracePath = tracePath
  vm.message = nimTraceLabelOf(vm.request.action) & ": recorded " &
               extractFilenameOf(tracePath)
  vm.changed = true

proc refuse*(vm: NimTracingVM; message: string) =
  ## The tool refused; `message` is its words.
  vm.fail(classifyFailure(vm.request.action, message), message)

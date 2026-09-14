## viewmodels/evidence_call_vm.nim
##
## AA-3 — recognising the agent's *evidence handoff* in a session transcript.
##
## `codetracer-specs/DeepReview/DeepReview-GUI.md` §2.1.1: "When the agent
## hands a review over, that handoff appears in the session as a tool call
## like any other.  It gets a **custom rendering** rather than the generic
## tool-call line, and it is **actionable**: selecting it loads the review
## dataset that call produced."
##
## The handoff is not a CodeTracer-specific protocol — RV-7 made it "two
## ordinary commands" a shell tool runs (`docs/agent-prompt/
## deepreview-evidence.md`):
##
## ```sh
## ct review collect --diff main..HEAD --recordings .ct/runs -o review.json
## ct agent evidence review.json
## ```
##
## so recognising it means recognising *those command lines* in the session's
## tool calls.  This module is that recogniser plus the fold that decides what
## became of the call, and it is deliberately pure — no DOM, no `cstring`, no
## signals — so every rule below is assertable on both Nim backends
## (`src/tests/gui/tests/agent-activity/evidence_call_vm_test.nim`, registered
## in `CoreViewModelGateTests`).
##
## ## Two rules that shape the whole module
##
## 1. **Only a tool call counts.**  The recogniser reads
##    `AgentActivityMessageEntry.toolName` — the tool's own invocation, which
##    the agent protocols fill in (`nim-agents`' `acpUpdateToAgentEvent` maps
##    ACP's `tool_call.title` onto it) — and never the prose in `content`.  An
##    agent that *writes* "next I'll run ct review collect" has collected
##    nothing, and turning that sentence into a clickable review would be the
##    fabricated-evidence failure this milestone family exists to prevent.
##    This is the same shape as AA-2's rule that a message becomes a run only
##    when it actually carries runner events.
##
## 2. **A command is evidence only when we can name its dataset.**  Every
##    accepted spelling below states its output path explicitly, so the
##    dataset a card points at is always one the agent typed, never one
##    inferred from a default.  `ct agent end-of-turn` is accepted *only* when
##    it carries `--output`, precisely because that flag has a default
##    (`agent_cli.DefaultHookOutputDir`, overridable from the environment) and
##    guessing it would be an unverifiable claim about where a file is.

import std/[options, strutils]

import ../store/types

type
  EvidenceCommandKind* = enum
    ## Which of RV-7's two commands this call is.  Kept apart because they
    ## mean different things to a reviewer: `collect` *produced* the dataset,
    ## `evidence` *handed it over*, and a session usually contains both.
    eckCollect = "collect"
    eckHandoff = "handoff"

  EvidenceCallState* = enum
    ## What the *tool call* did — a separate question from whether the dataset
    ## it names can be read (`EvidenceDatasetState`).
    ecsUnreported = "unreported"
      ## No update has reported an outcome for this call.  That covers a
      ## collect still in flight **and** a session that ended without ever
      ## saying how the call went; nothing in a transcript distinguishes the
      ## two, so the rendering states the fact it has rather than picking one.
    ecsFailed = "failed"
      ## The backend said the call failed.  Its own output is kept verbatim.
    ecsCompleted = "completed"

  EvidenceDatasetState* = enum
    ## What is known about the file the call named.  Filled in by the host
    ## (only the main process can read a file); the projection never invents
    ## a value here.
    edsUnknown = "unknown"
      ## Nobody has looked yet.  Renders no shape and offers nothing —
      ## "unknown" is not "missing" and must not be printed as either.
    edsReady = "ready"
    edsUnavailable = "unavailable"
      ## The file is gone, or would not read.  Carries the reader's own
      ## message, never one invented here.

  EvidenceDataset* = object
    ## The shape of a dataset, as far as it is known.
    ##
    ## `fileCount` is meaningful **only** under `edsReady`; a dataset that
    ## genuinely contains no files still prints "0 files", because the rule is
    ## about *absent* data rather than about zero being unprintable (the same
    ## distinction AA-2 drew for "0/5 passed").
    state*: EvidenceDatasetState
    fileCount*: int
    commit*: string
      ## Already abbreviated for display, or "" when the dataset names none.
    message*: string
      ## The reader's diagnostic for `edsUnavailable`; "" otherwise.

  EvidenceCall* = object
    ## One evidence handoff in the session feed.
    anchorId*: string
      ## The id of the message this card is painted *in place of*, exactly as
      ## `AgentTestRunEntry.anchorId` is — the message list stays the feed's
      ## ordering spine, so a handoff renders where it happened.
    toolCallId*: string
    kind*: EvidenceCommandKind
    command*: string
      ## The command line the session reported, verbatim.  Never a
      ## reconstructed one: a command CodeTracer invented would read as one
      ## that ran.
    datasetPath*: string
      ## The path the command named.  Never empty for a recognised call —
      ## see rule 2 in the module header.
    state*: EvidenceCallState
    failureText*: string
      ## The failing call's own output, or "".
    dataset*: EvidenceDataset

  EvidenceCommand* = object
    ## The result of recognising one command line.
    kind*: EvidenceCommandKind
    datasetPath*: string

proc `==`*(a, b: EvidenceDataset): bool {.noSideEffect.} =
  a.state == b.state and a.fileCount == b.fileCount and
    a.commit == b.commit and a.message == b.message

proc `==`*(a, b: EvidenceCall): bool {.noSideEffect.} =
  a.anchorId == b.anchorId and a.toolCallId == b.toolCallId and
    a.kind == b.kind and a.command == b.command and
    a.datasetPath == b.datasetPath and a.state == b.state and
    a.failureText == b.failureText and a.dataset == b.dataset

proc `==`*(a, b: EvidenceCommand): bool {.noSideEffect.} =
  a.kind == b.kind and a.datasetPath == b.datasetPath

# ---------------------------------------------------------------------------
# Reading a command line
# ---------------------------------------------------------------------------

type
  CommandLineDialect* = enum
    ## **Which shell wrote this command line.**
    ##
    ## A command line is just a string, and `\` means opposite things in the
    ## two families that produce one: a POSIX shell **escapes** the next
    ## character with it, while `cmd.exe` and PowerShell use it to **separate**
    ## path components and never escape with it at all.  The same bytes
    ## therefore have two correct readings, and no per-character rule can pick
    ## between them — `C:\out\` and a bash-escaped `C:\\out\\` are each
    ## unambiguous *given their producer* and mutually contradictory without
    ## one.  See `splitCommandLine`'s "Whose backslash is it?".
    ##
    ## So the dialect is a **parameter**, not a compile-time fact.  It is
    ## deliberately *not* `when defined(windows)`: the producer here is an
    ## agent session and the reader is whoever opens that session afterwards,
    ## which need not be the same machine — the reported case is precisely a
    ## dataset collected by an agent on Windows and opened in a CodeTracer
    ## running on Linux.  A compile-time switch would key the decision on the
    ## wrong end of the wire, would still be wrong for a session copied between
    ## hosts or replayed from a committed trace, and — because both CI lanes
    ## are Linux — its Windows arm would never execute a single assertion while
    ## appearing to be covered.  A runtime parameter is exercised on both sides
    ## by the Linux tests.
    cldAuto = "auto"
      ## **The producer is unknown**, which is every caller today: no producer
      ## records the agent's OS (`AgentActivityMessageEntry` carries no such
      ## field, and neither ACP's `tool_call.title` nor Agent Harbor's shell
      ## events do).  This is therefore a *heuristic*, named as one, and the
      ## rules it uses and their confidence are spelled out in
      ## `splitCommandLine`.  When a producer does start recording its OS, the
      ## fix is to pass `cldPosix`/`cldWindows` here rather than to sharpen the
      ## heuristic further.
    cldPosix = "posix"
      ## **A POSIX shell wrote it.**  `\` escapes the next character outside
      ## single quotes; inside `"…"` it escapes only `"` and `\`; `'…'` is
      ## literal throughout.  This is what `bash -c` would have done with the
      ## string.
    cldWindows = "windows"
      ## **`cmd.exe` or PowerShell wrote it — the *shell* reading, not the CRT
      ## reading.**  `\` is *never* an escape; it is a path separator or a
      ## literal.  Quoting is by `"…"` and (for PowerShell) `'…'`.
      ##
      ## Deliberately **not** the MSVCRT / `CommandLineToArgvW` backslash-run
      ## rule (2n backslashes before `"` → n backslashes and a quote toggle,
      ## 2n+1 → n backslashes and a literal quote —
      ## https://learn.microsoft.com/en-us/cpp/c-language/parsing-c-command-line-arguments).
      ## That rule is what makes `"C:\dir\"` parse as `C:\dir"`, a string that
      ## cannot be a Windows path because `"` is not a legal path character.
      ## It is a well-known CRT trap rather than anything a person means, and
      ## reproducing it here would name a wrong-*but-plausible* dataset — the
      ## exact failure this module's quoting exists to prevent.  At the shell
      ## level, which is the level a tool title is written at, `cmd.exe` and
      ## PowerShell both read `"C:\dir\"` as `C:\dir\`.

const CommandLineWhitespace = {' ', '\t', '\n', '\r'}
  ## What separates one argv token from the next.

const DelimitersAfterBackslash = CommandLineWhitespace + {'\'', '"'}
  ## Under `cldAuto`, the only characters a backslash may escape — see
  ## `splitsTokenAfter`.

proc splitsTokenAfter(c: char): bool {.noSideEffect, inline.} =
  ## Whether a `\` immediately before `c` *could* be an escape under
  ## `cldAuto`, as opposed to a literal backslash that happens to precede `c`.
  ##
  ## The answer is: only before a character that would otherwise *end or
  ## delimit the token* — whitespace and the two quote marks.  Before anything
  ## else, including a letter, a digit, a `.` or another `\`, it is a literal
  ## backslash, because escaping is needed here *only* to stop a delimiter from
  ## delimiting; for every other character the two readings differ merely in
  ## whether a literal `\` survives, and a surviving `\` is the only reading
  ## that can be right for `C:\out\review.json`.
  ##
  ## This is a *necessary* condition, not a sufficient one: `splitCommandLine`
  ## withdraws the escape again once the token has shown itself to be a Windows
  ## path.  See rule (2) there.
  c in DelimitersAfterBackslash

proc continuesTheSamePath(line: string; whitespaceAt: int): bool
    {.noSideEffect.} =
  ## Whether the text after the whitespace run beginning at `whitespaceAt`
  ## could be **more of the same path token**, as opposed to the next argument.
  ##
  ## This is rule (2)'s lookahead, and it exists because the local picture is
  ## genuinely identical in the two cases it has to tell apart:
  ##
  ## * `C:\Program\ Files\out\r.json` — the `\ ` is a **real escape**, and what
  ##   follows it is the rest of one path.
  ## * `C:\out\ --diff main..HEAD` — the `\` is a **trailing separator** that
  ##   happens to sit at an argument boundary, and what follows is a flag.
  ##
  ## Both tokens have single `\` separators and both carry a literal backslash
  ## before the space, so nothing *behind* the backslash distinguishes them.
  ## What does is that **a flag is the one argv token that can never be a path
  ## continuation**: a component of a Windows path does not begin with `-`
  ## immediately after a space.  End of line counts as "cannot continue" for
  ## the same reason — there is nothing left to continue with.
  var i = whitespaceAt
  while i < line.len and line[i] in CommandLineWhitespace:
    inc i
  i < line.len and line[i] != '-'

proc backslashEscapesUnder(dialect: CommandLineDialect; line: string;
                           backslashAt: int;
                           inDoubleQuotes, tokenHasSeparator: bool): bool
    {.noSideEffect.} =
  ## Whether the `\` at `backslashAt` is an **escape**, for one dialect and one
  ## position.  The caller guarantees `line[backslashAt] == '\\'` and that a
  ## next character exists.
  ##
  ## The single place any dialect's backslash rule is stated, so the unquoted
  ## and double-quoted arms of the tokenizer cannot drift apart — they did once
  ## before, which is why `"C:\Program Files\…"` was mangled after the unquoted
  ## arm alone had been fixed.
  let next = line[backslashAt + 1]
  case dialect
  of cldPosix:
    # POSIX keeps the backslash's special meaning inside `"…"` only before
    # `$`, `` ` ``, `"`, `\` and newline.  This splitter performs no expansion,
    # so `\$` and ``\` `` could never have produced a correct path anyway and
    # the backslash is kept literal there; that is the reading that cannot
    # invent a shorter path than the one written.
    if inDoubleQuotes: next in {'"', '\\'} else: true
  of cldWindows:
    false
  of cldAuto:
    if not next.splitsTokenAfter:
      false
    elif not tokenHasSeparator:
      # Rule (1) alone: nothing yet says this token is a Windows path.
      true
    elif next in {'\'', '"'}:
      # Rule (2), the quote half, and it is unconditional: a Windows path
      # cannot contain `'` or `"` at all, so in a token already carrying a
      # literal separator a `\"` is a trailing separator meeting the closing
      # quote — never an escaped quote.
      false
    else:
      # Rule (2), the whitespace half.  NOT unconditional, because a token can
      # be Windows-shaped AND POSIX-escaped at once — see
      # `continuesTheSamePath`.  The escape survives exactly when what follows
      # is more of this path, and is withdrawn when it is the next argument.
      line.continuesTheSamePath(backslashAt + 1)

iterator backslashRuns(token: string): tuple[start, length: int] =
  ## Every *maximal* run of `\` in `token`, in order, as `(offset, length)`.
  ##
  ## Maximal is the whole point: rule (3) of `splitCommandLine` is a statement
  ## about run *lengths*, and a scan that saw `\\` as two runs of one could not
  ## tell a doubled separator from a UNC prefix.  Shared by the two procs below
  ## so the test and the rewrite cannot disagree about where the runs are.
  var i = 0
  while i < token.len:
    if token[i] != '\\':
      inc i
      continue
    let start = i
    while i < token.len and token[i] == '\\':
      inc i
    yield (start, i - start)

proc hasOnlyEvenBackslashRuns(token: string): bool {.noSideEffect.} =
  ## Whether `token` contains at least one run of `\` and *every* such run has
  ## even length — the signature of a Windows path that a POSIX shell doubled.
  ## See rule (3) of `splitCommandLine`.
  result = false
  for run in token.backslashRuns:
    if run.length mod 2 != 0:
      return false
    result = true

proc halveBackslashRuns(token: string): string {.noSideEffect.} =
  ## `token` with every run of `\` halved — the inverse of POSIX doubling.
  ## Only ever applied to a token `hasOnlyEvenBackslashRuns` accepted.
  result = newStringOfCap(token.len)
  var copied = 0
  for run in token.backslashRuns:
    result.add token[copied ..< run.start]
    for _ in 0 ..< run.length div 2:
      result.add '\\'
    copied = run.start + run.length
  result.add token[copied .. ^1]

proc splitCommandLine*(line: string; dialect = cldAuto): seq[string]
    {.noSideEffect.} =
  ## Split a command line into argv, for the quoting forms an agent's tool
  ## title actually uses.
  ##
  ## Quoting matters here rather than being pedantry: a path with a space in
  ## it (`"/home/a b/review.json"`) is the case where a naive whitespace split
  ## produces a *wrong but plausible* path, and the reviewer would be told a
  ## dataset is missing when it is not.
  ##
  ## An unterminated quote yields the tokens read so far — a partial command
  ## is not evidence, and the caller's own checks reject it.
  ##
  ## ## Whose backslash is it?
  ##
  ## `\` **escapes** on a POSIX shell and **separates** on `cmd.exe` and
  ## PowerShell, so the same bytes have two correct readings and the honest
  ## answer is that this function has to be *told* which one it is reading.
  ## That is `dialect`, and `CommandLineDialect` says why it is a runtime
  ## parameter rather than `when defined(windows)`.
  ##
  ## The two readings are not merely different, they are **mutually
  ## exclusive**, and the proof is a pair of inputs each of which is
  ## unambiguous on its own:
  ##
  ## * `-o C:\out\ --diff` needs `\ ` to be a **separator followed by a
  ##   delimiter**, or the two arguments are glued into one.
  ## * `env CT_LOG=/home/a\ b/log …` needs `\ ` to be an **escaped space**, or
  ##   one argument is split into two.
  ##
  ## No per-character rule satisfies both.  Under `cldPosix` and `cldWindows`
  ## each is simply right, because the dialect settles it.
  ##
  ## ## What `cldAuto` does, and how far to trust it
  ##
  ## No producer records the agent's OS today, so `cldAuto` is what every
  ## caller gets, and it is a heuristic.  It decides **per token, never per
  ## line** — a single command line really does carry both readings at once
  ## (`env CT_LOG=/home/a\ b/log ct review collect -o C:\out\review.json`), so
  ## any "does this line look POSIX" vote is wrong before it starts.
  ##
  ## **`cldAuto` is not "guess which of the two dialects it is".**  For a line
  ## written wholly in one of them it does agree with that one, and the tests
  ## assert exactly that.  But a third spelling is common enough to be a first
  ## -class case rather than an edge: **a Windows path typed at a POSIX shell**,
  ## where only the characters that would break tokenisation are escaped and
  ## the separators are left alone —
  ##
  ##     C:\Program\ Files\out\r.json
  ##
  ## `cldPosix` reads that as `C:Program Filesoutr.json` and `cldWindows` as
  ## two tokens; **both are wrong, and `cldAuto` is deliberately neither**.
  ## That is what the rules below are for, and it is why "auto agrees with a
  ## dialect" is asserted only over lines that *have* one.
  ##
  ## Three rules, each with what it is and is not confident about:
  ##
  ## 1. **Per character**: a `\` is a candidate escape only before whitespace,
  ##    `'` or `"` — the characters that would otherwise end the token
  ##    (`splitsTokenAfter`).  Before anything else it is a literal backslash.
  ##    Confidence: high.  A POSIX `\z` is a pointlessly-escaped `z`, which
  ##    agents do not write, whereas `C:\z` is what they do write.
  ##
  ## 2. **Per token, narrowing rule 1**: once a token has contained a *literal*
  ##    backslash it is a Windows path, and rule 1's escape is narrowed for the
  ##    rest of that token.  The two halves have different strengths and are
  ##    stated apart on purpose:
  ##
  ##    * **Before a quote the escape is withdrawn outright.**  Confidence:
  ##      high, and it is a fact about Windows rather than a guess — `'` and
  ##      `"` are not legal characters in a Windows path at all, so inside a
  ##      token that already carries a separator a `\"` can only be a trailing
  ##      separator meeting the closing quote.  This is what stops
  ##      `"C:\Program Files\out\"` swallowing its own closing quote.
  ##
  ##    * **Before whitespace the escape is withdrawn only when the text after
  ##      the whitespace cannot continue the path** (`continuesTheSamePath`,
  ##      i.e. it begins with `-`, or the line ends).  This is what stops
  ##      `-o C:\out\ --flag` gluing two arguments.
  ##
  ##    **A premise worth stating because its obvious form is false.** It is
  ##    tempting to argue that a literal backslash proves the token is not
  ##    POSIX-escaped — that the POSIX reading would have had to call it a
  ##    pointless escape (`\o` in `C:\out`, `\P` in `C:\Program Files`), which
  ##    agents do not write.  **That argument does not hold for whitespace.**
  ##    A token can be Windows-shaped *and* POSIX-escaped at the same time:
  ##
  ##        C:\Program\ Files\out\r.json
  ##
  ##    is what git-bash, WSL or any shell-quoting harness emits for the
  ##    commonest Windows path there is, and its `\ ` is a *genuine, necessary*
  ##    escape while every other backslash is a separator.  An earlier version
  ##    of this rule withdrew the escape unconditionally and truncated that
  ##    path to `C:\Program\` — a wrong-but-plausible dataset, which is the
  ##    failure this module exists to prevent.  Hence the lookahead.
  ##
  ##    **The admitted loss, and why it is this class.**  The lookahead cannot
  ##    have both of these, because they are locally identical and differ only
  ##    in what follows:
  ##
  ##        -o C:\Users\John\ Doe\review.json   (an escaped space: wins)
  ##        -o C:\out\ report.json              (a trailing separator: loses,
  ##                                             read as one token
  ##                                             `C:\out report.json`)
  ##
  ##    The losing class is the rarer one, deliberately.  `C:\Program Files`
  ##    and `C:\Users\John Doe` are the two commonest spaced Windows paths in
  ##    existence, while a *positional* argument after an output directory does
  ##    not occur in any spelling this recogniser accepts: `-o`/`--output` is
  ##    followed by another flag or by end of line, and `ct agent evidence`
  ##    takes its path last.  A trailing separator before a *flag* — the
  ##    reported case — is handled, and so is one at end of line.
  ##
  ## 3. **Per token, post-pass**: if *every* run of `\` in the finished token
  ##    has even length, the token is a POSIX-escaped rendering of a Windows
  ##    path and each run is halved.  Confidence: high for what agents write,
  ##    and it is the rule that keeps a UNC path intact — `\\server\share\x`
  ##    has runs 2, 1, 1, so it is *not* all-even and is left alone, while its
  ##    bash-escaped spelling `\\\\server\\share\\x` has runs 4, 2, 2 and
  ##    halves back to it.  The one input it reads wrongly is a *literal*
  ##    Windows path in which every separator was doubled by hand; no shell
  ##    requires that and it is not a spelling agents produce.
  ##
  ## A caller that learns the producer should pass `cldPosix` or `cldWindows`
  ## and stop relying on any of the three.
  ##
  ## ## Consequences worth stating, because each was chosen rather than fallen into
  ##
  ## * Under every dialect, `'…'` is literal through and through.
  ## * Under `cldAuto` a lone `\\` pair that survives rule 3's test is two
  ##   literal backslashes, because a UNC output path
  ##   (`\\build-server\artifacts\review.json`) is a real thing a Windows CI
  ##   agent writes and collapsing the pair would yield `\build-server\…` — a
  ##   wrong *but plausible* path.
  ## * A trailing `\` with nothing after it is a literal under every dialect:
  ##   an escape with nothing to escape, which is also the right answer for a
  ##   Windows directory written with its separator (`-o C:\out\`).
  ##
  ## Recorded as a recurring class, not a novelty:
  ## `windows-porting-initiative-status.md` (§"Regressions found and fixed
  ## this session", the `env.ps1` entry) has this repo's previous instance —
  ## "passed a backslash Windows path to bash, mangling it and silently
  ## skipping tree-sitter-nim parser regeneration" — where the fix was
  ## likewise to stop letting a POSIX reader eat a Windows path's separators.
  result = @[]
  var current = ""
  var started = false
  var sawLiteralBackslash = false
    ## Rule 2's evidence: has *this* token already carried a literal `\`?
    ## Reset with the token, never with the line, because the decision is per
    ## token.
  var quote = '\0'
    ## The open quote character, or `'\0'` when unquoted.

  template emitToken() =
    if started:
      # Rule 3 is a property of the finished token, so it can only run here.
      result.add(
        if dialect == cldAuto and current.hasOnlyEvenBackslashRuns:
          current.halveBackslashRuns
        else:
          current)
      current = ""
      started = false
      sawLiteralBackslash = false

  var i = 0
  while i < line.len:
    let c = line[i]
    if quote == '\'':
      # Single quotes are literal through and through, on every shell.
      if c == '\'':
        quote = '\0'
      else:
        current.add c
      inc i
    elif c == '\\':
      started = true
      if i + 1 < line.len and
          backslashEscapesUnder(dialect, line, i, quote == '"',
                                sawLiteralBackslash):
        current.add line[i + 1]
        inc i, 2
      else:
        # Not an escape: the backslash is part of the token, and it is also
        # rule 2's evidence that the token is a Windows path.  A `\` at the
        # very end of the line lands here too.
        current.add c
        sawLiteralBackslash = true
        inc i
    elif c == quote:
      quote = '\0'
      inc i
    elif quote == '\0' and (c == '"' or c == '\''):
      started = true
      quote = c
      inc i
    elif quote == '\0' and c in {' ', '\t', '\n', '\r'}:
      emitToken()
      inc i
    else:
      started = true
      current.add c
      inc i
  emitToken()

proc commandBaseName*(token: string): string {.noSideEffect.} =
  ## The executable name of an argv[0], **as written**, with any directory and
  ## a Windows `.exe` suffix removed.  An agent may invoke `ct` by absolute
  ## path (a Nix store path, a build tree) and that is still `ct`.
  ##
  ## The `.exe` test is case-insensitive because the suffix is a Windows one
  ## and Windows does not distinguish `ct.exe` from `ct.EXE`.  The *name* is
  ## returned unfolded, though — deciding what it names is `namesCtBinary`'s
  ## job, and a name is worth reporting the way its author typed it.
  var cut = -1
  for i in countdown(token.high, 0):
    if token[i] == '/' or token[i] == '\\':
      cut = i
      break
  result = if cut >= 0: token[cut + 1 .. ^1] else: token
  if result.len > 4 and result[^4 .. ^1].toLowerAscii == ".exe":
    result = result[0 ..< result.len - 4]

proc namesCtBinary*(token: string): bool {.noSideEffect.} =
  ## Whether this argv token invokes CodeTracer's own `ct`.
  ##
  ## Case-insensitive, and that is the whole content of this predicate.  An
  ## executable name is case-insensitive on Windows and on a default macOS
  ## volume, so `CT.EXE`, `Ct.exe` and `ct` all name one binary on two of the
  ## three platforms CodeTracer ships on; the suffix test in
  ## `commandBaseName` was already case-insensitive, which is precisely why
  ## `ct.EXE` used to be accepted while `CT.EXE` was refused — one half of one
  ## comparison folding case is not a rule, it is a bug.
  ##
  ## What this does *not* widen: it is still a whole-name test, so `myct`,
  ## `ctx`, `ct-wrapper` and `ct.exe.bak` remain rejected, which is the check
  ## that stands between "the agent ran ct" and "the agent ran something with
  ## ct in its name".  The one input it newly accepts is a Linux binary
  ## literally named `CT`, and the cost of that is a card naming a dataset the
  ## agent itself typed — whereas the cost of today's refusal is a real
  ## Windows handoff silently never becoming clickable at all.
  token.commandBaseName.cmpIgnoreCase("ct") == 0

proc flagValue(tokens: openArray[string]; start: int;
               names: openArray[string]): string {.noSideEffect.} =
  ## The value of the first of `names` that appears at or after `start`,
  ## in either the `--flag value` or the `--flag=value` spelling.
  ##
  ## "" when the flag is absent or names nothing — which the caller turns into
  ## "this is not a recognisable evidence call", never into a guessed path.
  var i = start
  while i < tokens.len:
    let token = tokens[i]
    for name in names:
      if token == name:
        if i + 1 < tokens.len:
          return tokens[i + 1]
        return ""
      if token.len > name.len and token.startsWith(name) and
          token[name.len] == '=':
        return token[name.len + 1 .. ^1]
    inc i
  ""

proc firstPositional(tokens: openArray[string]; start: int): string
    {.noSideEffect.} =
  ## The first token at or after `start` that is not a flag and is not a
  ## flag's value.  `ct agent evidence <PATH>`'s argument, in other words.
  var i = start
  while i < tokens.len:
    let token = tokens[i]
    if token.startsWith("-"):
      # `--session foo` consumes its value; `--session=foo` does not.  A
      # switch we do not know about is assumed to take a value only when it
      # is not written with `=`, which is the conservative reading: guessing
      # wrong here yields no path rather than a wrong one, because the next
      # candidate is checked the same way.
      if not token.contains('='):
        inc i
      inc i
      continue
    return token
  ""

proc parseEvidenceCommand*(commandLine: string; dialect = cldAuto):
    Option[EvidenceCommand] {.noSideEffect.} =
  ## Recognise one of RV-7's evidence commands, and name the dataset it
  ## produces or hands over.
  ##
  ## Accepted, and nothing else:
  ##
  ## ==================================  =========================
  ## command                             dataset
  ## ==================================  =========================
  ## `ct review collect … -o/--output X` `X`
  ## `ct agent evidence X`               `X`
  ## `ct agent end-of-turn … --output X` `X`
  ## ==================================  =========================
  ##
  ## The `ct` token may be any path whose base name names `ct`
  ## (`namesCtBinary`, which folds case), because an agent commonly invokes
  ## the binary it was given rather than one on `PATH`; and it may be preceded
  ## by other tokens (`env FOO=1 ct review collect …`,
  ## `nix run … -- ct review collect …`), so the scan looks for `ct` anywhere
  ## rather than only at argv[0].
  ##
  ## `dialect` is passed straight to `splitCommandLine`; see
  ## `CommandLineDialect` for why it is a runtime parameter and why every
  ## caller today leaves it at `cldAuto`.
  ##
  ## Returns `none` for everything else — including a `ct review collect`
  ## with no `--output` and a `ct agent end-of-turn` with no `--output`.  See
  ## rule 2 in the module header: a card that could not name its dataset would
  ## have nothing to open and nothing honest to say about its shape.
  let tokens = splitCommandLine(commandLine, dialect)
  for i in 0 ..< tokens.len:
    if not tokens[i].namesCtBinary:
      continue
    if i + 2 >= tokens.len:
      continue
    let verb = tokens[i + 1]
    let subVerb = tokens[i + 2]
    if verb == "review" and subVerb == "collect":
      let output = flagValue(tokens, i + 3, ["--output", "-o"])
      if output.len > 0:
        return some(EvidenceCommand(kind: eckCollect, datasetPath: output))
    elif verb == "agent" and subVerb == "evidence":
      let path = firstPositional(tokens, i + 3)
      if path.len > 0:
        return some(EvidenceCommand(kind: eckHandoff, datasetPath: path))
    elif verb == "agent" and subVerb == "end-of-turn":
      let output = flagValue(tokens, i + 3, ["--output", "-o"])
      if output.len > 0:
        return some(EvidenceCommand(kind: eckCollect, datasetPath: output))
  none(EvidenceCommand)

# ---------------------------------------------------------------------------
# Folding a conversation
# ---------------------------------------------------------------------------

proc evidenceStateFromStatus*(status: string): EvidenceCallState
    {.noSideEffect.} =
  ## Read the backend's own word for how a tool call ended.
  ##
  ## Anything unrecognised — including the empty string a call that has not
  ## reported yet carries — is `ecsUnreported`, never `ecsCompleted`:
  ## guessing "completed" would offer a review over a dataset the command may
  ## never have written.
  case status.toLowerAscii
  of "completed", "success", "succeeded", "ok": ecsCompleted
  of "failed", "failure", "error", "cancelled", "canceled": ecsFailed
  else: ecsUnreported

proc projectEvidenceCalls*(messages: openArray[AgentActivityMessageEntry]):
    seq[EvidenceCall] {.noSideEffect.} =
  ## Find the evidence handoffs in a conversation.
  ##
  ## Two passes over one message list.  The first recognises calls from their
  ## `toolName`; the second folds every *later* row carrying the same
  ## `toolCallId` onto the call it belongs to, which is how a `tool_call` and
  ## its `tool_call_update` are joined without relying on them being adjacent.
  ##
  ## A call whose backend reports no `toolCallId` (Agent Harbor's shell events
  ## do not) simply keeps `ecsUnreported` — pairing by position instead would
  ## attach whatever row happened to follow, and "the command succeeded" is
  ## exactly the claim that must not be guessed.
  result = @[]
  for message in messages:
    if message.toolName.len == 0:
      continue
    # `cldAuto`, and not by oversight: nothing in the transcript says which
    # shell produced the title.  `AgentActivityMessageEntry` carries no OS,
    # ACP's `tool_call` carries none on the title, and Agent Harbor's shell
    # events carry none either — so the heuristic in `splitCommandLine` is the
    # best available answer.  Threading a real dialect here is a change to the
    # *producers* (a field on this entry, filled from the agent's own
    # environment), not to this fold.
    let command = parseEvidenceCommand(message.toolName, cldAuto)
    if command.isNone:
      continue
    result.add EvidenceCall(
      anchorId: message.id,
      toolCallId: message.toolCallId,
      kind: command.get.kind,
      command: message.toolName,
      datasetPath: command.get.datasetPath,
      # The call row may already carry an outcome (a backend that emits one
      # update per call rather than a call plus an update).
      state: evidenceStateFromStatus(message.status),
      failureText: "",
      dataset: EvidenceDataset(state: edsUnknown))

  if result.len == 0:
    return

  for message in messages:
    if message.toolCallId.len == 0 or message.toolName.len > 0:
      continue
    let state = evidenceStateFromStatus(message.status)
    if state == ecsUnreported:
      continue
    for i in 0 ..< result.len:
      if result[i].toolCallId != message.toolCallId:
        continue
      result[i].state = state
      # Only a failure keeps its output: a successful collect prints the
      # dataset's location, which the card already states from the command
      # itself, and repeating it would push the affordance off the row.
      result[i].failureText = if state == ecsFailed: message.content else: ""

proc evidenceCommandName*(kind: EvidenceCommandKind): string {.noSideEffect.} =
  ## What the card calls this kind of call, for a reader who has not memorised
  ## the CLI.
  case kind
  of eckCollect: "Collected review evidence"
  of eckHandoff: "Handed over review evidence"

proc canOpenEvidence*(call: EvidenceCall): bool {.noSideEffect.} =
  ## Whether this call has a review to enter.
  ##
  ## The view gates the affordance on this and `AgentActivityVM.openEvidence`
  ## gates the *action* on the same fact, so a stale rendering cannot enter a
  ## review over a dataset that is not there — the shape AA-2 gave the
  ## drill-down, for the same reason.
  call.state == ecsCompleted and call.dataset.state == edsReady and
    call.datasetPath.len > 0

proc evidenceDatasetShapeText*(call: EvidenceCall): string {.noSideEffect.} =
  ## "enough of its shape — file count, reviewed commit — to be recognisable
  ## without opening it" (§2.1.1), or "" when this card has no shape it may
  ## honestly claim.
  ##
  ## Gated on `canOpenEvidence` — the *same* fact that decides the affordance
  ## — rather than on the dataset's read state alone, so the two can never
  ## disagree.  That is not belt-and-braces: a session that collected twice
  ## into one path, failing the first time and succeeding the second, has a
  ## perfectly readable file at the failed call's path, and printing its
  ## shape on that card would attribute a real measurement to a command that
  ## did not produce it.  (Found by this rule's own view test, which paired
  ## "the failed card offers nothing" with "and claims no shape".)
  ##
  ## Under the open-able state the count always prints, zero included — that
  ## *is* a measurement, and hiding it would be the mirror defect AA-2
  ## recorded.  The commit prints only when the dataset names one: a
  ## changeset from a standalone patch has none, and an empty `commitSha` is
  ## absence rather than a value.
  if not call.canOpenEvidence():
    return ""
  let dataset = call.dataset
  result =
    if dataset.fileCount == 1: "1 file" else: $dataset.fileCount & " files"
  if dataset.commit.len > 0:
    result.add " · " & dataset.commit

proc evidenceNoteText*(call: EvidenceCall): string {.noSideEffect.} =
  ## The sentence the card shows about a call that has nothing to open, or ""
  ## when it has.
  ##
  ## AA-1's rule, stated for this surface: **where something happened, say so
  ## in words; where nothing happened, render nothing.**  Every state in which
  ## the reviewer cannot click through produces a sentence naming *which*
  ## state it is, because a card that merely lacked a button would be
  ## indistinguishable from a card that had not loaded yet.
  case call.state
  of ecsUnreported:
    # Deliberately not "still collecting": a transcript cannot tell a command
    # in flight from one whose session ended before it reported.  Stating the
    # observation covers both without claiming either.
    "No outcome has been reported for this command yet."
  of ecsFailed:
    "This command failed, so there is no review dataset to open."
  of ecsCompleted:
    case call.dataset.state
    of edsReady:
      ""
    of edsUnknown:
      "Reading " & call.datasetPath & "…"
    of edsUnavailable:
      var text = "The review dataset at " & call.datasetPath &
        " could not be read."
      if call.dataset.message.len > 0:
        text.add " " & call.dataset.message
      text

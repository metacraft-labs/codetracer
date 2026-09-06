## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it. This module is a PURE FUNCTION of a value. It holds no
## ViewModel, runs no command and reads no terminal: it turns keystrokes into a
## LINE, and somebody else runs it.
##
## app/views/command_line.nim — CTUI-10. §3.3.6's "Interactive Command Entry"
## and "Interactive Search Prompt": the `:` prompt, with history and completion,
## and the `/` and `?` prompts, which are the same field with a different sigil.
##
## ## ONE PROMPT, THREE SIGILS
##
## §3.3.6 describes two prompts and §4.2 binds three keys to them (`:`, `/`,
## `?`). They are one widget: the same buffer, the same cursor, the same
## `Backspace`, the same `Esc`, the same `Enter`. What differs is the sigil,
## whether completion is offered, and which history the recall walks — and each
## of those is a field, not a second implementation. CTUI-9's `modal_state`
## already models it that way (`ModalState.buffer` is shared and the mode says
## which prompt is open), so a second buffer here would be a second thing that
## can disagree with the mode indicator.
##
## ## COMPLETION TAKES ITS CANDIDATES AS A VALUE
##
## `complete` is given the candidate list. It does NOT import
## `app/commands/interpreter.nim` to ask for `commandNames()`, and that is the
## same rule every view in this tree follows: a view is a pure function of a
## value so that it can be asserted without the thing that produced the value,
## and so that two frames are two values. The caller passes `commandNames()` at
## a `:` prompt and, for instance, the recording's own function names at a
## `:break` argument.
##
## ## HISTORY IS VIM'S, INCLUDING THE PART THAT IS EASY TO GET WRONG
##
## Three properties, each of which has an assertion in
## `app/tests/test_gdb_command_surface.nim`:
##
##   1. **A submitted line is pushed once.** Submitting the same line twice in
##      a row does not grow the history — the entry is MOVED to the end. A
##      history that grew on every repeat makes `Up` `Up` reach the line before
##      last only after as many presses as the user repeated themselves.
##   2. **Browsing stashes the partial line.** `Up` from a half-typed command
##      keeps that text and `Down` past the newest entry restores it. Losing it
##      is the defect that makes people stop using history.
##   3. **An empty or all-blank line is not history.** Nothing was run, so
##      there is nothing to recall.
##
## ## EVERY KEY IS ACCOUNTED FOR, AND `applyKey` SAYS WHICH
##
## `applyKey` answers a `CommandLineAction` for every token, including the ones
## it declines. `claUnhandled` is not silence: it tells the caller the prompt
## did not want the key, so the caller can pass it on rather than swallow it —
## which is what keeps `Ctrl+c` working while a prompt is open.

import std/[algorithm, strutils]

import ./header
import ./styled_row

export header, styled_row

type
  PromptKind* = enum
    ## Which of §4.2's three prompt keys opened this line. The value IS the
    ## sigil the prompt shows, so §3.3.6's "Prompt `:`" and "Prompt `/`" have
    ## one source.
    pkCommand = ":"
    pkSearchForward = "/"
    pkSearchBackward = "?"

  CommandLineAction* = enum
    ## What one token did. Reported rather than inferred from a buffer diff,
    ## for `modal_state`'s reason: `Tab` with no candidate and `Tab` that
    ## completed to the text already there are different answers.
    claUnhandled = "unhandled"
      ## The prompt is closed, or the key is not one of this widget's. NOT
      ## silence — see the module header.
    claOpened = "opened"
    claEdited = "edited"
    claSubmitted = "submitted"
    claCancelled = "cancelled"
    claCompleted = "completed"
    claNoCompletion = "no-completion"
    claHistoryMoved = "history-moved"
    claNoHistory = "no-history"
    claCursorMoved = "cursor-moved"

  CommandLineModel* = object
    ## The prompt, whole, as a value.
    open*: bool
    kind*: PromptKind
    buffer*: string
    cursor*: int
      ## Insertion point, in BYTES into `buffer`. Bytes rather than cells
      ## because every edit here is a byte splice and the only consumer that
      ## needs cells is `cursorColumn`, which converts once.
    history*: seq[string]
      ## Oldest first. Shared across prompt kinds is WRONG and this is
      ## per-model: a caller keeps one model per prompt kind, so `/`'s history
      ## never surfaces at `:`.
    historyIndex*: int
      ## `history.len` means "not browsing". Any smaller value is the entry
      ## currently shown.
    stash*: string
      ## The partial line browsing began from. See the header, property 2.
    completions*: seq[string]
      ## The candidates the LAST `Tab` matched, in the order it cycles them.
    completionIndex*: int
    completionPrefix*: string
      ## The text `completions` were matched against, kept for the hint strip
      ## and so a reader of a failure can see what was asked for.
    completionStart*: int
      ## Byte offset in `buffer` where the completed word begins. THE FIELD
      ## THAT MAKES CYCLING CORRECT: a second `Tab` must replace the candidate
      ## the first one inserted, and computing that span from the PREFIX's
      ## length would delete the wrong bytes the moment the two differ in size.
    completionActive*: bool
      ## Whether the buffer currently holds a candidate this widget inserted.
      ## Cleared by any edit, so `Tab` after typing re-matches instead of
      ## cycling a stale list.
    message*: string
      ## The §3.3.6 notification for this prompt — an error from the last run,
      ## or a match count. Rendered after the buffer.

const
  KeyEnter* = "\r"
  KeyEnterLf* = "\n"
  KeyEscape* = "\x1b"
  KeyBackspace* = "\x7f"
  KeyBackspaceCtrlH* = "\b"
  KeyTab* = "\t"
  KeyLeft* = "Left"
  KeyRight* = "Right"
  KeyUp* = "Up"
  KeyDown* = "Down"
  KeyHome* = "Home"
  KeyEnd* = "End"
    ## The canonical names `keymap.keyName` produces for the non-printable
    ## keys, plus the raw bytes for the four that arrive as one byte. A prompt
    ## is driven by both spellings in this tree — `applyKey` takes the token
    ## the runtime framed, and `keymap.keyName` names it — so both are matched
    ## and `app/tests/test_gdb_command_surface.nim` asserts each.

  MaxHistory* = 200
    ## How many lines a prompt remembers. Bounded because a TUI's whole memory
    ## budget is 30 MB (the initiative goal) and an unbounded history is the
    ## one structure in this widget that grows with session length.

  NoCompletionText* = "no completion"
  EmptyHistoryText* = "no history"

  PromptStyle* = CellStyle(fg: "white")
  SigilStyle* = CellStyle(fg: "yellow", bold: true)
  MessageStyle* = CellStyle(fg: "bright_black")

proc initCommandLineModel*(kind = pkCommand;
                           history: seq[string] = @[]): CommandLineModel =
  CommandLineModel(open: false, kind: kind, buffer: "", cursor: 0,
                   history: history, historyIndex: history.len, stash: "",
                   completions: @[], completionIndex: 0, completionPrefix: "",
                   completionStart: 0, completionActive: false, message: "")

# ---------------------------------------------------------------------------
# Opening and closing
# ---------------------------------------------------------------------------

proc clearTransient(model: var CommandLineModel) =
  model.completions = @[]
  model.completionIndex = 0
  model.completionPrefix = ""
  model.completionStart = 0
  model.completionActive = false
  model.historyIndex = model.history.len
  model.stash = ""

proc open*(model: var CommandLineModel; kind: PromptKind): CommandLineAction =
  ## `:`, `/` or `?`. The buffer starts EMPTY — CTUI-9's `applyModalEvent`
  ## clears `ModalState.buffer` on every accepted route into a prompt, and a
  ## prompt that reopened with the last query in it would disagree with the
  ## mode's own idea of what has been typed.
  model.open = true
  model.kind = kind
  model.buffer = ""
  model.cursor = 0
  model.message = ""
  model.clearTransient()
  claOpened

proc cancel*(model: var CommandLineModel): CommandLineAction =
  ## `Esc`. The buffer is dropped; the history is not.
  if not model.open:
    return claUnhandled
  model.open = false
  model.buffer = ""
  model.cursor = 0
  model.clearTransient()
  claCancelled

# ---------------------------------------------------------------------------
# Editing
# ---------------------------------------------------------------------------

proc insert*(model: var CommandLineModel; text: string): CommandLineAction =
  ## One printable token into the buffer at the cursor.
  if not model.open or text.len == 0:
    return claUnhandled
  model.buffer.insert(text, model.cursor)
  model.cursor += text.len
  model.clearTransient()
  claEdited

proc backspace*(model: var CommandLineModel): CommandLineAction =
  ## §4.1's prompt correction. Deleting the last character of an EMPTY buffer
  ## does NOT close the prompt: §4.2 gives closing to `Esc`, and a prompt that
  ## vanished on one Backspace too many would lose a mode change the user did
  ## not ask for.
  if not model.open:
    return claUnhandled
  if model.cursor <= 0:
    return claEdited
  # THE WHOLE TRAILING RUNE, not one byte: deleting a byte would split a UTF-8
  # sequence and leave a buffer no width table can measure. The scan walks back
  # over continuation bytes (`10xxxxxx`) to the lead byte — the same rule
  # `moveCursor` uses for `Left`, so the cursor and the delete can never
  # disagree about where a character starts.
  var start = model.cursor - 1
  while start > 0 and (model.buffer[start].uint8 and 0xC0'u8) == 0x80'u8:
    dec start
  model.buffer.delete(start .. model.cursor - 1)
  model.cursor = start
  model.clearTransient()
  claEdited

proc moveCursor*(model: var CommandLineModel;
                 token: string): CommandLineAction =
  ## `Left` / `Right` / `Home` / `End`. §4.2 binds none of these — they are
  ## what a text field is, the same way `Enter` and `Backspace` are, and
  ## `keymap.nim`'s header records that the prompt's own keys come from §4.1.
  if not model.open:
    return claUnhandled
  case token
  of KeyLeft:
    if model.cursor > 0:
      dec model.cursor
      while model.cursor > 0 and
            (model.buffer[model.cursor].uint8 and 0xC0'u8) == 0x80'u8:
        dec model.cursor
    claCursorMoved
  of KeyRight:
    if model.cursor < model.buffer.len:
      inc model.cursor
      while model.cursor < model.buffer.len and
            (model.buffer[model.cursor].uint8 and 0xC0'u8) == 0x80'u8:
        inc model.cursor
    claCursorMoved
  of KeyHome:
    model.cursor = 0
    claCursorMoved
  of KeyEnd:
    model.cursor = model.buffer.len
    claCursorMoved
  else:
    claUnhandled

# ---------------------------------------------------------------------------
# History
# ---------------------------------------------------------------------------

proc pushHistory*(model: var CommandLineModel; line: string) =
  ## Record a line that was actually RUN. See the header's three properties.
  let text = line.strip()
  if text.len == 0:
    return
  var kept: seq[string] = @[]
  for entry in model.history:
    if entry != text:
      kept.add entry
  kept.add text
  if kept.len > MaxHistory:
    kept = kept[kept.len - MaxHistory .. ^1]
  model.history = kept
  model.historyIndex = model.history.len

proc historyPrev*(model: var CommandLineModel): CommandLineAction =
  ## `Up`: one entry older.
  if not model.open:
    return claUnhandled
  if model.history.len == 0:
    model.message = EmptyHistoryText
    return claNoHistory
  if model.historyIndex >= model.history.len:
    model.stash = model.buffer
  if model.historyIndex == 0:
    return claNoHistory
  dec model.historyIndex
  model.buffer = model.history[model.historyIndex]
  model.cursor = model.buffer.len
  claHistoryMoved

proc historyNext*(model: var CommandLineModel): CommandLineAction =
  ## `Down`: one entry newer, and past the newest, back to what was typed.
  if not model.open:
    return claUnhandled
  if model.historyIndex >= model.history.len:
    return claNoHistory
  inc model.historyIndex
  if model.historyIndex >= model.history.len:
    model.buffer = model.stash
  else:
    model.buffer = model.history[model.historyIndex]
  model.cursor = model.buffer.len
  claHistoryMoved

# ---------------------------------------------------------------------------
# Completion
# ---------------------------------------------------------------------------

proc completionWord*(model: CommandLineModel): string =
  ## The word `Tab` completes: everything after the last space before the
  ## cursor. So `:break iter<Tab>` completes the ARGUMENT and `:bre<Tab>` the
  ## command, from the same call, without the widget knowing what a command is.
  let head = model.buffer[0 ..< model.cursor]
  let space = head.rfind(' ')
  if space < 0: head else: head[space + 1 .. ^1]

proc candidatesFor*(candidates: openArray[string];
                    prefix: string): seq[string] =
  ## Every candidate starting with `prefix`, sorted, deduplicated.
  ##
  ## SORTED so that `Tab` `Tab` `Tab` cycles in a stable order — a cycle whose
  ## order depended on the caller's list order would visit the same entries in
  ## a different order after an unrelated change.
  result = @[]
  for c in candidates:
    if c.startsWith(prefix) and c notin result:
      result.add c
  result.sort()

proc complete*(model: var CommandLineModel;
               candidates: openArray[string]): CommandLineAction =
  ## `Tab`. The first press replaces the word with the first candidate; each
  ## further press cycles, until the word is edited.
  if not model.open:
    return claUnhandled
  if model.completionActive and model.completions.len > 1:
    # Cycling: the previous `Tab` left `completions` in place and the buffer
    # holding one of them, starting at `completionStart`.
    model.completionIndex =
      (model.completionIndex + 1) mod model.completions.len
  else:
    let word = model.completionWord()
    let matched = candidatesFor(candidates, word)
    if matched.len == 0:
      model.message = NoCompletionText
      model.completions = @[]
      model.completionPrefix = ""
      model.completionActive = false
      return claNoCompletion
    model.completions = matched
    model.completionPrefix = word
    model.completionStart = model.cursor - word.len
    model.completionIndex = 0
    model.completionActive = true
  let chosen = model.completions[model.completionIndex]
  if model.cursor > model.completionStart:
    model.buffer.delete(model.completionStart .. model.cursor - 1)
  model.buffer.insert(chosen, model.completionStart)
  model.cursor = model.completionStart + chosen.len
  model.message = ""
  claCompleted

# ---------------------------------------------------------------------------
# Submitting
# ---------------------------------------------------------------------------

proc submit*(model: var CommandLineModel): (CommandLineAction, string) =
  ## `Enter`. Answers the line to run, and pushes it into the history.
  ##
  ## The PROMPT CLOSES here, which is what CTUI-9's `applyModalEvent` does for
  ## `meCommit` in COMMAND mode (`accept(mmNormal, spTyping)`). SEARCH is the
  ## exception — its commit keeps the mode and moves to `spBrowsing` — and the
  ## caller decides that from the mode, not from this widget, because the mode
  ## machine is the one place that knows.
  if not model.open:
    return (claUnhandled, "")
  let line = model.buffer
  model.pushHistory(line)
  model.open = false
  model.buffer = ""
  model.cursor = 0
  model.clearTransient()
  (claSubmitted, line)

proc applyKey*(model: var CommandLineModel; token: string;
               candidates: openArray[string] = []): CommandLineAction =
  ## One input token against the prompt.
  ##
  ## Takes the token the runtime framed OR the canonical name
  ## `keymap.keyName` produces, because both spellings reach a prompt in this
  ## tree — the snapshot runtime hands `applyToken` raw bytes, and CTUI-9's
  ## resolver hands a caller `Left` / `Up` / `Backspace`.
  if not model.open:
    return claUnhandled
  case token
  of KeyEnter, KeyEnterLf, "Enter":
    let (action, _) = model.submit()
    action
  of KeyEscape, "Esc":
    model.cancel()
  of KeyBackspace, KeyBackspaceCtrlH, "Backspace":
    model.backspace()
  of KeyTab, "Tab":
    model.complete(candidates)
  of KeyUp, "\x1b[A":
    model.historyPrev()
  of KeyDown, "\x1b[B":
    model.historyNext()
  of KeyRight, "\x1b[C":
    model.moveCursor(KeyRight)
  of KeyLeft, "\x1b[D":
    model.moveCursor(KeyLeft)
  of KeyHome, KeyEnd:
    model.moveCursor(token)
  else:
    if token.len == 1 and token[0] >= ' ' and token[0] <= '~':
      model.insert(token)
    else:
      claUnhandled

# ---------------------------------------------------------------------------
# What the user sees
# ---------------------------------------------------------------------------

proc promptText*(model: CommandLineModel; width: int): string =
  ## §3.3.6's bottom line while a prompt is open: sigil, buffer, message.
  if width <= 0 or not model.open:
    return ""
  var line = $model.kind & model.buffer
  if model.message.len > 0:
    line.add "   " & model.message
  fitCells(line, width)

proc cursorColumn*(model: CommandLineModel): int =
  ## Where a terminal should park its cursor: one cell for the sigil plus the
  ## CELL width of the buffer before the insertion point.
  ##
  ## `tests/real_terminal/test_real_command_mode.nim` asserts this against the
  ## terminal's own `cursorPosition`, which `docs/tui-testing.md` lists as one
  ## of the seven things Tier 1 cannot see.
  1 + cellWidthOf(model.buffer[0 ..< model.cursor])

proc completionHint*(model: CommandLineModel): string =
  ## The other candidates, for the hint strip. Empty when `Tab` has not run or
  ## matched exactly one.
  if model.completions.len <= 1:
    return ""
  var others: seq[string] = @[]
  for i, c in model.completions:
    if i != model.completionIndex:
      others.add c
  others.join(" ")

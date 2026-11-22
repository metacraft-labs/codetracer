## views/agent_harbor_results_words.nim
##
## What every host's omnibox result commands draw besides the groups and
## rows the viewmodel publishes (`ResultCommandsVM`): the field's text, a
## group's title and state in their roles, a row's parts (title split at the
## query's matches, what it is, where, its tag), `+N more`, the way back
## from a group shown alone, the line that stands in place of the rows, and
## the operations a key or a press runs.
##
## The web (`isonim_agent_harbor_results_view.nim`), GPUI
## (`gpui/agent_harbor/ah_results.nim`) and the terminal
## (`tui/agent_harbor/ah_tui_results.nim`) draw the same viewmodel and must
## decide these things alike; as `agent_harbor_composer_words`, this module
## renders nothing and imports no renderer.
##
## ## The keys and the presses
##
## Routed (Input-Routing-And-Keymaps.md §4 and §5.1, P2c study D48): the
## keys are keymap rows in the `results` scope (`overlay_rows`, the table
## `ResultsTable`: `Enter` opens, `Down` / `Up` move, `Tab` inserts), and a
## host resolves a key through its router and hands the operation to
## `runResultsOperation`. Each element a press acts on carries its operation
## (`data-ct-operation`) and its target (`data-ah-target`): a row
## `results.open` and its index, `+N more` `results.more` and its group's
## id, `← All providers` `results.all`. The host's hit test hands both to its
## router, and what it resolves to, with the target, to `runResultsPress`.

import std/strutils

import nim_agents_isonim_viewmodels/agent_harbor/result_commands_vm

import ../editor/find_match

export result_commands_vm

const
  ResultsOpenOperation* = "results.open"
  ResultsNextOperation* = "results.next"
  ResultsPreviousOperation* = "results.previous"
  ResultsInsertOperation* = "results.insert"
  ResultsMoreOperation* = "results.more"
  ResultsAllOperation* = "results.all"
  ResultsOperations* = [ResultsOpenOperation, ResultsNextOperation,
                        ResultsPreviousOperation, ResultsInsertOperation]
    ## Every operation the results' keys run (`operation_catalogue`).
  ResultsPressOperations* = [ResultsOpenOperation, ResultsMoreOperation,
                             ResultsAllOperation]
    ## Every operation a press on the results carries.
  ResultsTargetAttribute* = "data-ah-target"
  AllProviders* = "\xE2\x86\x90 All providers"
    ## The way back from a group shown alone.
  ScriptsNotRun* = "Scripts are not run for this source"
  BoxMoreBelow* = "More below \xE2\x86\x93"
    ## Under a trusted rich box whose content is taller than its cap.
  HtmlTag* = "HTML"
  ResultsDot* = " \xC2\xB7 "

type
  ResultsPress* = proc(operation, target: string)
    ## A host's route for a press: the operation the pressed element carries
    ## and its target. The host resolves it through its router and runs what
    ## it resolves to (`runResultsPress`).

proc runResultsOperation*(vm: ResultCommandsVM; operation: string): bool =
  ## Runs one of the results' key operations on `vm`; false for an operation
  ## that is not the results'.
  case operation
  of ResultsOpenOperation:
    vm.openSelected()
    true
  of ResultsNextOperation:
    vm.moveSelection(1)
    true
  of ResultsPreviousOperation:
    vm.moveSelection(-1)
    true
  of ResultsInsertOperation:
    discard vm.insertSelected()
    true
  else: false

proc runResultsPress*(vm: ResultCommandsVM; operation, target: string): bool =
  ## Runs the operation a press resolved to, on `target`: opening a row (its
  ## index among the rows drawn), a group alone (its id), every group again.
  case operation
  of ResultsOpenOperation:
    try:
      vm.open(parseInt(target))
      true
    except ValueError:
      false
  of ResultsMoreOperation:
    if target.len == 0: return false
    vm.showGroup(target)
    true
  of ResultsAllOperation:
    vm.showAll()
    true
  else: vm.runResultsOperation(operation)

proc moreLabel*(g: ShownGroup): string =
  ## `+N more` under a group that holds more than it shows; "" otherwise.
  if g.more > 0: "+" & $g.more & " more" else: ""

proc groupTitle*(g: ShownGroup): string = g.group.title

proc emptyProvidersLine*(vm: ResultCommandsVM): string =
  ## The one quiet line after the groups that names every `/search`
  ## provider that answered with nothing (`No matches in Files, Symbols,
  ## Program text`, P2c study D60); "" when none did.
  let names = vm.emptyProviders
  if names.len == 0: "" else: "No matches in " & names.join(", ")

proc spansIn*(shown, needle: string): seq[(int, int)] =
  ## Every place `needle` stands in `shown` (case ignored, as the query
  ## matches), as `(start, length)` byte spans: what a cut matched line
  ## draws bold (every match in view, P2c study D62). The editor's one
  ## matcher finds them (`find_match.matchesOf`, a literal, case-insensitive
  ## match; Find-And-Incremental-Search FS-1), so a result row bolds what a
  ## find for the same text would highlight.
  for m in matchesOf(shown, needle, MatchOptions(caseSensitive: false)):
    result.add (m.a, m.b - m.a)

proc matchedSpan*(row: ResultRow; query: string): (int, int) =
  ## Where the query matched a row's title first, as byte offsets
  ## `(start, end)`; `(0, 0)` when it did not. A line of the program's text
  ## is cut around it (`cut_text_rules.cutAroundMatch`, P2c study D62).
  let spans = matchSpans(row.title, query)
  if spans.len == 0: (0, 0) else: (spans[0][0], spans[0][0] + spans[0][1])

proc titleParts*(row: ResultRow; query: string): seq[tuple[text: string; matched: bool]] =
  ## The row's title in parts, the query's matches marked (drawn in bold).
  let spans = matchSpans(row.title, query)
  var at = 0
  for (start, length) in spans:
    if start > at: result.add (row.title[at ..< start], false)
    result.add (row.title[start ..< start + length], true)
    at = start + length
  if at < row.title.len: result.add (row.title[at .. ^1], false)

proc queryText*(vm: ResultCommandsVM): string =
  ## What the rows' matches are of: the query's text, or the token a
  ## completion completes.
  let q = vm.query
  case q.kind
  of qkCompletion: q.token
  of qkSearch, qkAhRun: q.text
  of qkAhList:
    if q.typed.startsWith(AhPrefix & "-"): q.typed[AhPrefix.len + 1 .. ^1] else: ""
  else: ""

proc rowDetail*(vm: ResultCommandsVM; row: ResultRow): string =
  ## What the row is, after its title: a command's aliases and its
  ## description, else the row's subtitle.
  if row.kind == rkCommand:
    let aliases = vm.aliasesOf(row)
    if aliases.len > 0: aliases else: ""
  else: row.subtitle

proc rowSecondLine*(vm: ResultCommandsVM; row: ResultRow): string =
  ## A line under the title: a command's description; where the text
  ## matched when the title does not show it (a session's message, quoted),
  ## or a rich row's words where its box is not drawn (its text form; the
  ## box, where drawn, already holds them); a row passed on to the system
  ## says so.
  if vm.openedOutside(row): OpenedOutside
  elif row.kind == rkCommand: row.subtitle
  elif row.excerpt.len > 0 and not vm.showsHtml(row): "\xE2\x80\x9C" & row.excerpt & "\xE2\x80\x9D"
  else: ""

proc rowTagText*(vm: ResultCommandsVM; row: ResultRow): string =
  ## The quiet tag at the row's right: where a command or a contributed row
  ## comes from; `HTML` on a rich row drawn as HTML (web only: a host that
  ## draws the text form never says HTML).
  vm.rowTag(row)

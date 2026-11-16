## record_child_argv — which words of a `ct record ... -- ...` line are the
## recorded program and which are its arguments.
##
## NORMATIVE SOURCE: `codetracer-pm` `spec/CLI/ct/record.md`, "Program
## arguments".
##
## Everything after the first `--` belongs to the recorded program, verbatim.
## The program itself may stand on either side of it:
##
##   ct record -- prog a b     the first word after `--` is the program;
##   ct record prog -- a b     the program was named before `--`, and every
##                             word after it is an argument.
##
## Which form a line is cannot be told from the words alone, because a `ct`
## option may take a value (`-o out prog` names `prog`; `-o out` does not).
## So ct's own parser decides.  The caller hands it ct's half of the line --
## the words before `--` -- with `RecordProgramSlot` inserted right after
## `record` (`recordParserLine`).  As the first word after the subcommand, the
## slot always fills `recordProgram`, and no option can take it as its value:
## the word before it is `record` itself.  Every positional the user wrote
## before `--` then lands in `recordArgs`, in order, and `resolveRecordChild`
## reads the program off the front of them.
##
## Until 2026-11-15 the placeholder (then `"\0ct-record-child-program"`) was
## appended at the END of ct's half instead.  A value-taking option written
## just before `--` took it as its value: `ct record --lang -- prog` lost
## `prog` and refused with "The required option 'recordProgram' was not
## specified", and `ct record --store-trace-folder-for-pid -- prog` printed the
## placeholder, NUL bytes included, as an invalid integer.  Moving the slot
## to the front removes both, but then an option that ends ct's half has no
## word to take at all, and the pinned confutils silently drops an option
## that is last on its line.  `recordOptionMissingValue` finds that option, so
## that `ct` can say it needs a value.
##
## PURE apart from the `probe` callback: asserted by
## `src/tests/cli/record_child_argv_test.nim`.

import std/strutils

type
  RecordChild* = object
    program*: string
    args*: seq[string]
    error*: string     ## non-empty: print it and exit 1

  RecordProbe* = object
    ## What one trial parse of a line produced.
    parsed*: bool          ## the parser accepted the line
    args*: seq[string]     ## `recordArgs`, when `parsed`

const
  RecordProgramSlot* = "ct-record-program-slot"
    ## Stands in for `recordProgram`, which is a required argument and may
    ## live to the RIGHT of `--`, where the parser cannot see it.  Printable
    ## on purpose: it can only ever land in `recordProgram`, which
    ## `resolveRecordChild` overwrites, but if a future parser ever echoed it
    ## back it must not put control bytes in a terminal, a pipe or a log.
  RecordOwnArgsEnd* = "ct-record-end-of-own-arguments"
    ## A trial word appended after ct's half by `recordOptionMissingValue`.
    ## It never reaches the real parse.

proc recordParserLine*(ownHalf: seq[string]): seq[string] =
  ## The line ct's parser reads for a `ct record ... -- ...` line whose words
  ## before `--` are `ownHalf` (`ownHalf[0]` is `record`).
  doAssert ownHalf.len > 0 and ownHalf[0] == "record",
    "recordParserLine: ct's half must start with `record`"
  result = @[ownHalf[0], RecordProgramSlot]
  result.add ownHalf[1 .. ^1]

proc recordOptionMissingValue*(
    ownHalf: seq[string],
    probe: proc (line: seq[string]): RecordProbe {.closure.}): string =
  ## The option before `--` that takes a value and was given none, when
  ## ct's half of the line ends with one -- returned exactly as the user
  ## wrote it (`--lang`, `-o`, `--lang=`) -- and "" otherwise.
  ##
  ## `probe` parses a line with ct's own parser, without printing an error or
  ## exiting.  The question is put to the parser rather than answered from
  ## the words, so it cannot drift from the parser's idea of which options
  ## take a value:
  ##
  ## 1. Append `RecordOwnArgsEnd` to the line.  Only the word right before it
  ##    can take it as a value.  When the parse succeeds, it either ends
  ##    `recordArgs` (no option was waiting for a value) or it does not (a
  ##    string-valued option took it).
  ## 2. A parse that fails may have failed BECAUSE an option rejected the
  ##    trial word (an integer option, an enum option).  Parse the line again
  ##    without it: if that succeeds, the trial word was the only problem, so
  ##    the last word was an option waiting for a value.  If it fails too,
  ##    the line has an error of its own, which the real parse reports.
  ##
  ## The waiting option is the last word with the parser ct keeps since
  ## CS-M10 (a value option takes the next word, even one that starts with
  ## `-`).  The confutils ct pinned before it kept an option waiting for its
  ## value across a following switch (`ct record --lang --upload --` gave the
  ## trial word to `--lang`), so the option is not read off the end: once
  ## the line is known to end with an option waiting for a value, the words
  ## are dropped from the end, one at a time, while the shorter line still
  ## ends that way; the last word dropped before it stops is the option.
  proc waiting(half: seq[string]): bool =
    ## Does `half` end with an option still waiting for its value?
    if half.len < 2:
      return false              # `ct record --`: nothing before `--`
    let line = recordParserLine(half)
    let withEnd = probe(line & @[RecordOwnArgsEnd])
    if withEnd.parsed:
      return withEnd.args.len == 0 or withEnd.args[^1] != RecordOwnArgsEnd
    probe(line).parsed
  if not waiting(ownHalf):
    return ""
  var last = ownHalf.high
  while last > 1 and waiting(ownHalf[0 ..< last]):
    dec last
  ownHalf[last]

proc recordMissingValueError*(option: string): string =
  ## The refusal for an option that ends ct's half of the line without its
  ## value.  It names only what the user wrote.
  let bare = if option.endsWith("="): option[0 ..< ^1] else: option
  "error: `" & bare & "` needs a value: give it before `--`, as `" & bare &
    "=<value>` or `" & bare & " <value>`"

proc resolveRecordChild*(parsedProgram: string, parsedArgs: seq[string],
                         afterSeparator: seq[string]): RecordChild =
  ## `parsedProgram` / `parsedArgs`: what the parser read from
  ## `recordParserLine(ownHalf)`.  `afterSeparator`: the words after `--`.
  if parsedProgram != RecordProgramSlot:
    # Cannot happen while the slot is the first word after `record`; refuse
    # rather than record a program the user did not name.
    return RecordChild(error: "error: internal: `ct record` could not tell " &
      "which program to record (the parser moved the program slot)")
  if parsedArgs.len > 0:
    # `ct record [flags] prog [words] -- a b`: the program was named before
    # `--`.  Words between it and `--` stay its first arguments.
    result.program = parsedArgs[0]
    result.args = parsedArgs[1 .. ^1]
    result.args.add afterSeparator
    return
  # `ct record [flags] -- prog a b`
  if afterSeparator.len == 0:
    return RecordChild(error: "error: `ct record ... --` names no program: " &
      "give it before `--` (ct record prog -- args) or right after it " &
      "(ct record -- prog args)")
  RecordChild(program: afterSeparator[0], args: afterSeparator[1 .. ^1])

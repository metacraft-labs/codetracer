## record_child_argv — which words of a `ct record ... -- ...` line are the
## recorded program and which are its arguments.
##
## NORMATIVE SOURCE: `codetracer-specs/CLI/ct/record.md`, "Program arguments".
##
## Everything after the first `--` belongs to the recorded program, verbatim.
## The program itself may stand on either side of it:
##
##   ct record -- prog a b     the first word after `--` is the program;
##   ct record prog -- a b     the program was named before `--`, and every
##                             word after it is an argument.
##
## The caller appends `placeholder` to ct's own half of the line before
## parsing it, as the next positional.  The parser puts it in the program slot
## exactly when no program was named before `--`; otherwise it lands among the
## program's arguments.  This proc reads that outcome.
##
## PURE: asserted by `src/tests/cli/record_child_argv_test.nim`.

type
  RecordChild* = object
    program*: string
    args*: seq[string]
    error*: string     ## non-empty: print it and exit 1

proc resolveRecordChild*(parsedProgram: string, parsedArgs: seq[string],
                         afterSeparator: seq[string],
                         placeholder: string): RecordChild =
  ## `parsedProgram` / `parsedArgs`: what the parser read from ct's half of the
  ## line (placeholder included).  `afterSeparator`: the words after `--`.
  if parsedProgram == placeholder:
    # `ct record [flags] -- prog a b`
    if afterSeparator.len == 0:
      return RecordChild(error: "error: `ct record ... --` names no program: " &
        "give it before `--` (ct record prog -- args) or right after it " &
        "(ct record -- prog args)")
    return RecordChild(program: afterSeparator[0],
                       args: afterSeparator[1 .. ^1])
  # `ct record [flags] prog [words] -- a b`: the program was named before
  # `--`.  Words between it and `--` stay its first arguments; the
  # placeholder is dropped wherever the parser put it.
  result.program = parsedProgram
  for a in parsedArgs:
    if a != placeholder: result.args.add a
  result.args.add afterSeparator

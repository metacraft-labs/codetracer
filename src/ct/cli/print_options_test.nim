## print_options_test.nim
##
## How ct's switches are parsed: `ct print`'s `--verify` and `--follow`, and
## the `-i` / `--interactive` switch of `replay`, `console` and `upload`. A
## switch takes no value from the next token, works on either side of a
## positional argument, and a one-letter abbreviation is case-sensitive.
##
## `tests/test_ct_print.sh` states the `ct print` contract by running a built
## `ct` (`ct print <manifest> --verify` verifies, and fails for an empty
## manifest). That script needs a binary, so a regression in parsing went
## unseen until someone ran it. Three confutils defects were behind it:
##
## * `--verify` was declared `Option[bool]`, and confutils took any switch
##   whose type is not literally `bool` to want a value from the next token.
##   `ct print --verify <file>` spent `<file>` as the value and was refused;
##   `ct print <file> --verify` left the switch waiting for a value that never
##   came, and it was dropped, so the trace was printed instead of verified.
##   Recorded in codetracer-pm
##   `issues/2026-11-02-ct-print-ignores-verify-after-the-path-and-rejects-the-path-after-verify.md`.
##   `--interactive` is still `Option[bool]`, because `customValidateConfig`
##   needs to know whether it was given at all, so it covers the
##   `Option[bool]` half of the confutils fix.
## * `-F` (`--follow`) resolved to `-f` (`--filter`), because confutils
##   compared abbreviations case-insensitively.
## * A value-taking option with no value left was dropped silently.
##
## This suite parses through the production declaration, `CodetracerConf`,
## with the same `load` call `ct` makes, so it fails whenever the declaration
## or the parser does.
##
## No mocks: the argument vectors go through the real confutils parser.
##
## Lane: `ct-cli-units` (discovered by `src/ct/**/*_test.nim`).

import
  std/[options, unittest],
  confutils,
  ../codetracerconf

proc parseCt(args: openArray[string]): CodetracerConf =
  ## Parse `ct <args>` exactly as `ct` does, but raise a `ConfigurationError`
  ## instead of quitting, so a refusal is a test failure rather than the end
  ## of the test process.
  CodetracerConf.load(
    cmdLine = @args,
    printUsage = false,
    quitOnFailure = false)

proc parsePrint(args: openArray[string]): CodetracerConf =
  parseCt(@["print"] & @args)

proc refusalOf(args: openArray[string]): ref ConfigurationError =
  ## The error `ct <args>` is refused with, or nil when it parses.
  try:
    discard parseCt(args)
  except ConfigurationError as e:
    return e
  nil

suite "ct print: --verify and --follow are switches":
  test "--verify after the path is honoured":
    let conf = parsePrint(["trace.jsonl", "--verify"])
    check conf.cmd == StartupCommand.print
    check conf.printPath == "trace.jsonl"
    check conf.printVerify

  test "--verify before the path does not swallow the path":
    let conf = parsePrint(["--verify", "trace.jsonl"])
    check conf.printPath == "trace.jsonl"
    check conf.printVerify

  test "without --verify the trace is printed, not verified":
    let conf = parsePrint(["trace.jsonl"])
    check conf.printPath == "trace.jsonl"
    check not conf.printVerify
    check not conf.printFollow

  test "--verify between the path and a valued option leaves both intact":
    let conf = parsePrint(["trace.jsonl", "--verify", "--filter", "errors"])
    check conf.printPath == "trace.jsonl"
    check conf.printVerify
    check conf.printFilter.get("") == "errors"

  test "--follow is a flag on either side of the path":
    check parsePrint(["trace.jsonl", "--follow"]).printFollow
    let before = parsePrint(["--follow", "trace.jsonl"])
    check before.printFollow
    check before.printPath == "trace.jsonl"

  test "-F means --follow, and -f still means --filter":
    let follow = parsePrint(["-F", "trace.jsonl"])
    check follow.printFollow
    check follow.printPath == "trace.jsonl"
    check follow.printFilter.isNone
    let filter = parsePrint(["-f", "errors", "trace.jsonl"])
    check not filter.printFollow
    check filter.printFilter.get("") == "errors"
    check filter.printPath == "trace.jsonl"

  test "valued options still take the next token as their value":
    # The space-separated value form must keep working for the options that
    # do take one; the fix must not turn them into flags.
    let conf = parsePrint(["trace.jsonl", "--limit", "3", "--format", "json"])
    check conf.printPath == "trace.jsonl"
    check conf.printLimit.get(0) == 3
    check conf.printFormat.get("") == "json"
    check not conf.printVerify

  test "a valued option with no value left is refused, not dropped":
    for spelling in ["--filter", "-f", "--limit", "-n", "--format"]:
      let e = refusalOf(["print", "trace.jsonl", spelling])
      check e != nil
      if e != nil:
        check e.kind == cekMissingValue
        check e.option == spelling

suite "ct replay / console / upload: -i is a switch":
  test "-i before the pattern does not swallow it":
    # Parsing alone: `customValidateConfig` then refuses the pair, because
    # `-i` and a pattern each select the trace. Before the fix this line was
    # refused for a different reason: `'pattern' is not a valid boolean value`.
    let conf = parseCt(["replay", "-i", "calc"])
    check conf.cmd == StartupCommand.replay
    check conf.replayInteractive == some(true)
    check conf.lastTraceMatchingPattern == some("calc")

  test "-i after the pattern is applied":
    let conf = parseCt(["replay", "calc", "-i"])
    check conf.replayInteractive == some(true)
    check conf.lastTraceMatchingPattern == some("calc")

  test "-i alone, and --interactive, select interactive mode":
    check parseCt(["replay", "-i"]).replayInteractive == some(true)
    check parseCt(["replay", "--interactive"]).replayInteractive == some(true)
    check parseCt(["replay"]).replayInteractive.isNone

  test "an explicit value is still accepted":
    check parseCt(["replay", "--interactive=false"]).replayInteractive ==
      some(false)

  test "console and upload parse -i the same way":
    let console = parseCt(["console", "-i", "calc"])
    check console.consoleInteractive == some(true)
    check console.consoleLastTraceMatchingPattern == some("calc")
    let upload = parseCt(["upload", "calc", "-i"])
    check upload.uploadInteractive == some(true)
    check upload.uploadLastTraceMatchingPattern == some("calc")

  test "-I is not -i":
    let e = refusalOf(["replay", "-I"])
    check e != nil
    if e != nil: check e.kind == cekUnknownOption

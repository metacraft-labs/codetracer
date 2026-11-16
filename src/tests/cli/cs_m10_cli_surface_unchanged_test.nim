## CS-M10 (Clispec Library campaign, reprobuild-pm): `ct`'s whole command
## line, pinned BEFORE it moves from confutils' type-based loader to a clispec
## description.
##
## The milestone ("confutils users describe their command lines in clispec")
## requires the flags, environment variables, configuration files, defaults,
## help content and exit codes of `ct` to be unchanged for its users.  This
## test is the evidence: a golden capture taken from the tree before the move
## (`libs/nim-confutils` at 172981d, nim-confutils' `codetracer` branch, whose
## parsing ct keeps: CS-M10's decision of 2026-11-16, option (a); the first
## capture, at 3bf016c, was replaced by this one before the move), compared
## EXACTLY (whole files, no `contains`) with what the tree produces now.
##
## WHAT IS PINNED (goldens under `golden/cs_m10/linux-amd64/`):
##
##   * `parse_<command>.txt`: a table of argv cases for every command of
##     `CodetracerConf` (the enum subcommands `StartupCommand`, `ArbCommand`,
##     `CICommand` and `TraceCommand`), covering every option: its long and
##     short spellings, `--x v`, `--x=v`, `--x:v`, other letter cases and
##     `_` inside a name (confutils compares with `cmpIgnoreStyle`), values
##     that start with `-`, empty values, a value-taking option given last,
##     repeated options, switch values (`=true`, `=false`, `=maybe`, ...),
##     `--no-<switch>`, positionals (missing, extra), subcommand words in
##     other spellings, the environment variables the loader reads
##     (`<app path>_<OPTION NAME>`, upper-cased, `-` -> `_`: confutils'
##     default `envVarsPrefix` is `getAppFilename()`), and the completion
##     protocol it answers when `COMP_LINE` is set.  Each case records the
##     exit code, stdout and stderr, and, when the parse succeeds, the
##     resolved `CodetracerConf` field by field and the `replayInteractive`
##     global that `customValidateConfig` sets.
##
##     These cases go through the "parse probe": this very test binary,
##     started with `CT_CS_M10_PARSE_PROBE` set (to a marker file it creates
##     first) and the case's argv as its own argv, runs `CodetracerConf.load` with the arguments `codetracer.nim`
##     passes it (`version`, `copyrightBanner`, `cmdLine`) and then
##     `customValidateConfig` -- and stops there, where `ct` would call
##     `runInitial`.  A separate process per case because the loader ends the
##     process on every refusal and on `--help` (`quitOnFailure = true` is
##     what ct uses, and the only way to see its messages and exit codes),
##     and because `{.restOfArgs.}` reads the process's own `paramStr`, not
##     `cmdLine`.  The probe is the only place in this file that runs ct's
##     loader (`probeMain`); the description itself is asked only which help
##     a line requests (`expectedHelp`, under HELP below).
##   * `binary_help.txt`, through the real `ct` binary: every help request
##     (top level and per command and subcommand, `--help`, `-h`, the `help`
##     and `version` words, other spellings, other terminal widths; see HELP
##     below for how a help screen is compared), the
##     version, and the help-delegate commands that print the command surface
##     (`ct-describe-commands`, `ct-help`, `ct-complete`, `ct-completions`).
##   * `binary_dispatch.txt`, through the binary: the hand-written dispatch
##     that runs before the loader (`--ui`, `--deepreview`, `review`, `agent`,
##     `test`, `record ... --`), and EVERY parse-probe case that did not reach
##     the end of the parse (a refusal, a help or version screen), re-run as a
##     `ct` process, so the printed text and the exit code of the real binary
##     are pinned too.
##
## Cases whose parse SUCCEEDS are never run through the binary: `ct` would go
## on to open a window, record, upload, start a server or replay.  Neither is
## a case with `COMP_LINE` set (the loader prints the candidates and RETURNS;
## the probe pins what it returns, while `ct` itself stops there with exit 0
## -- `record_child_argv_test.nim` pins that through the binary), nor one that the
## hand-written dispatch before the loader could rewrite into a line that
## parses (`--`, `--ui`, `--headless`, the intercepted first words).  The
## explicit binary cases go through the probe first as well, and one that the
## probe says `ct` would run is recorded as `NOT RUN` instead of being run
## (`remote --help` and `electron --help`, where `{.restOfArgs.}` takes
## `--help`); if the probe cannot be started, no binary case runs at all.
##
## HELP.  ct's help screens are clispec's: what clispec renders by default
## for ct's description (CS-M10's decision of 2026-11-16), not a layout of
## ct's own, so they are not pinned as text.  For every run (probe or
## binary) the test asks the description in-process, with ct's options and
## the words ct's loader would get (`loaderLine`), whether the line asks for
## help: `CtCli.load` raising `CliHelpRequest` for that very request, and
## `ctHelpScreen` (the function ct's loader prints help with) rendering it
## with clispec's default layout.  The rendering reads no terminal: clispec's
## help does not wrap unless a layout asks it to and never looks at `COLUMNS`,
## a tty or `/dev/tty`, so neither the child's nor this process's terminal
## can reach it (the `COLUMNS` cases pin that ct ignores the variable too).
## When the run's stdout is exactly that text (with the newline
## ct ends it with), stdout is replaced by one marker line,
## `<the help clispec renders for this request: ct record>`, and the golden
## pins the marker, the exit code and stderr.  So the goldens pin WHICH help
## a line gets and the help's text follows clispec's default design without
## a re-capture; a help screen that differs from the rendering stays text and
## fails the comparison.  The version text, the help-delegate surface
## (`ct-help`, `ct-describe-commands`, `ct-complete`, `ct-completions`) and
## the help texts of the commands ct dispatches itself (`review`, `agent`)
## are not clispec's help and stay text.
##
## The goldens are text: a child's control characters are written `\e`,
## `\r`, `\0` or `\xNN`, and the last blank of a line that ends in one as
## `\x20` (or `\t`), so the repository's whitespace hooks cannot rewrite
## them; the binary's path, its environment prefix, the scratch directory and
## the version are replaced by `<BIN>`, `<APP>`, `<SCRATCH>` and `<VERSION>`.
##
## Configuration files: the loader reads none (`ct` passes no
## `secondarySources`); what `ct` reads itself is not part of this surface.
##
## REGENERATING.  The goldens are written by this file, never by hand:
##
##     nim c -r src/tests/cli/cs_m10_cli_surface_unchanged_test.nim --write-goldens [dir]
##
## writes them (to `dir`, default the golden directory) from the tree it is
## compiled in.  To regenerate from the baseline after the move, run that in a
## checkout of the baseline commit (this file is part of it) and compare.
##
## The binary is `$CODETRACER_E2E_CT_PATH`, else `$CODETRACER_BUILD_DIR/bin/ct`,
## else `src/build-debug/bin/ct` (the order the other CLI suites use).  A
## binary older than any source it is built from (`src/ct`, `src/common`,
## `src/ct_test`, `libs/nim-confutils`, `libs/nim-cli-spec`, the repo
## `config.nims`) would pin the previous build rather than this tree, so the
## test REFUSES it by name.
##
## Linux/amd64 only: the declarations and the dispatch have platform arms, so
## the goldens are per platform and only this one has been captured.
##
## Lane: `cli-record` (`ci/lib/test-lane-files.sh` globs `src/tests/cli`).

when not (defined(linux) and defined(amd64)):
  {.error: "cs_m10_cli_surface_unchanged_test: goldens exist for linux/amd64 only".}

import std/[os, osproc, strutils, streams, strtabs, times, options, tempfiles,
            unittest]
import confutils/defs
import confutils/clispec_config
import ../../ct/[codetracerconf, globals, ui_selection, version]
import ../../ct/trace/record_child_argv

const
  ThisDir = currentSourcePath.parentDir
  GoldenDir = ThisDir / "golden" / "cs_m10" / "linux-amd64"
  RepoRoot = ThisDir.parentDir.parentDir.parentDir

  ## The environment variable that turns this binary into the parse probe.
  ## Its value is a file the probe creates before it parses: a run without
  ## it did not reach the loader (the probe could not be started at all),
  ## so it says nothing about the case, and the case is never handed to the
  ## real binary on its strength.
  ProbeEnvVar = "CT_CS_M10_PARSE_PROBE"
  ProbeMarker = "probe-started"

  ## What `codetracer.nim` passes to the loader.  The version text is the
  ## same expression; it is replaced by `<VERSION>` in every golden (with
  ## the `(debug)` that a `-d:debug` build appends), so neither a release nor
  ## the build flavour of the binary changes them.
  VersionText = "CodeTracer version: " & version.CodeTracerVersionStr & (
    when defined(debug): "(debug)" else: "")
  BannerText = "CodeTracer - the user-friendly time-travelling debugger"

  ## Binary runs (probe or `ct`) in flight at once.  Each is a few ms of CPU
  ## and otherwise waits on exec; every run has its own scratch directory, so
  ## the order they finish in cannot reach the output.
  MaxInFlight = 8

type
  Case = object
    label: string
    argv: seq[string]
    env: seq[(string, string)]   ## `<APP>` in a name: the binary's env prefix

  Group = object
    name: string                 ## golden file stem
    title: string
    cases: seq[Case]

  Run = tuple[code: int, output: string, failure: string]

# ─── the parse probe ─────────────────────────────────────────────────────────

proc lit(s: string): string = s.escape()

proc render[T](v: T): string =
  when T is string:
    lit(v)
  elif T is Option:
    if v.isSome: "some(" & render(v.get) & ")" else: "none"
  elif T is seq or T is array:
    var parts: seq[string]
    for x in v: parts.add render(x)
    "@[" & parts.join(", ") & "]"
  elif T is enum:
    $v
  else:
    $v

proc renderFields[T](v: T): string =
  ## One line per field of the resolved configuration object (the branch
  ## fields of the commands that were chosen, and only those).
  for k, x in v.fieldPairs:
    result.add "  " & k & " = " & render(x) & "\n"

proc probeMain(): int =
  ## `ct`'s parse, up to the point where `ct` calls `runInitial`.  THE ONE
  ## CALL OF THE LOADER IN THIS FILE: the same arguments as `codetracer.nim`.
  try:
    writeFile(getEnv(ProbeEnvVar), "")
  except IOError:
    return 3
  var conf = CodetracerConf.load(
    version = VersionText,
    copyrightBanner = BannerText,
    cmdLine = commandLineParams())
  stdout.write "PARSED\n" & renderFields(conf)
  stdout.flushFile()
  customValidateConfig(conf)
  stdout.write "VALIDATED replayInteractive = " & $replayInteractive & "\n"
  stdout.flushFile()
  0

# ─── case builders ───────────────────────────────────────────────────────────

proc add(cs: var seq[Case]; label: string; argv: seq[string];
         env: seq[(string, string)] = @[]) =
  cs.add Case(label: label, argv: argv, env: env)

proc styleVariants(s: string): seq[string] =
  ## Other spellings of a long option that confutils' `cmpIgnoreStyle`
  ## treats as the same name (letter case, `_`), and two that it does not
  ## (`-` dropped, the name in camelCase).
  if not s.startsWith("--") or s.len < 4: return
  let name = s[2 .. ^1]
  result.add "--" & name.toUpperAscii
  result.add "--" & name[0] & "_" & name[1 .. ^1]
  if '-' in name:
    result.add "--" & name.replace("-", "_")
    result.add "--" & name.replace("-", "")

proc valueOption(cs: var seq[Case]; spellings: openArray[string];
                 good, bad: openArray[string]; pre, post: seq[string]) =
  ## A value-taking option: every spelling with the first good value as the
  ## next word, attached with `=` and with `:`; every good and bad value in
  ## both forms; empty values; `=` followed by the value as the next word; a
  ## value that starts with `-`; the option given twice; the option last with
  ## no value, and with no value before the rest; other letter cases and
  ## separators in the name.
  let s0 = spellings[0]
  let g0 = good[0]
  for s in spellings:
    cs.add s & " <v>", pre & @[s, g0] & post
    cs.add s & "=<v>", pre & @[s & "=" & g0] & post
    cs.add s & ":<v>", pre & @[s & ":" & g0] & post
    if not s.startsWith("--"):
      cs.add s & "<v> (attached)", pre & @[s & g0] & post
      cs.add s.toUpperAscii & " <v> (other case)", pre & @[s.toUpperAscii, g0] & post
      cs.add "-" & s & " <v> (the letter as a long option)", pre & @["-" & s, g0] & post
  for g in good:
    cs.add s0 & " " & g, pre & @[s0, g] & post
    cs.add s0 & "=" & g, pre & @[s0 & "=" & g] & post
  for b in bad:
    cs.add s0 & " bad " & b, pre & @[s0, b] & post
    cs.add s0 & "=bad " & b, pre & @[s0 & "=" & b] & post
  cs.add s0 & " empty", pre & @[s0, ""] & post
  cs.add s0 & "= (empty)", pre & @[s0 & "="] & post
  cs.add s0 & "= <v> (next word)", pre & @[s0 & "=", g0] & post
  cs.add s0 & " -x (value starts with -)", pre & @[s0, "-x"] & post
  cs.add s0 & " --x (value starts with --)", pre & @[s0, "--x"] & post
  cs.add s0 & " --new-tab <v> (an option between it and its value)",
    pre & @[s0, "--new-tab", g0] & post
  cs.add s0 & " repeated, last wins", pre & @[s0, g0, s0, good[^1]] & post
  cs.add s0 & " missing value (last)", pre & post & @[s0]
  if post.len > 0:
    cs.add s0 & " missing value (before the rest)", pre & @[s0] & post
  for v in styleVariants(s0):
    cs.add v & " <v> (style variant)", pre & @[v, g0] & post

proc switchOption(cs: var seq[Case]; spellings: openArray[string];
                  pre, post: seq[string]) =
  ## A switch: every spelling bare, explicit values, given twice, the
  ## `--no-` form, a following word, other letter cases and separators.
  let s0 = spellings[0]
  for s in spellings:
    cs.add s, pre & @[s] & post
    if not s.startsWith("--"):
      cs.add s.toUpperAscii & " (other case)", pre & @[s.toUpperAscii] & post
      cs.add "-" & s & " (the letter as a long option)", pre & @["-" & s] & post
  for v in ["true", "false", "on", "off", "yes", "no", "1", "0", "maybe", ""]:
    cs.add s0 & "=" & v, pre & @[s0 & "=" & v] & post
  cs.add s0 & ":false", pre & @[s0 & ":false"] & post
  cs.add s0 & " false (next word)", pre & @[s0, "false"] & post
  cs.add s0 & " twice", pre & @[s0, s0] & post
  if s0.startsWith("--"):
    cs.add "--no-" & s0[2 .. ^1], pre & @["--no-" & s0[2 .. ^1]] & post
  for v in styleVariants(s0):
    cs.add v & " (style variant)", pre & @[v] & post

proc optionalSwitch(cs: var seq[Case]; spellings: openArray[string];
                    pre, post: seq[string]) =
  ## An `Option[bool]` option (`--interactive`): it takes a value, so it is
  ## pinned both ways -- with boolean words and with what follows it.
  let s0 = spellings[0]
  for s in spellings:
    cs.add s & " (last)", pre & post & @[s]
    cs.add s & " true", pre & @[s, "true"] & post
    cs.add s & "=false", pre & @[s & "=false"] & post
  for v in ["true", "false", "on", "maybe", ""]:
    cs.add s0 & "=" & v, pre & @[s0 & "=" & v] & post
  cs.add s0 & " <pattern> (next word)", pre & @[s0, "prog"] & post
  cs.add s0 & " --cwd=x (next word an option)", pre & @[s0, "--cwd=x"] & post
  if s0.startsWith("--"):
    cs.add "--no-" & s0[2 .. ^1], pre & @["--no-" & s0[2 .. ^1]] & post

proc commonTail(cs: var seq[Case]; pre, post: seq[string]) =
  ## What every command is asked: an unknown long and short option, a lone
  ## `-` and `--`, `--help`/`-h`/`--version` after the command, an extra
  ## positional, and a global option after the command.
  cs.add "unknown long option", pre & @["--bogus"] & post
  cs.add "unknown long option with value", pre & @["--bogus=1"] & post
  cs.add "unknown short option", pre & @["-Z"] & post
  cs.add "lone -", pre & @["-"] & post
  cs.add "lone -- then a word", pre & @["--", "w"] & post
  cs.add "--=v", pre & @["--=v"] & post
  cs.add "extra positional", pre & post & @["extra1", "extra2", "extra3", "extra4", "extra5"]
  cs.add "global --cwd after the command", pre & @["--cwd", "/w"] & post
  cs.add "global --new-tab after the command", pre & @["--new-tab"] & post
  cs.add "--version after the command", pre & @["--version"] & post
  cs.add "-h after the command", pre & @["-h"] & post

# ─── the case table, command by command ──────────────────────────────────────

proc rootCases(): seq[Case] =
  var c: seq[Case]
  c.add "no arguments", @[]
  c.add "the empty word", @[""]
  c.add "unknown command", @["frobnicate"]
  c.add "unknown command that looks like an option", @["--frobnicate"]
  c.add "-h", @["-h"]
  c.add "-H", @["-H"]
  c.add "--version", @["--version"]
  c.add "--VERSION", @["--VERSION"]
  c.add "-v", @["-v"]
  c.add "version (a word)", @["version"]
  c.add "--version=1", @["--version=1"]
  c.add "lone -", @["-"]
  c.add "lone --", @["--"]
  c.add "-- then a word", @["--", "list"]
  c.add "--=v", @["--=v"]
  c.add "-=v", @["-=v"]
  c.add "noCommand (the default's name)", @["noCommand"]
  c.add "nocommand", @["nocommand"]
  # the subcommand word in other spellings (findCmd: cmpIgnoreStyle)
  for w in ["LIST", "List", "l_ist", "get_default_org", "getdefaultorg",
            "GET-DEFAULT-ORG", "startbackend", "START_BACKEND", "StartBackend",
            "start-backend", "ctdescribecommands", "Import", "TRACE", "gfx_replay",
            "gfxreplay", "listrecenttx", "lis"]:
    c.add "command word " & w, @[w]
  # the global options, before any command
  let pre: seq[string] = @[]
  let post: seq[string] = @[]
  c.valueOption(["--cwd"], ["/w", "rel/dir"], [], pre, post)
  c.valueOption(["--env-file"], ["a.env", "b.env"], [], pre, post)
  c.valueOption(["--env0-file"], ["a.env0", "b.env0"], [], pre, post)
  c.valueOption(["--tmp-env-file"], ["t.env", "u.env"], [], pre, post)
  c.valueOption(["--tmp-env0-file"], ["t.env0", "u.env0"], [], pre, post)
  c.valueOption(["--inspect"], ["9229", "0.0.0.0:9229"], [], pre, post)
  c.valueOption(["--remote-debugging-port"], ["9222", "0"], [], pre, post)
  c.switchOption(["--remote-debugging-pipe"], pre, post)
  c.switchOption(["--new-tab"], pre, post)
  c.switchOption(["--new-window"], pre, post)
  c.add "--new-tab --new-window", @["--new-tab", "--new-window"]
  c.add "every global option, then a command", @["--cwd=/w", "--env-file", "a",
    "--env0-file=b", "--tmp-env-file", "c", "--tmp-env0-file", "d",
    "--inspect=1", "--remote-debugging-port", "2", "--remote-debugging-pipe",
    "--new-window", "list"]
  c.add "-- matches the first option (cwd)", @["--", "/w", "list"]
  c.add "unknown short cluster", @["-xyz"]
  # the environment, under the binary's own prefix
  c.add "env <APP>_CWD", @["list"], @[("<APP>_CWD", "/from-env")]
  c.add "env <APP>_CWD, flag wins", @["--cwd", "/flag", "list"], @[("<APP>_CWD", "/from-env")]
  c.add "env <APP>_ENV_FILE", @["list"], @[("<APP>_ENV_FILE", "e.env")]
  c.add "env <APP>_NEW_TAB=true", @["list"], @[("<APP>_NEW_TAB", "true")]
  c.add "env <APP>_NEW_TAB=maybe", @["list"], @[("<APP>_NEW_TAB", "maybe")]
  c.add "env <APP>_NEW_TAB= (empty)", @["list"], @[("<APP>_NEW_TAB", "")]
  c.add "env <APP>_REMOTE_DEBUGGING_PIPE=1", @[], @[("<APP>_REMOTE_DEBUGGING_PIPE", "1")]
  c.add "env <APP>_CMD=list (the discriminator)", @[], @[("<APP>_CMD", "list")]
  c.add "env <APP>_cwd (lower case: not read)", @["list"], @[("<APP>_cwd", "/lower")]
  c.add "env CT_CWD (another prefix: not read)", @["list"], @[("CT_CWD", "/ct")]
  c.add "env CODETRACER_CWD (another prefix: not read)", @["list"], @[("CODETRACER_CWD", "/c")]
  # the completion protocol (COMP_LINE / COMP_POINT)
  for (line, point) in [("ct ", -1), ("ct rec", -1), ("ct record --", -1),
                        ("ct record -", -1), ("ct print -", -1),
                        ("ct upload --omniscient-db ", -1),
                        ("ct upload --omniscient-db=", -1),
                        ("ct trace ", -1), ("ct ci ", -1), ("ct ci exec --", -1),
                        ("ct --e", -1), ("ct arb ", -1), ("ct record ", -1),
                        ("ct list", 3), ("ct ", 99), ("ct x", -5)]:
    let p = if point == -1: $line.len else: $point
    c.add "COMP_LINE " & lit(line) & " COMP_POINT " & p, @[],
      @[("COMP_LINE", line), ("COMP_POINT", p)]
  c.add "COMP_LINE with a bad COMP_POINT", @[], @[("COMP_LINE", "ct "), ("COMP_POINT", "x")]
  c.add "COMP_LINE without COMP_POINT", @[], @[("COMP_LINE", "ct li")]
  c.add "COMP_LINE with argv", @["list", "--format", "json"], @[("COMP_LINE", "ct li"), ("COMP_POINT", "5")]
  c

proc installCases(): seq[Case] =
  var c: seq[Case]
  let pre = @["install"]
  let post: seq[string] = @[]
  c.add "bare", pre
  c.switchOption(["--path", "-p"], pre, post)
  c.switchOption(["--desktop", "-d"], pre, post)
  c.switchOption(["--bpf"], pre, post)
  c.switchOption(["--agent-harbor"], pre, post)
  c.switchOption(["--json"], pre, post)
  c.add "-pd (cluster)", pre & @["-pd"]
  c.add "-p=false -d=false", pre & @["-p=false", "-d=false"]
  c.add "env <APP>_PATH=false", pre, @[("<APP>_PATH", "false")]
  c.add "env <APP>_AGENT_HARBOR=0", pre, @[("<APP>_AGENT_HARBOR", "0")]
  c.commonTail(pre, post)
  c

proc listCases(): seq[Case] =
  var c: seq[Case]
  let pre = @["list"]
  c.add "bare", pre
  c.add "target remote", pre & @["remote"]
  c.add "target local", pre & @["local"]
  c.add "target other", pre & @["other"]
  c.add "two targets", pre & @["local", "remote"]
  c.valueOption(["--format"], ["json", "text"], ["xml"], pre, @[])
  c.valueOption(["--format"], ["json"], [], pre, @["remote"])
  c.add "env <APP>_FORMAT=json", pre, @[("<APP>_FORMAT", "json")]
  c.add "env <APP>_LISTTARGET=remote (a positional)", pre, @[("<APP>_LISTTARGET", "remote")]
  c.add "env <APP>_TARGET=remote (the argument's name)", pre, @[("<APP>_TARGET", "remote")]
  c.commonTail(pre, @[])
  c

proc printCases(): seq[Case] =
  var c: seq[Case]
  let pre = @["print"]
  let post = @["t.jsonl"]
  c.add "no path", pre
  c.add "path", pre & post
  c.add "two paths", pre & @["a", "b"]
  c.add "path starting with -", pre & @["-t.jsonl"]
  c.valueOption(["--filter", "-f"], ["calls", "errors"], [], pre, post)
  c.valueOption(["--function"], ["main"], [], pre, post)
  c.valueOption(["--limit", "-n"], ["5", "-1", "0"], ["ten", "1.5", "0x10"], pre, post)
  c.valueOption(["--format"], ["json", "csv"], [], pre, post)
  c.switchOption(["--verify"], pre, post)
  c.switchOption(["--follow", "-F"], pre, post)
  c.add "--verify before the path", pre & @["--verify", "t.jsonl"]
  c.add "--verify after the path", pre & @["t.jsonl", "--verify"]
  c.add "--follow before the path", pre & @["--follow", "t.jsonl"]
  c.add "-F x (filter or follow?)", pre & @["-F", "x", "t.jsonl"]
  c.add "-f x -F", pre & @["-f", "x", "-F", "t.jsonl"]
  c.add "-n5 (attached)", pre & @["-n5", "t.jsonl"]
  c.add "-fn (cluster)", pre & @["-fn", "t.jsonl"]
  c.add "env <APP>_PRINTPATH (the positional)", pre, @[("<APP>_PRINTPATH", "e.jsonl")]
  c.add "env <APP>_LIMIT=ten", pre & post, @[("<APP>_LIMIT", "ten")]
  c.add "env <APP>_VERIFY=yes", pre & post, @[("<APP>_VERIFY", "yes")]
  c.commonTail(pre, post)
  c

proc traceSelectorCases(cmd: string; extra: proc (c: var seq[Case]; pre, post: seq[string])): seq[Case] =
  ## `replay`, `console` and `upload` share `--id`, `--trace-folder`/`-t`, a
  ## pattern and `--interactive`/`-i`, and `customValidateConfig`'s rule that
  ## at most one of them is given.
  var c: seq[Case]
  let pre = @[cmd]
  let post: seq[string] = @[]
  c.add "bare", pre
  c.add "pattern", pre & @["prog"]
  c.add "two patterns", pre & @["a", "b"]
  c.valueOption(["--id"], ["0190d7a0", "0190d7a0-1234-7abc-8def-0123456789ab"], [], pre, post)
  c.valueOption(["--trace-folder", "-t"], ["/tr", "rel"], [], pre, post)
  c.optionalSwitch(["--interactive", "-i"], pre, post)
  c.add "--id and a pattern", pre & @["--id", "x", "prog"]
  c.add "--id and -t", pre & @["--id", "x", "-t", "/tr"]
  c.add "-t and -i", pre & @["-t", "/tr", "-i", "true"]
  c.add "pattern and -i false", pre & @["prog", "-i", "false"]
  c.add "-i false alone", pre & @["-i", "false"]
  c.add "-i true alone", pre & @["-i", "true"]
  c.add "-ti (cluster)", pre & @["-ti", "x"]
  c.add "env <APP>_ID", pre, @[("<APP>_ID", "0190d7a0")]
  c.add "env <APP>_INTERACTIVE=false", pre, @[("<APP>_INTERACTIVE", "false")]
  c.add "env <APP>_INTERACTIVE=maybe", pre, @[("<APP>_INTERACTIVE", "maybe")]
  extra(c, pre, post)
  c.commonTail(pre, post)
  c

proc replayExtra(c: var seq[Case]; pre, post: seq[string]) =
  c.valueOption(["--thread-sync-order"], ["total", "per-object"], ["bogus"], pre, post)
  c.valueOption(["--os-simulation"], ["weak-userspace", "strong-kernel"], ["bogus"], pre, post)
  c.valueOption(["--follow-request-spans"], ["1", "0"], ["yes"], pre, post)
  c.add "env <APP>_OS_SIMULATION", pre, @[("<APP>_OS_SIMULATION", "strong-kernel")]
  c.add "env CT_OS_SIMULATION (read later, not by the loader)", pre, @[("CT_OS_SIMULATION", "strong-kernel")]
  c.add "every replay option", pre & @["-t", "/tr", "--thread-sync-order", "total",
    "--os-simulation=weak-userspace", "--follow-request-spans", "1", "--new-window"]

proc consoleExtra(c: var seq[Case]; pre, post: seq[string]) = discard

proc uploadExtra(c: var seq[Case]; pre, post: seq[string]) =
  c.valueOption(["--org"], ["acme"], [], pre, post)
  c.valueOption(["--token"], ["tok"], [], pre, post)
  c.valueOption(["--base-url"], ["https://x.test"], [], pre, post)
  c.switchOption(["--no-portable"], pre, post)
  c.switchOption(["--no-split-upload"], pre, post)
  c.valueOption(["--omniscient-db"], ["off", "on", "lazy", "pre-prepared"],
    ["bogus", "LAZY", "Lazy", "pre_prepared", "preprepared", "Pre-Prepared", "OFF", "o_n"], pre, post)
  c.valueOption(["--artifact"], ["/a/dir"], [], pre, post)
  c.valueOption(["--kind"], ["recording", "review-dataset"], [], pre, post)
  c.switchOption(["--encrypt"], pre, post)
  c.valueOption(["--password-file"], ["pw.txt", "-"], [], pre, post)
  c.switchOption(["--password-stdin"], pre, post)
  c.valueOption(["--visibility"], ["tenant", "tenant-or-invite"], [], pre, post)
  c.add "--portable (removed spelling)", pre & @["--portable"]
  c.add "env <APP>_OMNISCIENT_DB=lazy", pre, @[("<APP>_OMNISCIENT_DB", "lazy")]
  c.add "env <APP>_OMNISCIENT_DB=bogus", pre, @[("<APP>_OMNISCIENT_DB", "bogus")]
  c.add "env <APP>_ENCRYPT=on", pre, @[("<APP>_ENCRYPT", "on")]

proc hostCases(): seq[Case] =
  var c: seq[Case]
  let pre = @["host"]
  let post: seq[string] = @[]
  c.add "bare", pre
  c.add "trace arg", pre & @["42"]
  c.add "two trace args", pre & @["42", "43"]
  c.valueOption(["--port"], ["5000", "0", "-1"], ["http", "50.5", "99999999999999999999"], pre, post)
  c.valueOption(["--bind"], ["0.0.0.0", "::1"], [], pre, post)
  c.valueOption(["--backend-socket-port"], ["5001"], ["x"], pre, post)
  c.valueOption(["--frontend-socket"], ["5002"], ["x"], pre, post)
  c.valueOption(["--frontend-socket-parameters"], ["a=b"], [], pre, post)
  c.valueOption(["--idle-timeout"], ["30s", "never"], [], pre, post)
  c.valueOption(["--trace-path"], ["/t.ct"], [], pre, post)
  c.valueOption(["--manifest"], ["/m.json"], [], pre, post)
  c.valueOption(["--storage-base-url"], ["https://s.test"], [], pre, post)
  c.valueOption(["--storage-tenant-id"], ["ten"], [], pre, post)
  c.valueOption(["--storage-token"], ["tok"], [], pre, post)
  c.valueOption(["--storage-protocol"], ["local-storage"], [], pre, post)
  c.add "env <APP>_PORT=7", pre, @[("<APP>_PORT", "7")]
  c.add "env <APP>_PORT=x", pre, @[("<APP>_PORT", "x")]
  c.add "env CODETRACER_HOST_PORT (read later, not by the loader)", pre, @[("CODETRACER_HOST_PORT", "7")]
  c.commonTail(pre, post)
  c

proc positionalCases(cmd: string; names: seq[string]; extraOpts: proc (c: var seq[Case]; pre, post: seq[string]) = nil): seq[Case] =
  ## A command whose surface is positionals (and maybe a few options): none,
  ## each prefix of them, one too many, one that starts with `-`.
  var c: seq[Case]
  let pre = @[cmd]
  var vals: seq[string]
  c.add "no arguments", pre
  for i, n in names:
    vals.add n & "1"
    c.add $(i + 1) & " argument(s)", pre & vals
  c.add "one argument too many", pre & vals & @["surplus"]
  if names.len > 0:
    c.add "an argument starting with -", pre & @["-a"] & vals[1 .. ^1]
  if extraOpts != nil:
    extraOpts(c, pre, vals)
  c.commonTail(pre, vals)
  c

proc recordCases(): seq[Case] =
  var c: seq[Case]
  let pre = @["record"]
  let post = @["prog"]
  c.add "no program", pre
  c.add "program", pre & post
  c.add "program and args", pre & @["prog", "a", "b"]
  c.add "program and args that look like options", pre & @["prog", "-x", "--y"]
  c.add "program then a ct option", pre & @["prog", "--lang", "python"]
  c.add "program then -o", pre & @["prog", "-o", "/out"]
  c.add "args after a word", pre & @["prog", "a", "-o", "/out", "b"]
  c.valueOption(["--lang"], ["python", "ruby", ""], [], pre, post)
  c.valueOption(["--output-folder", "-o"], ["/out", "rel"], [], pre, post)
  c.valueOption(["--backend"], ["mcr", "rr", "ttd"], ["bogus"], pre, post)
  c.valueOption(["--export", "-e"], ["/e.zip"], [], pre, post)
  c.valueOption(["--stylus-trace", "-t"], ["/s.json"], [], pre, post)
  c.valueOption(["--address", "-a"], ["0xabc"], [], pre, post)
  c.valueOption(["--socket"], ["/sock"], [], pre, post)
  c.valueOption(["--with-diff"], ["last-commit", "HEAD~1"], [], pre, post)
  c.valueOption(["--store-trace-folder-for-pid"], ["123", "0"], ["pid", "1e3"], pre, post)
  c.switchOption(["--upload"], pre, post)
  c.switchOption(["--use-interpose"], pre, post)
  c.switchOption(["--server"], pre, post)
  c.switchOption(["--portable"], pre, post)
  c.add "-oe (cluster)", pre & @["-oe", "x", "prog"]
  c.add "-o/out (attached)", pre & @["-o/out", "prog"]
  c.add "env <APP>_LANG", pre & post, @[("<APP>_LANG", "ruby")]
  c.add "env <APP>_LANG, flag wins", pre & @["--lang", "python"] & post, @[("<APP>_LANG", "ruby")]
  c.add "env <APP>_RECORDPROGRAM (the positional)", pre, @[("<APP>_RECORDPROGRAM", "envprog")]
  c.add "env <APP>_RECORDARGS (the list positional)", pre & post, @[("<APP>_RECORDARGS", "a1")]
  c.add "env <APP>_STORE_TRACE_FOLDER_FOR_PID=x", pre & post, @[("<APP>_STORE_TRACE_FOLDER_FOR_PID", "x")]
  c.add "env <APP>_PORTABLE=on", pre & post, @[("<APP>_PORTABLE", "on")]
  c.add "env CODETRACER_PORTABLE (read later, not by the loader)", pre & post, @[("CODETRACER_PORTABLE", "on")]
  c.commonTail(pre, post)
  c

proc recordTestCases(): seq[Case] =
  var c: seq[Case]
  let pre = @["record-test"]
  let post = @["name", "path", "10", "1"]
  c.add "no arguments", pre
  c.add "name", pre & @["name"]
  c.add "name path", pre & @["name", "path"]
  c.add "name path line", pre & @["name", "path", "10"]
  c.add "all four", pre & post
  c.add "bad line", pre & @["name", "path", "ten", "1"]
  c.add "bad column", pre & @["name", "path", "10", "x"]
  c.add "negative line", pre & @["name", "path", "-3", "1"]
  c.valueOption(["--with-diff"], ["last-commit"], [], pre, post)
  c.valueOption(["--store-trace-folder-for-pid"], ["7"], ["x"], pre, post)
  c.add "env <APP>_RECORDTESTLINE=5", pre & @["name", "path"], @[("<APP>_RECORDTESTLINE", "5"), ("<APP>_RECORDTESTCOLUMN", "2")]
  c.commonTail(pre, post)
  c

proc restCases(cmd: string; first: seq[string]): seq[Case] =
  ## `run`, `remote` and `electron` end in `{.restOfArgs.}`, which the loader
  ## fills from the PROCESS's own arguments (`paramStr`), not `cmdLine`.
  var c: seq[Case]
  let pre = @[cmd]
  c.add "bare", pre
  c.add "one word", pre & first
  c.add "words", pre & first & @["a", "b"]
  c.add "words that look like options", pre & first & @["-x", "--y=1", "--cwd", "/z"]
  c.add "a ct option first", pre & @["--new-tab"] & first & @["a"]
  c.add "-- inside", pre & first & @["--", "a"]
  c.add "--help inside", pre & first & @["a", "--help"]
  c.commonTail(pre, first)
  c

proc downloadCases(): seq[Case] =
  var c: seq[Case]
  let pre = @["download"]
  let post = @["https://x.test/t/1"]
  c.add "no url", pre
  c.add "url", pre & post
  c.add "two urls", pre & @["u1", "u2"]
  c.valueOption(["--token"], ["tok"], [], pre, post)
  c.valueOption(["--base-url"], ["https://b.test"], [], pre, post)
  c.valueOption(["--password-file"], ["pw.txt", "-"], [], pre, post)
  c.switchOption(["--password-stdin"], pre, post)
  c.add "env <APP>_TRACEDOWNLOADURL", pre, @[("<APP>_TRACEDOWNLOADURL", "https://env.test")]
  c.commonTail(pre, post)
  c

proc tokenBaseUrlCases(cmd: string): seq[Case] =
  var c: seq[Case]
  let pre = @[cmd]
  c.add "bare", pre
  c.add "a word", pre & @["w"]
  c.valueOption(["--token"], ["tok"], [], pre, @[])
  c.valueOption(["--base-url"], ["https://b.test"], [], pre, @[])
  c.add "env <APP>_TOKEN", pre, @[("<APP>_TOKEN", "envtok")]
  c.commonTail(pre, @[])
  c

proc loginCases(): seq[Case] =
  var c: seq[Case]
  let pre = @["login"]
  c.add "bare", pre
  c.valueOption(["--default-org"], ["acme"], [], pre, @[])
  c.valueOption(["--base-url"], ["https://b.test"], [], pre, @[])
  c.commonTail(pre, @[])
  c

proc arbCases(): seq[Case] =
  var c: seq[Case]
  let pre = @["arb"]
  c.add "bare", pre
  c.valueOption(["--arbitrum-rpc-url"], ["http://n.test:8547"], [], pre, @[])
  c.valueOption(["--arbitrum-rpc-url"], ["http://n.test:8547"], [], pre, @["explorer"])
  for sub in ["explorer", "deploy", "listRecentTx", "listrecenttx", "list-recent-tx",
              "noCommand", "Explorer", "bogus"]:
    c.add "subcommand " & sub, pre & @[sub]
  c.add "record no tx", pre & @["record"]
  c.add "record tx", pre & @["record", "0xabc"]
  c.add "record two txs", pre & @["record", "0xabc", "0xdef"]
  c.add "replay tx", pre & @["replay", "0xabc"]
  c.add "replay no tx", pre & @["replay"]
  c.add "rpc url after the subcommand", pre & @["explorer", "--arbitrum-rpc-url", "u"]
  c.add "help word", pre & @["help"]
  c.add "version word", pre & @["version"]
  c.add "explorer help word", pre & @["explorer", "help"]
  c.add "record --help", pre & @["record", "--help"]
  c.add "two subcommands", pre & @["explorer", "deploy"]
  c.add "a StartupCommand word", pre & @["list"]
  c.add "env <APP>_ARBITRUM_RPC_URL", pre, @[("<APP>_ARBITRUM_RPC_URL", "http://env.test")]
  c.add "env <APP>_ARBCOMMAND=deploy", pre, @[("<APP>_ARBCOMMAND", "deploy")]
  c.add "env <APP>_ARBRECORDTRANSACTION", pre & @["record"], @[("<APP>_ARBRECORDTRANSACTION", "0xenv")]
  c.commonTail(pre, @[])
  c.commonTail(pre & @["explorer"], @[])
  c

proc ciCases(): seq[Case] =
  var c: seq[Case]
  let pre = @["ci"]
  c.add "bare", pre
  c.valueOption(["--token"], ["tok"], [], pre, @[])
  c.valueOption(["--base-url"], ["https://b.test"], [], pre, @[])
  c.add "--token after the subcommand", pre & @["status", "--token", "t"]
  for sub in ["status", "cancel", "Status", "STATUS", "bogus", "noCommand"]:
    c.add "subcommand " & sub, pre & @[sub]
  c.add "help word", pre & @["help"]
  c.add "status help word", pre & @["status", "help"]
  c.add "status extra", pre & @["status", "extra"]
  # start / run share their run-description options
  for sub in ["start", "run"]:
    let spre = pre & @[sub]
    let spost = if sub == "run": @["cmd"] else: @[]
    c.add sub & " bare", spre
    c.valueOption(["--repo"], ["https://g.test/r"], [], spre, spost)
    c.valueOption(["--commit"], ["abc123"], [], spre, spost)
    c.valueOption(["--branch"], ["main"], [], spre, spost)
    c.valueOption(["--base-commit"], ["def456"], [], spre, spost)
    c.valueOption(["--label"], ["nightly"], [], spre, spost)
    c.switchOption(["--monitor-processes"], spre, spost)
    c.commonTail(spre, spost)
  c.add "run cmd args", pre & @["run", "cmd", "a", "b"]
  c.switchOption(["--record"], pre & @["run"], @["cmd"])
  c.add "attach no id", pre & @["attach"]
  c.add "attach id", pre & @["attach", "r1"]
  c.add "attach two ids", pre & @["attach", "r1", "r2"]
  c.commonTail(pre & @["attach"], @["r1"])
  c.add "exec bare", pre & @["exec"]
  c.add "exec cmd", pre & @["exec", "cmd"]
  c.add "exec cmd args", pre & @["exec", "cmd", "a", "b"]
  c.add "exec cmd args that look like options", pre & @["exec", "cmd", "-x", "--y"]
  c.switchOption(["--monitor-processes"], pre & @["exec"], @["cmd"])
  c.switchOption(["--record"], pre & @["exec"], @["cmd"])
  c.commonTail(pre & @["exec"], @["cmd"])
  c.add "finish bare", pre & @["finish"]
  c.valueOption(["--status"], ["passed", "failed"], [], pre & @["finish"], @[])
  c.commonTail(pre & @["finish"], @[])
  c.add "log no message", pre & @["log"]
  c.add "log message", pre & @["log", "hello"]
  c.add "log two words", pre & @["log", "a", "b"]
  c.add "env <APP>_CICOMMAND=status", pre, @[("<APP>_CICOMMAND", "status")]
  c.add "env <APP>_LABEL", pre & @["start"], @[("<APP>_LABEL", "envlabel")]
  c.add "env CODETRACER_TOKEN (read later, not by the loader)", pre & @["status"], @[("CODETRACER_TOKEN", "t")]
  c.commonTail(pre, @[])
  c

proc traceMetadataCases(): seq[Case] =
  var c: seq[Case]
  let pre = @["trace-metadata"]
  let post: seq[string] = @[]
  c.add "bare", pre
  c.valueOption(["--id"], ["0190d7a0"], [], pre, post)
  c.valueOption(["--path"], ["/t"], [], pre, post)
  c.valueOption(["--record-pid", "-r"], ["42"], ["x"], pre, post)
  c.valueOption(["--program"], ["prog"], [], pre, post)
  c.switchOption(["--recent"], pre, post)
  c.switchOption(["--recent-folders"], pre, post)
  c.valueOption(["--add-recent-folder"], ["/f"], [], pre, post)
  c.valueOption(["--limit"], ["10", "0"], ["x"], pre, post)
  c.valueOption(["--import-ct"], ["/t.ct"], [], pre, post)
  c.valueOption(["--import-source"], ["/src"], [], pre, post)
  c.switchOption(["--test"], pre, post)
  c.add "a positional", pre & @["word"]
  c.add "env <APP>_LIMIT=9", pre, @[("<APP>_LIMIT", "9")]
  c.commonTail(pre, post)
  c

proc startBackendCases(): seq[Case] =
  var c: seq[Case]
  let pre = @["start_backend"]
  let post = @["db"]
  c.add "no kind", pre
  c.add "kind db", pre & @["db"]
  c.add "kind rr", pre & @["rr"]
  c.add "two kinds", pre & @["db", "rr"]
  c.add "start-backend spelling", @["start-backend", "db"]
  c.add "startBackend spelling", @["startBackend", "db"]
  c.switchOption(["--stdio"], pre, post)
  c.valueOption(["--socket-path"], ["/s.sock"], [], pre, post)
  c.add "env <APP>_BACKENDKIND", pre, @[("<APP>_BACKENDKIND", "db")]
  c.commonTail(pre, post)
  c

proc traceCases(): seq[Case] =
  var c: seq[Case]
  let pre = @["trace"]
  c.add "bare", pre
  for sub in ["bogus", "noCommand", "EXPORT", "extract_gfx", "extractgfx",
              "omniscient_prep"]:
    c.add "subcommand " & sub, pre & @[sub]
  c.add "help word", pre & @["help"]
  # extract-gfx
  let xpre = pre & @["extract-gfx"]
  c.add "extract-gfx bare", xpre
  c.add "extract-gfx path only", xpre & @["t.ct"]
  c.add "extract-gfx -o only", xpre & @["-o", "/d"]
  c.valueOption(["--output-dir", "-o"], ["/d"], [], xpre, @["t.ct"])
  c.commonTail(xpre, @["-o", "/d", "t.ct"])
  # export
  let epre = pre & @["export"]
  c.add "export bare", epre
  c.add "export path only", epre & @["t.ct"]
  c.valueOption(["--output", "-o"], ["/e.ct"], [], epre, @["t.ct"])
  c.switchOption(["--portable"], epre, @["-o", "/e.ct", "t.ct"])
  c.commonTail(epre, @["-o", "/e.ct", "t.ct"])
  # omniscient-prep
  let opre = pre & @["omniscient-prep"]
  c.add "omniscient-prep bare", opre
  c.add "omniscient-prep path", opre & @["t.ct"]
  c.valueOption(["--mode"], ["on", "lazy", "bogus"], [], opre, @["t.ct"])
  c.commonTail(opre, @["t.ct"])
  c.add "env <APP>_TRACECOMMAND=export", pre, @[("<APP>_TRACECOMMAND", "export")]
  c.add "env <APP>_OUTPUT", epre & @["t.ct"], @[("<APP>_OUTPUT", "/env.ct")]
  c.add "env <APP>_MODE", opre & @["t.ct"], @[("<APP>_MODE", "lazy")]
  c.commonTail(pre, @[])
  c

proc gfxReplayCases(): seq[Case] =
  var c: seq[Case]
  let pre = @["gfx-replay"]
  let post = @["--gfx-stream", "/g"]
  c.add "bare (gfx-stream required)", pre
  c.valueOption(["--gfx-stream"], ["/g"], [], pre, @[])
  c.switchOption(["--http"], pre, post)
  c.valueOption(["--port"], ["8080"], ["x"], pre, post)
  c.valueOption(["--backend"], ["software", "hardware"], [], pre, post)
  c.add "a positional", pre & post & @["word"]
  c.add "env <APP>_GFX_STREAM", pre, @[("<APP>_GFX_STREAM", "/envg")]
  c.commonTail(pre, post)
  c

proc helpDelegateCases(): seq[Case] =
  ## The four help-delegate commands as the LOADER parses them.  `ct` itself
  ## intercepts `ct-complete` and `ct-completions` before the loader (they
  ## are pinned through the binary in `binary_help.txt`).
  var c: seq[Case]
  for cmd in ["ct-describe-commands", "ct-help", "ct-complete", "ct-completions"]:
    c.add cmd & " bare", @[cmd]
    c.add cmd & " a word", @[cmd, "w"]
    c.add cmd & " two words", @[cmd, "w", "v"]
    c.add cmd & " an option", @[cmd, "--x"]
  c.add "help bare", @["help"]
  c.add "help record", @["help", "record"]
  c.add "HELP", @["HELP"]
  c.add "he_lp", @["he_lp"]
  c

proc firstRefusalCases(): seq[Case] =
  ## Lines with two refusals: which one is printed.  The loader reads the
  ## line word by word and rejects a value at the option that takes it, so
  ## the refusal printed is the first in argv order: a rejected value before
  ## an unknown option, a missing value, a stray word or an unknown
  ## subcommand, and the first of two rejected values.  The command line
  ## before the environment.
  var c: seq[Case]
  c.add "value, then an unknown long option", @["print", "--limit", "abc", "--bogus", "t.jsonl"]
  c.add "value, then an unknown short option", @["print", "t.jsonl", "--limit", "abc", "-Z"]
  c.add "unknown option, then a value", @["print", "--bogus", "--limit", "abc", "t.jsonl"]
  c.add "value, then a missing value", @["print", "--limit", "abc", "t.jsonl", "--filter"]
  c.add "value, then a stray word", @["print", "--limit", "abc", "a", "b"]
  c.add "switch value, then an integer value", @["print", "--verify=maybe", "-n", "abc", "t.jsonl"]
  c.add "integer value, then a switch value", @["print", "-n", "abc", "--verify=maybe", "t.jsonl"]
  c.add "two switch values", @["install", "--json=maybe", "--bpf=nah"]
  c.add "global switch value, then an unknown option after the command", @["--new-tab=maybe", "list", "--bogus"]
  c.add "global switch value, then an unknown option before the command", @["--new-tab=maybe", "--bogus", "list"]
  c.add "global switch value, then an unknown command", @["--new-tab=maybe", "frob"]
  c.add "integer value, then an unknown option", @["host", "--port", "x", "--bogus"]
  c.add "two integer values", @["trace-metadata", "--limit", "x", "--record-pid", "y"]
  c.add "enum value, then a missing value", @["upload", "--omniscient-db=bad", "--id"]
  c.add "enum value in another style, then an unknown option", @["upload", "--omniscient-db=PRE_prepared", "--bogus"]
  c.add "record: integer value, then an unknown option", @["record", "--store-trace-folder-for-pid", "x", "--bogus", "prog"]
  c.add "ci exec: two switch values", @["ci", "exec", "--record=nope", "--monitor-processes=x", "cmd"]
  c.add "value on the command line, value in the environment", @["print", "--limit", "abc", "t.jsonl"], @[("<APP>_VERIFY", "maybe")]
  c.add "unknown option on the command line, value in the environment", @["print", "--bogus", "t.jsonl"], @[("<APP>_LIMIT", "ten")]
  c

proc groups(): seq[Group] =
  result.add Group(name: "root", title: "ct (no command) and the global options", cases: rootCases())
  result.add Group(name: "install", title: "ct install", cases: installCases())
  result.add Group(name: "list", title: "ct list", cases: listCases())
  result.add Group(name: "print", title: "ct print", cases: printCases())
  result.add Group(name: "replay", title: "ct replay", cases: traceSelectorCases("replay", replayExtra))
  result.add Group(name: "console", title: "ct console", cases: traceSelectorCases("console", consoleExtra))
  result.add Group(name: "upload", title: "ct upload", cases: traceSelectorCases("upload", uploadExtra))
  result.add Group(name: "host", title: "ct host", cases: hostCases())
  result.add Group(name: "import", title: "ct import", cases: positionalCases("import", @["zip", "out"]))
  result.add Group(name: "build", title: "ct build", cases: positionalCases("build", @["src", "out"]))
  result.add Group(name: "record", title: "ct record", cases: recordCases())
  result.add Group(name: "record-test", title: "ct record-test", cases: recordTestCases())
  result.add Group(name: "run", title: "ct run", cases: restCases("run", @["prog"]))
  result.add Group(name: "remote", title: "ct remote", cases: restCases("remote", @[]))
  result.add Group(name: "electron", title: "ct electron", cases: restCases("electron", @[]))
  result.add Group(name: "download", title: "ct download", cases: downloadCases())
  result.add Group(name: "login", title: "ct login", cases: loginCases())
  result.add Group(name: "set-default-org", title: "ct set-default-org", cases: positionalCases("set-default-org", @["org"]))
  result.add Group(name: "get-default-org", title: "ct get-default-org", cases: positionalCases("get-default-org", @[]))
  result.add Group(name: "activate", title: "ct activate", cases: tokenBaseUrlCases("activate"))
  result.add Group(name: "check-license", title: "ct check-license", cases: tokenBaseUrlCases("check-license"))
  result.add Group(name: "arb", title: "ct arb", cases: arbCases())
  result.add Group(name: "ci", title: "ct ci", cases: ciCases())
  result.add Group(name: "index-diff", title: "ct index-diff", cases: positionalCases("index-diff", @["trace"]))
  result.add Group(name: "edit", title: "ct edit", cases: positionalCases("edit", @["path"]))
  result.add Group(name: "review", title: "ct review (the launch form the loader parses)", cases: positionalCases("review", @["dataset"]))
  result.add Group(name: "trace-metadata", title: "ct trace-metadata", cases: traceMetadataCases())
  result.add Group(name: "start_backend", title: "ct start_backend", cases: startBackendCases())
  result.add Group(name: "trace", title: "ct trace", cases: traceCases())
  result.add Group(name: "gfx-replay", title: "ct gfx-replay", cases: gfxReplayCases())
  result.add Group(name: "doctor", title: "ct doctor", cases: positionalCases("doctor", @["lang"]))
  result.add Group(name: "help-delegate", title: "ct help and the help-delegate commands", cases: helpDelegateCases())
  result.add Group(name: "first-refusal", title: "two refusals in one line: the first in argv order is printed", cases: firstRefusalCases())

# ─── binary-only cases ───────────────────────────────────────────────────────

proc binaryHelpCases(): seq[Case] =
  var c: seq[Case]
  c.add "top: --help", @["--help"]
  c.add "top: -h", @["-h"]
  c.add "top: help (a word)", @["help"]
  c.add "top: help record", @["help", "record"]
  c.add "top: --HELP", @["--HELP"]
  c.add "top: --he_lp", @["--he_lp"]
  c.add "top: --help=1", @["--help=1"]
  c.add "top: --help record", @["--help", "record"]
  c.add "top: -help (a cluster)", @["-help"]
  c.add "top: --version", @["--version"]
  c.add "top: version (a word)", @["version"]
  c.add "top: --help, COLUMNS=40", @["--help"], @[("COLUMNS", "40")]
  c.add "top: --help, COLUMNS=120", @["--help"], @[("COLUMNS", "120")]
  c.add "top: --help, COLUMNS=250", @["--help"], @[("COLUMNS", "250")]
  c.add "top: --help, COLUMNS=x", @["--help"], @[("COLUMNS", "x")]
  for cmd in ["install", "list", "print", "replay", "console", "upload", "host",
              "import", "build", "record", "record-test", "run", "remote",
              "electron", "download", "login", "set-default-org",
              "get-default-org", "activate", "check-license", "arb", "ci",
              "index-diff", "edit", "trace-metadata",
              "start_backend", "trace", "gfx-replay", "doctor",
              "ct-describe-commands", "ct-help"]:
    c.add cmd & " --help", @[cmd, "--help"]
  c.add "review --help (intercepted)", @["review", "--help"]
  c.add "review -h (intercepted)", @["review", "-h"]
  c.add "review help (intercepted)", @["review", "help"]
  c.add "review x --help", @["review", "x", "--help"]
  for sub in ["explorer", "record", "replay", "deploy", "listRecentTx"]:
    c.add "arb " & sub & " --help", @["arb", sub, "--help"]
  for sub in ["start", "attach", "exec", "finish", "run", "log", "status", "cancel"]:
    c.add "ci " & sub & " --help", @["ci", sub, "--help"]
  for sub in ["extract-gfx", "export", "omniscient-prep"]:
    c.add "trace " & sub & " --help", @["trace", sub, "--help"]
  c.add "ci help (a word)", @["ci", "help"]
  c.add "trace help (a word)", @["trace", "help"]
  c.add "arb version (a word)", @["arb", "version"]
  c.add "record --help, COLUMNS=60", @["record", "--help"], @[("COLUMNS", "60")]
  c.add "record --help, COLUMNS=200", @["record", "--help"], @[("COLUMNS", "200")]
  c.add "record: options then --help", @["record", "-o", "/o", "--lang=python", "--help"]
  c.add "record: --help after a bad option", @["record", "--bogus", "--help"]
  c.add "record: --help after a bad value", @["record", "--store-trace-folder-for-pid=x", "--help"]
  c.add "print -h", @["print", "-h"]
  c.add "upload --version", @["upload", "--version"]
  # the help-delegate surface
  c.add "ct-describe-commands", @["ct-describe-commands"]
  c.add "ct-help", @["ct-help"]
  for shell in ["bash", "zsh", "fish", "powershell", "", "bogus"]:
    c.add "ct-completions " & lit(shell), @["ct-completions", shell]
  c.add "ct-completions (no shell)", @["ct-completions"]
  for words in [@[""], @["rec"], @["record", ""], @["record", "--"], @["record", "-"],
                @["record", "--l"], @["upload", "--omniscient-db", ""],
                @["upload", "--omniscient-db="], @["trace", ""], @["ci", ""],
                @["ci", "exec", "--"], @["arb", ""], @["print", "-"], @["--"],
                @["--c"], @["install", "--"], @["review", ""], @["agent", ""],
                @["test", ""], @[]]:
    var shown: seq[string]
    for w in words: shown.add lit(w)
    c.add "ct-complete " & (if shown.len == 0: "(no words)" else: shown.join(" ")),
      @["ct-complete"] & words
  c

proc binaryDispatchCases(): seq[Case] =
  ## The hand-written dispatch in `codetracer.nim` that runs before the
  ## loader, in the forms that end the process before anything is launched.
  var c: seq[Case]
  c.add "--deepreview x (retired)", @["--deepreview", "x"]
  c.add "--deepreview=x (retired)", @["--deepreview=x"]
  c.add "--cwd /w --deepreview x (retired)", @["--cwd", "/w", "--deepreview", "x"]
  c.add "list --deepreview x (not intercepted)", @["list", "--deepreview", "x"]
  c.add "--ui=bogus", @["--ui=bogus", "--help"]
  c.add "--ui (no value)", @["--ui"]
  c.add "--ui= (empty)", @["--ui=", "--help"]
  c.add "--ui=electron --help", @["--ui=electron", "--help"]
  c.add "--ui electron --help", @["--ui", "electron", "--help"]
  c.add "--headless --help", @["--headless", "--help"]
  c.add "env CODETRACER_UI=bogus --help", @["--help"], @[("CODETRACER_UI", "bogus")]
  c.add "env CODETRACER_UI=electron --help", @["--help"], @[("CODETRACER_UI", "electron")]
  c.add "review (no path, intercepted?)", @["review", "--bogus"]
  c.add "review export", @["review", "export"]
  c.add "review collect --help", @["review", "collect", "--help"]
  c.add "review inspect --help", @["review", "inspect", "--help"]
  c.add "agent", @["agent"]
  c.add "agent --help", @["agent", "--help"]
  c.add "agent frob", @["agent", "frob"]
  c.add "agent prompt extra", @["agent", "prompt", "extra"]
  c.add "test", @["test"]
  c.add "test frob", @["test", "frob"]
  c.add "test e2e frob", @["test", "e2e", "frob"]
  c.add "record -- (no program)", @["record", "--"]
  c.add "record -o /o -- (no program)", @["record", "-o", "/o", "--"]
  c.add "record --bogus -- prog", @["record", "--bogus", "--", "prog"]
  c.add "record --help -- prog", @["record", "--help", "--", "prog"]
  c.add "record --lang -- prog (value missing before --)", @["record", "--store-trace-folder-for-pid", "--", "prog"]
  c

# ─── environment control ─────────────────────────────────────────────────────

proc envPrefix(bin: string): string =
  ## The loader's environment prefix for `bin`, as `constructEnvKey` spells
  ## it (upper case, `-` and ` ` as `_`).
  bin.toUpperAscii.multiReplace(("-", "_"), (" ", "_"))

# ─── running binaries ────────────────────────────────────────────────────────

proc startBin(bin: string; argv: seq[string]; env: seq[(string, string)];
              scratch: string; probe: bool): tuple[p: Process, failure: string] =
  ## Starts `bin argv` in `scratch` (its own directory), under `timeout 60`,
  ## in a session of its own (`setsid`), with a minimal environment: PATH, HOME, TMPDIR and CODETRACER_HOME in
  ## `scratch`, the dev shell's run-time library path, the probe switch,
  ## plus the case's own; stdin closed, stdout and stderr on separate pipes.
  var e = newStringTable(modeCaseSensitive)
  e["PATH"] = getEnv("PATH")
  e["HOME"] = scratch / "home"
  e["TMPDIR"] = scratch / "tmp"
  e["CODETRACER_HOME"] = scratch / "cthome"
  for v in ["CODETRACER_LD_LIBRARY_PATH", "LD_LIBRARY_PATH", "LOCALE_ARCHIVE"]:
    if existsEnv(v): e[v] = getEnv(v)
  if probe: e[ProbeEnvVar] = scratch / ProbeMarker
  let prefix = envPrefix(bin)
  for (k, v) in env: e[k.replace("<APP>", prefix)] = v
  # Not followed: on a coreutils multi-call install `timeout` is a link to
  # `coreutils`, which runs as `timeout` only when called by that name.
  let timeoutExe = findExe("timeout", followSymlinks = false)
  if timeoutExe.len == 0:
    return (nil, "no `timeout` on PATH")
  # A new session, so the child has no controlling terminal: `terminalWidth()`
  # (the help screens' wrapping) falls back to `/dev/tty` when `COLUMNS` does
  # not answer, so without this the width of the terminal the test happens to
  # be started from would reach the goldens.  `-w`: wait for the child and
  # exit with its status, should `setsid` have to fork.
  let setsidExe = findExe("setsid", followSymlinks = false)
  if setsidExe.len == 0:
    return (nil, "no `setsid` on PATH")
  try:
    for d in ["home", "tmp", "cthome"]: createDir(scratch / d)
    let p = startProcess(setsidExe, workingDir = scratch,
                         args = @["-w", timeoutExe, "-k", "5", "60", bin] & argv,
                         env = e,
                         options = {})
    p.inputStream.close()
    (p, "")
  except CatchableError as err:
    (nil, "could not run " & bin & ": " & err.msg)

proc visibleControls(text: string): string =
  ## A child's output with its control characters written visibly, so every
  ## golden is a text file: ESC (the help screens' colours) as `\e`, CR as
  ## `\r`, NUL (which ct prints in one refusal: the placeholder
  ## `codetracer.nim` gives `ct record ... --` reaches an error message) as
  ## `\0`, any other one but LF and TAB as `\xNN`.
  for c in text:
    case c
    of '\e': result.add "\\e"
    of '\r': result.add "\\r"
    of '\0': result.add "\\0"
    of '\n', '\t': result.add c
    elif c < ' ' or c == '\x7f': result.add "\\x" & toHex(ord(c), 2)
    else: result.add c

proc visibleLineEnds(text: string): string =
  ## The goldens never end a line in whitespace: the repository's
  ## `trim-trailing-whitespace` hook would rewrite them on commit (help
  ## screens pad with spaces).  The LAST blank of a line is written as
  ## `\x20` (a space) or `\t` (a tab), so the transformation is lossless.
  var lines = text.split('\n')
  for line in lines.mitems:
    if line.len > 0 and line[^1] in {' ', '\t'}:
      let last = if line[^1] == ' ': "\\x20" else: "\\t"
      line = line[0 ..< ^1] & last
  lines.join("\n")

type
  ExpectedHelp = tuple[asked: bool, path: seq[string], text: string]
    ## The help a line asks for, as the description renders it by default.

proc loaderLine(argv: seq[string]; env: seq[(string, string)];
                probe: bool): tuple[reaches: bool, line: seq[string]] =
  ## The words `ct`'s loader gets for `argv`: the probe hands it its argv
  ## unchanged; the binary first takes `--ui`/`--headless` out (the `--ui`
  ## prologue, `planUiSelection`, with no configuration file: every run has
  ## an empty HOME) and splits `record ... --` (`recordParserLine`), as
  ## `codetracer.nim` does.  `reaches` is false when the prologue ends the
  ## process or hands it to another binary.
  if probe:
    return (true, argv)
  var envUi = ""
  for (k, v) in env:
    if k == UiEnvVar: envUi = v
  let plan = planUiSelection(argv, envUi, "")
  var line: seq[string]
  case plan.kind
  of upkInProcess: line = plan.ctArgs
  of upkRewrite: line = plan.rewrittenArgs
  of upkHandoff, upkUsageError: return (false, @[])
  let sep = line.find("--")
  if sep >= 0 and line.len > 0 and line[0] == "record":
    line = recordParserLine(line[0 ..< sep])
  (true, line)

proc expectedHelp(cs: Case; argv: seq[string]; probe: bool): ExpectedHelp =
  ## Whether ct's loader answers this line with help, and with which text:
  ## the description is asked in-process (`CtCli.load`, ct's own options),
  ## and the `CliHelpRequest` it raises carries the command and the help
  ## clispec renders by default for that request.  Rendered under the
  ## case's `COLUMNS` (or none), as the child sees it.
  let (reaches, line) = loaderLine(argv, cs.env, probe)
  if not reaches:
    return
  var columns = ""
  var hasColumns = false
  for (k, v) in cs.env:
    if k == "COLUMNS": (columns, hasColumns) = (v, true)
  let saved = getEnv("COLUMNS")
  let hadColumns = existsEnv("COLUMNS")
  if hasColumns: putEnv("COLUMNS", columns) else: delEnv("COLUMNS")
  try:
    discard CtCli.load(line, CliSources(), ctCliOptions(VersionText))
  except CliVersionRequest:
    discard
  except CliHelpRequest as e:
    result = (true, e.commandPath, ctHelpScreen(e))
  except CatchableError:
    discard
  if hadColumns: putEnv("COLUMNS", saved) else: delEnv("COLUMNS")

proc helpMarker(path: seq[string]): string =
  ## What a help screen is replaced with in the goldens (see "HELP" in the
  ## module documentation): the command whose help was asked for.
  "<the help clispec renders for this request: " &
    (@["ct"] & path).join(" ") & ">\n"

proc finishBin(p: Process; scratch, bin: string; probe: bool;
               help: ExpectedHelp): Run =
  ## Collects a run started by `startBin` and renders its exit code, stdout
  ## and stderr.  stdout is read to its end first; no case writes anywhere
  ## near a pipe's capacity to stderr, so the child cannot block on it.  A
  ## run that `timeout` had to stop (exit 124, or 137 after the kill) is
  ## reported as a failure.
  try:
    var o = p.outputStream.readAll()
    let r = p.errorStream.readAll()
    let code = p.waitForExit()
    # A help screen: compared here with the help the description renders
    # for the same request, in-process, and pinned by the marker.
    if help.asked:
      let printed = if help.text.endsWith("\n"): help.text
                    else: help.text & "\n"
      if o == printed:
        o = helpMarker(help.path)
    p.close()
    if code in [124, 137]:
      return (code, "", "did not exit within 60 s; stopped by timeout")
    if probe and not fileExists(scratch / ProbeMarker):
      return (code, "", "the parse probe did not start (exit " & $code &
        "): " & (o & r).strip)
    var text = "--- stdout\n" & o
    if o.len > 0 and not o.endsWith("\n"): text.add "\n(no newline at end of stdout)\n"
    text.add "--- stderr\n" & r
    if r.len > 0 and not r.endsWith("\n"): text.add "\n(no newline at end of stderr)\n"
    text.add "--- end\n"
    text = text.multiReplace((scratch, "<SCRATCH>"), (bin, "<BIN>"),
                             (envPrefix(bin), "<APP>"),
                             (version.CodeTracerVersionStr & "(debug)", "<VERSION>"),
                             (version.CodeTracerVersionStr, "<VERSION>"),
                             )
    (code, visibleControls(text), "")
  except CatchableError as err:
    (-1, "", "could not collect a run: " & err.msg)

proc runAll(bin, tag: string; cases: seq[Case]; scratch: string;
            probe: bool): seq[Run] =
  ## Runs every case, at most `MaxInFlight` at once, each in its own
  ## directory `<scratch>/<tag>-<i>`; results in case order.
  result = newSeq[Run](cases.len)
  var inFlight: seq[tuple[i: int, p: Process, dir: string,
                          help: ExpectedHelp]]
  var next = 0
  while next < cases.len or inFlight.len > 0:
    while next < cases.len and inFlight.len < MaxInFlight:
      let cs = cases[next]
      let dir = scratch / (tag & "-" & $next)
      var argv: seq[string]
      for a in cs.argv: argv.add a.replace("<SCRATCH>", dir)
      let (p, failure) = startBin(bin, argv, cs.env, dir, probe)
      if p == nil: result[next] = (-1, "", failure)
      else: inFlight.add (next, p, dir, expectedHelp(cs, argv, probe))
      inc next
    if inFlight.len > 0:
      let head = inFlight[0]
      inFlight.delete(0)
      result[head.i] = finishBin(head.p, head.dir, bin, probe, head.help)

proc caseHeader(i: int; cs: Case): string =
  var parts: seq[string]
  for a in cs.argv: parts.add lit(a)
  var envs: seq[string]
  for (k, v) in cs.env: envs.add k & "=" & lit(v)
  "\n### " & $(i + 1) & ": " & cs.label & "\n" &
    "argv: ct " & (if parts.len == 0: "(none)" else: parts.join(" ")) & "\n" &
    "env: " & (if envs.len == 0: "(none)" else: envs.join(" ")) & "\n"

proc interceptedBeforeTheLoader(cs: Case): bool =
  ## Whether `codetracer.nim`'s dispatch before the loader could act on this
  ## line (rewrite it, or run it itself), or the loader would return without
  ## parsing it (`COMP_LINE`).  Conservative: any line that MIGHT be.
  for (k, _) in cs.env:
    if k in ["COMP_LINE", "COMP_POINT", "CODETRACER_UI"]: return true
  if cs.argv.len > 0 and cs.argv[0] in ["test", "review", "agent",
      "ct-complete", "ct-completions", "shell-session"]:
    return true
  for a in cs.argv:
    if a == "--" or a.startsWith("--ui") or a == "--headless" or
        a.startsWith("--deepreview"):
      return true

const
  ## Commands whose successful parse only prints (the help-delegate surface):
  ## the explicit binary cases may run them.
  PrintOnlyCommands = ["ct-describe-commands", "ct-help"]

proc reachesRunInitial(r: Run): bool =
  ## The probe got through the loader and `customValidateConfig`: this is a
  ## line `ct` would go on to RUN.
  "\nVALIDATED " in r.output

proc guarded(cases: seq[Case]; probed: seq[Run]; toRun: var seq[Case];
             skipped: var seq[bool]) =
  ## An explicit binary case is skipped when the loader would see it and the
  ## probe says `ct` would go on to run it.
  for i, cs in cases:
    let skip = not interceptedBeforeTheLoader(cs) and reachesRunInitial(probed[i]) and
      not (cs.argv.len > 0 and cs.argv[0] in PrintOnlyCommands)
    skipped.add skip
    toRun.add cs

proc renderBinary(bin, scratch, title: string; cases: seq[Case];
                  skipped: seq[bool]; tag: string;
                  failures: var seq[string]): string =
  var runnable: seq[Case]
  for i, cs in cases:
    if not skipped[i]: runnable.add cs
  let got = runAll(bin, tag, runnable, scratch, probe = false)
  result = "# " & title & ": " & $cases.len & " cases\n"
  var n = 0
  for i, cs in cases:
    result.add caseHeader(i, cs)
    if skipped[i]:
      result.add "NOT RUN: the parse succeeds, so ct would go on to run it\n"
      continue
    let r = got[n]
    inc n
    if r.failure.len > 0: failures.add cs.label & ": " & r.failure
    result.add "exit: " & $r.code & "\n"
    result.add r.output

# ─── assembling everything ───────────────────────────────────────────────────

proc produce(bin, probe, scratch: string; failures: var seq[string]):
    seq[tuple[file, text: string]] =
  ## Every parse case goes through the probe.  The binary runs are the
  ## explicit help and dispatch cases plus every parse case that did not
  ## reach `runInitial`.  An explicit case that the loader reaches is probed
  ## first, and NOT run if the probe says `ct` would go on to run it (the
  ## golden then says so, which also fails the comparison if a line that was
  ## refused starts to parse); the explicit cases the dispatch intercepts
  ## before the loader are each one that ends the process with a usage text
  ## or an error (checked by reading that dispatch, `codetracer.nim`).
  let gs = groups()
  var all: seq[Case]
  var owner: seq[int]
  for gi, g in gs:
    for cs in g.cases:
      all.add cs
      owner.add gi
  let help = binaryHelpCases()
  let dispatch = binaryDispatchCases()
  let explicit = help & dispatch
  let runs = runAll(probe, "parse", all & explicit, scratch, probe = true)

  var refused: seq[Case]
  for gi, g in gs:
    var text = "# " & g.title & ": " & $g.cases.len &
      " argv cases through ct's loader (the parse probe)\n"
    var j = 0
    for k in 0 ..< all.len:
      if owner[k] != gi: continue
      let cs = all[k]
      let r = runs[k]
      if r.failure.len > 0: failures.add g.name & " " & cs.label & ": " & r.failure
      text.add caseHeader(j, cs)
      text.add "exit: " & $r.code & "\n"
      text.add r.output
      if r.failure.len == 0 and not reachesRunInitial(r) and
          not interceptedBeforeTheLoader(cs):
        refused.add Case(label: g.name & " " & $(j + 1) & ": " & cs.label,
                         argv: cs.argv, env: cs.env)
      inc j
    result.add ("parse_" & g.name & ".txt", text)

  for i in all.len ..< runs.len:
    if runs[i].failure.len > 0:
      failures.add explicit[i - all.len].label & " (probe): " & runs[i].failure
  if failures.len > 0:
    # A probe that did not run cannot say which lines are safe to hand to
    # `ct`: stop before the first run of the real binary.
    return

  var helpCases, dispatchCases: seq[Case]
  var helpSkipped, dispatchSkipped: seq[bool]
  guarded(help, runs[all.len ..< all.len + help.len], helpCases, helpSkipped)
  guarded(dispatch, runs[all.len + help.len .. ^1], dispatchCases, dispatchSkipped)
  for cs in refused:
    dispatchCases.add cs
    dispatchSkipped.add false
  result.add ("binary_help.txt",
    renderBinary(bin, scratch, "help screens, the version and the help-delegate commands, through ct",
                 helpCases, helpSkipped, "help", failures))
  result.add ("binary_dispatch.txt",
    renderBinary(bin, scratch, "the dispatch before the loader, and every parse case that did not reach runInitial, through ct",
                 dispatchCases, dispatchSkipped, "dispatch", failures))

proc firstDifference(a, b: string): string =
  let la = a.splitLines()
  let lb = b.splitLines()
  for i in 0 ..< max(la.len, lb.len):
    let x = if i < la.len: la[i] else: "<end of golden>"
    let y = if i < lb.len: lb[i] else: "<end of output>"
    if x != y:
      var ctx = ""
      for j in max(0, i - 3) ..< i:
        if j < la.len: ctx.add "    " & la[j] & "\n"
      return "first difference at line " & $(i + 1) & ":\n" & ctx &
        "  golden: " & x & "\n  now:    " & y
  "texts differ only in a trailing newline"

proc ctBinary(): string =
  ## The binary the other CLI suites drive, in their order.
  result = getEnv("CODETRACER_E2E_CT_PATH", "")
  if result.len == 0:
    result = getEnv("CODETRACER_BUILD_DIR", RepoRoot / "src" / "build-debug") /
      "bin" / "ct"

proc newestSource(): tuple[path: string, time: Time] =
  ## The most recently modified source `ct`'s command line is built from.
  ## An `OSError` is the caller's: a tree that cannot be read cannot clear
  ## the binary.
  result = ("", fromUnix(0))
  for top in ["src/ct", "src/common", "src/ct_test", "libs/nim-confutils",
              "libs/nim-cli-spec"]:
    let dir = RepoRoot / top
    if not dirExists(dir): continue
    for f in walkDirRec(dir):
      if not (f.endsWith(".nim") or f.endsWith(".nims")): continue
      if f.endsWith("_test.nim") or "/tests/" in f: continue
      let t = getLastModificationTime(f)
      if t > result.time: result = (f, t)
  for f in [RepoRoot / "config.nims"]:
    let t = getLastModificationTime(f)
    if t > result.time: result = (f, t)

proc locateBinary(): tuple[bin, problem: string] =
  let bin = ctBinary()
  if not fileExists(bin):
    return ("", "no ct binary at " & bin & ": build it (`just build-once`, or " &
      "the `ct` rule of src/ct/Tupfile) or point CODETRACER_E2E_CT_PATH at one")
  try:
    let binTime = getLastModificationTime(bin)
    let newest = newestSource()
    if newest.time > binTime:
      return ("", bin & " is older than " & newest.path &
        ": it was built from a previous tree, so it cannot speak for this " &
        "one.  Rebuild it and run again")
  except OSError as e:
    return ("", "cannot compare " & bin & " with its sources: " & e.msg)
  (absolutePath(bin), "")

proc main(): int =
  var writeTo = ""
  var params: seq[string]
  for i in 1 .. paramCount(): params.add paramStr(i)
  if params.len > 0:
    if params[0] != "--write-goldens" or params.len > 2:
      echo "usage: cs_m10_cli_surface_unchanged_test [--write-goldens [dir]]"
      return 2
    writeTo = if params.len == 2: absolutePath(params[1]) else: GoldenDir

  let (bin, problem) = locateBinary()
  if problem.len > 0:
    echo "FAIL: " & problem
    return 1
  let probe = getAppFilename()
  var scratch = ""
  try:
    scratch = createTempDir("ct_cs_m10_", "")
  except OSError, IOError:
    echo "FAIL: cannot create a scratch directory"
    return 1
  echo "ct binary: " & bin
  echo "parse probe: " & probe

  var failures: seq[string]
  var produced = produce(bin, probe, scratch, failures)
  for item in produced.mitems:
    item.text = visibleLineEnds(item.text)
  try: removeDir(scratch)
  except OSError: discard
  if failures.len > 0:
    for f in failures: echo "FAIL: " & f
    return 1

  if writeTo.len > 0:
    try:
      createDir(writeTo)
      for (file, text) in produced:
        writeFile(writeTo / file, text)
        echo "wrote " & (writeTo / file) & " (" & $text.countLines() & " lines)"
    except OSError, IOError:
      echo "FAIL: cannot write the goldens to " & writeTo
      return 1
    return 0

  var bad = 0
  suite "CS-M10: ct's command line equals the golden captured before the move":
    test "the goldens exist and cover every file this test produces":
      var missing: seq[string]
      for (file, _) in produced:
        if not fileExists(GoldenDir / file): missing.add file
      var extra: seq[string]
      for kind, path in walkDir(GoldenDir):
        var known = false
        for (file, _) in produced:
          if path.lastPathPart == file: known = true
        if not known: extra.add path.lastPathPart
      if missing.len > 0: checkpoint("missing goldens: " & missing.join(", "))
      if extra.len > 0: checkpoint("goldens this test no longer produces: " & extra.join(", "))
      check missing.len == 0
      check extra.len == 0
    test "every help screen is clispec's default rendering, less env names and letter aliases":
      # The goldens compare ct's help with `ctHelpScreen`, the function ct
      # prints it with, so this pins `ctHelpScreen` against clispec itself:
      # for every command, its screen has the words of clispec's default
      # rendering of the description (`cliHelpText`) in the same order, less
      # each `[env: X]` note and each `--<letter>,` alias -- the right page,
      # nothing else dropped or added -- and no Nim spelling of a default.
      let g = CtCli.cliGrammar
      var paths: seq[seq[string]]
      for c in g.commands:
        if c.path notin paths: paths.add c.path
      for path in paths:
        var stock, shown: seq[string]
        try:
          stock = cliHelpText(g, cliHelpCommand(g, path, "ct"), "ct").splitWhitespace
        except CliUsageError as e:
          checkpoint("ct " & path.join(" ") & ": " & e.msg)
          check false
        shown = ctHelpScreen((ref CliHelpRequest)(commandPath: path,
          text: "<not rendered>")).splitWhitespace
        var expected: seq[string]
        var inEnv = false
        for w in stock:
          if inEnv:
            inEnv = not w.endsWith("]")
          elif w == "[env:":
            inEnv = true
          elif w.len == 4 and w.startsWith("--") and w.endsWith(",") and
              w[2] in Letters:
            discard
          else:
            expected.add w
        if shown != expected:
          checkpoint("ct " & path.join(" ") & ":\n" & shown.join(" ") &
            "\n  expected:\n" & expected.join(" "))
        check shown == expected
        let text = shown.join(" ")
        for nimism in ["[env:", "@[]", "[default: ]", "OmniscientDbMode."]:
          if nimism in text:
            checkpoint("ct " & path.join(" ") & " shows " & nimism)
          check nimism notin text
    for item in produced:
      let file = item.file
      let text = item.text
      test file:
        var golden = ""
        try: golden = readFile(GoldenDir / file)
        except IOError, OSError: golden = "<unreadable>"
        # A named boolean, so a failure prints the first difference above
        # rather than both whole files.
        let same = golden == text
        if not same:
          inc bad
          checkpoint(file & ": " & firstDifference(golden, text))
        check same
  if bad > 0: 1
  else: programResult

when isMainModule:
  if existsEnv(ProbeEnvVar):
    quit(probeMain())
  else:
    let rc = main()
    if rc != 0: quit(rc)

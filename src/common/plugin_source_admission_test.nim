## plugin_source_admission_test.nim — the ATTACK ON PLAT-8'S OWN ALLOW-LIST.
##
## `ci/test/plugin-reactive-boundary.sh` check 19 refuses any `std/` module a
## plugin's closure imports that is not in `PluginAllowedStdlibModules`. That
## rule is only worth what the LIST is worth, and a list is worth nothing if one
## of its members hands the plugin, by re-export, the thing the list exists to
## keep away. `std/os` re-exports a great deal; `std/intsets` is literally
## `export packedsets`.
##
## So this suite does not read the list — it MEASURES it. Every admitted module
## is imported here under an alias, and `declared()` is asked whether a corpus
## of dangerous names resolves through it. The answer must be no for all
## twenty-one, and — this is the half that makes the first half evidence — YES
## for `std/os`, `std/posix`, `std/osproc`, `std/net`, `std/dynlib`,
## `std/streams`, `std/syncio`, `std/json` and `std/asyncdispatch`, which are
## imported here for exactly that purpose (Verification-Harness-Traps §4a: a
## negative check needs a positive twin running through the same code path).
##
## ## WHY THE CORPUS IS NOT THE DECISION, AND SAYING SO IS THE POINT
##
## The corpus below is a DENYLIST OF NAMES, which is the mechanism the
## allow-list exists because it lost. It is here as a CONTROL and not as the
## membership test, and the distinction is exact:
##
##   * the MEMBERSHIP RULE is in `plugin_model/source_admission.nim`'s header
##     and is applied by a human, per row, with the reason recorded beside the
##     module;
##   * this corpus demonstrates that the probe can SEE a reachable dangerous
##     name (the twins light up) and that the admitted modules do not hand out
##     the ones the SDK's own denied lists name.
##
## It proves nothing about a name nobody thought to put in it. That is precisely
## why the list is small, closed, and grows only with a recorded reason —
## `std/browsers` opens a program, `std/tempfiles` creates a file and
## `std/sysrand` reads a device, and NONE of their entry points is in the corpus
## below. Had membership been decided by "does the corpus light up", all three
## would have been admitted.
##
## ## THE CLOSURE RULE, ASSERTED RATHER THAN DESCRIBED
##
## `import` is not `export`: `std/times` imports `std/posix` on the POSIX arm
## and re-exports none of it, so `times.fork` does not resolve. What DOES
## propagate is a re-exported MODULE, and there is exactly one instance in the
## list — `std/intsets` is `export packedsets`. The case below asserts both
## halves: that `packedsets` is reachable through `intsets`, and that
## `std/packedsets` is therefore itself on the allow-list.
##
## ## THE COVERAGE ASSERTION IS WHAT KEEPS THIS FILE HONEST
##
## The twenty-one imports are a second copy of the table (nim cannot import from
## a `const`), so `the probe covers every admitted module` compares the probed
## set with the table's own and fails when they differ. Adding a row to the
## allow-list without adding a probe arm reddens this suite instead of silently
## widening the boundary — which is Verification-Harness-Traps §14's remedy
## applied to the one duplication that could not be removed.
##
## ## TRAP 13
##
## `ck` is a `template`. A `check` inside a plain `proc` sets a global and the
## case reports `[OK]` with the failed comparison printed above it.
##
## Compile and run:
##   nim c -r src/common/plugin_source_admission_test.nim

import std/unittest

import ./plugin_model/source_admission

# --- the allow-list, imported. One alias per admitted module. --------------
import std/algorithm as a_algorithm
import std/bitops as a_bitops
import std/deques as a_deques
import std/hashes as a_hashes
import std/heapqueue as a_heapqueue
import std/intsets as a_intsets
import std/lists as a_lists
import std/math as a_math
import std/monotimes as a_monotimes
import std/options as a_options
import std/packedsets as a_packedsets
import std/parseutils as a_parseutils
import std/sequtils as a_sequtils
import std/sets as a_sets
import std/strformat as a_strformat
import std/strutils as a_strutils
import std/sugar as a_sugar
import std/tables as a_tables
import std/times as a_times
import std/typetraits as a_typetraits
import std/unicode as a_unicode

# --- the twins. Refused modules, imported here so the probe has something it
# --- must be able to see. Aliased, so importing them does not make the bare
# --- module names reachable and defeat the case that asserts they are not.
import std/os as d_os
import std/posix as d_posix
import std/osproc as d_osproc
import std/net as d_net
import std/dynlib as d_dynlib
import std/streams as d_streams
import std/syncio as d_syncio
import std/json as d_json
import std/asyncdispatch as d_asyncdispatch

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

template dangerousIn(m: untyped): seq[string] =
  ## Every name in the corpus that resolves through module alias M.
  ##
  ## ONE TEMPLATE, EXPANDED AT EVERY CALL SITE — the admitted twenty-one and the
  ## refused nine ask the identical question, so a corpus that stopped matching
  ## would take the twins down with it and the run would say so.
  ##
  ## The lookup is QUALIFIED (`m.name`). An unqualified `declared(name)` would
  ## answer about `system`, which exports `readFile`, `open`, `close` and
  ## `write` into every scope in the language, and every module would then look
  ## dangerous for a reason that has nothing to do with it.
  block:
    var f: seq[string] = @[]
    # process
    when declared(m.execShellCmd): f.add("execShellCmd")
    when declared(m.startProcess): f.add("startProcess")
    when declared(m.execProcess): f.add("execProcess")
    when declared(m.execCmd): f.add("execCmd")
    when declared(m.execCmdEx): f.add("execCmdEx")
    # filesystem
    when declared(m.walkDir): f.add("walkDir")
    when declared(m.removeFile): f.add("removeFile")
    when declared(m.createDir): f.add("createDir")
    when declared(m.copyFile): f.add("copyFile")
    when declared(m.getFileInfo): f.add("getFileInfo")
    when declared(m.openFileStream): f.add("openFileStream")
    when declared(m.newFileStream): f.add("newFileStream")
    when declared(m.parseFile): f.add("parseFile")
    when declared(m.readFile): f.add("readFile")
    when declared(m.writeFile): f.add("writeFile")
    when declared(m.readLines): f.add("readLines")
    # network
    when declared(m.newSocket): f.add("newSocket")
    when declared(m.newAsyncSocket): f.add("newAsyncSocket")
    when declared(m.dial): f.add("dial")
    when declared(m.connect): f.add("connect")
    when declared(m.getAddrInfo): f.add("getAddrInfo")
    when declared(m.socket): f.add("socket")
    when declared(m.bindAddr): f.add("bindAddr")
    when declared(m.listen): f.add("listen")
    when declared(m.accept): f.add("accept")
    # ambient process state
    when declared(m.getEnv): f.add("getEnv")
    when declared(m.putEnv): f.add("putEnv")
    when declared(m.paramStr): f.add("paramStr")
    when declared(m.commandLineParams): f.add("commandLineParams")
    when declared(m.getCurrentDir): f.add("getCurrentDir")
    when declared(m.getAppFilename): f.add("getAppFilename")
    when declared(m.getHomeDir): f.add("getHomeDir")
    # the FFI escape
    when declared(m.loadLib): f.add("loadLib")
    when declared(m.symAddr): f.add("symAddr")
    when declared(m.unloadLib): f.add("unloadLib")
    when declared(m.fork): f.add("fork")
    when declared(m.execv): f.add("execv")
    when declared(m.execvp): f.add("execvp")
    # turning the asynchronous API back into a blocking one
    when declared(m.waitFor): f.add("waitFor")
    when declared(m.runForever): f.add("runForever")
    when declared(m.poll): f.add("poll")
    when declared(m.drain): f.add("drain")
    f

const
  ProbedModules = [
    "std/algorithm", "std/bitops", "std/deques", "std/hashes", "std/heapqueue",
    "std/intsets", "std/lists", "std/math", "std/monotimes", "std/options",
    "std/packedsets", "std/parseutils", "std/sequtils", "std/sets",
    "std/strformat", "std/strutils", "std/sugar", "std/tables", "std/times",
    "std/typetraits", "std/unicode",
  ]

suite "PLAT-8: the std allow-list, measured rather than read":

  test "the probe covers every admitted module, and nothing else":
    ## The coverage assertion. Verification-Harness-Traps §4b: the membership of
    ## this loop is KNOWABLE, so the control is the COUNT and not "at least
    ## one".
    ck ProbedModules.len == PluginAllowedStdlibModules.len
    var missing: seq[string] = @[]
    for entry in PluginAllowedStdlibModules:
      var found = false
      for probed in ProbedModules:
        if probed == entry.primitive:
          found = true
      if not found:
        missing.add(entry.primitive)
    checkpoint("admitted but unprobed: " & $missing)
    ck missing.len == 0
    var stale: seq[string] = @[]
    for probed in ProbedModules:
      if not isAllowedStdlibModule(probed):
        stale.add(probed)
    checkpoint("probed but no longer admitted: " & $stale)
    ck stale.len == 0

  test "the probe CAN see a dangerous name — nine refused modules light up":
    ## THE POSITIVE TWIN, and it is the whole reason the next case is evidence.
    ## A `declared()` sweep that matched nothing would report every admitted
    ## module clean and every refused one clean too, and the transcript would be
    ## identical to a correct run.
    ck dangerousIn(d_os).len >= 8
    ck "execShellCmd" in dangerousIn(d_os)
    ck "getEnv" in dangerousIn(d_os)
    ck "fork" in dangerousIn(d_posix)
    ck "execv" in dangerousIn(d_posix)
    ck "socket" in dangerousIn(d_posix)
    ck "startProcess" in dangerousIn(d_osproc)
    ck "newSocket" in dangerousIn(d_net)
    ck "loadLib" in dangerousIn(d_dynlib)
    ck "newFileStream" in dangerousIn(d_streams)
    ck "readFile" in dangerousIn(d_syncio)
    ck "parseFile" in dangerousIn(d_json)
    # `std/asyncdispatch` is the one a reader assumes is already handled. The
    # SDK re-exports it MINUS these four; a plugin importing it itself gets
    # them back, which is why it is refused rather than admitted.
    ck "waitFor" in dangerousIn(d_asyncdispatch)
    ck "poll" in dangerousIn(d_asyncdispatch)
    ck "drain" in dangerousIn(d_asyncdispatch)

  test "no admitted module hands out a dangerous name":
    ## THE RULE. Twenty-one modules, one assertion each, so a failure names the
    ## module rather than the set.
    ck dangerousIn(a_algorithm).len == 0
    ck dangerousIn(a_bitops).len == 0
    ck dangerousIn(a_deques).len == 0
    ck dangerousIn(a_hashes).len == 0
    ck dangerousIn(a_heapqueue).len == 0
    ck dangerousIn(a_intsets).len == 0
    ck dangerousIn(a_lists).len == 0
    ck dangerousIn(a_math).len == 0
    ck dangerousIn(a_monotimes).len == 0
    ck dangerousIn(a_options).len == 0
    ck dangerousIn(a_packedsets).len == 0
    ck dangerousIn(a_parseutils).len == 0
    ck dangerousIn(a_sequtils).len == 0
    ck dangerousIn(a_sets).len == 0
    ck dangerousIn(a_strformat).len == 0
    ck dangerousIn(a_strutils).len == 0
    ck dangerousIn(a_sugar).len == 0
    ck dangerousIn(a_tables).len == 0
    ck dangerousIn(a_times).len == 0
    ck dangerousIn(a_typetraits).len == 0
    ck dangerousIn(a_unicode).len == 0

  test "the list is closed under re-export — intsets IS 'export packedsets'":
    ## `import` is not `export`, and the difference is the whole membership
    ## rule. `std/times` imports `std/posix` on this arm and re-exports none of
    ## it; `std/intsets` re-exports `std/packedsets` WHOLE, so admitting the
    ## first commits the list to the second.
    ##
    ## Both halves are asserted, because either alone is satisfiable by
    ## accident: the first by a probe that cannot see a module name at all, the
    ## second by a list that happens to hold `packedsets` for another reason.
    ck declared(packedsets.incl)
    ck isAllowedStdlibModule("std/packedsets")
    # And the negative direction, which is what makes the rule cheap: an
    # imported-but-not-exported module does NOT propagate.
    ck not declared(posix.fork)
    ck not declared(os.getEnv)
    ck not declared(osproc.startProcess)
    ck not declared(streams.newFileStream)
    ck not declared(json.parseFile)
    ck not declared(asyncdispatch.waitFor)
    ck not declared(dynlib.loadLib)
    ck not declared(nativesockets.getAddrInfo)

  test "'system' is the residual, and it is asserted rather than described":
    ## The allow-list cannot reach `system`: it is auto-imported into every nim
    ## module, exported by nothing, and filterable by no `except` clause, so
    ## there is no import to refuse. What still stands in front of it is
    ## `PluginDeniedSyncIo`'s NAME-based scan — a denylist, which is the
    ## mechanism the allow-list exists because it lost, and the only one
    ## available here.
    ##
    ## These are asserted TRUE on purpose. The day nim moves one of them out of
    ## `system`, this case goes red and somebody re-reads the residual, instead
    ## of a paragraph quietly becoming false.
    ##
    ## ## IT ENUMERATED TEN NAMES AND THE RESIDUAL WAS NOT TEN NAMES
    ##
    ## Corrected 2026-09-09. `system.nim` ends with `export syncio`, so the
    ## surface is the WHOLE of `std/syncio` — thirty-six entries on the pinned
    ## compiler — and the ten below were a sample somebody wrote down. `open`
    ## was among them and was denied nowhere; `readBuffer` and `writeBuffer`
    ## were not among them at all, and with `open` they are a complete
    ## unmediated file I/O API. `plugin_probes/sysio_raw_plugin.nim.probe` is
    ## that program and it printed `SYSIO-READ[gpu-server-001]`.
    ##
    ## **THIS CASE IS NOT THE ENUMERATION AND MUST NOT BE READ AS ONE.** The
    ## set is derived from the compiler by `ci/lib/system-io-surface.sh` and
    ## checked for completeness by the gate's `system-surface-enumerated`; a
    ## list in a test file is exactly the thing that was short three times.
    ## What this case is, is a TRIPWIRE on the language: it names the routines
    ## the residual's argument actually rests on, so that if nim moves one the
    ## argument is re-read rather than assumed.
    ck declared(readFile)
    ck declared(writeFile)
    ck declared(readLine)
    ck declared(readLines)
    ck declared(readChar)
    ck declared(staticExec)
    ck declared(gorge)
    ck declared(gorgeEx)
    ck declared(open)
    ck declared(close)
    # The routines that BIND A PATH OR A DESCRIPTOR to a `File` — the ones the
    # sweep added, and the reason the old ten were not the surface. `reopen`
    # needs no `open`; `lines` needs one identifier.
    ck declared(reopen)
    ck declared(lines)
    ck declared(getFileHandle)
    ck declared(getOsFileHandle)
    # The buffer family, which turns `open` into a complete read and write.
    ck declared(readBuffer)
    ck declared(readBytes)
    ck declared(readChars)
    ck declared(writeBuffer)
    ck declared(writeBytes)
    ck declared(writeChars)
    ck declared(writeLine)
    # Compile time is not inside the sandbox either.
    ck declared(slurp)
    ck declared(staticRead)
    # AND THE THREE `File` VALUES A PLUGIN STILL HAS. These are what `write`
    # and `close` — the two names that cannot be denied, because they are the
    # SDK's own spellings — can still reach. Asserted so the residual's "it
    # cannot name a path" stays a statement about something real.
    ck declared(stdin)
    ck declared(stdout)
    ck declared(stderr)

  test "every admitted entry carries a reason, and every entry is a std spec":
    ## The reason column is the review the membership rule asks for, so an entry
    ## with an empty one is an entry nobody argued for. And the spelling matters
    ## mechanically: `stdlib_admitted` in the gate compares whole specs, so an
    ## entry written `strutils` would admit nothing and the symptom would be a
    ## plugin refused for importing the module the table says is fine.
    for entry in PluginAllowedStdlibModules:
      ck entry.primitive.len > 4
      ck entry.primitive[0 .. 3] == "std/"
      ck entry.replacement.len >= 20
    for entry in PluginDeniedFfiPragmas:
      ck entry.primitive.len > 0
      ck entry.replacement.len > 0

  test "the assertion count is what this file says it is":
    ## Verification-Harness-Traps §4c. Written from a run, and it fails until
    ## somebody moves it deliberately.
    check countedAssertions == 164
    # DECLARE THE TALLY TO THE LANE. `run-nim-test-lane.sh` reads
    # `CHECKS: <n>` out of a suite's OUTPUT; a file that prints none is
    # counted as unmeasured and named as such, because a CASE count is
    # not an assertion count (Verification-Harness-Traps 7).
    echo "CHECKS: " & $countedAssertions

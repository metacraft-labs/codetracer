## plugin_model/source_admission.nim — PLAT-8's SOURCE-LEVEL admission policy.
##
## `capabilities.nim` decides what a plugin may DO once it is running. This
## module decides what a plugin's SOURCE may REACH, which is the question that
## comes first — because a plugin that never calls the SDK never reaches
## `decide` at all.
##
## ## WHY THIS EXISTS: THE MODEL WAS NOT IN THE PATH
##
## Measured on 2026-09-09, with a DECLARED plugin, against the real gate. A
## module carrying the `## CT-PLUGIN:` marker, importing `codetracer_plugin`
## and `std/posix` and nothing else:
##
##     posix read of /etc/hostname, no fs:read grant -> gpu-server-001
##     posix fork+exec of /bin/sh, no process grant  -> child pid 505249
##     POSIX-EXEC-REACHED
##
## and `ci/test/plugin-reactive-boundary.sh` over that tree:
##
##     OK  plugin-uses-the-surface: all 6 declared plugin(s) import
##         'codetracer_plugin'
##     OK  plugin-names-no-sync-io: 6 module(s) in the plugin closure,
##         no synchronous I/O primitive named in code
##     plugin-reactive-boundary: 19 check(s), 0 failing
##
## Nineteen green checks over a plugin that reads any file and runs any
## program. Three separate reasons, and none of them is a bug in a regex:
##
##   * `PluginDeniedSyncIo` is a list of NAMES. `std/posix` spells the same
##     operations `open`, `read`, `write`, `socket`, `connect`, `fork` and
##     `execv`, and most of those CANNOT go on a denied list — `read` and
##     `write` are the SDK's own spellings, so denying them denies the
##     sanctioned path (Verification-Harness-Traps §4a, from the other side).
##   * the gate admitted EVERY `std/` import by name, on the argument that the
##     standard library "carries no reactive primitive". True, and beside the
##     point once the subject widened from PLAT-7's primitives to PLAT-8's
##     operating system.
##   * a denylist over a language surface loses. PLAT-7 paid seven passes to
##     learn that on the import extractor; this is the same lesson on the
##     import SUBJECT. Seven more names on a denylist is seven more names.
##
## ## THE MEMBERSHIP RULE
##
## An allow-list is only as good as the sentence that decides membership, so
## the sentence is here and every row below is an application of it:
##
## > **A `std/` module is admitted into a plugin's closure only if nothing its
## > interface hands the plugin can produce an effect the capability model
## > exists to mediate — process creation, filesystem access, or network
## > access — and nothing it hands the plugin is an FFI escape (`importc`,
## > `dynlib`, `header`) through which any of those could be reconstructed.
## > Admission is decided over the module's EXPORTED surface, including every
## > module it re-exports, and not over its name.**
##
## Four consequences worth stating, because each has already caught something:
##
##   1. **`import` is not `export`.** `std/times` imports `std/posix` on the
##      POSIX arm and re-exports nothing of it, so `times.fork` does not
##      resolve. A rule written over the transitive IMPORT closure would refuse
##      most of the list for no gain; the rule is over the EXPORT closure.
##   2. **The list is closed under re-export.** `std/intsets` is
##      `export packedsets`, so admitting the first commits you to the second.
##      `plugin_source_admission_test.nim` asserts the closure rather than
##      describing it.
##   3. **A clock is not a mediated kind.** `std/times` and `std/monotimes`
##      read the wall clock, the monotonic counter and the local timezone.
##      None of those is a `IoRequestKind`, so the rule admits them, and what
##      that leaves open is written down in the milestone's residual list
##      rather than quietly enjoyed.
##   4. **A bound FFI function is not an FFI escape.** `std/math` carries 110
##      `importc` declarations and every one of them is a pure function of its
##      arguments — `sqrt` reconstructs no syscall. What the rule refuses is a
##      GENERAL escape (`std/dynlib`'s `loadLib`/`symAddr`) or a binding to an
##      operation the model mediates (`std/posix`'s `fork`, `execv`, `socket`).
##
## ## WHAT IS DELIBERATELY OFF THE LIST, WITH THE REASON
##
## | module | why it is refused |
## |---|---|
## | `std/os`, `std/osproc`, `std/posix`, `std/dynlib`, `std/net`, `std/nativesockets`, `std/asyncnet`, `std/asyncfile`, `std/httpclient` | each is directly a mediated effect |
## | `std/streams` | `openFileStream`, `newFileStream` and `lines` open files |
## | `std/syncio` | `readFile`, `writeFile`, `readLines` |
## | `std/json` | `parseFile` reads a file. Everything else in it is inert, and this is the entry a plugin author will miss most; the answer is for the SDK to offer the parser over bytes the plugin obtained through `ctx.readPath`, which is PLAT-9's diff and not this one's |
## | `std/asyncdispatch` | this is the interesting one. The SDK re-exports it with `waitFor`, `runForever`, `poll` and `drain` FILTERED OUT, and a plugin writing `import std/asyncdispatch` itself gets all four back. `export … except` narrows one path and cannot narrow a second one the plugin opens for itself |
## | `std/tempfiles`, `std/browsers`, `std/sysrand`, `std/cpuinfo`, `std/rdstdin`, `std/terminal`, `std/posix_utils`, `std/termios`, `std/exitprocs`, `std/locks`, `std/oids` | each creates a file, spawns a program, reads a device, reads a tty, or reaches libc |
##
## The refusals are NOT enumerated in code. That is the whole shape of an
## allow-list and it is what makes it different from the four denied lists this
## campaign already has: a module nobody has thought about is refused, and a
## module added to nim tomorrow is refused.
##
## ## WHAT THE ALLOW-LIST DOES NOT REACH — `system`
##
## **THE SURFACE HERE IS NOT BOUNDED BY ANY ENUMERATION THIS REPOSITORY
## MAINTAINS.** This section used to name ten routines and call the surface
## "small and enumerable"; that was the defect, and it is quoted in the
## milestone's residual list rather than deleted. `system.nim` ends with
##
##     when not defined(nimPreviewSlimSystem):
##       import std/syncio
##       export syncio
##
## so what `system` puts in every plugin's scope is **the whole exported
## surface of `std/syncio`** — thirty-six entries on the pinned compiler — plus
## `system`'s own compile-time family in `system/compilation.nim`. Nine of the
## thirty-six were denied. `open` was named in the paragraph and denied nowhere;
## `readBuffer`, `readBytes`, `readChars` and `writeBuffer` were not named at
## all. Those five are a complete unmediated file I/O API, and it was measured:
##
##     SYSIO-READ[gpu-server-001]     <- /etc/hostname, no fs:read grant
##     SYSIO-WRITE-OK                 <- a file created, no fs:write grant
##
## from a module whose entire import list is `import codetracer_plugin` and
## which carries no pragma — this module's own motivating measurement,
## reproduced by a route with no import for this module to range over. It is
## committed as `plugin_probes/sysio_raw_plugin.nim.probe`.
##
## No `except` clause can filter `system` and no import allow-list can refuse
## it, because there is no import to refuse. So the mechanism is still the
## NAME-based source gate — a denylist, exactly the mechanism this module
## exists because it lost, and the only one `system` leaves available.
## **What changed on 2026-09-09 is not the mechanism but where its list comes
## from.**
##
## `ci/lib/system-io-surface.sh` sweeps the exported surface of `std/syncio` and
## `system/compilation.nim` off the PINNED COMPILER'S OWN SOURCE on every gate
## run, and check 23 (`system-surface-enumerated`) requires every derived name
## to be on one of two tables in `plugin_host/plugin_io.nim`: refused
## (`PluginDeniedSyncIo`, 41 entries) or **exempted with a written reason**
## (`PluginSystemSurfaceExempt`, 27). A name on neither reddens the gate, so a
## nim release that adds a routine to `syncio` is a red check rather than a
## silent widening. That is the property no list kept in this file could have,
## and it is why the list is no longer kept in this file.
##
## THE SWEEP IS WHAT A HAND-KEPT LIST COULD NOT BE. Two of the twenty-one names
## it added appear on no enumeration anybody wrote of this hole:
##
##   * `reopen(stdin, "/etc/hostname", fmRead)` reads any file with **no `open`
##     at all** — `stdin` is already a `File` — so denying only the name that
##     HAD been written down would have left the hole exactly where it was;
##   * `for l in lines("/etc/hostname")` reads any file with ONE identifier.
##
## ### WHAT IS STILL OPEN, STATED AS WHAT IT IS
##
## Two names cannot be denied, because they are the SDK's own spellings and
## denying them would refuse the sanctioned path: `write` and `close`. What they
## can still reach is `stdin`, `stdout`, `stderr` and `stdmsg` — the host's own
## standard streams — because every routine that binds a PATH or a DESCRIPTOR to
## a `File` is refused (`open`, `reopen`, `lines`, `readFile`, `writeFile`,
## `readLines`, `getFileHandle`, `getOsFileHandle`). A plugin can still write to
## CodeTracer's standard streams and close them; **it cannot READ them** — every
## routine that could, `readLine`, `readAll`, `readBuffer`, `readChar`,
## `readChars` and `lines`, is on `PluginDeniedSyncIo` — so `write` and `close`
## are the whole of what the exemption permits, and **it cannot name a path.**
##
## CORRECTED 2026-09-09, IN VERIFICATION, and the correction is the same kind of
## defect as the one this section already records. It read "write to
## CodeTracer's stdout and read its stdin". The reading half was never true: it
## was found by MEASURING the claim — asking which routines could read `stdin`
## and finding every one of them already denied — rather than by reading the
## sentence again. It overstated the residual, which is the safe direction to be
## wrong in, and a residual that overstates is still a residual nobody can
## check. The whole point of the 2026-09-09 pass was to replace a claim with a
## derived fact; a hand-written sentence about the derived set is exactly where
## the next such claim hides.
##
## That sentence is a claim about the PINNED COMPILER'S `std/syncio`, re-derived
## on every run — not a bound this file maintains. It is the strongest form the
## claim has, because the alternative is a longer list that is short in a way
## nobody has found yet, which is what the previous two versions of this
## paragraph were.
##
## The derivation's SCOPE is part of the claim: `std/syncio` and
## `system/compilation.nim` in full, and NOT `system.nim`'s other five
## hundred-odd exported names, which are arithmetic, memory management and
## control flow. Two things in that remainder are worth naming, because they are
## what the scope actually costs:
##
##   * `quit` and `addQuitProc`. A plugin calling `quit` terminates CodeTracer —
##     an effect the capability model does not describe and does not mediate.
##   * **`cast`.** `cast[File](0)` fabricates a `File` out of an integer, and
##     `write` — undeniable, because it is the SDK's own spelling — accepts it.
##     Measured, `surface_reach_probe`: `cast-to-File-reachable=true`,
##     `write-to-cast-File-reachable=true`. It does NOT let a plugin name a
##     path: the value is a `FILE*`, so it reaches a real file only by guessing
##     the address of one the host already has open, and the constant is a null
##     pointer that crashes rather than opening anything. Same shape as the
##     `AsyncFD` vocabulary — addressable by number, not constructible — and
##     the reason "it cannot name a path" is written above rather than "it
##     cannot reach a file".
##
## ## HOW THIS IS ENFORCED, AND BY WHOM
##
## | reader | what it does with this table |
## |---|---|
## | `ci/test/plugin-reactive-boundary.sh` | parses the names out of it with the same `table_names` awk that reads `PluginDeniedPrimitives` and `PluginDeniedSyncIo`, and refuses a plugin closure importing a `std/` module that is not here |
## | `src/common/plugin_source_admission_test.nim` | imports every module named here and asserts, by `declared()`, that the dangerous surface is not reachable through it — with `std/os`, `std/posix`, `std/osproc`, `std/net` and `std/dynlib` as the positive twins that prove the probe can see one |
## | `ci/lib/system-io-surface.sh` | the FIFTH list, and the only one not written down in this repository: it DERIVES `system`'s auto-imported surface from the compiler in use, and check 23 requires the two tables in `plugin_io.nim` to partition it. See the `system` section above for why a list kept here could not do that job |
##
## Nothing hardcodes the list in either place. That is the property
## `PluginDeniedPrimitives` and `PluginDeniedSyncIo` already have and the reason
## the table lives in code rather than in the gate.
##
## ## THE LIST IS MINIMAL BY CONSTRUCTION
##
## An entry nobody imports is review surface with no consumer, so the list holds
## what the rule admits AND something in this tree needs. **Adding a row is
## expected and is a one-line change**; what it costs is the reason column and a
## probe arm in the conformance suite, which is the review the rule asks for.

const
  PluginAllowedStdlibModules*: array[21, tuple[primitive, replacement: string]] = [
    ## THE ALLOW-LIST. Left: the module spec, exactly as a plugin writes it.
    ## Right: the reason it satisfies the membership rule above.
    ##
    ## The tuple field is called `primitive` because
    ## `plugin-reactive-boundary.sh`'s `table_names` is ONE awk program over
    ## three tables (Verification-Harness-Traps §14) and the two older ones
    ## carry primitives. A second parser for a second field name would be a
    ## second thing that can be wrong.
    ("std/algorithm", "sorting, searching and reversing over seqs already in memory"),
    ("std/bitops", "bit manipulation on integers; every routine is a pure function of its arguments"),
    ("std/deques", "a double-ended queue over values the plugin already holds"),
    ("std/hashes", "hashing of in-memory values; opens nothing"),
    ("std/heapqueue", "a binary heap over values the plugin already holds"),
    ("std/intsets", "a sparse int set; it is `export packedsets` and nothing else, so the closure rule commits to packedsets below"),
    ("std/lists", "singly and doubly linked lists over in-memory values"),
    ("std/math", "arithmetic; its importc declarations bind libm, and a bound pure function is not an FFI escape"),
    ("std/monotimes", "a monotonic counter. A clock is not a mediated kind — see the rule's third consequence"),
    ("std/options", "the Option type; a wrapper over a value"),
    ("std/packedsets", "the set intsets re-exports; admitted for the closure rule, not separately"),
    ("std/parseutils", "parsing numbers and tokens out of a string in memory"),
    ("std/sequtils", "map, filter and fold over seqs"),
    ("std/sets", "hash sets over in-memory values"),
    ("std/strformat", "the `fmt` macro; string interpolation over values in scope"),
    ("std/strutils", "string manipulation. Its only re-exports are `toLower` and `toUpper`"),
    ("std/sugar", "`=>`, `dup` and `collect`; syntax over expressions the plugin wrote"),
    ("std/tables", "hash tables over in-memory values"),
    ("std/times", "wall clock, durations and formatting. A clock is not a mediated kind; it imports std/posix on that arm and re-exports none of it"),
    ("std/typetraits", "compile-time type introspection; it emits no code that runs"),
    ("std/unicode", "rune-level string handling, including the generated range tables"),
  ]

  PluginDeniedFfiPragmas*: array[13, tuple[primitive, replacement: string]] = [
    ## THE ROUTE THE ALLOW-LIST DOES NOT CLOSE, CLOSED SEPARATELY.
    ##
    ## Found by attacking the allow-list on the day it was written, and it
    ## needs NO import at all — so refusing every module in the world would not
    ## have reached it. Measured, compiled and run against the real surface:
    ##
    ##     # the whole module
    ##     import codetracer_plugin
    ##     proc c_system(cmd: cstring): cint
    ##       {.importc: "system", header: "<stdlib.h>".}
    ##     discard c_system("printf FFI-REACHED > /tmp/ct-plat8-ffi.txt")
    ##
    ##     $ cat /tmp/ct-plat8-ffi.txt
    ##     FFI-REACHED
    ##
    ## One line of pragma is `system(3)`, which is every grant at once. An
    ## allow-list over imports that left this open would have been a repair
    ## whose headline claim — *a plugin reaches the operating system only
    ## through the SDK* — was false on the day it shipped, which is the shape
    ## this campaign has had to withdraw six times.
    ##
    ## **AND THIS ONE IS A DENYLIST, WHICH IS WORTH SAYING RATHER THAN
    ## GLOSSING.** The argument for an allow-list is that a denylist over an
    ## OPEN set loses, and the set of library identifiers is open. The set of
    ## nim's FOREIGN-FUNCTION pragmas is not: it is closed, enumerable, and
    ## fixed by the compiler's own grammar, so a denylist over it is a
    ## different kind of object from a denylist over `readFile`. A pragma nim
    ## ADDS in a future release is not on this list, and nothing here will
    ## notice. That is a compiler upgrade's review item, not a spelling a plugin
    ## author can invent.
    ##
    ## ## THIS LIST AND THE ALLOW-LIST ARE ONE COMPOSED DEFENCE, NOT TWO
    ##
    ## Corrected 2026-09-09; it was described as an independent second layer and
    ## it is not one. The gate matches these names INSIDE `{. … .}` spans, which
    ## is what keeps an ordinary variable called `header` from being a finding —
    ## and it is also what makes the list defeated outright by a pragma that is
    ## BUILT rather than written:
    ##
    ##     nnkPragma.newTree(
    ##       nnkExprColonExpr.newTree(ident("importc"), newLit("system")))
    ##
    ## puts the word `importc` nowhere on any line of source. MEASURED, through
    ## the gate's own `code_lines | blank_strings | pragma_spans` pipeline: such
    ## a module yields **zero spans**, against two for the committed
    ## `ffi_raw_plugin` probe. What refuses that module is the ALLOW-LIST,
    ## because `std/macros` is not on it.
    ##
    ## The dependency runs the other way too — this list is what stops a plugin
    ## reconstructing a syscall out of the modules the allow-list DOES admit —
    ## so neither is a fallback for the other and they do not degrade
    ## gracefully. **The operational consequence is a rule about admission, not
    ## a note about a diagram: admitting `std/macros` to
    ## `PluginAllowedStdlibModules` would silently retire this entire table
    ## along with it.** Any candidate that can SYNTHESISE a pragma, an `emit` or
    ## a call — `std/macros`, `std/genasts`, anything reflective — carries that
    ## cost, and the membership rule's FFI clause has to be read as covering
    ## CONSTRUCTION and not only spelling.
    ##
    ## Left: the pragma. Right: what a plugin does instead.
    ("importc", "call the SDK; a plugin does not bind C functions"),
    ("importcpp", "call the SDK; a plugin does not bind C++ functions"),
    ("importobjc", "call the SDK; a plugin does not bind Objective-C methods"),
    ("importjs", "call the SDK; a plugin does not bind host JS"),
    ("dynlib", "call the SDK; a plugin does not load shared objects"),
    ("header", "call the SDK; a plugin includes no C header"),
    ("emit", "call the SDK; a plugin emits no backend code"),
    ("compile", "call the SDK; a plugin adds no compilation unit"),
    ("link", "call the SDK; a plugin links nothing of its own"),
    ("passC", "call the SDK; a plugin does not steer the C compiler"),
    ("passL", "call the SDK; a plugin does not steer the linker"),
    ("codegenDecl", "call the SDK; a plugin does not rewrite its own codegen"),
    ("nodecl", "call the SDK; a plugin declares no foreign symbol"),
  ]

  PluginDeniedFfiPragmasConst* = "PluginDeniedFfiPragmas"
    ## Read by the gate the same way, and by name for the same reason.

  PluginAllowedStdlibModulesConst* = "PluginAllowedStdlibModules"
    ## The name `ci/test/plugin-reactive-boundary.sh` looks the table up by,
    ## read from here rather than spelled in the gate — the same drift guard
    ## `CodeTracerPluginSurfaceModule` puts on the surface's module name. A
    ## rename that did not carry the gate with it would leave the gate parsing
    ## nothing, and a parsed-nothing allow-list refuses every plugin loudly
    ## rather than admitting one silently, which is the direction this failure
    ## has to fall.

func isAllowedStdlibModule*(spec: string): bool =
  ## True when SPEC is a `std/` module a plugin's closure may import.
  ##
  ## ONE PREDICATE, ONE FUNCTION (Verification-Harness-Traps §14). The gate
  ## asks the same question in awk over the same table; this is what the Nim
  ## conformance suite asks, and the suite asserts the two agree by comparing
  ## the parsed name set with this array rather than by re-listing it.
  for entry in PluginAllowedStdlibModules:
    if entry.primitive == spec:
      return true
  false

## editor_core_admission.nim — PLAT-29's SOURCE-LEVEL admission policy for the
## editor model's import closure.
##
## Owns the mechanical half of Editor-ViewModel.md §11's third rule: *"The
## model never waits. It has no `Future`, no callback, no clock."*
##
## ## WHY A CLOSURE AND NOT A SCAN, AND WHY THIS IS THE MILESTONE THAT CHANGED IT
##
## Until PLAT-29 that sentence was checked — where it was checked at all — by a
## TEXT SCAN over the editor modules' own source, looking for `await` and
## `Future`. **A scan over a module's own text cannot see an `await` reached
## through a transitive import**, and one module of indirection defeats it
## completely. PLAT-8 measured the same shape one layer up and recorded it in
## those words: *"until 2026-09-08 the two rules below were applied to each
## declared plugin FILE and to nothing else, and one module of indirection
## defeated them completely."*
##
## So the subject is the CLOSURE: every module reachable by import from any
## module in `src/frontend/viewmodel/editor/`, and the standard-library specs
## that closure names.
##
## ## THE MEMBERSHIP RULE
##
## An allow-list is only as good as the sentence that decides membership, so
## the sentence is here and every row below is an application of it:
##
## > **A `std/` module is admitted into the editor model's closure only if
## > nothing its interface hands the model can suspend, schedule, block, read a
## > clock, touch a file, spawn a process or open a socket — and nothing it
## > hands the model is an FFI escape (`importc`, `dynlib`, `header`) through
## > which any of those could be reconstructed. Admission is decided over the
## > module's EXPORTED surface, including every module it re-exports, and not
## > over its name.**
##
## Three consequences, each of which already decides a row:
##
##   1. **A CLOCK IS REFUSED HERE AND IS ADMITTED BY PLAT-8's LIST.** The two
##      lists answer different questions and this is the row where they visibly
##      disagree. `PluginAllowedStdlibModules` admits `std/times` and
##      `std/monotimes`, with the reason *"a clock is not a mediated kind"* —
##      true for the capability model, which mediates effects. §11 mediates
##      DETERMINISM: a model that reads a clock cannot be replayed, cannot be
##      compared across two hosts, and cannot have its edit latency measured
##      without the measurement changing under it. So the editor core gets its
##      own list rather than reusing that one, and the divergence is a row with
##      a reason rather than an oversight.
##   2. **`import` IS NOT `export`.** The rule is over the EXPORT closure, the
##      same way PLAT-8's is: `std/times` imports `std/posix` on the POSIX arm
##      and re-exports nothing of it.
##   3. **THE REFUSALS ARE NOT ENUMERATED.** That is the whole shape of an
##      allow-list: a module nobody has thought about is refused, and a module
##      Nim adds tomorrow is refused.
##
## ## HOW THIS IS ENFORCED, AND BY WHOM
##
## | reader | what it does with this table |
## |---|---|
## | `ci/test/editor-import-closure.sh` | parses the names out of it and refuses a closure module importing a `std/` module that is not here |
## | `src/frontend/viewmodel/tests/unit/test_editor_async_closure.nim` | drives that gate against the real tree AND against seven synthetic trees, one per route past a text scan, and asserts the gate reddens on each |
##
## Nothing hardcodes the list in either place. The gate looks the table up by
## the name in `EditorCoreAllowedStdlibModulesConst` below, read from here
## rather than spelled in the gate — so a rename that did not carry the gate
## with it leaves the gate parsing nothing, and a parsed-nothing allow-list
## refuses every module loudly rather than admitting one silently.
##
## ## THE LIST IS MINIMAL BY CONSTRUCTION
##
## An entry nobody imports is review surface with no consumer, so the list holds
## what the rule admits AND something in the editor closure needs today. Adding
## a row is a one-line change; what it costs is the reason column.

const
  EditorCoreAllowedStdlibModules*: array[6, tuple[primitive, replacement: string]] = [
    ## THE ALLOW-LIST. Left: the module spec, exactly as a module writes it.
    ## Right: the reason it satisfies the membership rule above.
    ##
    ## The tuple field is called `primitive` because the gate's table parser is
    ## ONE awk program over several tables and the older ones carry primitives
    ## (Verification-Harness-Traps §30). A second parser for a second field
    ## name would be a second thing that can be wrong.
    ("std/algorithm", "sorting, searching and reversing over seqs already in memory; suspends nothing and opens nothing"),
    ("std/options", "the Option type; a wrapper over a value the caller already has"),
    ("std/sequtils", "map, filter and fold over seqs in memory"),
    ("std/strutils", "string manipulation. Its only re-exports are `toLower` and `toUpper`"),
    ("std/tables", "hash tables over in-memory values"),
    ("std/unicode", "rune-level string handling, including the generated range tables. The grapheme segmenter the whole coordinate model rests on is built on it"),
  ]

  EditorCoreDeniedNames*: array[18, tuple[primitive, replacement: string]] = [
    ## THE ROUTE THE ALLOW-LIST DOES NOT CLOSE, CLOSED SEPARATELY — and it is
    ## the same route PLAT-8 found: `system` is auto-imported, so there is no
    ## import to refuse and no scope to filter.
    ##
    ## A denylist, which is worth saying rather than glossing. It is the only
    ## mechanism available for `system`, and it is NOT the primary defence: the
    ## allow-list is. What this adds is the identifiers that need no import at
    ## all, plus the four async spellings that would arrive through a re-export
    ## the allow-list had already admitted.
    ##
    ## **THIS LIST AND THE ALLOW-LIST ARE ONE COMPOSED DEFENCE, NOT TWO**
    ## (Verification-Harness-Traps §32a): each needs evidence only it can
    ## satisfy, or the older one silently loses its mutation coverage. The
    ## closure suite's seven routes are split accordingly — the `export … except`
    ## route and the re-export route are refused by the ALLOW-LIST and by
    ## nothing else, and the FFI-pragma route is refused by the PRAGMA table and
    ## by nothing else.
    ##
    ## Left: the identifier. Right: what the model does instead.
    ("await", "the model does not suspend; an async producer computes outside it and is reconciled by `reconcile`"),
    ("waitFor", "the model does not block; §11's whole point is that a keystroke waits on nothing"),
    ("runForever", "the model owns no loop"),
    ("asyncCheck", "the model starts no task"),
    ("callSoon", "the model schedules nothing; a front-end observes a signal"),
    ("addTimer", "the model has no timer"),
    ("sleep", "the model never waits"),
    ("getTime", "the model reads no clock; a transaction that wants a timestamp carries one as an `anTime` annotation the CALLER supplied"),
    ("epochTime", "as `getTime`"),
    ("cpuTime", "as `getTime`"),
    ("getMonoTime", "as `getTime`"),
    ("readFile", "a file read is an async producer outside the model, reconciled as `pkFileRead`"),
    ("writeFile", "a file write is an async producer outside the model, reconciled as `pkFileWrite`"),
    ("readLines", "as `readFile`"),
    ("openFileStream", "as `readFile`"),
    ("startProcess", "the model spawns nothing"),
    ("execCmd", "the model spawns nothing"),
    ("newSocket", "the model opens no socket"),
  ]

  EditorCoreAllowedStdlibModulesConst* = "EditorCoreAllowedStdlibModules"
    ## The name `ci/test/editor-import-closure.sh` looks the table up by, read
    ## from here rather than spelled in the gate — the same drift guard PLAT-8
    ## puts on its own three tables.

  EditorCoreDeniedNamesConst* = "EditorCoreDeniedNames"

  EditorCoreRootDir* = "src/frontend/viewmodel/editor"
    ## The closure's ROOT SET is this directory, enumerated at run time.
    ## Verification-Harness-Traps §35: *"a source scan is only as wide as its
    ## subject list, and a hardcoded subject list cannot see a new file in the
    ## directory it claims to cover."* A list of module names here would have
    ## been exactly that list.

func isEditorCoreAllowedStdlibModule*(spec: string): bool =
  ## True when SPEC is a `std/` module the editor model's closure may import.
  ##
  ## ONE PREDICATE, ONE FUNCTION (Verification-Harness-Traps §30). The gate asks
  ## the same question in awk over the same table; this is what the Nim suite
  ## asks, and the suite asserts the two agree by comparing the gate's parsed
  ## name set with this array rather than by re-listing it.
  for entry in EditorCoreAllowedStdlibModules:
    if entry.primitive == spec:
      return true
  false

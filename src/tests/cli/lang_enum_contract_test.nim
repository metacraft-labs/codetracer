## lang_enum_contract_test.nim
##
## Three properties of the `Lang` enum that nothing else checks, asserted
## mechanically rather than by inspection.
##
## ## 1. `detectLangFromPath` answers `LangUnknown`, it does not fall off its end
##
## `src/ct/utilities/language_detection.nim`'s `detectLangFromPath` had no final
## `return`.  Nim initialises `result` to the enum's zero value, `LangC` is
## ordinal 0, and so every path with an extension the table does not know was
## reported as **C**: `a.out`, `my.project`, `python3.11`, `libfoo.so.1`,
## `data.json`, `notes.txt`, `archive.tar.gz`.  Only a dot-less name hit the
## `ext.len <= 1` guard and produced `LangUnknown`.
##
## That silently disabled the `ct-native-replay recognize` delegation: a
## non-`LangUnknown` answer ends `detectTarget`'s ladder, so an extensionless
## native binary named `a.out` was decided to be C and the recognizer was never
## spawned.
##
## The cases below assert the returned value directly.  They therefore keep
## holding if `Lang` is ever reordered — which is the point, because a proc
## that is correct only because of which constant happens to be ordinal 0 is
## not correct.
##
## ## 2. The hand-written JS ordinal map is the same list as the `Lang` enum
##
## `src/frontend/trace_metadata.nim` carries a **complete second copy** of every
## `Lang` ordinal, written out by hand inside a JS string literal in an
## `importjs` block (`var LANG = { LangC:0, ... }`).  It exists because
## `ct trace-metadata` serialises the enum with `json_serialization`, which
## writes enum *names*, while the renderer reconstructs the record with
## `cast[Trace](JSON.parse(...))`, a reinterpret that needs the integer ordinal
## Nim's JS backend uses at runtime.
##
## No compiler checks that copy.  Its lookup miss falls back to
## `LANG.LangUnknown`, so a language added to `Lang` but forgotten here does not
## error anywhere — every trace recorded in that language silently loads as
## "unknown".  A *stale* entry is worse: it silently mislabels loaded traces
## with a real, wrong language.
##
## The test below parses the JS block out of the source file and compares it to
## `Lang` itself: every enum value present, every ordinal equal, and no extra
## keys.  Adding a language without updating the JS map now fails here, at the
## table, instead of in a renderer that shows the wrong syntax highlighting.
##
## ## 3. The Nim `Lang` enum is the same list as the canonical Rust `Lang`
##
## Until LRS-1, `ct/load-locals` sent `CtLoadLocalsArguments.lang` as an
## **integer**: the Nim side wrote `ord(Lang)` and the Rust side read it with
## `serde_repr` into the `Lang` declared in `libs/ct-lang/src/lib.rs`.  That
## hop now carries the language's NAME (properties 7-9 below).  What still
## carries the ordinal is the tracepoint pair — `Tracepoint.lang` on
## `ct/run-tracepoints` (Nim → Rust) and `Stop.lang` on
## `ct/tracepoint-results` (Rust → Nim) — so the two enums are still
## hand-maintained copies whose declaration order is a wire contract, and a
## variant inserted in the middle of either one silently re-points every
## ordinal above it.  This property is what makes the pending renumber (LRS-4)
## a lockstep change rather than a wire break.
##
## The Rust definition used to live in `src/db-backend/src/lang.rs`; that file
## now re-exports it (`pub use ct_lang::{lang_wire, Lang}`) so that
## `src/tui` and `libs/ct-dap-client` can share the one definition without
## taking on db-backend's `build.rs` — see property 4.
##
## (The doc comment on the Nim enum used to name
## `codetracer-native-backend/src/lang.rs` as its partner.  That was wrong:
## that enum has a `Small` variant at ordinal 21 and diverges from there.  The
## worker socket between the two Rust crates now carries language names, so no
## ordinal crosses a repository boundary any more.)
##
## **Correction (trace_index schema version 1).**  This paragraph used to end
## "…this hop is the last one that carries an ordinal at all outside the
## persisted `trace_index.db.lang` column".  That parenthetical is no longer
## true and the column is no longer an exception: `recordings.lang` is `TEXT`
## and stores the enum *name*, migrated in one shot under a
## `PRAGMA user_version` gate (see the "Schema versioning" section of
## `src/common/trace_index.nim` and `trace_index_migration_test.nim`).
##
## **Correction (LRS-1).**  The sentence that followed said the `ct/load-locals`
## hop "is now the **only** place an ordinal survives".  It was not the only
## one — `Tracepoint.lang` and `Stop.lang` carry it on the tracepoint hop and
## always did — and it no longer carries one at all: see properties 7-9.
##
## The test below parses the `pub enum Lang { … }` block out of the Rust source
## and compares it to `Lang`, name by name and ordinal by ordinal.
##
## ## 4. There is exactly ONE ordinal-carrying `Lang` in the Rust tree
##
## Property 3 only pins the copy it is pointed at.  The reason this file exists
## at all is that there used to be *three* Rust copies, and the ones nobody was
## checking were the ones that had rotted:
##
## * `src/tui/src/lang.rs` had **37** variants.  It stopped at `Solana` and was
##   missing `Elixir`, `Erlang` and `Php` — while decoding the shared
##   `trace_index.db` `lang` column and sending the ordinal to the backend in
##   `ConfigureArg`.  The live database on a developer machine already holds
##   rows at `lang = 37` (`LangElixir`), past that copy's last ordinal of 36 —
##   an ordinal it decoded as `None`, which the TUI's
##   `.expect("expected valid lang")` would have turned into a panic.  (No
##   count is quoted here on purpose: that database is written by ordinary
##   development and the number moves.  Three successive readings during this
##   work gave 24, 25 and 26.  The claim that matters is that the population is
##   non-empty, not its size.)
##
##   **Correction.**  This bullet used to say the TUI *wrote* that ordinal into
##   `trace_index.db`.  It did not, and could not: `register_trace_in_db`
##   (`src/tui/src/main.rs`) targets the pre-M-REC-2 `traces` / `trace_values`
##   tables with camelCase columns, which `src/common/trace_index_test_helper.nim`
##   asserts must *not* exist on a current database; its first `prepare(…)?`
##   therefore fails, and its only call site is commented out
##   (`src/tui/src/main.rs:363`).  The sibling read path
##   `load_trace_from_program` panics on the same missing table before it ever
##   reaches the `lang` column.  The *read* hazard described above was real; the
##   *write* was not.  The Nim core is, and was, the column's only writer —
##   which is what made the schema-version-1 migration a single-writer problem.
## * `libs/ct-dap-client/src/types/common.rs` had **21**, diverging from ordinal
##   6 (`Fortran` canonically, `Python` there), and its tracepoint requests
##   carry that ordinal over DAP to db-backend.
##
## Both are gone: they now consume `libs/ct-lang`.  The sweep below walks every
## `.rs` file in the repository and fails if an `enum Lang` appears anywhere
## outside a small, documented allowlist — so re-introducing a private copy is a
## test failure rather than a silent divergence that surfaces years later as a
## mislabelled trace.  The allowlist's non-canonical entries are additionally
## checked to carry no `#[repr(...)]` and no `serde_repr` derive, which are what
## turn an enum's ordinal into a wire value in the first place.  That attribute
## check anchors its look-back on the previous top-level item rather than on a
## fixed character count, because an attribute padded far enough above its
## declaration by doc comments would otherwise escape the window and be read as
## absent — see `sweepRustLangDecls`.
##
## ## 5. The former copy sites consume the canonical definition
##
## The complement of property 4: the three sites are checked positively, so
## "the duplicate is gone" cannot be satisfied by deleting the consumer.
##
## ## 6. The four axes are the same lists in Nim and in Rust, name for name
##
## LRS-2B added `SourceLanguage`, `TargetIsa`, `Toolchain` and
## `RecordingApproach` to `libs/ct-lang` beside `Lang`, mirroring
## `src/common/target_axes.nim`.  Unlike `Lang` they carry NO ordinal: every
## value crosses every boundary as its `wire_name`, which is the Nim
## `token(v)`.  So the pin is by NAME and by TOKEN — each Rust variant must be
## the Nim member with its two-letter prefix stripped, in the same position,
## with the same token — and the sweep additionally asserts that the axis
## enums never acquire `#[repr(...)]` or a `serde_repr` derive, which is what
## would turn their position into a wire value and reintroduce the `Lang`
## defect one axis over.  The Rust side is parsed out of the `axis_enum!`
## invocations, strictly: a block that cannot be found fails the run.
##
## ## 7. `langWireName` is `Lang::wire_name`, member for member
##
## LRS-1 took the ordinal off `ct/load-locals`: the Nim sender writes
## `langWireName(lang)` (`src/common/common_lang.nim`) and the Rust receiver
## decodes it with `ct-lang`'s `lang_wire` adapter, which parses
## `Lang::wire_name` spellings and refuses anything else — including a bare
## integer.  So the two spelling tables are now the wire contract, and this
## property pins them against each other: same members, and for every member
## the same string.  The Rust side is parsed out of the `wire_name` `match`,
## strictly.  A spelling that differs is not a wrong language, it is a refused
## request — which is the point, but only if the two tables agree.
##
## ## 8. The `ct/load-locals` receiver decodes a name, not an ordinal
##
## `CtLoadLocalsArguments.lang` in `src/db-backend/src/task.rs` must carry
## `#[serde(with = "crate::lang::lang_wire")]`.  Without it the field falls
## back to `Lang`'s `serde_repr` derive and silently accepts `32` as Leo
## again.  The Rust unit tests in `task.rs` assert the behaviour; this asserts
## the attribute, so that a refactor which drops it fails here even when the
## Rust tests are not run.
##
## ## 9. No payload spells `lang` as a bare integer
##
## The class of defect that hid in `src/codetracer-bench/src/gui_ops.rs`
## (`Language::Cairo => 32`, where Cairo is 30) and in
## `src/db-backend/tests/leo_search_calltrace_test.rs` (`"lang": 33` for a
## Leo fixture, where Leo is 32) was invisible to properties 3 and 4: those
## look at enum DECLARATIONS, and a hand-written integer in a `json!` body or
## a `%*{}` builder is neither.  This sweep walks every `.rs` and `.nim` file
## and reads every `"lang":` key in a payload position, classifying its value
## as an ORDINAL (an integer literal, an `as u8` cast, an `ord(...)`), a NAME
## (a string literal, `.wire_name()`, `langWireName(...)`, or one of the two
## pinned literal constants `LoadLocalsDefaultLang` / `LOAD_LOCALS_DEFAULT_LANG`)
## or OPAQUE (an identifier the sweep cannot type).
## It then requires: no ordinal outside a frozen, positively-checked list of
## the tracepoint-hop remnants; every opaque site on a list a human has
## classified; the fixed sites' REPLACEMENTS present as names; and the
## classifier itself proven on a positive-control fixture of the exact shapes
## that were wrong — so an empty or mis-parsed scan cannot pass.
##
## Mocking justification (workspace policy on mock objects): none.  There is no
## mock in this file.  Property 1 calls the production proc; properties 2–9
## read the production source files.
##
## Compile and run:
##   nim c -r src/tests/cli/lang_enum_contract_test.nim

import std/[algorithm, os, sets, strutils, tables, unittest]
import ../../common/lang
import ../../common/target_axes
import ../../ct/utilities/language_detection

const
  ThisFile = currentSourcePath()
  RepoRoot = ThisFile.parentDir.parentDir.parentDir.parentDir
    ## src/tests/cli/<this> -> src/tests/cli -> src/tests -> src -> <repo>
  TraceMetadataPath = RepoRoot / "src" / "frontend" / "trace_metadata.nim"
  CtLangPath = RepoRoot / "libs" / "ct-lang" / "src" / "lib.rs"
    ## The single canonical Rust `Lang`.
  CtLangManifestPath = RepoRoot / "libs" / "ct-lang" / "Cargo.toml"
  DbBackendLangPath = RepoRoot / "src" / "db-backend" / "src" / "lang.rs"
    ## Re-exports `CtLangPath`'s `Lang`; keeps `lang_from_context`.
  CtDapClientLangPath =
    RepoRoot / "libs" / "ct-dap-client" / "src" / "types" / "common.rs"
  TuiLangPath = RepoRoot / "src" / "tui" / "src" / "lang.rs"
    ## Deleted.  Must stay deleted.
  DbBackendTaskPath = RepoRoot / "src" / "db-backend" / "src" / "task.rs"
    ## Declares the DAP-facing `CtLoadLocalsArguments` (property 8).

# ---------------------------------------------------------------------------
# Property 1 — detectLangFromPath returns LangUnknown for what it does not know
# ---------------------------------------------------------------------------

const
  # The seven names measured against the pre-fix build.  Every one of them
  # reported `LangC`.
  MeasuredUnknownPaths = [
    "a.out",
    "my.project",
    "python3.11",
    "libfoo.so.1",
    "data.json",
    "notes.txt",
    "archive.tar.gz",
  ]

suite "detectLangFromPath: an unknown extension is LangUnknown, never the zero value":

  test "the seven measured paths that used to resolve to LangC":
    for path in MeasuredUnknownPaths:
      let lang = detectLangFromPath(path, isWasm = false)
      check:
        lang == LangUnknown
      if lang != LangUnknown:
        checkpoint(
          "detectLangFromPath(\"" & path & "\") returned " & $lang &
          " but the extension is not in LANGS, so the only correct answer is " &
          "LangUnknown.  Before the fix this returned LangC because the proc " &
          "fell off its end onto Nim's zero-initialised `result`.")

  test "a dot-less name is LangUnknown (the one case that always worked)":
    check detectLangFromPath("a_out", isWasm = false) == LangUnknown
    check detectLangFromPath("program", isWasm = false) == LangUnknown
    check detectLangFromPath("", isWasm = false) == LangUnknown

  test "the answer does not depend on which Lang is ordinal 0":
    # The regression this file exists for was invisible precisely because the
    # wrong answer was a *plausible* language.  Pin the mechanism: whatever
    # `Lang(0)` happens to be, an unknown extension must not return it merely
    # by falling through.
    let zeroValue = Lang(0)
    for path in MeasuredUnknownPaths:
      let lang = detectLangFromPath(path, isWasm = false)
      check:
        lang == LangUnknown
      if zeroValue != LangUnknown and lang == zeroValue:
        checkpoint(
          "detectLangFromPath(\"" & path & "\") returned the enum's zero " &
          "value " & $zeroValue & ".  That is the signature of a missing " &
          "final `return LangUnknown`, not of a real detection.")

  test "every extension NOT in LANGS resolves to LangUnknown":
    # A generated sweep rather than a hand list, so an extension that is added
    # to `LANGS` later is covered automatically and one that is *removed* stops
    # being asserted as known.
    const Candidates = [
      "out", "project", "11", "1", "json", "txt", "gz", "tar", "so", "dll",
      "exe", "bin", "o", "a", "log", "md", "yml", "yaml", "toml", "lock",
      "png", "csv", "xml", "html", "css", "class", "jar", "pyc", "swp",
      "bak", "tmp", "conf", "ini", "cfg", "dat", "db", "sqlite", "zip",
    ]
    for extension in Candidates:
      if LANGS.hasKey(extension):
        continue
      let path = "program." & extension
      let lang = detectLangFromPath(path, isWasm = false)
      check:
        lang == LangUnknown
      if lang != LangUnknown:
        checkpoint(
          "extension `." & extension & "` is not a key of LANGS, yet " &
          "detectLangFromPath(\"" & path & "\") returned " & $lang & ".")

  test "the extensions that ARE in LANGS still resolve to their language":
    # The fix must not turn a working detection into LangUnknown.  This is the
    # other half of the property and it is what makes the sweep above safe.
    for extension, expected in LANGS.pairs:
      let path = "program." & extension
      let lang = detectLangFromPath(path, isWasm = false)
      check:
        lang == expected
      if lang != expected:
        checkpoint(
          "LANGS maps `." & extension & "` to " & $expected &
          " but detectLangFromPath returned " & $lang & ".")

  test "an uppercase known extension still resolves (the lowercasing path)":
    check detectLangFromPath("Program.PY", isWasm = false) == LangPythonDb
    check detectLangFromPath("Program.RB", isWasm = false) == LangRubyDb

  test "isWasm routes the wasm extensions and leaves the rest alone":
    check detectLangFromPath("program.rs", isWasm = true) == LangRustWasm
    check detectLangFromPath("program.cpp", isWasm = true) == LangCppWasm
    # An extension nothing knows is still LangUnknown in wasm mode.
    check detectLangFromPath("a.out", isWasm = true) == LangUnknown

# ---------------------------------------------------------------------------
# Property 2 — the JS ordinal map in trace_metadata.nim matches `Lang`
# ---------------------------------------------------------------------------

proc parseJsLangMap(source: string): Table[string, int] =
  ## Extract `var LANG = { LangC:0, ... };` from `trace_metadata.nim`'s
  ## `importjs` string literal.
  ##
  ## Deliberately strict: if the block cannot be located, this raises rather
  ## than returning an empty table.  An anti-drift check that silently finds
  ## nothing to compare is the exact failure mode it exists to prevent.
  result = initTable[string, int]()
  let startMarker = "var LANG = {"
  let startIdx = source.find(startMarker)
  if startIdx < 0:
    raise newException(ValueError,
      "could not find `" & startMarker & "` in " & TraceMetadataPath &
      ".  The JS ordinal map moved or was renamed; this check must be " &
      "updated to follow it, not deleted — it is the only thing standing " &
      "between a forgotten enum entry and silently mislabelled traces.")

  let bodyStart = startIdx + startMarker.len
  let endIdx = source.find("}", bodyStart)
  if endIdx < 0:
    raise newException(ValueError,
      "found `" & startMarker & "` in " & TraceMetadataPath &
      " but no closing `}` after it.")

  let body = source[bodyStart ..< endIdx]
  for rawEntry in body.split(','):
    let entry = rawEntry.strip()
    if entry.len == 0:
      continue
    let colon = entry.find(':')
    if colon < 0:
      raise newException(ValueError,
        "unparsable entry in the JS LANG map: `" & entry & "`")
    let name = entry[0 ..< colon].strip()
    let ordinalText = entry[colon + 1 .. ^1].strip()
    var ordinal: int
    try:
      ordinal = ordinalText.parseInt()
    except ValueError:
      raise newException(ValueError,
        "entry `" & name & "` in the JS LANG map has a non-integer ordinal `" &
        ordinalText & "`")
    if result.hasKey(name):
      raise newException(ValueError,
        "entry `" & name & "` appears twice in the JS LANG map")
    result[name] = ordinal

suite "trace_metadata.nim's JS LANG map is the Lang enum, entry for entry":

  setup:
    check fileExists(TraceMetadataPath)

  test "the map parses and is not empty":
    let jsMap = parseJsLangMap(readFile(TraceMetadataPath))
    check jsMap.len > 0
    checkpoint("parsed " & $jsMap.len & " entries from the JS LANG map")

  test "every Lang value is present in the JS map with the same ordinal":
    let jsMap = parseJsLangMap(readFile(TraceMetadataPath))
    for value in Lang:
      let name = $value
      check:
        jsMap.hasKey(name)
      if not jsMap.hasKey(name):
        checkpoint(
          "`" & name & "` (ordinal " & $ord(value) & ") is missing from the " &
          "JS LANG map in " & TraceMetadataPath & ".  The map's lookup miss " &
          "falls back to LANG.LangUnknown, so this does not error at " &
          "runtime: every trace recorded in " & name & " would silently load " &
          "as unknown.")
        continue
      check:
        jsMap[name] == ord(value)
      if jsMap[name] != ord(value):
        checkpoint(
          "`" & name & "` is ordinal " & $ord(value) & " in the Lang enum " &
          "but " & $jsMap[name] & " in the JS LANG map in " &
          TraceMetadataPath & ".  A stale ordinal here does not error " &
          "anywhere; it silently relabels every loaded trace.")

  test "the JS map has no entries that are not Lang values":
    let jsMap = parseJsLangMap(readFile(TraceMetadataPath))
    var enumNames = initHashSet[string]()
    for value in Lang:
      enumNames.incl($value)
    var extras: seq[string] = @[]
    for name in jsMap.keys:
      if name notin enumNames:
        extras.add(name)
    extras.sort()
    check:
      extras.len == 0
    if extras.len > 0:
      checkpoint(
        "the JS LANG map in " & TraceMetadataPath & " declares " &
        $extras.len & " name(s) that are not values of the Lang enum: " &
        extras.join(", ") & ".  These are dead at best and, if a Lang value " &
        "was renamed, a silent mislabel at worst.")

  test "the two lists are the same length":
    let jsMap = parseJsLangMap(readFile(TraceMetadataPath))
    var enumCount = 0
    for _ in Lang:
      inc enumCount
    check:
      jsMap.len == enumCount
    if jsMap.len != enumCount:
      checkpoint(
        "the Lang enum has " & $enumCount & " values but the JS LANG map in " &
        TraceMetadataPath & " has " & $jsMap.len & " entries.")

  test "the JS map's ordinals are exactly 0 .. n-1 with no gaps or repeats":
    # `cast[Trace](JSON.parse(...))` reinterprets the integer as a Lang, so a
    # gap or an out-of-range value is an out-of-range enum in the renderer.
    let jsMap = parseJsLangMap(readFile(TraceMetadataPath))
    var seen = initHashSet[int]()
    for name, ordinal in jsMap.pairs:
      check:
        ordinal >= 0 and ordinal < jsMap.len
      if ordinal < 0 or ordinal >= jsMap.len:
        checkpoint(
          "`" & name & "` has ordinal " & $ordinal & ", outside 0 .. " &
          $(jsMap.len - 1) & " for a " & $jsMap.len & "-entry map.")
      check:
        ordinal notin seen
      if ordinal in seen:
        checkpoint("ordinal " & $ordinal & " is used twice; `" & name &
          "` collides with an earlier entry.")
      seen.incl(ordinal)

# ---------------------------------------------------------------------------
# Property 3 — the Nim Lang enum matches the canonical Rust Lang enum
# ---------------------------------------------------------------------------

proc parseRustLangEnum(source: string, path: string): seq[string] =
  ## Extract the variant names of `pub enum Lang { ... }` from
  ## `libs/ct-lang/src/lib.rs`, in declaration order.
  ##
  ## Deliberately strict for the same reason as `parseJsLangMap`: an
  ## anti-drift check that quietly finds nothing to compare is worse than no
  ## check at all, because it reports a pass.
  result = @[]
  let startMarker = "pub enum Lang {"
  let startIdx = source.find(startMarker)
  if startIdx < 0:
    raise newException(ValueError,
      "could not find `" & startMarker & "` in " & path &
      ".  The enum moved or was renamed; this check must be updated to " &
      "follow it, not deleted — the tracepoint hop (`Tracepoint.lang`, " &
      "`Stop.lang`) still carries `lang` as an ordinal between the two " &
      "enums, and the pending renumber (LRS-4) is safe only if the two " &
      "lists move in lockstep.")

  let bodyStart = startIdx + startMarker.len
  let endIdx = source.find("\n}", bodyStart)
  if endIdx < 0:
    raise newException(ValueError,
      "found `" & startMarker & "` in " & path &
      " but no closing brace after it.")

  for rawLine in source[bodyStart ..< endIdx].splitLines():
    var line = rawLine.strip()
    # Drop doc comments, line comments and attributes such as `#[default]`.
    let commentIdx = line.find("//")
    if commentIdx >= 0:
      line = line[0 ..< commentIdx].strip()
    if line.len == 0 or line.startsWith("#["):
      continue
    # `C = 0,` -> `C`;  `Cpp,` -> `Cpp`
    var name = line
    let eqIdx = name.find('=')
    if eqIdx >= 0:
      name = name[0 ..< eqIdx]
    name = name.strip(chars = {' ', '\t', ','})
    if name.len == 0:
      continue
    result.add(name)

func nimNameFor(rustVariant: string): string =
  ## The Nim spelling of a Rust variant name.  Compared case-insensitively
  ## because the two files disagree on the capitalisation of exactly one
  ## variant (`PolkaVM` / `LangPolkavm`), which is a naming convention
  ## difference and not an ordinal difference.
  "Lang" & rustVariant

suite "the Nim Lang enum is the canonical Rust Lang enum, ordinal for ordinal":

  setup:
    check fileExists(CtLangPath)

  test "the Rust enum parses and is not empty":
    let variants = parseRustLangEnum(readFile(CtLangPath), CtLangPath)
    check variants.len > 0
    checkpoint("parsed " & $variants.len & " variants from " & CtLangPath)

  test "both enums have the same number of values":
    let variants = parseRustLangEnum(readFile(CtLangPath), CtLangPath)
    var nimCount = 0
    for _ in Lang:
      inc nimCount
    check:
      variants.len == nimCount
    if variants.len != nimCount:
      checkpoint(
        "the Nim Lang enum has " & $nimCount & " values but the Rust Lang " &
        "enum in " & CtLangPath & " has " & $variants.len & ".  " &
        "`Tracepoint.lang` and `Stop.lang` still cross that boundary as " &
        "integers, so a length difference means some ordinals decode as a " &
        "different language or as an out-of-range value.")

  test "every ordinal names the same language on both sides":
    let variants = parseRustLangEnum(readFile(CtLangPath), CtLangPath)
    var index = 0
    for value in Lang:
      if index >= variants.len:
        break
      let nimName = $value
      let expected = nimNameFor(variants[index])
      check:
        nimName.toLowerAscii == expected.toLowerAscii
      if nimName.toLowerAscii != expected.toLowerAscii:
        checkpoint(
          "ordinal " & $index & " is `" & nimName & "` in the Nim Lang enum " &
          "but `" & variants[index] & "` in " & CtLangPath & ".  " &
          "Every tracepoint carrying a language at or above this ordinal " &
          "would be decoded as the wrong language by the backend, and the " &
          "pending renumber would no longer be a lockstep change.")
      inc index

  test "the divergence from codetracer-native-backend is not re-introduced here":
    # The Nim enum's doc comment used to name the *native backend's* Lang as
    # its partner.  Pin the two facts that made that wrong, so the comment
    # cannot drift back: `LangPythonDb` is 21 here (it is 22 there, because
    # that enum has a `Small` at 21), and `LangUnknown` is 22 here (26 there).
    check ord(LangPythonDb) == 21
    check ord(LangUnknown) == 22
    check ord(LangC) == 0

# ---------------------------------------------------------------------------
# Property 4 — exactly one ordinal-carrying `Lang` exists in the Rust tree
# ---------------------------------------------------------------------------

type RustLangDecl = object
  ## One `enum Lang` found by the repository sweep.
  relPath: string   ## repo-relative, `/`-separated
  isRepr: bool      ## carries a `#[repr(...)]` attribute
  isSerdeRepr: bool ## carries a `Serialize_repr` / `Deserialize_repr` derive

const
  CanonicalRustLang = "libs/ct-lang/src/lib.rs"
    ## The one file allowed to declare the ordinal-carrying `Lang`.

  # Files that declare an enum which merely *shares the name* `Lang`.  Each is
  # a local selector whose integer value never leaves its crate; neither is a
  # copy of the ordinal enum, and the assertions below pin that distinction
  # rather than trusting the comment.
  #
  # If you are here because a new entry is needed: adding one is a decision to
  # maintain another type called `Lang`.  Prefer reusing `ct_lang::Lang`.
  NameOnlyLangDecls = [
    # 13 variants; selects a tree-sitter grammar for the Value-Origin-Tracking
    # classifier.  No `repr`, no serde; the ordinal is never serialised.
    "libs/origin-classifier/src/kinds.rs",
    # 2 variants (JavaScript, Python); private to the module and selects which
    # source formatter to shell out to.  No `repr`, no serde.
    "src/db-backend/src/autoformat.rs",
  ]

  # Directory names that are never part of this repository's own Rust sources.
  SweepSkipDirs = ["target", "node_modules", ".git", ".direnv", "dist"]

  # A floor on the sweep's reach.  The tree held 448 `.rs` files when this was
  # written; if a future refactor breaks the walk, the sweep must fail loudly
  # instead of "finding no duplicates" across zero files.
  MinRustFilesSwept = 300

proc sweepCargoManifests(root: string): seq[string] =
  ## Every `Cargo.toml` under `root` (repo-relative, `/`-separated), pruning
  ## `SweepSkipDirs` before descending for the reason `sweepRustLangDecls`
  ## gives.  Used by property 5 to make its dependent list exact against the
  ## tree rather than a list that is only checked where it points.
  result = @[]
  var pending = @[""]
  while pending.len > 0:
    let relDir = pending.pop()
    let absDir = if relDir.len == 0: root else: root / relDir
    for kind, entry in walkDir(absDir, relative = true, checkDir = true):
      let rel = if relDir.len == 0: entry else: relDir & "/" & entry
      case kind
      of pcDir:
        if entry notin SweepSkipDirs:
          pending.add(rel)
      of pcFile:
        if entry == "Cargo.toml":
          result.add(rel.replace('\\', '/'))
      else:
        discard
  if result.len < 4:
    raise newException(ValueError,
      "the manifest sweep found only " & $result.len & " `Cargo.toml` " &
      "files under " & root & "; the tree holds more than that, so the " &
      "walk is broken -- fix it, do not lower the floor.")

proc sweepRustLangDecls(root: string): seq[RustLangDecl] =
  ## Walk every `.rs` file under `root` and report each `enum Lang`
  ## declaration, with the two attributes that would make its ordinal a wire
  ## value.
  ##
  ## The walk prunes `SweepSkipDirs` *before* descending rather than filtering
  ## the paths afterwards.  `src/db-backend/target` alone is several gigabytes
  ## of build artefacts; walking into it and discarding the results would turn
  ## a sub-second check into a multi-minute one, and a slow test is a test that
  ## gets removed from the lane.
  result = @[]
  var swept = 0
  var pending = @[""] # repo-relative directories, "" is the root itself
  while pending.len > 0:
    let relDir = pending.pop()
    let absDir = if relDir.len == 0: root else: root / relDir
    for kind, entry in walkDir(absDir, relative = true, checkDir = true):
      let rel = if relDir.len == 0: entry else: relDir & "/" & entry
      case kind
      of pcDir:
        if entry notin SweepSkipDirs:
          pending.add(rel)
      of pcFile:
        if not entry.endsWith(".rs"):
          continue
        inc swept
        let source = readFile(root / rel)
        # `enum Lang` with a word boundary after it: matches
        # `pub enum Lang {`, `enum Lang {` and `pub(crate) enum Lang {`, but
        # not `enum Language`.
        var searchFrom = 0
        while true:
          let idx = source.find("enum Lang", searchFrom)
          if idx < 0:
            break
          searchFrom = idx + "enum Lang".len
          let after = if searchFrom < source.len: source[searchFrom] else: ' '
          if after in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
            continue # `enum Language`, `enum LangKind`, ...
          # Look back over the attribute block that precedes the declaration:
          # everything between the end of the previous top-level item (a `}` in
          # column 0) and this declaration.  That span is exactly the
          # attribute-and-doc-comment block belonging to this enum.
          #
          # This used to be a fixed 600-character window, which was not enough.
          # Rust lets an attribute sit any distance above its item, separated by
          # doc comments, and a mutation that padded `#[repr(u8)]` 812
          # characters above `pub enum Lang` with ten `///` lines slipped past
          # the window entirely: the sweep reported `isRepr = false` for an enum
          # that genuinely carried an ordinal, and the whole suite stayed green.
          # Anchoring on the previous item instead has no length limit, so the
          # attribute cannot be pushed out of range.
          let prevItemEnd = if idx == 0: -1 else: source.rfind("\n}", 0, idx - 1)
          let windowStart = if prevItemEnd < 0: 0 else: prevItemEnd
          let preamble = source[windowStart ..< idx]
          result.add(RustLangDecl(
            relPath: rel.replace('\\', '/'),
            isRepr: preamble.contains("#[repr("),
            isSerdeRepr: preamble.contains("Serialize_repr") or
                         preamble.contains("Deserialize_repr")))
      else:
        # Symlinks and special files: a symlinked directory could re-enter the
        # tree and loop, and a symlinked `.rs` is always reachable by its real
        # path too, so neither needs following.
        discard
  if swept < MinRustFilesSwept:
    raise newException(ValueError,
      "the `.rs` sweep visited only " & $swept & " files under " & root &
      ", below the floor of " & $MinRustFilesSwept & ".  The walk is broken " &
      "or the tree moved; a sweep that inspects nothing reports `no " &
      "duplicates` for the wrong reason.  Fix the walk — do not lower the " &
      "floor to make this pass.")

suite "libs/ct-lang holds the only ordinal-carrying Rust `Lang`":

  setup:
    check fileExists(CtLangPath)
    check fileExists(CtLangManifestPath)

  test "the sweep finds the canonical declaration":
    let decls = sweepRustLangDecls(RepoRoot)
    var canonical: seq[RustLangDecl] = @[]
    for decl in decls:
      if decl.relPath == CanonicalRustLang:
        canonical.add(decl)
    check:
      canonical.len == 1
    if canonical.len != 1:
      checkpoint(
        "expected exactly one `enum Lang` in " & CanonicalRustLang &
        " but the sweep found " & $canonical.len & ".  Every other property " &
        "in this file compares against that declaration.")
    else:
      check:
        canonical[0].isRepr
        canonical[0].isSerdeRepr
      if not canonical[0].isRepr or not canonical[0].isSerdeRepr:
        checkpoint(
          CanonicalRustLang & "'s `Lang` lost its `#[repr(...)]` or its " &
          "`serde_repr` derive.  Both are still load-bearing: " &
          "`Tracepoint.lang` and `Stop.lang` go through that derive on the " &
          "tracepoint hop.  (`ct/load-locals` and the persisted " &
          "`recordings.lang` column no longer do; when the tracepoint pair " &
          "moves to names as well, this assertion is the one to revisit.)")

  test "no `enum Lang` exists outside the canonical file and the allowlist":
    let decls = sweepRustLangDecls(RepoRoot)
    var allowed = initHashSet[string]()
    allowed.incl(CanonicalRustLang)
    for path in NameOnlyLangDecls:
      allowed.incl(path)

    var unexpected: seq[string] = @[]
    for decl in decls:
      if decl.relPath notin allowed:
        unexpected.add(decl.relPath)
    unexpected.sort()
    check:
      unexpected.len == 0
    if unexpected.len > 0:
      checkpoint(
        "found " & $unexpected.len & " unapproved `enum Lang` " &
        "declaration(s): " & unexpected.join(", ") & ".\n" &
        "  This repository used to carry three hand-written Rust copies of " &
        "the language enum.  Two of them had silently fallen behind: " &
        "`src/tui/src/lang.rs` was missing Elixir/Erlang/Php while still " &
        "decoding the ordinal from the shared trace_index.db, and " &
        "`libs/ct-dap-client` diverged from ordinal 6 while sending the " &
        "ordinal over DAP.  Depend on `ct-lang` instead.  If the new enum " &
        "genuinely is not the language ordinal, add it to " &
        "`NameOnlyLangDecls` above with a comment saying why.")

  test "every allowlisted `enum Lang` is actually present":
    # The allowlist must not rot into a list of files that no longer exist:
    # a stale entry would silently widen what the previous test permits.
    let decls = sweepRustLangDecls(RepoRoot)
    var found = initHashSet[string]()
    for decl in decls:
      found.incl(decl.relPath)
    for path in NameOnlyLangDecls:
      check:
        path in found
      if path notin found:
        checkpoint(
          "`" & path & "` is on `NameOnlyLangDecls` but no longer declares " &
          "an `enum Lang`.  Remove the entry; leaving it in place widens " &
          "the allowlist for a file that could later gain a real copy.")

  test "the name-only `Lang` enums carry no ordinal contract":
    # What separates them from the canonical enum is not their names, it is
    # that their integer value never crosses a boundary.  Pin that: if one of
    # them ever gains `#[repr(u8)]` or a `serde_repr` derive it becomes a
    # second wire enum, and it must come back here for a decision.
    let decls = sweepRustLangDecls(RepoRoot)
    for decl in decls:
      if decl.relPath == CanonicalRustLang:
        continue
      check:
        not decl.isRepr
        not decl.isSerdeRepr
      if decl.isRepr or decl.isSerdeRepr:
        checkpoint(
          "`" & decl.relPath & "` declares an `enum Lang` with " &
          (if decl.isRepr: "`#[repr(...)]` " else: "") &
          (if decl.isSerdeRepr: "a `serde_repr` derive " else: "") &
          "— that makes its ordinal a serialised value, which is exactly " &
          "what `ct-lang` exists to keep in one place.")

  test "ct-lang is a leaf crate, so every consumer can afford to depend on it":
    # The whole reason the enum is not simply db-backend's is that db-backend
    # has a build.rs which compiles the Nim MCR emulator, plus path
    # dependencies that reach into sibling repositories: making `src/tui`
    # depend on it grew the resolved dependency graph from 161 packages to
    # 385 and required `codetracer-native-recorder` to be present and built.
    # If ct-lang ever grows a build script or a path dependency, that
    # rationale silently collapses and the TUI stops being buildable on its
    # own.
    let manifest = readFile(CtLangManifestPath)
    let hasBuildScript = fileExists(RepoRoot / "libs" / "ct-lang" / "build.rs")
    check:
      not manifest.contains("[build-dependencies]")
      not manifest.contains("path =")
      not hasBuildScript
    if manifest.contains("[build-dependencies]") or
       manifest.contains("path =") or hasBuildScript:
      checkpoint(
        CtLangManifestPath & " gained a build script or a path dependency.  " &
        "`ct-lang` is depended on by `src/tui` and `libs/ct-dap-client`, " &
        "both of which build standalone; keep it a leaf.")

# ---------------------------------------------------------------------------
# Property 5 — the former copy sites consume the canonical definition
# ---------------------------------------------------------------------------

proc declaresCargoDep(manifestPath, crateName: string): bool =
  ## True if `manifestPath` declares `crateName` as a dependency.  Matches the
  ## `name = { ... }` form these manifests use; deliberately does not try to be
  ## a TOML parser.
  for rawLine in readFile(manifestPath).splitLines():
    let line = rawLine.strip()
    if line.startsWith("#"):
      continue
    if line.startsWith(crateName & " ") or line.startsWith(crateName & "="):
      return true
  false

suite "the deleted Lang copies stay deleted and their sites use ct-lang":

  test "src/tui/src/lang.rs does not exist":
    check:
      not fileExists(TuiLangPath)
    if fileExists(TuiLangPath):
      checkpoint(
        TuiLangPath & " is back.  The TUI supports every language the GUI " &
        "supports by definition; it must not carry its own list.  The copy " &
        "that used to live here had 37 of the 40 variants and decoded the " &
        "ordinal out of the same trace_index.db the Nim core writes.")

  test "src/db-backend/src/lang.rs re-exports rather than redeclares":
    check fileExists(DbBackendLangPath)
    let source = readFile(DbBackendLangPath)
    check:
      source.contains("pub use ct_lang::")
      not source.contains("enum Lang")
    if not source.contains("pub use ct_lang::"):
      checkpoint(
        DbBackendLangPath & " no longer re-exports `ct_lang`.  Every " &
        "`use crate::lang::Lang` in db-backend resolves through that " &
        "re-export.")
    if source.contains("enum Lang"):
      checkpoint(
        DbBackendLangPath & " declares an `enum Lang` again.  The Rust " &
        "definition belongs in " & CanonicalRustLang & " so that src/tui " &
        "and libs/ct-dap-client can share it without db-backend's build.rs.")

  test "libs/ct-dap-client re-exports rather than redeclares":
    check fileExists(CtDapClientLangPath)
    let source = readFile(CtDapClientLangPath)
    check:
      source.contains("pub use ct_lang::Lang")
      not source.contains("enum Lang")
    if source.contains("enum Lang"):
      checkpoint(
        CtDapClientLangPath & " declares an `enum Lang` again.  Its 21-" &
        "variant copy diverged from ordinal 6 onwards while its tracepoint " &
        "requests carried that ordinal over DAP to db-backend.")

  test "every crate that speaks `lang` on a wire declares the ct-lang dependency":
    # The positive half of property 4: a consumer must not satisfy "no
    # duplicate enum" by quietly dropping the shared type instead.
    #
    # Four, not three, since LRS-1: `src/codetracer-bench` used to hand-write
    # the ordinals it sent on `ct/load-locals` — two of ten wrong — and now
    # names the variant of the shared enum, so it must depend on it; a crate
    # that drops the dependency is a crate that has gone back to spelling the
    # value by hand.
    #
    # `src/backend-manager` is deliberately NOT here although it also puts
    # `lang` on `ct/load-locals`.  Its nix derivation (`nix/packages/default.nix`,
    # `backend-manager`) takes the CRATE directory as its source, so a
    # `path = "../../libs/ct-lang"` dependency does not resolve in that
    # sandbox and `nix build .#codetracer` fails at manifest load.  It relays
    # the client's string unchanged and spells its one default as the literal
    # `LOAD_LOCALS_DEFAULT_LANG = "c"`, which property 7 pins against
    # `langWireName(LangC)` — a literal NAME that drifts is a refused request,
    # not a wrong language, which is the difference from the ordinal it replaced.
    let expected = [
      "src/tui/Cargo.toml",
      "src/db-backend/Cargo.toml",
      "libs/ct-dap-client/Cargo.toml",
      "src/codetracer-bench/Cargo.toml",
    ]
    for rel in expected:
      let manifest = RepoRoot / rel
      check fileExists(manifest)
      check:
        declaresCargoDep(manifest, "ct-lang")
      if not declaresCargoDep(manifest, "ct-lang"):
        checkpoint(
          manifest & " no longer declares a `ct-lang` dependency, so it is " &
          "no longer sharing the canonical Lang enum.")
    # The list above is EXACT, in both directions, against the tree: every
    # manifest that declares `ct-lang` must be on it, and every entry must be
    # a manifest that declares it.  Without this a dependent that quietly
    # dropped off the list would be "checked" by no longer being looked at --
    # the review's mutation (f) removed `codetracer-bench` from a version of
    # this list that had no such guard and the suite stayed green.
    var actual: seq[string] = @[]
    for manifest in sweepCargoManifests(RepoRoot):
      if declaresCargoDep(RepoRoot / manifest, "ct-lang"):
        actual.add(manifest)
    actual.sort()
    var expectedSorted = @expected
    expectedSorted.sort()
    if actual != expectedSorted:
      checkpoint(
        "the manifests under " & RepoRoot & " that declare `ct-lang` are\n  " &
        actual.join("\n  ") & "\nbut this test lists\n  " &
        expectedSorted.join("\n  ") & "\nA crate that started depending on " &
        "the shared enum must be listed here (and, if it is built by a " &
        "crate-only nix derivation like `backend-manager`, must not depend " &
        "on it at all -- see the next test); a crate that stopped must be " &
        "removed here in the same change, with the reason.")
    check actual == expectedSorted

  test "src/backend-manager stays free of path dependencies (its nix sandbox is the crate alone)":
    # The counterpart of the exclusion above.  The `backend-manager`
    # derivation in `nix/packages/default.nix` has `src = ../../src/backend-manager`
    # -- the crate, not the repository -- so ANY `path = ".."`-style
    # dependency fails `nix build .#backend-manager`, and with it
    # `.#codetracer` (the release build) at manifest load time.  LRS-1's first
    # draft added `ct-lang = { path = "../../libs/ct-lang" }` here and the
    # review caught it by copying the crate directory alone and running
    # `cargo metadata --locked --offline` in it, which is what the sandbox
    # amounts to; this check is the cheap form of that experiment.
    let manifest = RepoRoot / "src" / "backend-manager" / "Cargo.toml"
    check fileExists(manifest)
    var pathDeps: seq[string] = @[]
    for rawLine in readFile(manifest).splitLines():
      let line = rawLine.strip()
      if line.startsWith("#"):
        continue
      if line.contains("path") and line.contains("=") and
         (line.contains("\"../") or line.contains("\"/")):
        pathDeps.add(line)
    if pathDeps.len > 0:
      checkpoint(
        manifest & " declares path dependencies that leave the crate " &
        "directory:\n  " & pathDeps.join("\n  ") & "\n  The nix " &
        "derivation's source is the crate alone; see " &
        "`nix/packages/default.nix` (`backend-manager`, `src = ...`).  Spell " &
        "the value locally (as `LOAD_LOCALS_DEFAULT_LANG` does) or widen the " &
        "derivation's source in the same change.")
    check pathDeps.len == 0

# ---------------------------------------------------------------------------
# Property 6 — the four axes match between Nim and Rust, name for name
# ---------------------------------------------------------------------------

type RustAxisVariant = tuple[variant: string, token: string]

proc parseRustAxis(source: string, path: string, name: string):
    seq[RustAxisVariant] =
  ## Extract `Variant => "token",` rows from the `axis_enum!` invocation that
  ## declares `name` in `libs/ct-lang/src/lib.rs`, in declaration order.
  ##
  ## Deliberately strict, like the other parsers in this file: a block that
  ## cannot be located raises rather than returning an empty list, because an
  ## anti-drift check that silently compares nothing reports a pass.
  result = @[]
  let header = "\n    " & name & ", ALL, Unknown {"
  let startIdx = source.find(header)
  if startIdx < 0:
    raise newException(ValueError,
      "could not find the `axis_enum!` block for `" & name & "` in " & path &
      ".  The axis enum moved or was renamed; this check must be updated " &
      "to follow it, not deleted — it is what pins the Rust axis against " &
      "`src/common/target_axes.nim`.")
  let bodyStart = startIdx + header.len
  let endIdx = source.find("\n    }", bodyStart)
  if endIdx < 0:
    raise newException(ValueError,
      "found the `" & name & "` axis block in " & path &
      " but no closing brace after it.")
  for rawLine in source[bodyStart ..< endIdx].splitLines():
    var line = rawLine.strip()
    let commentIdx = line.find("//")
    if commentIdx >= 0:
      line = line[0 ..< commentIdx].strip()
    if line.len == 0:
      continue
    let arrow = line.find("=>")
    if arrow < 0:
      raise newException(ValueError,
        "unparsable row in the `" & name & "` axis block: `" & line & "`")
    let variant = line[0 ..< arrow].strip()
    var tok = line[arrow + 2 .. ^1].strip(chars = {' ', ','})
    if tok.len < 2 or tok[0] != '"' or tok[^1] != '"':
      raise newException(ValueError,
        "row `" & line & "` in the `" & name & "` axis block has no quoted token")
    tok = tok[1 ..< tok.high]
    result.add((variant, tok))

proc nimAxisRows[T: enum](): seq[RustAxisVariant] =
  ## The Nim side in the same shape: `slC` -> ("C", "c").  The two-letter
  ## prefix is the Nim naming convention (`sl`, `ti`, `tc`, `ra`); the Rust
  ## variant is what follows it, capitalisation included.
  result = @[]
  for v in T:
    let full = $v
    result.add((full[2 .. ^1], token(v)))

template checkAxis(nimRowsExpr, rustRowsExpr: seq[RustAxisVariant],
                   name: string) =
  ## A TEMPLATE, not a proc, on purpose: `check` inside a proc has no
  ## `testStatusIMPL` in scope, so `fail()` only sets `programResult = 1` and
  ## the enclosing test still prints `[OK]`.  Found by the LRS-2B mutation
  ## run (a reordered axis exited 1 with 32 OK and no `[FAILED]` line); a
  ## template expands into the test body, where the failure belongs.
  let nimRows = nimRowsExpr
  let rustRows = rustRowsExpr
  check:
    rustRows.len == nimRows.len
  if rustRows.len != nimRows.len:
    checkpoint(
      "the Nim `" & name & "` has " & $nimRows.len & " members but the Rust " &
      "one in " & CtLangPath & " has " & $rustRows.len & ".")
  for i in 0 ..< min(nimRows.len, rustRows.len):
    check:
      nimRows[i].variant == rustRows[i].variant
      nimRows[i].token == rustRows[i].token
    if nimRows[i].variant != rustRows[i].variant or
       nimRows[i].token != rustRows[i].token:
      checkpoint(
        "position " & $i & " of `" & name & "` is `" & nimRows[i].variant &
        "` => \"" & nimRows[i].token & "\" in Nim but `" & rustRows[i].variant &
        "` => \"" & rustRows[i].token & "\" in " & CtLangPath & ".")

suite "the four axes in libs/ct-lang are the Nim axes, name for name and token for token":

  setup:
    check fileExists(CtLangPath)

  test "each axis parses out of the Rust source and is not empty":
    let source = readFile(CtLangPath)
    for name in ["SourceLanguage", "TargetIsa", "Toolchain", "RecordingApproach"]:
      let rows = parseRustAxis(source, CtLangPath, name)
      check rows.len > 0
      checkpoint("parsed " & $rows.len & " variants of " & name)

  test "SourceLanguage: same members, same order, same tokens":
    checkAxis(nimAxisRows[SourceLanguage](),
              parseRustAxis(readFile(CtLangPath), CtLangPath, "SourceLanguage"),
              "SourceLanguage")

  test "TargetIsa: same members, same order, same tokens":
    checkAxis(nimAxisRows[TargetIsa](),
              parseRustAxis(readFile(CtLangPath), CtLangPath, "TargetIsa"),
              "TargetIsa")

  test "Toolchain: same members, same order, same tokens":
    checkAxis(nimAxisRows[Toolchain](),
              parseRustAxis(readFile(CtLangPath), CtLangPath, "Toolchain"),
              "Toolchain")

  test "RecordingApproach: same members, same order, same tokens":
    checkAxis(nimAxisRows[RecordingApproach](),
              parseRustAxis(readFile(CtLangPath), CtLangPath, "RecordingApproach"),
              "RecordingApproach")

  test "the axis enums carry no ordinal contract":
    # What keeps them from becoming a second `Lang`: no `#[repr(...)]`, no
    # `serde_repr` derive, anywhere in the macro that declares them.  The
    # position of a variant is then never a serialised value, so reordering an
    # axis is a name-level change the pin above catches, not a silent wire
    # break.
    #
    # The region scanned is the macro AND its four invocations, up to the
    # axis tests: the macro's `$(#[$meta])*` slot passes any attribute written
    # on an invocation straight onto the enum, so a `#[repr(u8)]` placed on
    # `RecordingApproach, ALL, Unknown {` compiles and is an ordinal contract
    # just the same.  The review's mutation run put one there and the earlier
    # version of this test -- which scanned only the `macro_rules!` body --
    # stayed green; scanning to `mod axis_tests` closes that hole.
    let source = readFile(CtLangPath)
    let macroStart = source.find("macro_rules! axis_enum")
    check macroStart >= 0
    let regionEnd = source.find("mod axis_tests", macroStart)
    check regionEnd > macroStart
    if regionEnd <= macroStart:
      checkpoint(
        "`mod axis_tests` was not found after `macro_rules! axis_enum` in " &
        CtLangPath & "; this scan bounds the axis region by it and must be " &
        "updated to follow, not deleted.")
    let body = source[macroStart ..< max(regionEnd, macroStart)]
    check:
      not body.contains("#[repr(")
      not body.contains("Serialize_repr")
      not body.contains("Deserialize_repr")
    if body.contains("#[repr(") or body.contains("_repr"):
      checkpoint(
        "`axis_enum!` in " & CtLangPath & " gained a repr or a serde_repr " &
        "derive.  The axes travel as names; giving them an ordinal " &
        "contract recreates exactly the defect ct-lang's `Lang` has.")

  test "every Rust axis variant is the Nim member with its prefix stripped":
    # The name convention is what makes the pin readable; assert it holds
    # for every member of every axis so a Rust rename cannot hide behind a
    # coincidental token match.
    for v in SourceLanguage: check ($v).startsWith("sl")
    for v in TargetIsa: check ($v).startsWith("ti")
    for v in Toolchain: check ($v).startsWith("tc")
    for v in RecordingApproach: check ($v).startsWith("ra")

# ---------------------------------------------------------------------------
# Property 7 — langWireName is Lang::wire_name, member for member
# ---------------------------------------------------------------------------

proc parseRustLangWireNames(source: string, path: string): seq[RustAxisVariant] =
  ## Extract `Lang::Variant => "name",` rows from `impl Lang { pub fn
  ## wire_name ... }` in `libs/ct-lang/src/lib.rs`, in declaration order.
  ##
  ## Strict, like every parser in this file: a block that cannot be located
  ## raises rather than returning an empty list.  Since LRS-1 this table is
  ## what the `ct/load-locals` receiver decodes, so an anti-drift check that
  ## silently compared nothing would be reporting a pass on the wire contract
  ## itself.
  result = @[]
  let header = "pub fn wire_name(self) -> &'static str {"
  let startIdx = source.find(header)
  if startIdx < 0:
    raise newException(ValueError,
      "could not find `" & header & "` in " & path &
      ".  `Lang::wire_name` moved or was renamed; this check must be " &
      "updated to follow it, not deleted — it is the Rust half of the " &
      "`ct/load-locals` wire vocabulary that `langWireName` must match.")
  let bodyStart = source.find("match self {", startIdx)
  if bodyStart < 0 or bodyStart - startIdx > 200:
    raise newException(ValueError,
      "found `Lang::wire_name` in " & path & " but no `match self {` " &
      "directly inside it.")
  let endIdx = source.find("\n        }", bodyStart)
  if endIdx < 0:
    raise newException(ValueError,
      "found the `Lang::wire_name` match in " & path &
      " but no closing brace after it.")
  for rawLine in source[bodyStart + "match self {".len ..< endIdx].splitLines():
    var line = rawLine.strip()
    let commentIdx = line.find("//")
    if commentIdx >= 0:
      line = line[0 ..< commentIdx].strip()
    if line.len == 0:
      continue
    let arrow = line.find("=>")
    if arrow < 0:
      raise newException(ValueError,
        "unparsable arm in `Lang::wire_name`: `" & line & "`")
    var variant = line[0 ..< arrow].strip()
    if not variant.startsWith("Lang::"):
      raise newException(ValueError,
        "arm `" & line & "` in `Lang::wire_name` does not name a `Lang::` " &
        "variant — a catch-all arm here is exactly what the exhaustive " &
        "match forbids.")
    variant = variant["Lang::".len .. ^1]
    var tok = line[arrow + 2 .. ^1].strip(chars = {' ', ','})
    if tok.len < 2 or tok[0] != '"' or tok[^1] != '"':
      raise newException(ValueError,
        "arm `" & line & "` in `Lang::wire_name` has no quoted name")
    tok = tok[1 ..< tok.high]
    result.add((variant, tok))

suite "langWireName is the Rust Lang::wire_name, member for member (the ct/load-locals vocabulary)":

  setup:
    check fileExists(CtLangPath)

  test "the Rust wire_name table parses and is not empty":
    let rows = parseRustLangWireNames(readFile(CtLangPath), CtLangPath)
    check rows.len > 0
    checkpoint("parsed " & $rows.len & " wire names from " & CtLangPath)

  test "same members, same spelling — matched by NAME, not by position":
    # By name on purpose.  The wire contract this pins is "the member called
    # Leo is spelled `leo` on both sides"; WHERE Leo sits in either
    # declaration is exactly what the change makes irrelevant, so this test
    # must keep passing when the enum is renumbered in lockstep (the
    # milestone's mutation (a)) and property 3 is the one that says the two
    # declaration orders agree.
    let rustRows = parseRustLangWireNames(readFile(CtLangPath), CtLangPath)
    var rustByName = initTable[string, string]()
    for row in rustRows:
      let key = row.variant.toLowerAscii
      check key notin rustByName
      rustByName[key] = row.token
    var nimCount = 0
    for v in Lang:
      inc nimCount
      # Variant names compared case-insensitively for the same reason as
      # property 3 (`PolkaVM` / `LangPolkavm`, `GDScript` / `LangGdScript`);
      # the WIRE NAME is compared exactly, because that is the byte string
      # the receiver parses.
      let key = ($v)["Lang".len .. ^1].toLowerAscii
      check:
        rustByName.hasKey(key)
      if not rustByName.hasKey(key):
        checkpoint(
          "`" & $v & "` has no `Lang::wire_name` arm in " & CtLangPath &
          "; a `ct/load-locals` request for it could not be spelled on the " &
          "Rust side at all.")
        continue
      check:
        langWireName(v) == rustByName[key]
      if langWireName(v) != rustByName[key]:
        checkpoint(
          "`" & $v & "` is spelled \"" & langWireName(v) & "\" by " &
          "`langWireName` but \"" & rustByName[key] & "\" by " &
          "`Lang::wire_name` in " & CtLangPath & ".  A `ct/load-locals` " &
          "request for this language would be REFUSED by the backend " &
          "(`lang_wire` names the unknown spelling), not decoded as a " &
          "different language — but only the two tables agreeing makes the " &
          "request go through at all.")
    check:
      rustRows.len == nimCount
    if rustRows.len != nimCount:
      checkpoint(
        "the Nim `Lang` has " & $nimCount & " members but `Lang::wire_name` " &
        "in " & CtLangPath & " has " & $rustRows.len & " arms.")

  test "every wire name is lowercase, non-empty and unique":
    # The receiver matches exactly; a spelling that differs only in case is a
    # different (and unknown) name.  Uniqueness is what makes the name a
    # lossless replacement for the ordinal.
    var seen = initHashSet[string]()
    for v in Lang:
      let name = langWireName(v)
      check name.len > 0
      check name == name.toLowerAscii
      check name notin seen
      if name in seen:
        checkpoint("`" & name & "` is the wire name of two Lang members; " &
          "the second (" & $v & ") could never be sent.")
      seen.incl(name)

  test "the backend-manager's literal default is langWireName(LangC)":
    # `src/backend-manager` cannot depend on `ct-lang` (property 5 says why),
    # so its default `lang` for a relayed `ct/load-locals` is a literal.  A
    # literal can drift; this is what stops it -- the same pin `store_test.nim`
    # holds on `LoadLocalsDefaultLang` for the Nim store, which is a literal
    # for the same kind of reason (the Embed SDK's package graph).
    let path = RepoRoot / "src" / "backend-manager" / "src" / "backend_manager.rs"
    check fileExists(path)
    let source = readFile(path)
    let marker = "const LOAD_LOCALS_DEFAULT_LANG: &str = "
    let idx = source.find(marker)
    if idx < 0:
      checkpoint(
        path & " no longer declares `" & marker & "...`.  If the default " &
        "moved, follow it; if the crate now takes the name from `ct-lang`, " &
        "re-read property 5's note on its nix sandbox first.")
    check idx >= 0
    if idx >= 0:
      let rest = source[idx + marker.len .. ^1]
      let semi = rest.find(';')
      check semi > 2
      let literal = rest[0 ..< semi].strip()
      check literal.len >= 3 and literal[0] == '"' and literal[^1] == '"'
      if literal.len >= 3 and literal[0] == '"' and literal[^1] == '"':
        let value = literal[1 ..< literal.high]
        if value != langWireName(LangC):
          checkpoint(
            "`LOAD_LOCALS_DEFAULT_LANG` in " & path & " is \"" & value &
            "\" but `langWireName(LangC)` is \"" & langWireName(LangC) &
            "\".  The relayed request would be REFUSED by the backend, not " &
            "decoded as a different language -- but it would be refused.")
        check value == langWireName(LangC)
      # Both relay sites use the constant; neither has gone back to a literal
      # of its own or to an integer.
      check source.count("LOAD_LOCALS_DEFAULT_LANG") >= 3

  test "the names the fixed sites now send are the canonical ones":
    # The three languages whose hand-written ordinals were wrong (Cairo sent
    # as 32 = Leo, Solana as 35 = Cadence, Leo as 33 = Tolk), as the names
    # the bench and the Leo fixture now send.  If someone renames a variant's
    # wire spelling these are the requests that break.  Deliberately NO
    # `Lang(32)`-style assertion here: an ordinal is what this milestone
    # stopped caring about, and a test that pins one would fail the very
    # renumber the change exists to make safe.
    check langWireName(LangCairo) == "cairo"
    check langWireName(LangSolana) == "solana"
    check langWireName(LangLeo) == "leo"
    check langWireName(LangTolk) == "tolk"
    check langWireName(LangCadence) == "cadence"

# ---------------------------------------------------------------------------
# Property 8 — the ct/load-locals receiver decodes a name, not an ordinal
# ---------------------------------------------------------------------------

proc loadLocalsLangFieldAttributes(source: string, path: string): string =
  ## The attribute block that immediately precedes `pub lang: Lang,` inside
  ## `pub struct CtLoadLocalsArguments { ... }` in `task.rs`: every `#[...]`
  ## and `///` line between the previous field and this one.
  let structHeader = "pub struct CtLoadLocalsArguments {"
  let structIdx = source.find(structHeader)
  if structIdx < 0:
    raise newException(ValueError,
      "could not find `" & structHeader & "` in " & path &
      ".  The DAP-facing struct moved or was renamed; this check must be " &
      "updated to follow it, not deleted — it is what asserts the " &
      "`ct/load-locals` receiver decodes a NAME.")
  let structEnd = source.find("\n}", structIdx)
  if structEnd < 0:
    raise newException(ValueError,
      "found `" & structHeader & "` in " & path & " but no closing brace.")
  let body = source[structIdx ..< structEnd]
  let fieldIdx = body.find("pub lang: Lang,")
  if fieldIdx < 0:
    raise newException(ValueError,
      "`CtLoadLocalsArguments` in " & path & " has no `pub lang: Lang,` " &
      "field.  If the field was renamed or retyped, update this check; if " &
      "it was removed, the Nim sender (`requestLocals`) still sends it and " &
      "`deny_unknown_fields` will refuse every request.")
  # Walk back from the field over its own attribute / doc-comment lines.
  var lines = body[0 ..< fieldIdx].splitLines()
  discard lines.pop() # the indentation of the field line itself
  result = ""
  while lines.len > 0:
    let line = lines[^1].strip()
    if line.startsWith("#[") or line.startsWith("///"):
      result = line & "\n" & result
      discard lines.pop()
    else:
      break

suite "the ct/load-locals receiver decodes lang by name":

  setup:
    check fileExists(DbBackendTaskPath)

  test "CtLoadLocalsArguments.lang carries the lang_wire serde adapter":
    let attrs = loadLocalsLangFieldAttributes(readFile(DbBackendTaskPath),
                                              DbBackendTaskPath)
    if not attrs.contains("#[serde(with = \"crate::lang::lang_wire\")]"):
      checkpoint(
        "`CtLoadLocalsArguments.lang` in " & DbBackendTaskPath & " no " &
        "longer carries `#[serde(with = \"crate::lang::lang_wire\")]`.  " &
        "Without it the field falls back to `Lang`'s `serde_repr` derive " &
        "and a bare integer is accepted again — `32` decodes as Leo, `33` " &
        "as Tolk — which is the contract LRS-1 removed.  The attribute " &
        "block found was:\n" & attrs)
    check:
      attrs.contains("#[serde(with = \"crate::lang::lang_wire\")]")

  test "the receiver has not been given a second, integer-accepting path":
    # `#[serde(deserialize_with = ...)]` or an `untagged` enum wrapper could
    # accept both shapes; the point of the change is that an ordinal is
    # REFUSED, so the only adapter on the field must be `lang_wire`.
    let attrs = loadLocalsLangFieldAttributes(readFile(DbBackendTaskPath),
                                              DbBackendTaskPath)
    # Attributes only: the field's doc comment is allowed to NAME
    # `serde_repr` while explaining why it is no longer used.
    var attributeLines: seq[string] = @[]
    for line in attrs.splitLines():
      if line.startsWith("#["):
        attributeLines.add(line)
    check attributeLines.len >= 1
    let attributes = attributeLines.join("\n")
    check:
      not attributes.contains("deserialize_with")
      not attributes.contains("untagged")
      not attributes.contains("serde_repr")

# ---------------------------------------------------------------------------
# Property 9 — no payload spells `lang` as a bare integer
# ---------------------------------------------------------------------------

type
  LangPayloadClass = enum
    lpcOrdinal  ## an integer: literal, `as u8`-style cast, `ord(...)`, `.int`
    lpcName     ## a string: literal, `.wire_name()`, `langWireName(...)`, ...
    lpcOpaque   ## an identifier the sweep cannot type lexically

  LangPayloadSite = object
    ## One `"lang": <value>` key found in a payload position.
    relPath: string  ## repo-relative, `/`-separated
    line: int        ## 1-based
    value: string    ## the value text, trimmed, up to `,` / `}` / end of line
    class: LangPayloadClass

const
  # Files that nothing in this sweep should have to look at: the Rust sweep's
  # skip list applies here too (property 4 says why), and these two hold
  # generated or vendored Nim that is not this repository's payload code.
  PayloadSweepSkipDirs = ["target", "node_modules", ".git", ".direnv", "dist",
                          "nimcache", ".repro"]

  MinNimFilesSwept = 800
    ## The tree held ~1900 `.nim` files when this was written (submodules
    ## under `libs/` included).  A walk that finds fewer than this is broken.

  MinLangPayloadSites = 12
    ## Anti-vacuity floor on the number of `"lang":` payload keys found.
    ## There were 20 when this was written.  A sweep that sees none of them
    ## is not a sweep that found no defects.

  # The fixed sites, and what their REPLACEMENT must look like: each of these
  # files must contain at least one `"lang":` key classified as a NAME.  This
  # is the positive half of the property — the sweep cannot pass by failing
  # to see the files it was written for.
  NamedLangPayloadAnchors = [
    "src/frontend/viewmodel/headless_session.nim",          # was `"lang": 0`
    "src/tests/gui/tests/integration/real_backend_test.nim", # was `"lang": 0`
    "src/frontend/tui/tests/test_variables_tree_expansion.nim", # was `"lang": 0`
    "src/db-backend/tests/leo_search_calltrace_test.rs",    # was `"lang": 33`
    "src/db-backend/tests/javascript_locals_dap_test.rs",   # was `as u8` and `0`
    "src/db-backend/tests/origin_dap_test.rs",              # was `as u8`
    "src/db-backend/tests/origin_viewmodel_test.rs",        # was `as u8`
    "src/db-backend/tests/watch_expressions_dap_test.rs",   # was `as u8`
    "src/backend-manager/src/backend_manager.rs",           # was `"lang": 0`
    "libs/ct-dap-client/src/client.rs",                     # was `"lang": 0`
  ]

  # Payload sites whose value the sweep cannot type lexically, each classified
  # by a human: file and the EXACT number of opaque `"lang":` keys in it.  A
  # NEW opaque site fails the sweep until it is added here with its reason —
  # in a file already listed too, because the count is exact — since
  # `gui_ops.rs`'s `ctx.lang_wire` was exactly such a site — an identifier
  # whose type was `u8` — and nothing asked.  The two production senders on
  # this list have their TYPE asserted by the anchor test below
  # (`lang_wire: &'static str`; `lang: string = LoadLocalsDefaultLang`).
  OpaqueLangPayloadSites = [
    # `ctx.lang_wire` is `&'static str`, the `Lang::wire_name` of the bench
    # language (was `u8`, and wrong for two of ten languages).
    ("src/codetracer-bench/src/gui_ops.rs", 1),
    # `lang` is `requestLocals`'s `lang: string = LoadLocalsDefaultLang`
    # parameter — the wire name, handed in by the caller (was `lang: int = 0`).
    ("src/frontend/viewmodel/store/replay_data_store.nim", 1),
    # `lang` is a `&str` taken from the client's request with `as_str`, or
    # `LOAD_LOCALS_DEFAULT_LANG` (`"c"`, pinned by property 7) when absent;
    # an integer from the client is NOT forwarded.  (The crate's second
    # `ct/load-locals` site spells the constant directly and is a NAME.)
    ("src/backend-manager/src/backend_manager.rs", 1),
    # `metadata.langName`: the shared-artifact metadata, a `string`; not a
    # `Lang` at all.
    ("src/ct/online_sharing/artifact.nim", 1),
    # `spec.lang` is `TracepointSweepSpec.lang: int` — a `Lang` ORDINAL on
    # the `ct/run-tracepoints` payload.  This is the tracepoint-hop remnant
    # LRS-1 did not move (see `RemainingOrdinalLangPayloads`); it is opaque
    # to the sweep because the ordinal hides behind a field name.
    ("src/frontend/viewmodel/headless_session.nim", 1),
  ]

  # The payload sites that STILL carry a `Lang` ordinal, frozen: file and the
  # exact number of ordinal-classified `"lang":` keys in it.  These are the
  # `Tracepoint.lang` / `Stop.lang` fields of the tracepoint hop, which LRS-1
  # left on `serde_repr` (the Rust side never reads `Tracepoint.lang` and
  # always sends `Lang::default()` for `Stop.lang`, so they are inert — but
  # they are still an ordinal on a wire).  Exact counts, not upper bounds, so
  # a new ordinal in one of these files fails just like one anywhere else,
  # and a moved remnant must be removed from this list rather than left to
  # widen it.
  RemainingOrdinalLangPayloads = [
    # a `Tracepoint` built for `ct/run-tracepoints` in the Python bridge
    ("src/backend-manager/src/backend_manager.rs", 1),
    # a `Stop` synthesised for a `ct/tracepoint-results` event in a test
    # harness arm
    ("src/backend-manager/src/main.rs", 1),
  ]

proc classifyLangPayloadValue(value: string): LangPayloadClass =
  ## Lexical classification of the text after `"lang":`.  Deliberately
  ## conservative in ONE direction: anything that looks like an integer is an
  ## ordinal, even if a suffix or cast follows it.
  let v = value.strip()
  if v.len == 0:
    return lpcOpaque
  # An integer literal, optionally negative, optionally with a Rust suffix.
  var i = 0
  if v[0] == '-': inc i
  if i < v.len and v[i] in {'0'..'9'}:
    return lpcOrdinal
  # A cast onto an integer type, in either language.
  for pat in [" as u8", " as u16", " as u32", " as u64", " as i8", " as i16",
              " as i32", " as i64", " as usize", " as isize", "ord(", ".int",
              "int(", ".u8", "u8(", ".ord"]:
    if v.contains(pat):
      return lpcOrdinal
  # A name: a string literal or one of the two production spellers.
  if v[0] == '"' or v.contains(".wire_name()") or v.contains("langWireName(") or
     v.contains("LoadLocalsDefaultLang") or v.contains("LOAD_LOCALS_DEFAULT_LANG"):
    return lpcName
  lpcOpaque

proc sweepLangPayloadSites(root: string): seq[LangPayloadSite] =
  ## Walk every `.rs` and `.nim` file under `root` and report each `"lang":`
  ## key in a payload position with its value classified.
  ##
  ## "Payload position" means the key is preceded (ignoring whitespace) by
  ## `{` or `,` — the shape of a `json!({ ... })` body, a `%*{ ... }` builder
  ## or a raw JSON string.  That excludes `if it == "lang":` and prose like
  ## ``"lang": "LangPythonDb"`` inside a backticked doc comment.  Keys inside
  ## a Rust raw string literal (`r#"..."#`) on the same line are skipped: those
  ## are this test family's own wire fixtures and negative pins
  ## (`assert!(!json.contains(r#""lang":1"#))`), not senders.
  result = @[]
  var sweptRs = 0
  var sweptNim = 0
  var pending = @[""]
  while pending.len > 0:
    let relDir = pending.pop()
    let absDir = if relDir.len == 0: root else: root / relDir
    for kind, entry in walkDir(absDir, relative = true, checkDir = true):
      let rel = if relDir.len == 0: entry else: relDir & "/" & entry
      case kind
      of pcDir:
        if entry notin PayloadSweepSkipDirs:
          pending.add(rel)
      of pcFile:
        let isRs = entry.endsWith(".rs")
        let isNim = entry.endsWith(".nim")
        if not (isRs or isNim):
          continue
        if isRs: inc sweptRs else: inc sweptNim
        let source = readFile(root / rel)
        var searchFrom = 0
        while true:
          let idx = source.find("\"lang\"", searchFrom)
          if idx < 0:
            break
          searchFrom = idx + "\"lang\"".len
          # The colon, after optional whitespace.
          var j = searchFrom
          while j < source.len and source[j] in {' ', '\t'}: inc j
          if j >= source.len or source[j] != ':':
            continue
          # A key that is itself inside a comment line is prose, not a
          # payload (`// This used to read `"lang": 33`, which is ...`).
          let ownLineStart = source.rfind('\n', 0, idx) + 1
          let ownPrefix = source[ownLineStart ..< idx].strip()
          if (isRs and ownPrefix.startsWith("//")) or
             (isNim and ownPrefix.startsWith("#") and
              not ownPrefix.startsWith("#[")):
            continue
          # Payload position: the previous non-whitespace, non-comment
          # character is `{` or `,`.  Whole comment lines between the previous
          # key and this one are skipped (`// By NAME (LRS-1) ...` in Rust,
          # `# the wire NAME ...` in Nim) so that explaining a value does not
          # hide it from the sweep.
          var k = idx - 1
          while true:
            while k >= 0 and source[k] in {' ', '\t', '\r', '\n'}: dec k
            if k < 0:
              break
            let prevLineStart = source.rfind('\n', 0, k) + 1
            let prevLine = source[prevLineStart .. k].strip()
            if (isRs and prevLine.startsWith("//")) or
               (isNim and prevLine.startsWith("#") and
                not prevLine.startsWith("#[")):
              k = prevLineStart - 1
              continue
            break
          if k < 0 or source[k] notin {'{', ','}:
            continue
          # Skip a key inside a Rust raw string on the same line.
          let lineStart = source.rfind('\n', 0, idx) + 1
          var lineEnd = source.find('\n', idx)
          if lineEnd < 0: lineEnd = source.len
          let lineText = source[lineStart ..< lineEnd]
          let col = idx - lineStart
          let rawOpen = lineText.find("r#\"")
          if rawOpen >= 0 and rawOpen < col and
             lineText.find("\"#", col) >= 0:
            continue
          # The value: from after the colon to the first `,`, `}` or newline.
          var v = j + 1
          while v < source.len and source[v] in {' ', '\t'}: inc v
          var e = v
          while e < source.len and source[e] notin {',', '}', '\n', '\r'}: inc e
          var valueText = source[v ..< e]
          # Strip a trailing Nim / Rust line comment from the value text.
          let hashIdx = valueText.find(" #")
          if isNim and hashIdx >= 0: valueText = valueText[0 ..< hashIdx]
          let slashIdx = valueText.find("//")
          if isRs and slashIdx >= 0: valueText = valueText[0 ..< slashIdx]
          result.add(LangPayloadSite(
            relPath: rel.replace('\\', '/'),
            line: source[0 ..< idx].count('\n') + 1,
            value: valueText.strip(),
            class: classifyLangPayloadValue(valueText)))
      else:
        discard
  if sweptRs < MinRustFilesSwept:
    raise newException(ValueError,
      "the payload sweep visited only " & $sweptRs & " `.rs` files under " &
      root & ", below the floor of " & $MinRustFilesSwept & ".  Fix the " &
      "walk — do not lower the floor.")
  if sweptNim < MinNimFilesSwept:
    raise newException(ValueError,
      "the payload sweep visited only " & $sweptNim & " `.nim` files under " &
      root & ", below the floor of " & $MinNimFilesSwept & ".  Fix the " &
      "walk — do not lower the floor.")

proc describe(site: LangPayloadSite): string =
  site.relPath & ":" & $site.line & " `\"lang\": " & site.value & "`"

suite "no .rs or .nim payload spells lang as a bare integer":

  test "the classifier flags every shape that was actually wrong (positive control)":
    # The exact texts that hid in the tree, plus the shapes a re-introduction
    # would most plausibly take.  If the classifier stops seeing one of these
    # the sweep below is measuring nothing, so this runs first.
    for wrong in [
      "33",                       # leo_search_calltrace_test.rs, was Tolk
      "0",                        # headless_session.nim, "auto-detect"
      "32u8",                     # a suffixed literal
      "Lang::Leo as u8",          # origin_dap_test.rs et al.
      "Lang::Python as i64",
      "ord(lang)",                # the Nim spelling of the ordinal
      "lang.int",
      "int(lang)",
      "ctx.lang.ord",
      "-1",
    ]:
      check classifyLangPayloadValue(wrong) == lpcOrdinal
      if classifyLangPayloadValue(wrong) != lpcOrdinal:
        checkpoint("`\"lang\": " & wrong & "` was not classified as an ordinal")
    for right in [
      "\"leo\"",
      "Lang::Leo.wire_name()",
      "ct_lang::Lang::C.wire_name()",
      "langWireName(lang)",
      "langWireName(toLangFromFilename(path))",
      "LoadLocalsDefaultLang",
      "LOAD_LOCALS_DEFAULT_LANG",  # backend-manager's pinned literal (property 7)
    ]:
      check classifyLangPayloadValue(right) == lpcName
      if classifyLangPayloadValue(right) != lpcName:
        checkpoint("`\"lang\": " & right & "` was not classified as a name")
    check classifyLangPayloadValue("lang") == lpcOpaque
    check classifyLangPayloadValue("ctx.lang_wire") == lpcOpaque
    check classifyLangPayloadValue("spec.lang") == lpcOpaque

  test "the sweep sees the tree (anti-vacuity floor)":
    let sites = sweepLangPayloadSites(RepoRoot)
    check:
      sites.len >= MinLangPayloadSites
    if sites.len < MinLangPayloadSites:
      checkpoint(
        "only " & $sites.len & " `\"lang\":` payload keys found under " &
        RepoRoot & "; the floor is " & $MinLangPayloadSites & ".  The " &
        "walk or the key matcher is broken — a sweep that sees nothing " &
        "reports `no ordinals` for the wrong reason.")
    checkpoint("found " & $sites.len & " `\"lang\":` payload keys")

  test "every fixed site now sends a NAME (the replacements are present)":
    let sites = sweepLangPayloadSites(RepoRoot)
    for anchor in NamedLangPayloadAnchors:
      var named = 0
      for site in sites:
        if site.relPath == anchor and site.class == lpcName:
          inc named
      # `checkpoint` BEFORE `check`: std/unittest prints the checkpoints
      # accumulated so far when a check fails, so one written afterwards is
      # only seen if a LATER check in the same test fails too.
      if named < 1:
        checkpoint(
          "`" & anchor & "` has no `\"lang\":` key classified as a name.  " &
          "This file is one the sweep was written for; if the payload " &
          "moved, follow it — do not drop the anchor.")
      check:
        named >= 1
    # The two opaque production senders are typed by these declarations;
    # assert the types, since the sweep cannot.  `gui_ops.rs` is where the
    # wrong ordinals lived: the arms must now name `Lang::` variants and the
    # context field must be a string.
    let guiOps = readFile(RepoRoot / "src" / "codetracer-bench" / "src" / "gui_ops.rs")
    check:
      guiOps.contains("pub lang_wire: &'static str,")
      not guiOps.contains("pub lang_wire: u8")
      guiOps.contains("Language::Cairo => Lang::Cairo,")
      guiOps.contains("Language::Solana => Lang::Solana,")
      guiOps.contains(".wire_name()")
      not guiOps.contains("Language::Cairo => 3")
      not guiOps.contains("Language::Solana => 3")
      not guiOps.contains("=> 0u8")
    let store = readFile(RepoRoot / "src" / "frontend" / "viewmodel" / "store" /
                         "replay_data_store.nim")
    check:
      store.contains("lang: string = LoadLocalsDefaultLang)")
      not store.contains("lang: int = 0)")

  test "no ordinal `lang` outside the frozen tracepoint-hop remnants":
    let sites = sweepLangPayloadSites(RepoRoot)
    var counts = initTable[string, int]()
    var offenders: seq[string] = @[]
    for site in sites:
      if site.class != lpcOrdinal:
        continue
      counts[site.relPath] = counts.getOrDefault(site.relPath) + 1
      var allowed = false
      for (path, _) in RemainingOrdinalLangPayloads:
        if path == site.relPath:
          allowed = true
      if not allowed:
        offenders.add(describe(site))
    offenders.sort()
    if offenders.len > 0:
      checkpoint(
        "found " & $offenders.len & " `\"lang\":` payload key(s) spelled as " &
        "an integer:\n  " & offenders.join("\n  ") & "\n  Send " &
        "`langWireName(lang)` (Nim) or `Lang::X.wire_name()` (Rust) " &
        "instead.  The `ct/load-locals` receiver refuses an integer, and " &
        "the enum's declaration order is not a number to be spelled by " &
        "hand — that is how `gui_ops.rs` came to say Cairo = 32.")
    check:
      offenders.len == 0
    # The frozen list is exact and positively checked: each remnant must
    # still exist with exactly its count, or the list is rotting.
    for (path, expected) in RemainingOrdinalLangPayloads:
      let actual = counts.getOrDefault(path)
      if actual != expected:
        checkpoint(
          "`" & path & "` has " & $actual & " ordinal `\"lang\":` key(s); " &
          "`RemainingOrdinalLangPayloads` says " & $expected & ".  If the " &
          "tracepoint hop moved to names, remove the entry; if a new " &
          "ordinal appeared, it is a defect — do not raise the count.")
      check:
        actual == expected

  test "every opaque `lang` value is one a human has classified":
    let sites = sweepLangPayloadSites(RepoRoot)
    var unexplained: seq[string] = @[]
    var counts = initTable[string, int]()
    for site in sites:
      if site.class != lpcOpaque:
        continue
      counts[site.relPath] = counts.getOrDefault(site.relPath) + 1
      var allowed = false
      for (path, _) in OpaqueLangPayloadSites:
        if path == site.relPath:
          allowed = true
      if not allowed:
        unexplained.add(describe(site))
    unexplained.sort()
    if unexplained.len > 0:
      checkpoint(
        "found " & $unexplained.len & " `\"lang\":` payload key(s) whose " &
        "value the sweep cannot type:\n  " & unexplained.join("\n  ") &
        "\n  Either spell it as a name at the site, or add the file to " &
        "`OpaqueLangPayloadSites` with a comment saying what the " &
        "identifier's type is.  `gui_ops.rs`'s `ctx.lang_wire` was an " &
        "opaque `u8` for a long time.")
    check:
      unexplained.len == 0
    # And the allowlist is exact in both directions: a stale entry silently
    # widens what is permitted, and a second opaque site in a listed file is
    # a new site nobody has classified.
    for (path, expected) in OpaqueLangPayloadSites:
      let actual = counts.getOrDefault(path)
      if actual != expected:
        checkpoint(
          "`" & path & "` has " & $actual & " opaque `\"lang\":` key(s); " &
          "`OpaqueLangPayloadSites` says " & $expected & ".  If a site was " &
          "spelled as a name, lower the count (or remove the entry); if a " &
          "new identifier appeared, classify it here with its type — do " &
          "not raise the count without saying what the identifier is.")
      check:
        actual == expected

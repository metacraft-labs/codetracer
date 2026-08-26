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
## `ct/load-locals` sends `CtLoadLocalsArguments.lang` as an **integer**: the
## Nim side writes `ord(Lang)` (see
## `src/frontend/viewmodel/store/replay_data_store.nim`) and the Rust side
## reads it with `serde_repr` into the `Lang` declared in
## `libs/ct-lang/src/lib.rs`.  The two enums are hand-maintained copies and
## nothing checks that they agree — a variant inserted in the middle of either
## one silently re-points every ordinal above it, and the wrong value loader
## then decodes the frame.
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
## `src/common/trace_index.nim` and `trace_index_migration_test.nim`).  The
## `ct/load-locals` DAP hop this property pins is now the **only** place an
## ordinal survives, which is what makes this test the last line of defence
## rather than one of two.
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
## Mocking justification (workspace policy on mock objects): none.  There is no
## mock in this file.  Property 1 calls the production proc; properties 2–5
## read the production source files.
##
## Compile and run:
##   nim c -r src/tests/cli/lang_enum_contract_test.nim

import std/[algorithm, os, sets, strutils, tables, unittest]
import ../../common/lang
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
      "follow it, not deleted — `ct/load-locals` still sends `lang` as an " &
      "ordinal over that boundary, and since the persisted " &
      "`trace_index.db.recordings.lang` column moved to enum names " &
      "(trace_index schema version 1) that DAP hop is the last ordinal-" &
      "carrying boundary left.")

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
        "`ct/load-locals` sends `lang` as an integer across that boundary, " &
        "so a length difference means some ordinals decode as a different " &
        "language or as an out-of-range value.")

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
          "Every `ct/load-locals` request for a language at or above this " &
          "ordinal would be decoded as the wrong language by the backend, " &
          "and the wrong value loader would then read the frame.")
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
          "`serde_repr` derive.  Both are load-bearing: `ct/load-locals` " &
          "sends the ordinal as an integer and the persisted " &
          "`recordings.lang` column stores it.")

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

  test "all three crates declare the ct-lang dependency":
    # The positive half of property 4: a consumer must not satisfy "no
    # duplicate enum" by quietly dropping the shared type instead.
    for manifest in [
      RepoRoot / "src" / "tui" / "Cargo.toml",
      RepoRoot / "src" / "db-backend" / "Cargo.toml",
      RepoRoot / "libs" / "ct-dap-client" / "Cargo.toml",
    ]:
      check fileExists(manifest)
      check:
        declaresCargoDep(manifest, "ct-lang")
      if not declaresCargoDep(manifest, "ct-lang"):
        checkpoint(
          manifest & " no longer declares a `ct-lang` dependency, so it is " &
          "no longer sharing the canonical Lang enum.")

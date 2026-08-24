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
## ## 3. The Nim `Lang` enum is the same list as db-backend's Rust `Lang`
##
## `ct/load-locals` sends `CtLoadLocalsArguments.lang` as an **integer**: the
## Nim side writes `ord(Lang)` (see
## `src/frontend/viewmodel/store/replay_data_store.nim`) and the Rust side
## reads it with `serde_repr` into `src/db-backend/src/lang.rs`'s `Lang`.  The
## two enums are hand-maintained copies and nothing checks that they agree —
## a variant inserted in the middle of either one silently re-points every
## ordinal above it, and the wrong value loader then decodes the frame.
##
## (The doc comment on the Nim enum used to name
## `codetracer-native-backend/src/lang.rs` as its partner.  That was wrong:
## that enum has a `Small` variant at ordinal 21 and diverges from there.  The
## worker socket between the two Rust crates now carries language names, so no
## ordinal crosses a repository boundary any more; this hop is the last one
## that carries an ordinal at all outside the persisted
## `trace_index.db.lang` column.)
##
## The test below parses the `pub enum Lang { … }` block out of the Rust source
## and compares it to `Lang`, name by name and ordinal by ordinal.
##
## Mocking justification (workspace policy on mock objects): none.  There is no
## mock in this file.  Property 1 calls the production proc; properties 2 and 3
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
  DbBackendLangPath = RepoRoot / "src" / "db-backend" / "src" / "lang.rs"

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
# Property 3 — the Nim Lang enum matches db-backend's Rust Lang enum
# ---------------------------------------------------------------------------

proc parseRustLangEnum(source: string): seq[string] =
  ## Extract the variant names of `pub enum Lang { ... }` from
  ## `src/db-backend/src/lang.rs`, in declaration order.
  ##
  ## Deliberately strict for the same reason as `parseJsLangMap`: an
  ## anti-drift check that quietly finds nothing to compare is worse than no
  ## check at all, because it reports a pass.
  result = @[]
  let startMarker = "pub enum Lang {"
  let startIdx = source.find(startMarker)
  if startIdx < 0:
    raise newException(ValueError,
      "could not find `" & startMarker & "` in " & DbBackendLangPath &
      ".  The enum moved or was renamed; this check must be updated to " &
      "follow it, not deleted — `ct/load-locals` still sends `lang` as an " &
      "ordinal over that boundary.")

  let bodyStart = startIdx + startMarker.len
  let endIdx = source.find("\n}", bodyStart)
  if endIdx < 0:
    raise newException(ValueError,
      "found `" & startMarker & "` in " & DbBackendLangPath &
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

suite "the Nim Lang enum is db-backend's Rust Lang enum, ordinal for ordinal":

  setup:
    check fileExists(DbBackendLangPath)

  test "the Rust enum parses and is not empty":
    let variants = parseRustLangEnum(readFile(DbBackendLangPath))
    check variants.len > 0
    checkpoint("parsed " & $variants.len & " variants from " & DbBackendLangPath)

  test "both enums have the same number of values":
    let variants = parseRustLangEnum(readFile(DbBackendLangPath))
    var nimCount = 0
    for _ in Lang:
      inc nimCount
    check:
      variants.len == nimCount
    if variants.len != nimCount:
      checkpoint(
        "the Nim Lang enum has " & $nimCount & " values but the Rust Lang " &
        "enum in " & DbBackendLangPath & " has " & $variants.len & ".  " &
        "`ct/load-locals` sends `lang` as an integer across that boundary, " &
        "so a length difference means some ordinals decode as a different " &
        "language or as an out-of-range value.")

  test "every ordinal names the same language on both sides":
    let variants = parseRustLangEnum(readFile(DbBackendLangPath))
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
          "but `" & variants[index] & "` in " & DbBackendLangPath & ".  " &
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

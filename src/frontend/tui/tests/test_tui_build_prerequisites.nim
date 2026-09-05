## test_tui_build_prerequisites.nim — CTUI-0.
##
## ## What this asserts, and why it is a test rather than a build step
##
## Three prerequisites stand between a fresh checkout and a TUI that links, and
## every one of them was found by compiling rather than by reading:
##
##   1. `isonim` vendors Facebook Yoga as a git submodule that a fresh
##      workspace does not initialise. Without it the first Nim file that
##      touches layout fails with `cannot find: .../yoga/yoga/YGConfig.cpp`.
##   2. Linking needs a tree-sitter grammar archive. `tree-sitter-nim` does not
##      ship `src/parser.c`; it is generated.
##   3. The link line carries `-ltree-sitter`, whose runtime this repo's dev
##      shell does not put on `LD_LIBRARY_PATH`.
##
## Each of those fails, when it fails, at a point far from its cause: a missing
## submodule surfaces as a missing C++ file several minutes into an unrelated
## compile, and a missing archive surfaces as a linker path nobody recognises.
## This suite exists to move that diagnosis to the front of the run and to name
## the recipe that fixes it.
##
## ## IT DOES NOT SKIP
##
## A missing prerequisite is the defect this file exists to report, so every
## case FAILS on absence. There is no `skip()`, no early `return`, no
## `when false`. A suite that detected a missing prerequisite and returned
## early would be counted PASSED by the lane runner, which is precisely the
## defect catalogued in codetracer-specs/Testing/
## Silent-Self-Pass-Audit-2026-08-23.md — and it would be a particularly
## expensive instance, because the thing it would be silent about is the
## reason every OTHER file in this lane failed.
##
## ## It imports nothing that needs a prerequisite to link
##
## Deliberately: the prerequisites this file checks are what a compile of the
## product code NEEDS. A suite that imported `isonim_tui` to report a missing
## grammar archive could not link without the archive it was written to report.
## So it is the one file in the lane that still runs when everything else
## cannot.
##
## The one product module it does import is `app/cli`, and the rule is intact
## rather than bent: `cli.nim` imports `std/strutils` and `src/ct/version` (which
## imports `strutils` and nothing else). It emits no `{.passl.}`, links no
## archive and spawns nothing, so importing it cannot make this suite depend on
## a prerequisite it exists to report. It is imported because the alternative —
## grepping `cli.nim` for a flag spelling — is the vocabulary match
## Verification-Harness-Traps §4d is about: a future comment mentioning the flag
## would redden it, and a parser that started ACCEPTING the flag while the
## source still spelled it differently would not. Calling the parser asks the
## question that matters.

# `std/times` is here for the `<` on `Time` that the freshness comparison
# needs; `std/os` returns `Time` values but does not export the comparison.
# `std/osproc` is here for the two questions only git can answer: which
# `parser.c` a grammar submodule COMMITS, and whether generating one left the
# submodule dirty.
import std/[os, osproc, strutils, times, unittest]

import ../app/cli

# Read off a run, as codetracer-specs/Testing/Verification-Harness-Traps.md §4c
# asks: the count is asserted at the end, so a case that returned early or a
# loop that skipped a member reddens the file on the spot rather than being
# noticed by someone differencing two runs. Declared on ONE line because
# `ci/lib/run-nim-test-lane.sh` reads exactly that spelling — inside a `const`
# block it is invisible to the lane and the file reports "declared none".
const ExpectedAssertions = 43

const PrereqRecipe = "just tui-prereqs"

var countedAssertions = 0

template ck(condition: untyped) =
  ## `check`, counted.
  inc countedAssertions
  check condition

proc repoRoot(): string =
  ## The checkout this test's source lives in.
  var dir = currentSourcePath().parentDir
  while true:
    if dirExists(dir / "src" / "db-backend") and fileExists(dir / "justfile"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "could not locate the codetracer checkout from " & currentSourcePath())

proc declaredGrammars(root: string): seq[string] =
  ## Every `libs/tree-sitter-*` submodule `.gitmodules` declares.
  ##
  ## Read from `.gitmodules` for the same reason `scripts/build-tui-grammars.sh`
  ## reads it: the script, `just tui-prereqs` and this test must be talking
  ## about one list, or a grammar can be added to two of the three and the
  ## disagreement presents as a smaller archive rather than as an error.
  result = @[]
  let modules = root / ".gitmodules"
  if not fileExists(modules):
    return
  for rawLine in readFile(modules).splitLines():
    let line = rawLine.strip()
    if not line.startsWith("path"):
      continue
    let eq = line.find('=')
    if eq < 0:
      continue
    let path = line[eq + 1 .. ^1].strip()
    if path.startsWith("libs/tree-sitter-"):
      result.add(path)

proc git(dir: string; args: varargs[string]): tuple[code: int, text: string] =
  ## `git -C dir <args…>`, as (exit status, stdout+stderr).
  ##
  ## Every caller checks the status: a git that did not run answers "" to every
  ## question, and "" satisfies each of the emptiness assertions below for free
  ## (Verification-Harness-Traps §4).
  var cmd = "git -C " & quoteShell(dir)
  for a in args:
    cmd.add(" " & quoteShell(a))
  let (text, code) = execCmdEx(cmd)
  (code, text)

proc commitsParserC(root: string; grammar: string): bool =
  ## Does this grammar COMMIT `src/parser.c`, or must it be generated?
  ##
  ## Asked of git, mirroring `grammar_commits_parser_c` in
  ## `scripts/build-tui-grammars.sh`. `fileExists` would answer yes for a
  ## leftover from the era when that script generated in place, and this suite
  ## would then compare the archive's freshness against a file nothing compiles.
  ## The two must agree, so they ask the same question the same way.
  git(root / grammar, "ls-files", "--error-unmatch", "src/parser.c").code == 0

proc generatedDir(root: string; grammar: string): string =
  ## Where `tree-sitter generate -o` puts a grammar that ships no parser.c.
  ##
  ## OUTSIDE THE SUBMODULE, which is the point: the in-place form overwrites
  ## `src/tree_sitter/parser.h`, which is TRACKED, with whichever copy the
  ## tree-sitter CLI on PATH carries — and a build step that dirties a
  ## submodule blocks every push from the checkout that ran it, because the
  ## workspace pre-push gate refuses uncommitted changes in a repo's
  ## develop-set closure.
  root / "build" / "grammars" / "generated" /
    grammar[len("libs/") .. ^1]

proc parserCPath(root: string; grammar: string): string =
  ## The `parser.c` the archive is actually built from, wherever it lives.
  if commitsParserC(root, grammar):
    root / grammar / "src" / "parser.c"
  else:
    generatedDir(root, grammar) / "parser.c"

proc grammarSources(root: string; grammar: string): seq[string] =
  ## The translation units the archive is built from, for one grammar.
  result = @[]
  let parser = parserCPath(root, grammar)
  if fileExists(parser):
    result.add(parser)
  for unit in ["scanner.c", "scanner.cc"]:
    let p = root / grammar / "src" / unit
    if fileExists(p):
      result.add(p)

proc archiveHead(path: string): string =
  ## The first 256 KB of an `ar` archive, as text.
  ##
  ## `ar` writes member names as plain ASCII, either in the header or in the
  ## long-name table that precedes the members, so the names are readable
  ## without shelling out to `ar t` — which would make these checks depend on a
  ## binutils on PATH to report that a build product is incomplete.
  result = newString(256 * 1024)
  let f = open(path, fmRead)
  let n = f.readChars(toOpenArray(result, 0, result.len - 1))
  f.close()
  result.setLen(n)

proc countGrammarMembers(archivePath: string; grammars: seq[string]):
    tuple[found: int, missing: seq[string]] =
  ## How many of `grammars` contributed a `ct_ts_<lang>_parser.o` to this
  ## archive.
  ##
  ## The `ct_ts_` prefix is this repo's, chosen by
  ## `scripts/build-tui-grammars.sh` so that members of OUR archive can never be
  ## confused with members of isonim-tui's (`ts_nim_parser.o`,
  ## `ts_aiken_parser.o`). That makes this count an identity check as well as a
  ## completeness one: an isonim-tui archive substituted for ours scores zero,
  ## not two.
  result = (0, @[])
  let head = archiveHead(archivePath)
  for g in grammars:
    let lang = g[len("libs/tree-sitter-") .. ^1]
    let member = "ct_ts_" & lang & "_parser.o"
    if head.contains(member):
      inc result.found
    else:
      result.missing.add(member)

# ---------------------------------------------------------------------------
# The release entrypoint's import closure
# ---------------------------------------------------------------------------
#
# CTUI-2 gives `--test-ipc` to the snapshot apps under
# `src/frontend/tui/testing/`, and the milestone asks THIS file to be what
# fails if it can reach a release build. `app/cli.parseTuiCommand` refusing the
# flag is one half; the other half is that the entrypoint links none of the
# code that implements it, and that is a question about the import graph.
#
# The walker below is deliberately smaller than `test_tui_facade_boundary.nim`'s
# `importSpecs`, and the difference is the subject rather than the rigour.
# That one answers "may this module NAME this spec?" over an adversary who can
# choose the spelling, so it has to normalise quotes, split statements, strip
# one-line `when` prefixes and enumerate every module-path root. This one
# answers "what does the entrypoint REACH?" over code the repository controls,
# and its non-vacuity is guaranteed from the other side: the closure must
# contain four named modules, so a walker that stopped resolving goes red
# before its negative assertion is reached. The bound is stated rather than
# implied — a spec spelled in a form this extractor does not read would be
# MISSED here, and the mutation arm plants the two forms the tree actually
# uses (a relative import at the root and one two levels down).

proc importSpecsOf(path: string): seq[string] =
  ## The module specs one file names. Comments stripped, `,` lists and
  ## `a/[b, c]` bracket lists expanded, indented continuations under a bare
  ## `import` / `from` followed.
  result = @[]
  var continuing = false
  for rawLine in readFile(path).splitLines():
    var line = rawLine
    let hash = line.find('#')
    if hash >= 0: line = line[0 ..< hash]
    let trimmed = line.strip()
    if trimmed.len == 0:
      continuing = false
      continue
    var body = ""
    if trimmed.startsWith("import "):
      body = trimmed["import ".len .. ^1]
    elif trimmed.startsWith("from "):
      let rest = trimmed["from ".len .. ^1]
      let cut = rest.find(" import ")
      body = if cut >= 0: rest[0 ..< cut] else: rest
    elif trimmed.startsWith("include "):
      body = trimmed["include ".len .. ^1]
    elif trimmed == "import" or trimmed == "from":
      continuing = true
      continue
    elif continuing and (rawLine.startsWith(" ") or rawLine.startsWith("\t")):
      body = trimmed
    else:
      continuing = false
      continue
    continuing = continuing or trimmed == "import" or trimmed == "from"
    # `a/[b, c]` — one root, several leaves.
    let open = body.find('[')
    if open >= 0 and body.endsWith("]"):
      let stem = body[0 ..< open].strip()
      for leaf in body[open + 1 ..< body.high].split(','):
        let l = leaf.strip()
        if l.len > 0: result.add(stem & l)
    else:
      for part in body.split(','):
        var spec = part.strip()
        let asPos = spec.find(" as ")
        if asPos >= 0: spec = spec[0 ..< asPos].strip()
        let exceptPos = spec.find(" except ")
        if exceptPos >= 0: spec = spec[0 ..< exceptPos].strip()
        spec = spec.strip(chars = {'"'})
        if spec.len > 0: result.add(spec)

proc resolveSpec(root, importer, spec: string): string =
  ## The file a spec names, or "" when it resolves outside the repository (a
  ## `std/*` module, `isonim_tui`, `codetracer_embed`). Those are not walked —
  ## see the bound stated above.
  var roots = @[importer.parentDir,
                root / "src" / "frontend",
                root / "src" / "frontend" / "viewmodel",
                root / "src"]
  for r in roots:
    let candidate = normalizedPath(r / (spec & ".nim"))
    if fileExists(candidate) and candidate.isRelativeTo(root):
      return candidate
  ""

proc importClosure(root, entry: string): seq[string] =
  ## Every in-repo module reachable from `entry`, transitively, `entry`
  ## excluded.
  result = @[]
  var pending = @[normalizedPath(entry)]
  var seen: seq[string] = @[normalizedPath(entry)]
  while pending.len > 0:
    let current = pending.pop()
    for spec in importSpecsOf(current):
      let resolved = resolveSpec(root, current, spec)
      if resolved.len == 0 or resolved in seen: continue
      seen.add resolved
      result.add resolved
      pending.add resolved

suite "CTUI-0: TUI build prerequisites":

  let root = repoRoot()
  let grammars = declaredGrammars(root)
  let archive = root / "build" / "grammars" / "libcodetracer_tui_grammars.a"

  test "the declared grammar set is non-empty and matches the spec's ten":
    # THE NON-VACUITY FLOOR, and it is the check rather than a formality.
    # Every assertion below this one is quantified over `grammars`; on an empty
    # sequence they all pass, and the suite would report a clean sweep of a set
    # it never read (Verification-Harness-Traps §4, §6a).
    checkpoint("declared grammars: " & $grammars.len & " — " & grammars.join(", "))
    ck grammars.len > 0
    # CodeTracer-TUI.md §5.4 names ten vendored grammars, and CTUI-0's whole
    # argument for building the archive here rather than depending on
    # isonim-tui's two siblings is that this repo already has all ten. Fewer
    # means the claim in the specification stopped being true, which is a
    # review event and not something to discover from a smaller archive.
    ck grammars.len >= 10

  test "every declared grammar submodule is checked out":
    var populated = 0
    for g in grammars:
      let hasParser = fileExists(root / g / "src" / "parser.c")
      let hasGrammar = fileExists(root / g / "src" / "grammar.json")
      if hasParser or hasGrammar:
        inc populated
      else:
        checkpoint("grammar submodule not checked out: " & g &
                   " — run `" & PrereqRecipe & "`")
    ck populated == grammars.len

  test "tree-sitter-nim's parser.c was generated, outside the submodule":
    # The one grammar whose parser.c is NOT committed: tree-sitter-nim
    # gitignores it and produces it from the grammar. `just tui-prereqs` runs
    # `tree-sitter generate -o <scratch> src/grammar.json` — the JSON form,
    # because the bare `tree-sitter generate` loads grammar.js through node and
    # fails on a host without one; and `-o`, because the in-place form
    # overwrites `src/tree_sitter/parser.h`, which the submodule TRACKS. The
    # next test asserts the consequence; this one asserts the location.
    let gen = generatedDir(root, "libs/tree-sitter-nim")
    let parser = gen / "parser.c"
    if not fileExists(parser):
      checkpoint("missing " & parser & " — run `" & PrereqRecipe & "`")
    ck fileExists(parser)
    if fileExists(parser):
      # A zero-byte or truncated file would satisfy `fileExists` and fail at
      # `ar` time with a message about an object rather than about a grammar.
      ck getFileSize(parser) > 1_000_000
    # The runtime header the SAME generate run emitted. `parser.c` includes
    # `tree_sitter/parser.h`, and compiling it against the submodule's pinned
    # copy instead is an ABI mismatch found at compile time or not at all —
    # which is the reason the scratch directory holds both.
    if not fileExists(gen / "tree_sitter" / "parser.h"):
      checkpoint("missing " & gen / "tree_sitter" / "parser.h" &
                 " — run `" & PrereqRecipe & "`")
    ck fileExists(gen / "tree_sitter" / "parser.h")

  test "generating parsers left every grammar submodule clean":
    # THE DEFECT THIS ASSERTS AGAINST, stated plainly: `tree-sitter generate`
    # run inside a grammar checkout overwrites `src/tree_sitter/parser.h`,
    # which is TRACKED, on every run. The header it writes is whichever one the
    # CLI on PATH carries, so whether the run leaves DIRT depends on the
    # version — 0.25.3 adds a typedef the pinned header lacks and leaves a
    # permanent ` M libs/tree-sitter-<name>` in `git status`; 0.25.10 writes a
    # byte-identical header and leaves none. That is exactly why this is
    # asserted rather than reasoned about: the answer is a property of the host
    # the build ran on, so only the host can give it. The workspace pre-push
    # gate refuses uncommitted changes in a repo and its develop-set closure,
    # so the dirty case is not cosmetic: it blocks every push from the checkout
    # that ran the build step.
    #
    # `just tui-prereqs` therefore generates into `build/grammars/generated/`
    # and never writes inside a submodule. This is the outside check on that.
    #
    # THE POSITIVE CONTROL COMES FIRST, because "no dirty files" is what a
    # `git` that did not run also reports. Asking about a path that is KNOWN to
    # be ignored-and-present proves the invocation, the working directory and
    # the parsing all work before any emptiness is read as evidence.
    let control = git(root, "status", "--porcelain", "--ignored",
                      "--", "build/grammars")
    checkpoint("control (ignored build/grammars): " &
               $control.text.strip().splitLines().len & " line(s)")
    ck control.code == 0
    ck control.text.strip().len > 0
    # And the property. Scoped to the grammar submodules the TUI links, so an
    # unrelated edit elsewhere in the tree does not present as a TUI defect.
    let dirt = git(root, "status", "--porcelain", "--", "libs/tree-sitter-nim")
    if dirt.text.strip().len > 0:
      checkpoint("`just tui-prereqs` dirtied the grammar submodule: " &
                 dirt.text.strip())
    ck dirt.text.strip().len == 0

  test "isonim's Yoga submodule is populated":
    # `isonim/src/isonim/layout/yoga` is a git submodule; an uninitialised one
    # is an empty directory, so `dirExists` is not evidence. YGConfig.cpp is
    # the file the compiler names when it is absent, which makes it the honest
    # thing to look for.
    let yoga = root.parentDir / "isonim" / "src" / "isonim" / "layout" / "yoga"
    if not fileExists(yoga / "yoga" / "YGConfig.cpp"):
      checkpoint("isonim's Yoga submodule is not populated at " & yoga &
                 " — run `" & PrereqRecipe & "`")
    ck fileExists(yoga / "yoga" / "YGConfig.cpp")

  test "the grammar archive exists and is newer than every grammar source":
    if not fileExists(archive):
      checkpoint("missing " & archive & " — run `" & PrereqRecipe & "`")
    ck fileExists(archive)
    if fileExists(archive):
      let archiveTime = getLastModificationTime(archive)
      var stale: seq[string] = @[]
      var inspected = 0
      for g in grammars:
        for src in grammarSources(root, g):
          inc inspected
          if getLastModificationTime(src) > archiveTime:
            stale.add(src)
      # The count control again: `stale.len == 0` is satisfied by a loop that
      # inspected nothing, and a `grammarSources` that stopped resolving would
      # produce exactly that.
      checkpoint("grammar sources inspected: " & $inspected)
      ck inspected >= grammars.len
      if stale.len > 0:
        checkpoint("grammar sources newer than the archive: " & stale.join(", ") &
                   " — run `" & PrereqRecipe & "`")
      ck stale.len == 0

  test "the archive carries one member per declared grammar":
    # This is the assertion that distinguishes "a file exists" from "the
    # archive contains the grammars". A truncated archive, an `ar` invocation
    # that lost its argument list, or a loop that skipped a grammar all leave a
    # file behind, and only this notices.
    ck fileExists(archive)
    if fileExists(archive):
      let (found, missing) = countGrammarMembers(archive, grammars)
      for member in missing:
        # NOT `PrereqRecipe & " --force"`: `just` reads a trailing word as a
        # second recipe name and answers `Justfile does not contain recipe
        # '--force'`. The forcing flag belongs to the script, which
        # `tui-prereqs` calls without arguments.
        checkpoint("archive has no member " & member &
                   " — run `bash scripts/build-tui-grammars.sh --force`")
      checkpoint("archive members matched: " & $found & "/" & $grammars.len)
      ck found == grammars.len

  test "the tree-sitter runtime was resolved and recorded":
    # `-ltree-sitter` is on the link line whether or not this host has the
    # runtime, so its absence is a link failure with no context. `just
    # tui-prereqs` resolves it and writes the flags down; this asserts the
    # record exists AND still points at a directory that holds the library, so
    # a garbage-collected nix store path is caught here rather than at link
    # time.
    let flagsFile = root / "build" / "grammars" / "tui-link-flags.txt"
    if not fileExists(flagsFile):
      checkpoint("missing " & flagsFile & " — run `" & PrereqRecipe & "`")
    ck fileExists(flagsFile)
    if fileExists(flagsFile):
      let flags = readFile(flagsFile).strip()
      checkpoint("recorded link flags: " & flags)
      ck flags.startsWith("-L")
      ck flags.contains("-Wl,-rpath,")
      var libDir = flags.split(' ')[0]
      libDir = libDir[2 .. ^1]
      var haveRuntime = false
      for name in ["libtree-sitter.so", "libtree-sitter.dylib",
                   "libtree-sitter.a"]:
        if fileExists(libDir / name) or symlinkExists(libDir / name):
          haveRuntime = true
      if not haveRuntime:
        checkpoint("no libtree-sitter in " & libDir &
                   " — run `" & PrereqRecipe & "`")
      ck haveRuntime

  test "the archive at the path isonim_tui bakes in is OURS, and complete":
    # NOT a duplicate of the check above, and the difference is the point.
    #
    # `isonim-tui/src/isonim_tui/syntax/treesitter_ffi.nim` emits an archive
    # path as `{.passl.}`, so every binary that imports `isonim_tui` hands the
    # linker whatever sits at
    #
    #     <workspace>/isonim-tui/build/grammars/libisonim_tui_grammars.a
    #
    # unless it overrides the path with `-d:isonimTuiGrammarArchive=…`, which
    # `just build-tui` and both TUI lanes now do. `just tui-prereqs` still
    # symlinks that path to this repo's archive, as a fallback for an
    # isonim-tui predating the override — Nim ignores a define naming a
    # constant the sources do not declare, so without the fallback such a
    # workspace would fail at `ld: cannot find <path>` rather than at anything
    # legible.
    #
    # TWO ASSERTIONS, AND THE SECOND IS THE ONE WITH TEETH.
    #
    # `fileExists` and not `symlinkExists`: `symlinkExists` is TRUE for a
    # DANGLING link, which is precisely the state that fails the link — the
    # linker resolves the target, not the name — so accepting it would make
    # this check pass in the one case it exists to catch.
    #
    # And the member count, because existence is not identity. isonim-tui's own
    # `just grammars` tests this path with `[ -f "$archive" ]`, which FOLLOWS
    # the symlink: run it there and it either adopts this archive or replaces
    # the link with a TWO-grammar archive of its own — after which
    # `ensure_isonim_tui_archive` sees a file and leaves it. Ten grammars
    # instead of two is this milestone's headline benefit; without this count
    # the degradation is silent, and the `ct_ts_` prefix is exactly what
    # distinguishes our members from isonim-tui's `ts_nim_parser.o`.
    let sibling = root.parentDir / "isonim-tui" / "build" / "grammars" /
                  "libisonim_tui_grammars.a"
    if not fileExists(sibling):
      checkpoint("missing (or dangling) " & sibling &
                 " — run `" & PrereqRecipe & "`")
    ck fileExists(sibling)
    if fileExists(sibling):
      let (found, missing) = countGrammarMembers(sibling, grammars)
      if missing.len > 0:
        checkpoint("the archive at " & sibling & " is missing " &
                   $missing.len & " member(s): " & missing.join(", ") &
                   " — it is not this repo's ten-grammar archive. Remove it" &
                   " and run `" & PrereqRecipe & "`.")
      checkpoint("baked-path archive members matched: " & $found & "/" &
                 $grammars.len)
      ck found == grammars.len

  test "the CLI does not accept the test-only --test-ipc flag":
    # CTUI-2 introduces `--test-ipc`, a test-only flag that must never be
    # accepted by, or advertised in, the shipped command line; its milestone
    # asks THIS file to be what fails when it is. Asserted now, while the
    # answer is trivially true, because a guard added after the thing it guards
    # has to be written by someone who remembers to.
    #
    # STRUCTURAL, NOT LEXICAL. The previous form read `cli.nim` and asserted
    # the text did not contain `--test-ipc`, which is the vocabulary match
    # Verification-Harness-Traps §4d catalogues, pointing the other way: a
    # future COMMENT explaining why the flag is refused would redden it, and
    # rewording a comment to appease a scan is the smell that section names.
    # Worse, the scan is satisfied by any spelling change — a parser that
    # started accepting the flag from a `const TestIpcFlag` would pass.
    #
    # So the parser is called. The positive controls come first: a parser that
    # returned `tckUsageError` for everything would satisfy the real assertion
    # for free.
    ck parseTuiCommand(["--help"]).kind == tckHelp
    ck parseTuiCommand(["--version"]).kind == tckVersion
    let ipc = parseTuiCommand(["--test-ipc"])
    checkpoint("parseTuiCommand(--test-ipc) -> " & $ipc.kind)
    ck ipc.kind == tckUsageError
    if ipc.kind == tckUsageError:
      # And it must be refused BY NAME, so a user who typed it learns which
      # argument was rejected rather than that "something" was.
      ck ipc.message.contains("--test-ipc")
    # EVERY POSITION, not just the first. CTUI-2 gives the flag to the snapshot
    # apps under `src/frontend/tui/testing/`, and a parser that refused it as
    # the sole argument while ACCEPTING it after a trace path — or swallowing
    # it AS one — would satisfy the assertion above and still ship the flag.
    # The positive control comes first again: a bare path must still parse, or
    # the two arms below are refusals of everything rather than of this flag.
    ck parseTuiCommand(["/tmp"]).kind == tckOpenTrace
    ck parseTuiCommand(["/tmp", "--test-ipc"]).kind == tckUsageError
    ck parseTuiCommand(["--test-ipc", "/tmp"]).kind == tckUsageError
    ck parseTuiCommand(["--test-ipc=1"]).kind == tckUsageError
    # `--never-settle` and `--label=` are the runtime's other two test-only
    # flags; the shipped parser must not know them either.
    ck parseTuiCommand(["--never-settle"]).kind == tckUsageError
    ck parseTuiCommand(["--label=x"]).kind == tckUsageError
    # The help text, read as the value the binary prints rather than as bytes
    # in a file — a doc comment cannot satisfy this one. Positive twin first.
    ck TuiHelpText.contains("--version")
    ck not TuiHelpText.contains("--test-ipc")
    ck not TuiHelpText.contains("--never-settle")

  test "the release entrypoint cannot reach the test-only IPC runtime":
    # THE OTHER HALF OF THE `--test-ipc` CONTRACT, and the one that makes the
    # case above more than a convention. `parseTuiCommand` refusing the flag is
    # a statement about ONE parser; this is a statement about the BINARY: no
    # module under `src/frontend/tui/testing/` — the directory that holds the
    # flag, the `TermAssertClient` connection and the screenshot request — is in
    # `main.nim`'s import closure, so a release build contains none of it.
    #
    # STRUCTURAL: import specs are RESOLVED TO FILES and compared as paths,
    # exactly as `test_tui_facade_boundary.nim` does for the app/host rule.
    # A grep for the directory name would be reddened by this very comment.
    #
    # The POSITIVE CONTROL is the same walk: the closure must contain the four
    # modules the entrypoint genuinely reaches. A walker that resolved nothing
    # would report an empty closure, and an empty closure satisfies "contains
    # no testing/ module" for free — trap 4, arriving through a resolver
    # instead of through a regex.
    let root = repoRoot()
    let closure = importClosure(root, root / "src" / "frontend" / "tui" / "main.nim")
    var reached: seq[string] = @[]
    for f in closure:
      reached.add f.relativePath(root)
    checkpoint("main.nim reaches " & $closure.len & " in-repo module(s): " &
               reached.join(", "))
    for expected in ["src/frontend/tui/app/cli.nim",
                     "src/frontend/tui/app/tui_app.nim",
                     "src/frontend/tui/host/native_host.nim",
                     "src/ct/version.nim"]:
      if expected notin reached:
        checkpoint("the import walker did not reach " & expected &
                   " — every assertion below it is vacuous")
      ck expected in reached
    var testingModules: seq[string] = @[]
    for f in reached:
      if f.startsWith("src/frontend/tui/testing/"):
        testingModules.add f
    if testingModules.len > 0:
      checkpoint("the release entrypoint reaches TEST-ONLY module(s): " &
                 testingModules.join(", ") &
                 " — `--test-ipc` would be in the shipped binary")
    ck testingModules.len == 0

  test "MUTATION ARM: the closure walker sees a planted testing/ import":
    # A negative assertion whose walker had stopped resolving would stay green
    # forever. So the same walk is run over a COPY of the tree with one import
    # planted in it, and over the unmutated copy first — a control, because a
    # finding in a temporary tree must not be an artefact of the copy.
    let root = repoRoot()
    let tmp = getTempDir() / "ctui2-closure-arm-" & $getCurrentProcessId()
    removeDir(tmp)
    createDir(tmp / "src" / "frontend")
    copyDir(root / "src" / "frontend" / "tui", tmp / "src" / "frontend" / "tui")
    createDir(tmp / "src" / "ct")
    copyFile(root / "src" / "ct" / "version.nim",
             tmp / "src" / "ct" / "version.nim")
    let tmpMain = tmp / "src" / "frontend" / "tui" / "main.nim"

    var control: seq[string] = @[]
    for f in importClosure(tmp, tmpMain):
      if f.relativePath(tmp).startsWith("src/frontend/tui/testing/"):
        control.add f.relativePath(tmp)
    checkpoint("control (unmutated copy): " & $control.len & " testing/ module(s)")
    ck control.len == 0
    # And the control reached SOMETHING, or its zero means nothing.
    ck importClosure(tmp, tmpMain).len >= 4

    writeFile(tmpMain, readFile(tmpMain) &
              "\nimport ./testing/test_app_runtime\n")
    var mutated: seq[string] = @[]
    for f in importClosure(tmp, tmpMain):
      if f.relativePath(tmp).startsWith("src/frontend/tui/testing/"):
        mutated.add f.relativePath(tmp)
    checkpoint("mutated: " & mutated.join(", "))
    ck "src/frontend/tui/testing/test_app_runtime.nim" in mutated
    # And it walks THROUGH the planted module: `test_app_runtime` imports
    # `isonim_tui` (out of tree, so unresolved) and nothing else in `testing/`,
    # while `dual_snap` — planted below — pulls nothing further either. What
    # the arm proves is that a one-line edit anywhere in the entrypoint's
    # closure is caught, not only one at its root.
    let deeper = tmp / "src" / "frontend" / "tui" / "app" / "cli.nim"
    writeFile(tmpMain, readFile(tmpMain).replace(
      "\nimport ./testing/test_app_runtime\n", "\n"))
    writeFile(deeper, readFile(deeper) &
              "\nimport ../testing/dual_snap\n")
    var indirect: seq[string] = @[]
    for f in importClosure(tmp, tmpMain):
      if f.relativePath(tmp).startsWith("src/frontend/tui/testing/"):
        indirect.add f.relativePath(tmp)
    checkpoint("planted two levels down: " & indirect.join(", "))
    ck "src/frontend/tui/testing/dual_snap.nim" in indirect
    removeDir(tmp)

  test "assertion count":
    # Printed as well as asserted: `ci/lib/run-nim-test-lane.sh` reads a
    # `CHECKS: <n>` line as a RUNTIME assertion count, which is strictly
    # better evidence than the `[OK]` markers it otherwise has to tally —
    # unittest prints one of those per test block, including a block that
    # asserted nothing.
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions

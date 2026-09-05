## test_tui_facade_boundary.nim — CTUI-0.
##
## ## The rule
##
## `src/frontend/tui/app/` is the SDK-consuming half of the TUI. No module
## under it may reach `backend/stdio_backend`, `viewmodel/headless_session`,
## `std/osproc` or `std/posix`, and none may import `src/frontend/tui/host/`,
## which is the one directory holding those capabilities.
##
## This is a STRUCTURAL test, not a review convention. `headless_app.nim` says
## of itself that "this module cannot reach a `std/osproc` from where it sits,
## and `ci/test/sdk-facade-boundary.sh` is what keeps that true"; this file is
## the same sentence for the TUI, and the reason it is a Nim suite rather than
## another shell guard is the mutation arm below — the checker has to be
## callable against a tree that is not this repository.
##
## ## What the walk covers, stated exactly
##
## Every `.nim` file under `app/`, plus everything they import that RESOLVES
## INSIDE `src/frontend/tui/`. Edges that leave that tree are checked as module
## specs and not followed.
##
## ## Imports are resolved to FILES, not compared as strings
##
## This is the difference between a structural test and a spelling convention,
## and getting it wrong is how the first version of this file could be evaded.
## `config.nims` puts `src/frontend` on the Nim module path, so
##
##     import tui/host/native_host
##
## written inside `app/tui_app.nim` compiles, reaches the host layer, and names
## nothing on any forbidden-spec list. An importer-relative rule does not see
## it, because the spec is not relative to the importer.
##
## Nim resolves `import a/b` by joining the spec onto each root on the search
## path, which means a root can only succeed if it is an ANCESTOR DIRECTORY of
## the file it resolves to. So instead of enumerating the roots — a list that
## `config.nims`, `ci/lib/test-lane-files.sh` and any future `--path` can all
## extend without telling this file — `specSpellings` enumerates the ancestors
## of each host module, bounded by the tree being scanned, and that set is
## exhaustive over roots by construction. `native_host`, `host/native_host`,
## `tui/host/native_host`, `frontend/tui/host/native_host` and
## `src/frontend/tui/host/native_host` are all reported by the same rule, and
## `../host/native_host` is caught by resolving it against the importer.
##
## The same treatment is applied to the two product modules the facade
## withholds, whose files this repository does have: every spelling that
## resolves to `viewmodel/headless_session.nim` or to
## `viewmodel/backend/stdio_backend.nim` is a violation, not just the four
## spellings someone thought to write down.
##
## `std/osproc` and `std/posix` stay literal string matches, and that is not an
## oversight: they are stdlib modules with no file inside this checkout to
## resolve against, so both spellings of each are listed instead.
##
## ## A SPEC IS NORMALISED BEFORE IT IS GRADED, BECAUSE NIM HAS MANY SPELLINGS
##
## The rule above is exhaustive over module-path ROOTS. Being exhaustive over
## roots is not the same as being exhaustive over LEXICAL forms, and several
## forms used to escape. `import "tui/host/native_host"` is legal Nim, resolves
## through a `--path` root exactly as the bare spelling does, and was NOT
## reported, because `importSpecs` yielded the spec with its quotation marks
## still on — so it matched no host spelling and resolved to no file. Planted in
## the real `app/tui_app.nim` it compiled and left this suite green while six
## other spellings of the same import went red.
##
## `normalizeSpec` closes that, in this file and in
## `ci/test/sdk-facade-boundary.sh`'s `nim_imports` — the extractor this one
## deliberately mirrors rather than forks — in one change, because the second is
## what every "must not import X" rule in the repository is built on and a fix
## to one alone would give the TUI coverage the repo-wide guard lacks. The
## normalisation happens ONCE, where the spec is extracted, so the rules
## downstream never learn that quotation marks exist; teaching each rule
## separately is how a guard grows one hole per rule.
##
## THREE LEXICAL FACTS ABOUT NIM, each taken from the compiler rather than from
## memory — every form below was compiled against nim 2.2.8 and resolved to the
## same module through the same `--path`:
##
##   1. A SPEC MAY BE A STRING LITERAL: `import "a/b"`, `import "a/b" as c`,
##      `from "a/b" import c`, `from "a/b" as c import d`, `include "a/b"`,
##      `import a, "b/c"`, `import "a/b"/[c, d]`, `import "a"/b/c`,
##      `import a/"b"/c`, `import r"a/b"`, `import """a/b"""`,
##      `import "a/b" except d`, and the spec on a continuation line under a
##      bare `import`.
##   2. A STRING LITERAL SELF-TERMINATES, so the space before the next keyword
##      is OPTIONAL: `import "a/b"as c`, `import "a/b"except d` and
##      `from "a/b"as c import d` all compile. These are the forms a
##      spaced-keyword split turns into `a/bas c` — a module that does not
##      exist, and therefore silence. They exist only because the spec is
##      quoted, so they are squarely inside what this change is for.
##   3. `/` IS AN ORDINARY INFIX OPERATOR: `import a / b / c` and
##      `import "a" / "b" / "c"` compile and mean `a/b/c`. This one was never
##      about quoting and was missed at HEAD too. (`import a /b/ c` does NOT
##      compile — nim rejects the asymmetric spacing as `invalid module name` —
##      so only the symmetric form is handled.)
##
## `import "a/b/[c]"` is the one form that does NOT compile: inside quotes the
## brackets are part of a filename. So it is deliberately not expanded into a
## bracket list — expanding it would invent a module nobody imported.
##
## ## A LINE IS NOT A STATEMENT, WHICH IS A SEPARATE MISTAKE FROM THE ABOVE
##
## Everything above is about how a SPEC may be spelled. This is about where a
## STATEMENT may sit, and it is the one that hid an import in total silence
## rather than yielding a wrong spec:
##
##   4. `;` SEPARATES STATEMENTS. `import a; import b` is two imports and
##      compiles; so does `echo 1; import a` and `import a;`. Read as one
##      statement, the whole line normalises to the single spec `a;importb` —
##      one module nobody has — so BOTH imports are lost, including the
##      permitted one, and the file looks as if it imported nothing.
##      `splitStatements` splits on a `;` outside a string literal and outside
##      brackets, the second because `when (let x = 1; x > 0): import a`
##      compiles too.
##   5. `when` / `elif` / `else` MAY CARRY THEIR STATEMENT ON THEIR OWN LINE.
##      `when not defined(js): import a` is idiomatic and is ONE line, so the
##      indented-continuation handling — which covers the multi-line spelling of
##      exactly the same thing, and whose presence is what made this look
##      covered — never saw it. The line did not begin with `import`, so it was
##      skipped before any rule ran. `elif`, `else`, `when(c):` and
##      `else:import a` compile as well. `stripConditionalPrefix` reduces the
##      line to the statement it carries, choosing the colon that ends the
##      condition by WHAT FOLLOWS IT rather than by counting brackets, because
##      `when F(a: 1).a == 1:` and `when {1: 2}.len > 0:` both compile.
##
## The "quoted specs are read as the modules they name" and "a statement is not
## a line" tests below are the standing record of both lists; the fourth to
## seventh mutation arms are the proof they matter.
##
## ## WHAT IS LEFT — BOUNDED, AND MEASURED RATHER THAN REASONED
##
## This paragraph has been wrong twice, in the same direction both times: it
## claimed a completeness nobody had tested for. First "the residue can
## over-report but cannot hide an import", which assumed a module path must be a
## valid identifier throughout when only the BASENAME must; then "what remains
## is ONE form, a backslash", which overlooked the two statement shapes above.
## So what follows is bounded by what was actually put in front of the compiler.
##
## THE METHOD, so it can be repeated: every form named below was written into a
## probe module, compiled against nim 2.2.8, and — where it compiles — made to
## USE a symbol from the module it imports, so "it parses" was never mistaken
## for "it imports". Each was then run through this extractor AND through
## `nim_imports`, whose outputs are compared byte for byte over all 998 tracked
## Nim files.
##
## FORMS NIM ITSELF REJECTS, so no extractor has to carry them:
##   * `if c: import a`, `block: import a`, `static: import a`,
##     `proc p() = import a`, `for i in …: import a`, `case k of 1: import a`
##     — "'import' is only allowed at top level";
##   * `when a: when b: import c` — "nestable statement requires indentation";
##   * `when a: (import b)` — "expression expected, but found 'keyword import'";
##   * `import"a/b"`, `from"a/b"import c`, `include"a/b"` — the space AFTER the
##     keyword is mandatory (only the keyword after a quoted spec may be tight),
##     so `startsWith("import ")` is not missing a spelling on that side;
##   * `import a /b/ c` — nim wants the `/` spacing symmetric.
##
## FORMS THAT COMPILE AND ARE REFUSED, LOUDLY — three, and none of them passes
## in silence:
##   * a spec containing a BACKSLASH. `import "a\x2Fb\x2Fc"` imports `a/b/c`.
##     Decoding Nim's escapes — which differ between `"…"`, `r"…"` and `"""…"""`
##     — in two languages is a place to be subtly wrong, and subtly wrong here
##     is a MISS. `normalizeSpec` raises;
##   * an import statement running INTO, or resuming AFTER, a block comment that
##     does not close on the same line. A block comment that opens and closes on
##     one line is removed, nesting and all, and the import behind it is read;
##     tracking comment state ACROSS lines is what is refused, because a `#[`
##     inside a multi-line string literal would then swallow every import after
##     it — a miss of a whole file, worse than the one being fixed;
##   * a one-line `when`/`elif`/`else` that visibly carries an import which this
##     lexer could not read out of it (`conditionalImportUnread`). The realistic
##     cause is a CHARACTER LITERAL in the condition: `when '#' == '#':`,
##     `when ';' == ';':` and `when '"' == 'x':` all compile and land the
##     comment cut, the statement split or the quote parity inside the literal.
##     Teaching three scans about character literals would mean teaching them
##     that the suffix in `1'u8` is not one — a new way to be wrong — so the
##     extractor asserts on itself instead. It is deliberately quote-blind, and
##     the price is that a string on such a line which merely CONTAINS the words
##     trips it too. A loud false alarm beats a quiet miss.
##
## WHAT IS STILL A SILENT MISS, named here rather than left to be found a third
## time — and bounded BY THE PLACE rather than by the trick, because the draft
## before this one bounded it by the trick ("a character literal holding a `#`
## or a `"`") and was measurably too narrow. THE PLACE is a NON-conditional
## statement sharing its line with an import through a `;`. Anything in that
## leading statement which desynchronises the comment cut, the quote parity or
## the bracket depth carries the import past all three. Each of the following
## compiles on nim 2.2.8, imports usably, and is read by neither extractor:
##
## .. code-block:: nim
##    echo '#'; import a/b      — the comment cut lands inside the literal
##    echo '"'; import a/b      — quote parity inverted by the literal
##    echo '('; import a/b      — bracket depth raised by the literal, so the
##                                separator is never seen (`[` and `{` too)
##    echo "a\"b"; import a/b   — quote parity inverted by an ESCAPED quote in
##                                an ordinary string, not a character literal
##
## So does the closing triple-quote of a multi-line string literal followed by
## the same separator. A character literal holding a SEMICOLON or a CLOSING
## bracket is read correctly, so the family is not "character literals"; it is
## "anything that unbalances one of the three scans". The self-check above
## covers the CONDITIONAL version of every one of them, which is where the
## realistic evasion is; extending it to any line was measured and rejected:
## six real prose comments in this repository carry a `;` before the word
## `from`, eleven further prose lines carry a `:` before `import` or `from`, and
## all seventeen would go red for nothing — before counting the dozens of lines
## in THIS file that describe the very forms above.
##
## And the direction the rest of the residue runs in is worth stating: quote
## parity is per line, so lines inside a multi-line string literal are read as
## code. That is an OVER-report — noisy, never a miss — and this file's own
## probe fixtures are counted that way.
##
## ONE KNOWN ASYMMETRY BETWEEN THE MIRRORS, and it is in the reporting, not the
## reading: on a statement it refuses, `nim_imports` logs it and goes on walking
## the file, while `importSpecs` raises and abandons it. Both make the run red
## and neither can miss because of it, but the awk side will name more refusals
## in one run.
##
## ## WHERE THIS SUITE STOPS, AND WHO OWNS WHAT LIES PAST IT
##
## The walk's own boundary — edges that leave `src/frontend/tui/` are graded as
## specs and not followed — is deliberate and is not a weakening. What lies past
## `codetracer_embed` is `ci/test/sdk-facade-boundary.sh`'s subject: it walks
## the facade's own transitive graph — into `isonim` and `nim-everywhere` as
## well — and fails the build when a renderer, a DOM or an `osproc` is
## reachable from it. Re-walking that graph here would either duplicate that
## guard or, worse, disagree with it: the facade guard bans `osproc` but not
## `std/posix`, so a transitive walk from here would report `app/` violations
## for modules `app/` never names. The two guards compose — this one owns the
## TUI's own edges, that one owns everything past the facade — and each says so.
##
## Compose, not overlap, and it is worth being blunt about which way: NOTHING in
## `ci/test/sdk-facade-boundary.sh` reports an `app/` -> `host/` import, in any
## spelling. Its consumer rule fires only on specs resolving under
## `src/frontend/viewmodel`, and `host/` is not there; its one TUI rule,
## `tui-layers`, is about which directories carry a `.sdk-consumer` marker. So a
## host import planted in `app/` reddens THIS file and nothing else. Do not read
## a green run of that script as a second opinion on the rule below.
##
## ## The mutation arm is part of the deliverable
##
## Per codetracer-specs/Testing/Verification-Harness-Traps.md, a chain of
## passing checks is not a result: a scanner that finds nothing satisfies every
## "must not contain" assertion written over it. So this file
##
##   * asserts what the scan FOUND before asserting what it did not — the file
##     count, the edge count, and one named edge (`codetracer_embed`) that must
##     be there;
##   * copies `app/` to a temporary tree, plants `import std/osproc` in one
##     module, and requires the same checker to report exactly that;
##   * plants an `import ../host/native_host` and requires that to be reported
##     too, because the host edge is a different rule from the spec list;
##   * plants an `import tui/host/native_host` — the `src/frontend`-relative
##     spelling that an importer-relative rule cannot see, and the evasion this
##     file was found to be open to — and requires that to be reported as well;
##   * plants an `import "tui/host/native_host"` — the SAME import with
##     quotation marks round it, which is a different rule again: not a
##     spelling the resolver has to know, but a lexical form the extractor has
##     to normalise before any rule sees it — and requires that to be reported
##     too;
##   * plants an `import "tui/host/session_recorder"` against a host module
##     whose name ENDS IN `r`, because the arm above cannot catch the way that
##     normalisation is most easily got wrong. Strip the `r` of a raw string
##     literal whenever a quote follows it and the CLOSING quote qualifies too,
##     so every quoted spec ending in `r` silently loses its last letter.
##     `native_host` ends in `t`, so no amount of running that arm would show
##     it; `src/frontend/viewmodel` alone holds 21 modules that would be hit
##     (`request_tracker`, `front_end_adapter`, `reducer`, `sync_publisher`,
##     `noir_anchor_producer`, …);
##   * plants a `when not defined(js): import tui/host/native_host`, the SIXTH
##     arm — the form the comments in this file and in `nim_imports` already
##     read as covered, because the MULTI-LINE `when defined(js):` spelling was
##     covered and has had a contract case since it was written. They are
##     different code paths: the multi-line form puts `import` at the start of
##     its own line and the one-liner does not;
##   * plants an `import codetracer_embed; import tui/host/native_host`, the
##     SEVENTH, with the PERMITTED import first on purpose. A split that kept
##     only the tail would still report the violation and look right, so the arm
##     also asserts the edge for `codetracer_embed` — the difference between
##     "one import was hidden" and "the whole line was lost", which is what this
##     shape actually did;
##   * and runs the checker over the UNMUTATED copy first in every arm, so a
##     finding cannot be an artefact of the temporary tree.
##
## The temporary tree mirrors this repository's own layout
## (`<tmp>/src/frontend/tui/{app,host}`) rather than being a flat pair of
## directories. That is what makes the third to seventh arms meaningful:
## `tui/host/…` is only a spelling of the host module — quoted or not, and on
## whichever kind of line — when there is a `src/frontend` above it for a
## module-path root to sit on.
##
## Each mechanism was mutation-tested against the suite itself, not only
## described, and the measured answer is wider than "one arm each" — which is
## what the previous draft of this paragraph claimed. Made a no-op,
## `stripConditionalPrefix` reddens the sixth arm, the form-by-form statement
## test AND the self-check test, whose NEGATIVE half asserts that a readable
## one-line `when` is in fact read; `splitStatements` reddens the seventh arm,
## the statement test and the self-check test as well — neutered only at its
## call site in `importSpecs`, just the seventh and the statement test; and
## removing the block-comment branch of `stripComment` reddens the refusal test
## and the statement test. An arm that stays green when its mechanism is removed
## is not evidence of anything.

import std/[algorithm, os, sequtils, strutils, unittest]

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling, and inside a `const` block the declaration is invisible to it.
const ExpectedAssertions = 95

const
  ForbiddenSpecs = [
    "backend/stdio_backend",
    "stdio_backend",
    "headless_session",
    "viewmodel/headless_session",
    "std/osproc",
    "osproc",
    "std/posix",
    "posix",
  ]
    ## Both the qualified and the bare spelling of each, because Nim resolves
    ## `import osproc` and `import std/osproc` to the same module and a rule
    ## that named only one of them would be satisfied by writing the other.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

type
  ImportEdge = object
    ## One `import`/`from`/`include` edge, as written.
    file*: string   ## repo-relative-ish path of the importing file
    spec*: string   ## the module spec, exactly as it appears in the source

  Violation = object
    file*: string
    spec*: string
    reason*: string

  ScanResult = object
    files*: seq[string]
    edges*: seq[ImportEdge]
    violations*: seq[Violation]

proc repoRoot(): string =
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

type UnanalysableSpec = object of ValueError
  ## An import statement this extractor will not guess at. See `normalizeSpec`.

proc countOutsideQuotes(s: string, ch: char): int =
  ## Occurrences of `ch` in `s` that are not inside a string literal.
  ##
  ## Quote-aware because the caller counts the brackets that decide whether an
  ## import statement is finished, and `import "a[b/../c"` is ONE module whose
  ## name contains a bracket. Counted naively that bracket never closes: the
  ## statement is never flushed, every later line is glued onto the same
  ## buffer, and the file yields no specs at all — a whole file made invisible
  ## to every rule below by one character inside quotation marks.
  var inQuote = false
  for c in s:
    if c == '"':
      inQuote = not inQuote
    elif not inQuote and c == ch:
      inc result

proc stripComment(line: string; openedBlockComment: var bool): string =
  ## `line` with its comments removed, judging "comment" OUTSIDE string
  ## literals.
  ##
  ## Nim requires only the BASENAME of a module path to be a valid identifier,
  ## so `import "h#d/../tui/host/native_host"` compiles and imports the host
  ## module. Cut at the first `#` regardless of quoting and that statement
  ## becomes `import "h`, which names nothing: the host layer is reached and no
  ## rule ever sees it.
  ##
  ## BLOCK COMMENTS ARE REMOVED, NOT TREATED AS A LINE COMMENT.
  ## `import #[c]# tui/host/native_host` and `import tui/host/native_host #[c]#`
  ## both compile (nim 2.2.8), and cutting at the first `#` loses the spec of
  ## the first one outright. They nest (`#[ #[x]# ]#`) so this counts depth, and
  ## `##[ … ]##` opens one too.
  ##
  ## When the block comment does NOT close on this line, `openedBlockComment` is
  ## set and the caller refuses the statement instead of guessing: the rest of
  ## it is on a line this call will never see, and cross-line comment state is
  ## not tracked (a `#[` inside a multi-line string literal would then swallow
  ## the rest of the file, which is a MISS of a whole file).
  openedBlockComment = false
  var inQuote = false
  var i = 0
  result = newStringOfCap(line.len)
  while i < line.len:
    let c = line[i]
    if c == '"':
      inQuote = not inQuote
      result.add(c)
      inc i
    elif inQuote:
      result.add(c)
      inc i
    elif c == '#':
      let opensBlock = (i + 1 < line.len and line[i + 1] == '[') or
                       (i + 2 < line.len and line[i + 1] == '#' and line[i + 2] == '[')
      if not opensBlock:
        return
      var depth = 1
      i += (if line[i + 1] == '[': 2 else: 3)
      while i < line.len and depth > 0:
        if i + 1 < line.len and line[i] == '#' and line[i + 1] == '[':
          inc depth
          i += 2
        elif i + 1 < line.len and line[i] == ']' and line[i + 1] == '#':
          dec depth
          i += 2
        else:
          inc i
      if depth > 0:
        openedBlockComment = true
        return
    else:
      result.add(c)
      inc i

proc resumesAfterBlockComment(line: string): bool =
  ## True when a block comment CLOSES on this line and an import statement
  ## follows it: a closing bracket-hash followed by `import tui/host/native_host`
  ## IS an import, and `stripComment` — which starts every line outside any
  ## comment — cuts it at the `#` and yields `]`, so the statement would vanish.
  ## Refused, not parsed.
  ##
  ## (Spelled in prose rather than shown, deliberately: this file is itself one
  ## of the 998 the extractor walks, and a literal example here would be
  ## indistinguishable from the thing it describes — which is exactly the
  ## refusal working.)
  for i in 0 ..< max(line.len - 1, 0):
    if line[i] == ']' and line[i + 1] == '#':
      let rest = line[i + 2 .. ^1].strip()
      for kw in ["import", "from", "include"]:
        if rest == kw or (rest.len > kw.len and rest.startsWith(kw) and
                          rest[kw.len] in {' ', '\t'}):
          return true
  false

proc splitStatements(s: string): seq[string] =
  ## `s` split into the statements a `;` separates.
  ##
  ## `import a; import b` is TWO imports on one line and compiles (nim 2.2.8);
  ## so does `echo 1; import a`. Read as one statement the whole line yields
  ## `a;importb` — a module nobody has, so BOTH imports are lost and nothing is
  ## reported. A `;` inside a string literal is a filename character, and the
  ## bracket depth is what keeps `when (let x = 1; x > 0): import a` — which
  ## also compiles — in one piece.
  result = @[]
  var inQuote = false
  var depth = 0
  var cur = ""
  for c in s:
    if c == '"':
      inQuote = not inQuote
      cur.add(c)
      continue
    if not inQuote:
      if c in {'(', '[', '{'}:
        inc depth
      elif c in {')', ']', '}'}:
        dec depth
      elif c == ';' and depth <= 0:
        result.add(cur)
        cur = ""
        continue
    cur.add(c)
  result.add(cur)

proc startsStatement(s: string): bool =
  ## Does `s` begin an `import` / `from` / `include` statement?
  for kw in ["import", "from", "include"]:
    if s == kw:
      return true
    if s.len > kw.len and s.startsWith(kw) and s[kw.len] in {' ', '\t'}:
      return true
  false

proc dropUnmatchedClose(s: string): string =
  ## `s` with trailing `)` that closes nothing removed, counted outside
  ## literals. Reachable only from `stripConditionalPrefix`, for the one nested
  ## spelling nim accepts: `when a: (when b: import x)` compiles, and the
  ## statement inside it ends with the paren that closes the outer one.
  result = s
  while result.endsWith(")") and
        result.countOutsideQuotes('(') < result.countOutsideQuotes(')'):
    result = result[0 ..< result.len - 1].strip()

proc isConditionalLine(t: string): bool =
  ## Does `t` (already trimmed) begin a `when` / `elif` / `else` branch?
  ##
  ## `when(cond):` and `else:import a` are legal with no space anywhere, which
  ## is why the test is on the character after the keyword rather than on a
  ## trailing space.
  (t.len > 4 and t.startsWith("when") and t[4] in {' ', '\t', '('}) or
  (t.len > 4 and t.startsWith("elif") and t[4] in {' ', '\t', '('}) or
  (t.startsWith("else") and t[4 .. ^1].strip().startsWith(":"))

proc stripConditionalPrefix(t: string): string =
  ## A ONE-LINE `when` / `elif` / `else`, reduced to the statement it carries.
  ##
  ## `when not defined(js): import tui/host/native_host` is idiomatic Nim,
  ## compiles, and is ONE LINE — so the indented-continuation handling in
  ## `importSpecs`, which covers the multi-line spelling of the same thing,
  ## never sees it. At HEAD the line did not start with `import`, so it was
  ## skipped outright and the import was invisible to every rule below.
  ## `elif`, `else`, `when(cond):` and `else:import a` (no space anywhere) all
  ## compile too.
  ##
  ## WHICH COLON ENDS THE CONDITION is decided by what FOLLOWS it rather than by
  ## counting brackets, because a colon can legally appear inside the condition
  ## in more ways than a lexer this size can enumerate: `when F(a: 1).a == 1:`,
  ## `when {1: 2}.len > 0:` and `when ':' == ':':` all compile. The first colon
  ## whose remainder starts an import statement is the answer for every one of
  ## them, and for `when true: import "a:b"` too, since a colon inside a literal
  ## is skipped.
  if not t.isConditionalLine():
    return t
  var inQuote = false
  for i, c in t:
    if c == '"':
      inQuote = not inQuote
      continue
    if inQuote or c != ':':
      continue
    let rest = t[i + 1 .. ^1].strip()
    if rest.startsStatement():
      return dropUnmatchedClose(rest)
  t

proc cutKeywords(s: string, keywords: openArray[string]): string =
  ## `s` truncated before the first top-level occurrence of any of `keywords`.
  ##
  ## "Top-level" is outside a string literal, so a module whose name contains
  ## ` as ` is not cut in half.
  ##
  ## THE KEYWORD MAY BE PRECEDED BY WHITESPACE **OR BY A CLOSING QUOTE**, and
  ## that second case is the one a spaced-keyword search misses. A string
  ## literal self-terminates, so `import "a/b"as c`, `import "a/b"except d` and
  ## `from "a/b"as c import d` are all legal Nim (compiled, 2.2.8) and all
  ## resolve to `a/b`. Split only on ` as ` and the extractor yields `a/bas c`
  ## — no such module, no finding, evasion complete. Those forms exist BECAUSE
  ## the spec is quoted, so they are squarely inside what `normalizeSpec` is
  ## for.
  var inQuote = false
  for i, c in s:
    if c == '"':
      inQuote = not inQuote
      continue
    if inQuote:
      continue
    # inQuote is false here, so a preceding quote is necessarily a CLOSING one.
    if i > 0 and s[i - 1] notin {' ', '\t', '"'}:
      continue
    for kw in keywords:
      if i + kw.len > s.len or s[i ..< i + kw.len] != kw:
        continue
      # A keyword is only a keyword when it ends the word, which is what keeps
      # `import a/exceptions` and `import a, ascii` whole. END OF STRING counts:
      # `from ../ui/shortcut_labels import` with the symbol list on the lines
      # below is how several files in this repository are written.
      if i + kw.len == s.len or s[i + kw.len] in {' ', '\t'}:
        return s[0 ..< i]
  s

proc normalizeSpec(spec: string, path: string): string =
  ## `spec` reduced to the one spelling every rule below sees.
  ##
  ## TWO NORMALISATIONS, both of them the same module to Nim and neither of
  ## them cosmetic:
  ##
  ## **Quotes come off.** A QUOTED SPEC IS NOT A DIFFERENT MODULE, IT IS THE
  ## SAME MODULE WRITTEN DIFFERENTLY: `import "a/b"` is joined onto each
  ## `--path` root exactly as `import a/b` is; so are the partly quoted
  ## `import "a"/b/c` and `import a/"b"/c`, the raw `import r"a/b"` and the
  ## triple-quoted `import """a/b"""`.
  ##
  ## **Whitespace around `/` goes.** `/` is an ordinary infix operator, so
  ## `import a / b / c` and `import "a" / "b" / "c"` compile and mean `a/b/c`.
  ## Left alone the spec is `a / b / c`, which equals no host spelling and
  ## resolves to no file. (Only the symmetric spacing needs handling:
  ## `import a /b/ c` is rejected by nim as `invalid module name`.)
  ##
  ## Every spelling here was compiled against nim 2.2.8 before this proc was
  ## written, not guessed at, and the "quoted specs are read as the modules
  ## they name" test below is the standing record of that list.
  ##
  ## So the normalisation happens once, here, and every rule below — the
  ## forbidden spec list, the host spellings, the resolver — sees a single
  ## spelling. The alternative, teaching each rule about quotation marks, is
  ## how a guard grows a hole per rule.
  ##
  ## WHAT IT REFUSES. A spec containing a BACKSLASH cannot be read lexically:
  ## `import "a\x2Fb\x2Fc"` compiles and imports `a/b/c`. Decoding that
  ## correctly means implementing Nim's escape rules — including that `r"..."`
  ## and `"""..."""` do NOT interpret escapes — twice, here and in awk, where
  ## getting it subtly wrong is a silent MISS. So it is not decoded and not
  ## emitted raw either, because emitting `a\x2Fb\x2Fc` matches nothing and
  ## resolves to nothing, which is exactly the miss this whole change exists to
  ## close. It raises. Refusing to analyse is safe for a guard; guessing is not.
  result = newStringOfCap(spec.len)
  var inQuote = false
  var i = 0
  while i < spec.len:
    let c = spec[i]
    if c == '"':
      inQuote = not inQuote
    elif inQuote:
      if c == '\\':
        raise newException(UnanalysableSpec,
          path & ": the import spec " & spec & " carries Nim string escapes, " &
          "which this lexical extractor does not decode. `import \"a\\x2Fb\"` " &
          "imports `a/b`; decoding it wrongly would HIDE an import rather " &
          "than over-report one, so the statement is refused instead. " &
          "Write the import in its plain form.")
      result.add(c)
    elif c in {'r', 'R'} and i + 1 < spec.len and spec[i + 1] == '"':
      # The `r` of a raw string literal goes with the quote it INTRODUCES.
      # `not inQuote` is what makes that precise: the quote after an `r` opens
      # a literal only outside one. Without that test the CLOSING quote of
      # `"tui/host/request_tracker"` qualifies too and the spec becomes
      # `tui/host/request_tracke` — a miss, and not a rare one:
      # `src/frontend/viewmodel` alone holds 21 modules whose names end in `r`
      # (`request_tracker`, `front_end_adapter`, `reducer`, `sync_publisher`, …).
      discard
    elif c notin {' ', '\t'}:
      result.add(c)
    inc i

proc conditionalImportUnread(rawLine, line: string): bool =
  ## THE SELF-CHECK ON `stripConditionalPrefix`: this line is a one-line
  ## conditional, the RAW text of it visibly carries an import statement, and
  ## yet nothing was read out of it.
  ##
  ## It exists because a condition is arbitrary Nim and this is a lexer, not a
  ## parser. A CHARACTER LITERAL is the concrete way to break it — the scans
  ## above model double-quoted strings and nothing else — and all three of
  ## these compile (nim 2.2.8) while landing the comment cut, the statement
  ## split or the quote parity inside the literal:
  ##
  ## .. code-block:: nim
  ##    when '#' == '#': import tui/host/native_host
  ##    when ';' == ';': import tui/host/native_host
  ##    when '"' == 'x': import tui/host/native_host
  ##
  ## Every one of them was a silent MISS. Rather than teach three scans about
  ## character literals — which would then have to know that the numeric suffix
  ## in `1'u8` is not one, and be wrong in a new way — the extractor notices
  ## that it read nothing out of a line that plainly has an import on it, and
  ## refuses. A guard may fail to read; it may not fail to read QUIETLY.
  let t = rawLine.strip()
  if not t.isConditionalLine():
    return false
  # The raw line must VISIBLY carry a statement: an `import` / `from` /
  # `include` keyword separated from a `:` or a `;` by nothing but blanks.
  var carries = false
  for i, c in rawLine:
    if c notin {':', ';'}:
      continue
    let rest = rawLine[i + 1 .. ^1]
    var j = 0
    while j < rest.len and rest[j] in {' ', '\t'}:
      inc j
    let tail = rest[j .. ^1]
    for kw in ["import", "from", "include"]:
      if tail.len > kw.len and tail.startsWith(kw) and tail[kw.len] in {' ', '\t'}:
        carries = true
    if carries:
      break
  if not carries:
    return false
  for piece in splitStatements(line):
    let frag = stripConditionalPrefix(piece.strip())
    if frag.startsWith("import ") or frag.startsWith("from ") or
       frag.startsWith("include ") or frag == "import" or frag == "include":
      return false
  true

proc emitSpec(spec: string, path: string, into: var seq[string]) =
  ## Append one extracted spec to `into`, normalised, if it names anything.
  ##
  ## THE ALIAS COMES OFF HERE, per emitted spec, and deliberately not before
  ## the bracket test in `importSpecs`: `import ../[ types, config as
  ## frontend_config ]` aliases ONE ELEMENT OF THE LIST, and cutting the
  ## statement at that `as` would leave `../[ types, config`, which is no
  ## longer a bracket list, is never expanded, and hides both modules.
  ## `src/frontend/index/window.nim` is written exactly that way.
  ##
  ## Emptiness is tested AFTER normalising: `import ""` names nothing, and an
  ## empty spec downstream would resolve against every root as the directory
  ## itself.
  let s = normalizeSpec(cutKeywords(spec.strip(), ["as"]), path)
  if s.len > 0:
    into.add(s)

proc handleStatement(stmt, path: string; pending: var string;
                     into: var seq[string]) =
  ## One statement, fed either from a whole line or from one `;`-separated
  ## piece of it.
  ##
  ## Owns the multi-line buffering: `pending` says whether a bracket list or a
  ## bare `import` is still waiting for the lines beneath it.
  var trimmed = stmt
  if pending.len == 0:
    trimmed = stripConditionalPrefix(trimmed)
    if trimmed.startsWith("import ") or trimmed.startsWith("from ") or
       trimmed.startsWith("include ") or trimmed == "import" or
       trimmed == "include":
      pending = trimmed
    else:
      return
  else:
    if trimmed.len == 0:
      return
    pending = pending & " " & trimmed
  if pending in ["import", "include", "from"]:
    return
  if pending.countOutsideQuotes('[') != pending.countOutsideQuotes(']') or
     pending.endsWith(",") or pending.endsWith("["):
    return

  block:
    var body = pending
    if body.startsWith("from "):
      body = body[5 .. ^1]
      # `from "a/b"import c` needs no space either, so the `import` that ends
      # the module part is found the same way `as` and `except` are.
      body = body.cutKeywords(["import"])
    elif body.startsWith("import "):
      body = body[7 .. ^1]
    elif body.startsWith("include "):
      body = body[8 .. ^1]
    body = body.cutKeywords(["except"])

    # Split on top-level commas, then expand `prefix/[a, b]`. "Top-level"
    # means outside `[ ]` AND outside a string literal: `import "a,b"` is one
    # module whose name contains a comma, not two modules.
    var depth = 0
    var inQuote = false
    var item = ""
    var items: seq[string] = @[]
    for ch in body & ",":
      if ch == '"':
        inQuote = not inQuote
      elif not inQuote:
        if ch == '[': inc depth
        elif ch == ']': dec depth
      if ch == ',' and depth == 0 and not inQuote:
        if item.strip().len > 0:
          items.add(item.strip())
        item = ""
      else:
        item.add(ch)
    for raw in items:
      let spec = raw.strip()
      # The bracket test is anchored at the end, and that now carries a second
      # meaning: `import "a/[b]"` ends in a QUOTE, so it is one module whose
      # name contains brackets (which nim then fails to open) rather than a
      # bracket list, and expanding it would invent a module nobody imported.
      # `import "a/b"/[c, d]` does end in `]`, is expanded, and is normalised
      # afterwards.
      if spec.endsWith("]") and spec.contains('['):
        let open = spec.find('[')
        var prefix = spec[0 ..< open].strip()
        if prefix.endsWith("/"):
          prefix = prefix[0 ..< prefix.len - 1].strip()
        let inner = spec[open + 1 ..< spec.rfind(']')]
        for part in inner.split(','):
          let p = part.strip()
          if p.len > 0:
            emitSpec(prefix & "/" & p, path, into)
      elif spec.len > 0:
        emitSpec(spec, path, into)
    pending = ""

proc importSpecs(path: string): seq[string] =
  ## Every module spec a Nim file imports.
  ##
  ## Lexical, and it mirrors `ci/test/sdk-facade-boundary.sh`'s extractor
  ## rather than inventing a second dialect: `import a`, `import a, b`,
  ## `import a/b`, `import a/[b, c]`, `from a/b import c`, `include a`,
  ## `import a as b`, `import a except c`, and the indented continuation lines
  ## a bracket list may spread over — each of those with the spec written bare
  ## or as a string literal (`import "a/b"`, `import "a/b" as c`,
  ## `from "a/b" import c`, `include "a/b"`, `import a, "b/c"`,
  ## `import "a/b"/[c, d]`, `import "a"/b/c`, `import a/"b"/c`,
  ## `import r"a/b"`, `import """a/b"""`), with or without the space a quoted
  ## spec makes optional (`import "a/b"as c`, `import "a/b"except d`,
  ## `from "a/b"as c import d`), and with or without the whitespace `/` allows
  ## around itself (`import a / b / c`, `import "a" / "b" / "c"`) — all of
  ## which `normalizeSpec` reduces to one spelling.
  ##
  ## A LINE IS NOT A STATEMENT, AND THAT IS WHERE TWO IMPORTS USED TO VANISH.
  ## `;` separates statements, so `import a; import b` is two of them
  ## (`splitStatements`), and `when`/`elif`/`else` may carry one on the same
  ## line as the condition (`stripConditionalPrefix`). Both compile, both are
  ## idiomatic — `when not defined(js): import a` especially — and at HEAD both
  ## yielded NOTHING AT ALL for the line, which is a miss and not an
  ## over-report.
  result = @[]
  var pending = ""
  for rawLine in readFile(path).splitLines():
    var openedBlockComment = false
    let line = stripComment(rawLine, openedBlockComment)
    # THE TWO BLOCK-COMMENT SHAPES THAT WOULD OTHERWISE HIDE AN IMPORT. Both
    # are refused rather than parsed, for the same reason the backslash case is
    # (see `normalizeSpec`): a wrong guess here is a silent MISS.
    if openedBlockComment and
       (pending.len > 0 or line.strip().startsStatement()):
      raise newException(UnanalysableSpec,
        path & ": the import statement " & rawLine.strip() & " runs into a " &
        "block comment that does not close on the same line. This lexical " &
        "extractor tracks no cross-line comment state — doing so would let a " &
        "`#[` inside a multi-line string literal swallow the rest of the " &
        "file — so the statement is refused instead of guessed at. Close the " &
        "comment on the line, or move it off the import.")
    if rawLine.resumesAfterBlockComment():
      raise newException(UnanalysableSpec,
        path & ": the import statement " & rawLine.strip() & " resumes after " &
        "a block comment that opened on an earlier line. A closing " &
        "bracket-hash followed by an import statement IS an import, and this " &
        "lexical extractor starts every line outside any comment, so it is " &
        "refused rather than read as `]`. Put the import on a line of its own.")
    if pending.len == 0 and conditionalImportUnread(rawLine, line):
      raise newException(UnanalysableSpec,
        path & ": the one-line conditional " & rawLine.strip() & " carries an " &
        "import statement that this lexical extractor could not read out of " &
        "it. The usual cause is a character literal in the condition — a " &
        "hash, a semicolon or a double-quote inside one lands this scan's " &
        "comment cut, statement split or quote parity inside the literal. A " &
        "string on the line that merely CONTAINS the words will trip it too, " &
        "and that is the deliberate trade: this check is quote-blind so an " &
        "inverted quote parity cannot hide behind it. Refusing is the point — " &
        "the alternative is reading the line as carrying no import at all. " &
        "Put the import on a line of its own.")
    for stmt in splitStatements(line):
      handleStatement(stmt.strip(), path, pending, result)

proc isUnder(path, dir: string): bool =
  ## Is `path` inside `dir`?
  ##
  ## `startsWith(dir)` alone is wrong and quietly so: it makes
  ## `src/frontend/tui-notes/x.nim` look like a member of `src/frontend/tui`.
  ## The separator is what makes it a containment test rather than a prefix one.
  path == dir or path.startsWith(dir & DirSep)

proc specSpellings*(file, scanRoot: string): seq[string] =
  ## Every module spec that can resolve to `file` through Nim's module path.
  ##
  ## Nim joins an import spec onto each root on the search path, so a root can
  ## only resolve `spec` to `file` if that root is an ANCESTOR DIRECTORY of
  ## `file` and `spec` is the path from it. Enumerating the ancestors is
  ## therefore exhaustive over roots — including roots this file does not know
  ## about, which is the property that matters, because `config.nims`, the lane
  ## flags and any future `--path` all add roots without telling this test.
  ##
  ## Bounded at `scanRoot`: above the tree being scanned there is nothing this
  ## suite is entitled to make claims about, and a root above the repository
  ## would make every module in it ambiguous anyway.
  result = @[]
  let target = normalizedPath(file)
  let bound = normalizedPath(scanRoot)
  var dir = target.parentDir
  while true:
    var rel = target.relativePath(dir)
    when DirSep != '/':
      rel = rel.replace(DirSep, '/')
    if rel.endsWith(".nim"):
      rel.setLen(rel.len - len(".nim"))
    if rel.len > 0 and rel notin result:
      result.add(rel)
    let parent = dir.parentDir
    if dir == bound or parent == dir:
      break
    dir = parent

proc searchRoots(tuiTree, scanRoot: string): seq[string] =
  ## The directories an intra-tree import may be resolved against.
  ##
  ## Same argument as `specSpellings`, used for FOLLOWING edges rather than for
  ## grading them: any root that resolves to a file inside `tuiTree` is an
  ## ancestor of that file, so the chain from `tuiTree` up to `scanRoot` covers
  ## every root that can reach the tree from outside it.
  result = @[]
  var dir = normalizedPath(tuiTree)
  let bound = normalizedPath(scanRoot)
  while true:
    result.add(dir)
    let parent = dir.parentDir
    if dir == bound or parent == dir:
      break
    dir = parent

proc resolveWithin(spec, importer, tree: string; roots: seq[string]): string =
  ## Where `spec` resolves inside `tree`, or "" when it points outside it.
  ##
  ## The importer's own directory first — Nim's relative rule, and how every
  ## intra-tree import in `src/frontend/tui/` is written today — then every
  ## module-path root that could reach the tree. Both are needed: dropping the
  ## second is exactly the hole that let `import tui/host/native_host` compile
  ## with this suite green.
  for base in @[importer.parentDir] & roots:
    let candidate = normalizedPath(base / (spec & ".nim"))
    if fileExists(candidate) and candidate.isUnder(tree):
      return candidate
  ""

proc forbiddenFileSpecs(scanRoot: string; files: seq[string]): seq[string] =
  ## Every spelling of every module in `files`, for the files that exist.
  ##
  ## `files` are the product modules the Embed SDK facade withholds. They live
  ## OUTSIDE the scanned tree, so they are never reached by the traversal — but
  ## they are reachable by an import, and by more spellings than the four a
  ## reviewer would think to write down (`headless_session`,
  ## `viewmodel/headless_session`, `frontend/viewmodel/headless_session`,
  ## `src/frontend/viewmodel/headless_session`, and — via the importer — any
  ## `../…` path to the same file).
  result = @[]
  for f in files:
    if fileExists(f):
      for s in specSpellings(f, scanRoot):
        if s notin result:
          result.add(s)

proc scanAppTree*(appDir, tuiTree, hostDir, scanRoot: string;
                  facadeWithheld: seq[string] = @[]): ScanResult =
  ## Walk `appDir`, following only edges that stay inside `tuiTree`, and report
  ## every forbidden edge.
  ##
  ## Takes its roots as parameters rather than deriving them, which is what
  ## makes the mutation arms possible: the same code that grades this repository
  ## grades a planted copy of it.
  result = ScanResult(files: @[], edges: @[], violations: @[])

  # Every spelling that lands under `host/`, computed once. This is the rule
  # that replaced "the spec is written relative to the importer".
  var hostSpecs: seq[string] = @[]
  if hostDir.len > 0:
    for path in walkDirRec(hostDir):
      if path.endsWith(".nim"):
        for s in specSpellings(path, scanRoot):
          if s notin hostSpecs:
            hostSpecs.add(s)
  let withheldSpecs = forbiddenFileSpecs(scanRoot, facadeWithheld)
  let roots = searchRoots(tuiTree, scanRoot)

  var queue: seq[string] = @[]
  for path in walkDirRec(appDir):
    if path.endsWith(".nim"):
      queue.add(normalizedPath(path))
  sort(queue)
  var seen = queue
  var i = 0
  while i < queue.len:
    let file = queue[i]
    inc i
    result.files.add(file)
    for spec in importSpecs(file):
      result.edges.add(ImportEdge(file: file, spec: spec))
      var reported = false

      for forbidden in ForbiddenSpecs:
        if spec == forbidden:
          result.violations.add(Violation(
            file: file, spec: spec,
            reason: "app/ may not import '" & forbidden &
                    "'; that capability lives in src/frontend/tui/host/"))
          reported = true

      if not reported and spec in withheldSpecs:
        result.violations.add(Violation(
          file: file, spec: spec,
          reason: "app/ may not import a module the Embed SDK facade withholds" &
                  "; that capability lives in src/frontend/tui/host/"))
        reported = true

      # The host rule, by RESOLUTION rather than by spelling: either the spec
      # is one of the ancestor-relative names of a host module, or it resolves
      # against the importer to a file under `host/`.
      let resolved = resolveWithin(spec, file, tuiTree, roots)
      let hitsHost = hostDir.len > 0 and
        (spec in hostSpecs or (resolved.len > 0 and resolved.isUnder(hostDir)))
      if hitsHost:
        if not reported:
          result.violations.add(Violation(
            file: file, spec: spec,
            reason: "app/ may not import the host layer (resolves under " &
                    hostDir & ")"))
        continue

      if resolved.len == 0:
        continue
      if resolved notin seen:
        seen.add(resolved)
        queue.add(resolved)

proc describe(vs: seq[Violation]): string =
  vs.mapIt(it.file & " imports '" & it.spec & "': " & it.reason).join("; ")

proc copyTree(src, dst: string) =
  createDir(dst)
  for path in walkDirRec(src):
    let rel = path.relativePath(src)
    createDir((dst / rel).parentDir)
    copyFile(path, dst / rel)

type MutantTree = object
  ## A throwaway copy of the TUI's two layers, laid out exactly as the
  ## repository lays them out.
  ##
  ## The layout is not cosmetic. `tui/host/native_host` is only a spelling of
  ## the host module when a `src/frontend` exists above it for a module-path
  ## root to sit on, so a flat `<tmp>/{app,host}` could not host the third
  ## mutation arm at all — and an arm that cannot express the evasion is not an
  ## arm.
  root*: string     ## the scan root; stands in for the repo root
  tuiTree*: string
  appDir*: string
  hostDir*: string

proc newMutantTree(appDir, hostDir, tag: string): MutantTree =
  let tmp = getTempDir() / ("ctui0-facade-" & tag & "-" & $getCurrentProcessId())
  removeDir(tmp)
  result = MutantTree(
    root: tmp,
    tuiTree: normalizedPath(tmp / "src" / "frontend" / "tui"),
    appDir: normalizedPath(tmp / "src" / "frontend" / "tui" / "app"),
    hostDir: normalizedPath(tmp / "src" / "frontend" / "tui" / "host"))
  copyTree(appDir, result.appDir)
  copyTree(hostDir, result.hostDir)

proc scanMutant(m: MutantTree): ScanResult =
  ## Grade the mutant with the SAME checker that grades this repository.
  ## Named apart from the suite's `scan` value so method-call syntax cannot
  ## resolve to a shadowing local.
  scanAppTree(m.appDir, m.tuiTree, m.hostDir, m.root)

suite "CTUI-0: the app/ layer stays inside the Embed SDK facade":

  let root = repoRoot()
  let tuiTree = normalizedPath(root / "src" / "frontend" / "tui")
  let appDir = normalizedPath(tuiTree / "app")
  let hostDir = normalizedPath(tuiTree / "host")

  # The two modules `codetracer_embed` deliberately withholds, named as FILES
  # so that every spelling resolving to them is a violation rather than only
  # the ones written into `ForbiddenSpecs`.
  let facadeWithheld = @[
    normalizedPath(root / "src" / "frontend" / "viewmodel" / "headless_session.nim"),
    normalizedPath(root / "src" / "frontend" / "viewmodel" / "backend" /
                   "stdio_backend.nim")]

  let scan = scanAppTree(appDir, tuiTree, hostDir, root, facadeWithheld)

  test "the walk reached the app/ tree":
    # THE POSITIVE CONTROL, and it comes first because everything after it is
    # a universal quantification that an empty scan satisfies for free
    # (Verification-Harness-Traps §4). The count is asserted rather than
    # non-emptiness, because the membership is knowable: it is the set of
    # `.nim` files in the directory (§4b).
    var onDisk: seq[string] = @[]
    for path in walkDirRec(appDir):
      if path.endsWith(".nim"):
        onDisk.add(path)
    checkpoint("app/ modules on disk: " & $onDisk.len)
    checkpoint("modules walked: " & $scan.files.len)
    checkpoint("import edges read: " & $scan.edges.len)
    ck onDisk.len >= 2
    ck scan.files.len == onDisk.len
    ck scan.edges.len >= scan.files.len

  test "the extractor actually reads imports, not just files":
    # The positive twin of every negative assertion below. If `importSpecs`
    # stopped parsing — a changed dialect, a bad slice — the forbidden-edge
    # checks would go on passing over an empty set of edges, and only this
    # goes red.
    let specs = scan.edges.mapIt(it.spec)
    checkpoint("specs: " & specs.deduplicate().join(", "))
    ck "codetracer_embed" in specs
    ck "headless_app/headless_app" in specs
    ck "isonim_tui" in specs

  test "quoted specs are read as the modules they name":
    # THE LEXICAL RULE, ASSERTED FORM BY FORM RATHER THAN ONLY THROUGH THE
    # MUTATION ARMS BELOW. Those arms plant two spellings; this is the list they
    # are drawn from, and the list is the compiler's rather than a guess — every
    # line here was compiled against nim 2.2.8 and resolved to the module it
    # names through the same `--path` before it was written down.
    #
    # Nothing in this repository writes the quoted form today, which is exactly
    # why it needs a test of its own: the scan above cannot exercise a form the
    # tree does not contain, so without this the extractor could lose the
    # handling again and every other assertion in this file would stay green.
    const quotedForms = """
import "tui/host/native_host"
import "tui/host/native_host" as nh
from "tui/host/native_host" import HostThing
from "tui/host/native_host" as nh2 import HostThing
include "tui/host/native_host"
import "tui/host/native_host" except HostThing
import codetracer_embed, "tui/host/native_host"
import "tui/host"/[native_host, other_host]
import "tui"/host/native_host
import tui/"host"/native_host
import r"tui/host/native_host"
import
  "tui/host/native_host"
import "tui/host/native_host"as nh3
import "tui/host/native_host"except HostThing
from "tui/host/native_host"as nh4 import HostThing
import tui / host / native_host
import "tui" / "host" / "native_host"
import "tui/host/session_recorder"
import "h#d/../tui/host/native_host"
import "tui/host/[native_host]"
"""
    # `import """a/b"""` cannot be written inside a triple-quoted literal — the
    # three quotes would close it — so it is assembled from its pieces.
    let tripleQuoted = "import " & repeat('"', 3) & "tui/host/native_host" &
                       repeat('"', 3) & "\n"
    let probeDir = getTempDir() / ("ctui0-quoted-" & $getCurrentProcessId())
    removeDir(probeDir)
    createDir(probeDir)
    let probe = probeDir / "probe.nim"
    writeFile(probe, quotedForms & tripleQuoted)
    let quoted = importSpecs(probe)
    checkpoint("specs read from the quoted probe: " & quoted.join(", "))
    # Eighteen lines name the host module exactly; the last three deliberately
    # name something else.
    ck quoted.count("tui/host/native_host") == 18
    # The bracket list was expanded even though its prefix was a string literal.
    ck "tui/host/other_host" in quoted
    # And the unquoted neighbour on a mixed line survived the split.
    ck "codetracer_embed" in quoted
    # THE LAST LETTER SURVIVED. `session_recorder` ends in `r`, and the `r` of a
    # raw string literal belongs to the quote that OPENS one. A strip that drops
    # `r` before any quote eats this one and yields `tui/host/session_recorde`,
    # which equals no host spelling and resolves to no file — the hole reopened,
    # for every module in the tree whose name ends in `r`.
    ck "tui/host/session_recorder" in quoted
    # A `#` INSIDE THE LITERAL IS A FILENAME CHARACTER. Nim requires only the
    # BASENAME of a module path to be a valid identifier, so this compiles and
    # imports the host module; a comment-stripper that cut at the first `#`
    # yielded `h` and reported nothing at all.
    ck "h#d/../tui/host/native_host" in quoted
    # `import "a/[b]"` is NOT a bracket list: inside quotes the brackets are
    # part of a filename, and that spelling does not compile. Expanding it would
    # invent a module nobody imported, so it stays whole.
    ck "tui/host/[native_host]" in quoted
    # The two properties the rules downstream depend on: no spec still carries
    # the syntax it was written with, and none carries the whitespace nim allows
    # around the `/` separator.
    ck not quoted.anyIt(it.contains('"'))
    ck not quoted.anyIt(it.contains(' ') or it.contains('\t'))

    # A `[` INSIDE THE LITERAL IS A FILENAME CHARACTER TOO, and getting that
    # wrong is a miss of a different shape: the statement never balances, so
    # every following line is glued onto it and the NEXT import is never seen
    # as a statement at all. (The compiling form puts the bracket in a
    # directory component — `import "a[b/../../src/…/codetracer_embed"` builds
    # — because nim requires only the basename to be a valid identifier.)
    let unbalanced = probeDir / "unbalanced.nim"
    writeFile(unbalanced, "import \"a[b/../tui/host/native_host\"\n" &
                          "import tui/host/other_host\n")
    let afterBracket = importSpecs(unbalanced)
    checkpoint("specs read past the unbalanced bracket: " & afterBracket.join(", "))
    ck afterBracket == @["a[b/../tui/host/native_host", "tui/host/other_host"]
    removeDir(probeDir)

  test "a spec written with string escapes is refused, not guessed at":
    # THE ONE FORM THIS EXTRACTOR WILL NOT READ, AND IT SAYS SO.
    # `import "tui\x2Fhost\x2Fnative_host"` compiles and imports the host
    # module: `\x2F` is a Nim escape for `/`. Decoding that here would mean
    # implementing Nim's escape rules — which differ between `"..."`, `r"..."`
    # and `"""..."""` — twice, here and in awk, where being subtly wrong is a
    # MISS. Emitting the raw text is worse still: `tui\x2Fhost\x2Fnative_host`
    # equals no host spelling and resolves to no file, so the import passes in
    # silence. So it raises, and this suite goes red naming the statement.
    #
    # Asserted for both escape syntaxes that spell `/`, hex and decimal, since
    # a check written against `\x` alone would be satisfied by a guard that
    # only knew that one.
    let probeDir = getTempDir() / ("ctui0-escaped-" & $getCurrentProcessId())
    removeDir(probeDir)
    createDir(probeDir)
    for spec in ["\"tui\\x2Fhost\\x2Fnative_host\"",
                 "\"tui\\47host\\47native_host\""]:
      let probe = probeDir / "probe.nim"
      writeFile(probe, "import " & spec & "\n")
      var raised = false
      var message = ""
      try:
        # A finding here would BE the bug: it would mean the extractor emitted
        # something for a statement it cannot read.
        checkpoint("specs read from `import " & spec & "`: " &
                   importSpecs(probe).join(", "))
      except UnanalysableSpec as e:
        raised = true
        message = e.msg
      ck raised
      # The message has to be actionable on its own, so it names the file and
      # the statement rather than only the rule.
      ck message.contains(probe)
      ck message.contains(spec)
    removeDir(probeDir)

  test "a statement is not a line: ';' and one-line 'when' carry imports too":
    # THE SECOND LEXICAL RULE, and the one that had nothing to do with quoting.
    # Every line below compiles (nim 2.2.8, checked by compiling it and then
    # USING a symbol from the imported module, so the import is real and not
    # merely parsed), and at HEAD every one of them yielded NOTHING AT ALL —
    # not a wrong spec, not an over-report, silence. That is the outcome a
    # boundary lint may not produce.
    #
    # `when not defined(js): import x` is the one that matters in practice: it
    # is idiomatic Nim, this repository's own multi-line spelling of it WAS
    # handled, and the comments claiming so made the one-liner read as covered.
    const statementForms = """
import tui/host/native_host; import codetracer_embed
import codetracer_embed; import tui/host/native_host
echo 1; import tui/host/native_host
when not defined(js): import tui/host/native_host
when defined(js):
  discard
elif true: import tui/host/native_host
when defined(js):
  discard
else: import tui/host/native_host
when(true):import tui/host/native_host
when true: import codetracer_embed; import tui/host/native_host
when {1: 2}.len > 0: import tui/host/native_host
when "a;b" == "a;b": import tui/host/native_host
when (let x = 1; x > 0): import tui/host/native_host
when true: from tui/host/native_host import HostThing
when true: include tui/host/native_host
when true: (when true: import tui/host/native_host)
import tui/host/native_host;
import #[ which one? ]# tui/host/native_host
import tui/host/native_host #[ trailing ]#
"""
    let probeDir = getTempDir() / ("ctui0-statements-" & $getCurrentProcessId())
    removeDir(probeDir)
    createDir(probeDir)
    let probe = probeDir / "probe.nim"
    writeFile(probe, statementForms)
    let specs = importSpecs(probe)
    checkpoint("specs read from the statement probe: " & specs.join(", "))
    # Seventeen lines name the host module; three of them name the facade
    # beside it, on the far side of a `;`, and those three are what prove the
    # split kept BOTH statements rather than only the one a tail-or-head rule
    # would keep.
    ck specs.count("tui/host/native_host") == 17
    ck specs.count("codetracer_embed") == 3
    # The separator never survives into a spec. `a;importb` is what the whole
    # line looked like at HEAD: one module nobody has, so both imports lost.
    ck not specs.anyIt(it.contains(';'))

    # THE NEGATIVE HALF. Widening what counts as a statement is exactly the
    # change that starts reporting imports nobody wrote, and a guard that
    # reports a commented-out line is one people switch off.
    let commented = probeDir / "commented.nim"
    writeFile(commented, "# when true: import tui/host/native_host\n" &
                         "# import a; import tui/host/native_host\n" &
                         "import codetracer_embed\n")
    ck importSpecs(commented) == @["codetracer_embed"]
    removeDir(probeDir)

  test "an import split by a multi-line block comment is refused, not guessed at":
    # A BLOCK COMMENT IS NOT A LINE COMMENT, and `import #[c]# a/b` compiles.
    # A stripper that cut at the first `#` turned that into `import`, which
    # names nothing — so block comments are REMOVED, nesting and all, when they
    # open and close on one line. The positive control below is that half.
    #
    # When one SPANS lines there is no honest lexical answer. Tracking comment
    # state across lines would let a `#[` inside a multi-line string literal
    # swallow every import after it — a miss of a whole file, which is worse
    # than the miss being fixed. So both spanning shapes raise instead.
    let probeDir = getTempDir() / ("ctui0-blockcomment-" & $getCurrentProcessId())
    removeDir(probeDir)
    createDir(probeDir)

    # POSITIVE CONTROL FIRST: the comment that closes on its own line is
    # removed, and the import behind it is read normally.
    let sameLine = probeDir / "same_line.nim"
    writeFile(sameLine, "import #[ which one? ]# tui/host/native_host\n" &
                        "import tui/host/other_host #[ nested #[x]# ]#\n")
    let read = importSpecs(sameLine)
    checkpoint("specs read past same-line block comments: " & read.join(", "))
    ck read == @["tui/host/native_host", "tui/host/other_host"]

    # `runs into` — the comment opens on the import's own line.
    # `resumes after` — the comment opened earlier and the import follows its
    # close on the same line, where cutting at the first `#` leaves `]`.
    # The `resumes-after` source is ASSEMBLED rather than written out, and that
    # is not fastidiousness: this file is itself one of the 998 the extractor
    # walks, and a literal `]` `#` `import` here would be indistinguishable
    # from the thing it describes — the refusal would fire on this very file.
    let resumesAfter = "#[ a comment\n]" & "#import tui/host/native_host\n"
    for (tag, source) in [
      ("runs-into", "import tui/host/native_host #[ why this one\nand not the other ]#\n"),
      ("resumes-after", resumesAfter)]:
      let probe = probeDir / (tag & ".nim")
      writeFile(probe, source)
      var raised = false
      var message = ""
      try:
        # Reaching here at all would BE the bug: a spec emitted for a statement
        # this extractor cannot read is the silent miss, dressed as a result.
        checkpoint("specs read from the " & tag & " probe: " &
                   importSpecs(probe).join(", "))
      except UnanalysableSpec as e:
        raised = true
        message = e.msg
      ck raised
      ck message.contains(probe)
      ck message.contains("block comment")
    removeDir(probeDir)

  test "a one-line conditional this lexer cannot read is refused, not skipped":
    # THE SELF-CHECK, AND THE REASON THE CLAIM ABOVE IS BOUNDED RATHER THAN
    # TOTAL. `stripConditionalPrefix` decides where the condition ends by
    # looking at what follows each colon, which is right for every condition
    # shape nim allows EXCEPT one: a character literal. This extractor models
    # double-quoted strings and nothing else, so a character literal holding a
    # `#`, a `;` or a `"` lands the comment cut, the statement split or the
    # quote parity inside itself.
    #
    # All three compile. All three were a silent miss. None of them is fixed by
    # a cleverer scan that this file could then be wrong about in a new way —
    # `1'u8` is not a character literal, and a scanner told to skip `'…'` would
    # eat that. So the extractor asserts on ITSELF instead: a line that visibly
    # has an import on it and yielded none is refused by name.
    let probeDir = getTempDir() / ("ctui0-selfcheck-" & $getCurrentProcessId())
    removeDir(probeDir)
    createDir(probeDir)
    for source in ["when '#' == '#': import tui/host/native_host\n",
                   "when ';' == ';': import tui/host/native_host\n",
                   "when '\"' == 'x': import tui/host/native_host\n"]:
      let probe = probeDir / "probe.nim"
      writeFile(probe, source)
      var raised = false
      var message = ""
      try:
        # A finding here would BE the bug. So would an empty result: this is
        # the one place where "no specs" is the failure being tested for.
        checkpoint("specs read from " & source.strip() & ": " &
                   importSpecs(probe).join(", "))
      except UnanalysableSpec as e:
        raised = true
        message = e.msg
      ck raised
      ck message.contains(probe)

    # THE NEGATIVE HALF: the check keys on an import being visible, so a
    # conditional that carries something else is not refused, and neither is a
    # conditional the extractor reads correctly.
    let quiet = probeDir / "quiet.nim"
    writeFile(quiet, "when '#' == '#': echo 1\n" &
                     "when not defined(js): import tui/host/native_host\n")
    ck importSpecs(quiet) == @["tui/host/native_host"]
    removeDir(probeDir)

  test "no app/ module reaches the host layer or a host capability":
    if scan.violations.len > 0:
      checkpoint(describe(scan.violations))
    ck scan.violations.len == 0

  test "host/ is NOT a declared SDK consumer":
    # The exemption, asserted from this side too. `ci/test/sdk-facade-
    # boundary.sh` discovers consumers by marker, so a `.sdk-consumer` file
    # placed at `src/frontend/tui/` — one directory up, an easy and plausible
    # mistake — would silently enrol `host/` and make that guard fail for a
    # reason nobody would connect to this rule.
    ck fileExists(appDir / ".sdk-consumer")
    ck not fileExists(hostDir / ".sdk-consumer")
    ck not fileExists(tuiTree / ".sdk-consumer")

  test "host/ really does hold the capabilities app/ may not":
    # Without this the boundary could be satisfied by a host layer that reaches
    # nothing — a rule about a distinction that had stopped existing. This is
    # the same shape as trap 4a's "positive twin": the negative assertion above
    # and this positive one run through the same extractor.
    var hostSpecs: seq[string] = @[]
    for path in walkDirRec(hostDir):
      if path.endsWith(".nim"):
        hostSpecs.add(importSpecs(path))
    checkpoint("host/ specs: " & hostSpecs.deduplicate().join(", "))
    ck "headless_session" in hostSpecs
    ck "std/posix" in hostSpecs or "posix" in hostSpecs

  test "the resolver knows every spelling the module path gives host/":
    # THE POSITIVE CONTROL ON THE RULE ITSELF, and the reason the three
    # mutation arms below are not the only evidence: they plant three
    # spellings, and this asserts that the set the checker computed is the
    # complete one those three are drawn from. A `specSpellings` that returned
    # only the basename would still make the `../host/…` arm go red, and
    # nothing else in the file would notice.
    var hostSpecs: seq[string] = @[]
    for path in walkDirRec(hostDir):
      if path.endsWith(".nim"):
        for s in specSpellings(path, root):
          if s notin hostSpecs:
            hostSpecs.add(s)
    checkpoint("host spellings: " & hostSpecs.join(", "))
    # Bare, for a `--path` pointing at `host/` itself.
    ck "native_host" in hostSpecs
    # Relative to `src/frontend/tui/`.
    ck "host/native_host" in hostSpecs
    # Relative to `src/frontend`, which `config.nims` puts on the module path.
    # THIS IS THE ONE THE FIRST VERSION OF THIS FILE COULD NOT SEE.
    ck "tui/host/native_host" in hostSpecs
    # And relative to the checkout, for a `--path:.`.
    ck "src/frontend/tui/host/native_host" in hostSpecs

  test "MUTATION: a planted 'import std/osproc' in app/ is detected":
    # THE ARM THAT PROVES THE DETECTOR DETECTS. A green run of the tests above
    # is compatible with a checker that cannot fail; this is what separates the
    # two, and it is a deliverable of CTUI-0 rather than a demonstration.
    let m = newMutantTree(appDir, hostDir, "osproc")

    # CONTROL FIRST: the copy, unmutated, must be clean. Without this a
    # positive result below could equally mean "the temporary tree confuses the
    # checker", which is a hang wearing a mutation's label.
    let control = m.scanMutant()
    if control.violations.len > 0:
      checkpoint("control copy was not clean: " & describe(control.violations))
    ck control.violations.len == 0
    ck control.files.len == scan.files.len

    let victim = normalizedPath(m.appDir / "tui_app.nim")
    ck fileExists(victim)
    writeFile(victim, readFile(victim) & "\nimport std/osproc\n")

    let mutated = m.scanMutant()
    checkpoint("violations after planting std/osproc: " &
               describe(mutated.violations))
    ck mutated.violations.len == 1
    ck mutated.violations.anyIt(it.spec == "std/osproc")
    ck mutated.violations.anyIt(it.file == victim)
    removeDir(m.root)

  test "MUTATION: a planted importer-relative host import is detected":
    # A DIFFERENT RULE, so it needs its own arm: the spec list would not catch
    # `../host/native_host`, which names no forbidden module at all — it is
    # caught by resolving the spec against the importer, and only an arm that
    # plants it can show that half works.
    let m = newMutantTree(appDir, hostDir, "host-edge")

    let control = m.scanMutant()
    if control.violations.len > 0:
      checkpoint("control copy was not clean: " & describe(control.violations))
    ck control.violations.len == 0
    ck control.files.len == scan.files.len

    let victim = normalizedPath(m.appDir / "cli.nim")
    ck fileExists(victim)
    writeFile(victim, readFile(victim) & "\nimport ../host/native_host\n")

    let mutated = m.scanMutant()
    checkpoint("violations after planting '../host/native_host': " &
               describe(mutated.violations))
    ck mutated.violations.len == 1
    ck mutated.violations.anyIt(it.reason.contains("host layer"))
    ck mutated.violations.anyIt(it.file == victim)
    removeDir(m.root)

  test "MUTATION: a planted 'import tui/host/native_host' is detected":
    # THE EVASION THIS FILE WAS FOUND TO BE OPEN TO, and therefore the arm that
    # matters most here. `config.nims` puts `src/frontend` on the module path,
    # so this spelling COMPILES from `app/tui_app.nim`, reaches the host layer,
    # and is relative to no importer — the earlier rule looked only at the
    # importer's own directory and reported nothing. It is caught now because
    # the checker enumerates the ancestor-relative spellings of every host
    # module instead of the one spelling the TUI happens to use.
    let m = newMutantTree(appDir, hostDir, "path-root")

    let control = m.scanMutant()
    if control.violations.len > 0:
      checkpoint("control copy was not clean: " & describe(control.violations))
    ck control.violations.len == 0
    ck control.files.len == scan.files.len

    let victim = normalizedPath(m.appDir / "tui_app.nim")
    ck fileExists(victim)
    writeFile(victim, readFile(victim) & "\nimport tui/host/native_host\n")

    let mutated = m.scanMutant()
    checkpoint("violations after planting 'tui/host/native_host': " &
               describe(mutated.violations))
    ck mutated.violations.len == 1
    ck mutated.violations.anyIt(it.reason.contains("host layer"))
    ck mutated.violations.anyIt(it.file == victim)
    removeDir(m.root)

  test "MUTATION: a planted 'import \"tui/host/native_host\"' is detected":
    # THE SAME IMPORT AS THE ARM ABOVE, IN QUOTATION MARKS — and it was a
    # separate evasion, not a variant of that one. The arm above is about which
    # module-path root the spec is written against, and the ancestor rule
    # answers it. This one is about the LEXER underneath every rule: the spec
    # arrived as `"tui/host/native_host"`, with the quotes still attached, so it
    # equalled no host spelling and resolved to no file, and the checker had
    # nothing to report. Planted in the real `app/tui_app.nim` it compiled and
    # left this suite AND `ci/test/sdk-facade-boundary.sh` green while six other
    # spellings of the same import went red by name.
    #
    # `normalizeSpec` is what makes it fail now, and it is worth being explicit
    # about where the fix sits: not in this rule, but in the one place both
    # extractors turn a line of source into a spec — so no rule downstream, here
    # or in the repo-wide guard, has to know that quotation marks exist.
    let m = newMutantTree(appDir, hostDir, "quoted-spec")

    let control = m.scanMutant()
    if control.violations.len > 0:
      checkpoint("control copy was not clean: " & describe(control.violations))
    ck control.violations.len == 0
    ck control.files.len == scan.files.len

    let victim = normalizedPath(m.appDir / "tui_app.nim")
    ck fileExists(victim)
    writeFile(victim, readFile(victim) & "\nimport \"tui/host/native_host\"\n")

    let mutated = m.scanMutant()
    checkpoint("violations after planting 'import \"tui/host/native_host\"': " &
               describe(mutated.violations))
    ck mutated.violations.len == 1
    ck mutated.violations.anyIt(it.reason.contains("host layer"))
    ck mutated.violations.anyIt(it.file == victim)
    removeDir(m.root)

  test "MUTATION: a planted quoted host import whose name ends in 'r' is detected":
    # THE ARM THE ONE ABOVE STRUCTURALLY CANNOT BE, and that is the reason it
    # exists rather than being folded into it.
    #
    # Unquoting has one easy way to be wrong: the `r` of a raw string literal
    # has to leave with the quote it OPENS, and a strip that drops `r` whenever
    # a quote follows it takes the closing quote's `r` too. Every quoted spec
    # whose module name ends in `r` then loses that letter —
    # `tui/host/session_recorder` becomes `tui/host/session_recorde`, which
    # equals no host spelling and resolves to no file, and the quoted form is
    # once more the way past this rule. It is not hypothetical: run over all 998
    # tracked Nim files, that mistake truncated a real one —
    # `docs/book-isonim/src/ssr.nim`'s `"../../../../isonim-docs/src/ssr"` came
    # back as `.../src/ss`.
    #
    # `native_host` ends in `t`, so the arm above stays green through all of
    # that. This one cannot: its victim module is named for the letter. The host
    # module is CREATED in the mutant tree because this repository has no
    # `r`-final host module today — the arm has to be able to express the
    # evasion, and inventing the module is honest where inventing the finding
    # would not be.
    let m = newMutantTree(appDir, hostDir, "quoted-r")
    let plantedHost = normalizedPath(m.hostDir / "session_recorder.nim")
    writeFile(plantedHost, """
## A host module whose name ends in `r`, for the mutation arm below.
const SessionRecorderVersion* = 1
""")

    let control = m.scanMutant()
    if control.violations.len > 0:
      checkpoint("control copy was not clean: " & describe(control.violations))
    ck control.violations.len == 0
    ck control.files.len == scan.files.len

    let victim = normalizedPath(m.appDir / "tui_app.nim")
    ck fileExists(victim)
    writeFile(victim, readFile(victim) & "\nimport \"tui/host/session_recorder\"\n")

    let mutated = m.scanMutant()
    checkpoint("violations after planting 'import \"tui/host/session_recorder\"': " &
               describe(mutated.violations))
    ck mutated.violations.len == 1
    ck mutated.violations.anyIt(it.reason.contains("host layer"))
    ck mutated.violations.anyIt(it.file == victim)
    # The spec reached the rule WHOLE. Asserted by name because a truncated
    # `session_recorde` would simply be reported by no rule at all, and
    # "one violation" is what an unrelated second bug could also produce.
    ck mutated.violations.anyIt(it.spec == "tui/host/session_recorder")
    removeDir(m.root)

  test "MUTATION: a planted one-line 'when …: import tui/host/native_host' is detected":
    # THE ARM FOR THE FORM THE COMMENTS ALREADY CLAIMED WAS COVERED. The
    # multi-line `when defined(js):` spelling WAS handled — the contract suite
    # over the repo-wide guard has carried a case for it since it was written —
    # and that is exactly what made this one invisible: a reader checking
    # "are conditional imports handled?" found yes.
    #
    # They are different code paths. The multi-line form puts `import` at the
    # start of its own (indented) line, which the line-oriented extractor sees.
    # The one-liner does not, so the line was skipped before anything else ran.
    # `when not defined(js): import x` compiles and is idiomatic.
    let m = newMutantTree(appDir, hostDir, "one-line-when")

    let control = m.scanMutant()
    if control.violations.len > 0:
      checkpoint("control copy was not clean: " & describe(control.violations))
    ck control.violations.len == 0
    ck control.files.len == scan.files.len

    let victim = normalizedPath(m.appDir / "tui_app.nim")
    ck fileExists(victim)
    writeFile(victim, readFile(victim) &
              "\nwhen not defined(js): import tui/host/native_host\n")

    let mutated = m.scanMutant()
    checkpoint("violations after planting the one-line 'when': " &
               describe(mutated.violations))
    ck mutated.violations.len == 1
    ck mutated.violations.anyIt(it.reason.contains("host layer"))
    ck mutated.violations.anyIt(it.file == victim)
    # By name, because the condition must have been discarded and the STATEMENT
    # kept: a rule that cut at the wrong colon would report a spec with the
    # tail of `defined(js)` still attached, and that resolves to nothing.
    ck mutated.violations.anyIt(it.spec == "tui/host/native_host")
    removeDir(m.root)

  test "MUTATION: a planted ';'-separated host import is detected":
    # THE OTHER HALF OF "A LINE IS NOT A STATEMENT", and a separate arm because
    # it fails differently. The one-liner above was skipped for not starting
    # with `import`; this line DOES start with `import`, is read, and yields a
    # single spec of `codetracer_embed;importtui/host/native_host` — a module
    # nobody has. So BOTH imports vanish, and the permitted one vanishing is
    # what makes this shape worse than a plain miss: the file appears to import
    # nothing at all.
    #
    # The facade goes FIRST here on purpose. A split that kept only the tail
    # would still catch the violation and look correct; the edge assertion
    # below is what says the first statement survived too.
    let m = newMutantTree(appDir, hostDir, "semicolon")

    let control = m.scanMutant()
    if control.violations.len > 0:
      checkpoint("control copy was not clean: " & describe(control.violations))
    ck control.violations.len == 0
    ck control.files.len == scan.files.len

    let victim = normalizedPath(m.appDir / "cli.nim")
    ck fileExists(victim)
    writeFile(victim, readFile(victim) &
              "\nimport codetracer_embed; import tui/host/native_host\n")

    let mutated = m.scanMutant()
    checkpoint("violations after planting the ';'-separated import: " &
               describe(mutated.violations))
    ck mutated.violations.len == 1
    ck mutated.violations.anyIt(it.reason.contains("host layer"))
    ck mutated.violations.anyIt(it.file == victim)
    ck mutated.violations.anyIt(it.spec == "tui/host/native_host")
    # The statement in FRONT of the `;` was read as well, and reading it is the
    # difference between "one import was hidden" and "the line was lost".
    ck mutated.edges.anyIt(it.file == victim and it.spec == "codetracer_embed")
    removeDir(m.root)

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions

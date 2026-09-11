## project_definitions/containment.nim — PLAT-11. The one function that
## decides whether a string a cloned repository wrote may name a file.
##
## Project-Definitions.md §2.2:
##
##   "**No arbitrary path references.** A definition may not name a file
##    outside the project, and the loader resolves paths within the checkout —
##    the containment problem CTUI-4 found in the engine's bundled-source
##    resolution, in a new place and with the answer already known."
##
## ## IT IS A CLOSED GRAMMAR, NOT A LIST OF THINGS TO REJECT
##
## The tempting implementation is `if "../" in p: refuse`. That is a
## blocklist, and a blocklist over a syntax somebody else controls loses:
## `..\`, `%2e%2e/`, `a/../../b`, `C:..\..`, a NUL that truncates the string
## for whatever consumer eventually opens it. Every one of those is a thing
## somebody had to think of.
##
## So the grammar is the other way round. A path is a sequence of one or more
## SEGMENTS separated by exactly one `/`. A segment is one or more characters
## from a closed set, does not begin or end with a space, and is not `.` or
## `..`. Anything a repository can write that is not that shape has no
## meaning here — it is not refused by a rule, there is no rule it could
## satisfy.
##
## `\` is not a separator and not a legal character, so a Windows-style path
## is not "a path with the wrong separator", it is not a path. `:` is not a
## legal character, so a drive letter and a UNC prefix are likewise
## unspellable. Both are still reported by their OWN problem values rather
## than as a generic bad character, because "use `/`" and "name a path inside
## the project" are different fixes, and §4b's lesson is that a refusal
## asserted only as "it refused" passes for the wrong reason.
##
## ## IT IS LEXICAL, AND THAT IS THE POINT RATHER THAN A LIMITATION
##
## Nothing here touches the filesystem: no `getCurrentDir`, no `expandFilename`,
## no `symlinkExists`. A containment check that resolves symlinks would need
## I/O, and §2.2's first bullet forbids the loader any. A LEXICAL grammar this
## narrow is decidable without the disk, and the residue — a repository whose
## own checked-in symlink points outside itself — is a property of the
## checkout rather than of the definition, and belongs to whoever opens the
## file, not to whoever reads the declaration.
##
## ## ONE PREDICATE, TWO CALLERS
##
## Verification-Harness-Traps §14: the rule and its control must be one piece
## of code. `parse.nim` calls `pathProblem` and so does the suite; there is no
## second copy of "what a contained path looks like" anywhere, and a mutation
## arm aimed at this function reddens the suite through the same call the
## product makes.

type
  PathProblem* = enum
    ## Why a declared path is not a path inside this project. `ppOk` is the
    ## only value that means "usable"; everything else names the rule of the
    ## grammar the string is outside of.
    ppOk
    ppEmpty            ## the empty string names no file
    ppTooLong          ## beyond `MaxContainedPathBytes`
    ppTooManySegments  ## beyond `MaxContainedPathSegments`
    ppAbsolute         ## a leading `/`: the filesystem root, not this project
    ppDriveLetter      ## `C:\…` or `C:/…`
    ppUncPrefix        ## `\\server\share`
    ppBackslash        ## `\` anywhere else — one separator exists, and it is `/`
    ppParentSegment    ## a `..` segment, at any depth
    ppCurrentSegment   ## a `.` segment: two spellings of one path is one too many
    ppEmptySegment     ## `a//b`, or a trailing `/`
    ppSegmentTooLong   ## beyond `MaxContainedSegmentBytes`
    ppLeadingSpace     ## a segment beginning with a space
    ppTrailingSpace    ## a segment ending with a space
    ppControlChar      ## anything below 0x20, or 0x7f — NUL included
    ppBadChar          ## outside the closed set

const
  MaxContainedPathBytes* = 512
    ## Long enough for any real source path in any repository anyone will open
    ## here, short enough that a definition cannot make a consumer's buffer
    ## interesting.

  MaxContainedSegmentBytes* = 128
    ## `NAME_MAX` is 255 on Linux and 255 UTF-16 units on NTFS. Half of that
    ## is generous for a directory or file name and keeps the total bound
    ## meaningful rather than reachable by one enormous segment.

  MaxContainedPathSegments* = 32
    ## The deepest real source tree anyone has is nowhere near this. It exists
    ## so the segment walk is bounded by a constant rather than by the length
    ## of attacker-controlled input.

  ContainedSegmentChars* = {'A' .. 'Z', 'a' .. 'z', '0' .. '9',
                            '.', '_', '-', '+', '@', ' '}
    ## THE CLOSED SET, and the omissions are the security argument.
    ##
    ## Absent, and each absent for a reason somebody has exploited elsewhere:
    ## `/` (handled as the separator, so it cannot appear *inside* a segment),
    ## `\` (a second separator), `:` (a drive letter, and a PATH separator on
    ## POSIX), `$` and `` ` `` and `~` (expansion), `*` `?` `[` `]` (globbing),
    ## `"` `'` (quoting), `;` `&` `|` `<` `>` `(` `)` (shell metacharacters),
    ## `%` (URL escapes, and `cmd.exe` variable expansion), `,` and `=` (`mount`
    ## option syntax), and every byte below 0x20 including NUL.
    ##
    ## A space IS in the set, because real repositories contain paths with
    ## spaces and refusing them would be refusing something legitimate. It is
    ## forbidden at the START or END of a segment, where it is invisible in a
    ## diff and is how two different paths come to look like one.
    ##
    ## Non-ASCII bytes are absent. That is a real limitation, named rather
    ## than hidden: a repository whose source paths are not ASCII cannot
    ## declare points in them today. The alternative — admitting every byte
    ## ≥ 0x80 — admits overlong UTF-8 encodings of `/` and `.`, which is the
    ## exact mechanism of the 2000-era directory-traversal family, and
    ## admitting it correctly means a UTF-8 validator inside a security
    ## predicate. `project_definitions_test` asserts the refusal so the
    ## limitation is a measured fact rather than an assumption.

func reason*(p: PathProblem): string =
  ## Why, without the subject. Written once here rather than at each call
  ## site, so one problem cannot acquire two explanations.
  case p
  of ppOk: "is a path inside the project"
  of ppEmpty:
    "is empty. A path was declared and it names no file"
  of ppTooLong:
    "is longer than " & $MaxContainedPathBytes & " bytes"
  of ppTooManySegments:
    "has more than " & $MaxContainedPathSegments & " segments"
  of ppAbsolute:
    "is absolute. A project definition names files INSIDE the project, " &
    "relative to it; the loader resolves them within the checkout"
  of ppDriveLetter:
    "names a drive. A project definition names files inside the project, and " &
    "a drive letter is a different machine's filesystem"
  of ppUncPrefix:
    "is a UNC path, which names another host entirely"
  of ppBackslash:
    "contains '\\'. Paths here use '/' on every platform, so one definition " &
    "means the same file wherever it is cloned"
  of ppParentSegment:
    "contains a '..' segment, which leaves the project"
  of ppCurrentSegment:
    "contains a '.' segment; write the path it resolves to"
  of ppEmptySegment:
    "has an empty segment — a doubled '/' or a trailing one"
  of ppSegmentTooLong:
    "has a segment longer than " & $MaxContainedSegmentBytes & " bytes"
  of ppLeadingSpace:
    "has a segment beginning with a space, which is invisible in a diff"
  of ppTrailingSpace:
    "has a segment ending with a space, which is invisible in a diff"
  of ppControlChar:
    "contains a control character. A NUL truncates this string for anything " &
    "that hands it to a C API, so the path a consumer opens is not the path " &
    "that was checked"
  of ppBadChar:
    "contains a character outside the path grammar. A segment is made of " &
    "letters, digits, '.', '_', '-', '+', '@' and spaces"

func describe*(p: PathProblem; path: string): string =
  ## The refusal, spelled so the author can fix it from the message.
  ##
  ## THE SUBJECT IS PREFIXED UNIFORMLY rather than interpolated into each
  ## arm, and that is a repair rather than a tidy-up: written the other way,
  ## `ppEmpty`'s arm had no `path` in it at all — correctly, since the path IS
  ## the empty string — and the suite's sweep ("every refusal explains itself,
  ## AND NAMES THE PATH") found it on its first run. One prefix means the
  ## sweep holds over the whole enum by construction, including whatever is
  ## added next.
  "'" & path & "' " & reason(p)

func pathProblem*(path: string): PathProblem =
  ## THE predicate. Total, pure, no filesystem, no exceptions.
  ##
  ## The order of the tests is chosen so the SPECIFIC diagnosis wins over the
  ## general one: a `C:\x` is a drive letter rather than a bad character, and
  ## `\\host\share` is a UNC path rather than a backslash. A reader given the
  ## general answer to a specific mistake has to guess at the fix.
  if path.len == 0: return ppEmpty
  if path.len > MaxContainedPathBytes: return ppTooLong

  # The three shapes that mean "not this project", diagnosed before the
  # character walk so each gets its own sentence.
  if path.len >= 2 and path[0] == '\\' and path[1] == '\\':
    return ppUncPrefix
  if path[0] == '/' or path[0] == '\\':
    return ppAbsolute
  if path.len >= 2 and path[1] == ':':
    let c = path[0]
    if c in {'A' .. 'Z', 'a' .. 'z'}:
      return ppDriveLetter

  # A control character anywhere, checked over the WHOLE string before it is
  # split: a NUL is the one byte whose presence changes what "the rest of the
  # string" means to a later consumer, so it must not be able to hide in a
  # segment the walk stops before reaching.
  for ch in path:
    if ch < ' ' or ch == '\x7f':
      return ppControlChar
    if ch == '\\':
      return ppBackslash

  var segments = 0
  var start = 0
  var i = 0
  while true:
    let atEnd = i == path.len
    if atEnd or path[i] == '/':
      inc segments
      if segments > MaxContainedPathSegments:
        return ppTooManySegments
      let segLen = i - start
      if segLen == 0: return ppEmptySegment
      if segLen > MaxContainedSegmentBytes: return ppSegmentTooLong
      let seg = path[start ..< i]
      if seg == "..": return ppParentSegment
      if seg == ".": return ppCurrentSegment
      if seg[0] == ' ': return ppLeadingSpace
      if seg[^1] == ' ': return ppTrailingSpace
      for ch in seg:
        if ch notin ContainedSegmentChars:
          return ppBadChar
      if atEnd: break
      start = i + 1
    inc i
  ppOk

func isContained*(path: string): bool =
  ## The boolean form, for a caller that only needs the verdict. It CALLS
  ## `pathProblem` rather than re-deriving it: two spellings of one predicate
  ## is §14's defect, and a security predicate is the worst place for it.
  pathProblem(path) == ppOk

func joinContained*(scope, path: string): string =
  ## A package-relative path, expressed relative to the repository root.
  ##
  ## Both halves must ALREADY have been checked — the caller checks `scope`
  ## once per definition file and `path` once per point — so this does no
  ## checking of its own and cannot be handed anything to escape with: the
  ## concatenation of two paths that each contain no `..` and no absolute
  ## prefix contains neither.
  ##
  ## That is a property worth stating rather than assuming, and
  ## `project_definitions_test` asserts it as a sweep over a cross product of
  ## contained scopes and contained paths, so a future change that makes
  ## `joinContained` clever enough to break it goes red.
  if scope.len == 0: path
  elif path.len == 0: scope
  else: scope & "/" & path

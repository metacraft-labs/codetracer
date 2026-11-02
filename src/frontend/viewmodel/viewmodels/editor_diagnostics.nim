## viewmodels/editor_diagnostics.nim — **A build's diagnostics in the editor:
## the squiggles, the gutter icons and the hover text, from the Problems
## pane's `ErrorsVM`** (Build-Output-Pane.md §3.9).
##
## The three editors (Monaco on the desktop, the terminal's Edit pane, GPUI's
## editor) mark the SAME locations because they read the same rows — the
## Problems pane's, `ErrorsVM.problems` — through this module:
##
## * `diagnosticsForFile`: the rows that name the open file (a relative path
##   resolved against the BUILD'S working directory, EMT-A36; the file's path
##   against the project folder), each as a span of its line: from the
##   compiler's column to the end of the word there (the identifier a compiler
##   points at), the whole line's text when it gave no column;
## * `gutterSeverity`: the most severe diagnostic on a line — the gutter's icon
##   (`errors_vm.severityIcon`, the Problems pane's: `●` `⚠` `ⓘ`);
## * `hoverText`: what hovering the line says — every diagnostic on it, most
##   severe first, as the compiler worded it (`error: …`, `note: …`; a
##   message without a severity word gets the row's) — the terminal says it on its status line
##   when the caret is on the line, as it has no pointer hover.
##
## A new build clears the Problems pane (EMT-D22.7), so it clears the marks
## with it; F8 / Shift+F8 step through them (`problems.next` / `.previous`,
## PLAT-55).
##
## Columns: a compiler's column is 1-based and counts BYTES (gcc, clang, nim,
## rustc); a span is in CHARACTERS (code points) from 0, which is what every
## editor lays out (Monaco's columns are UTF-16, equal to code points outside
## the astral planes).
##
## Pure Nim. C and JavaScript backends.

import std/[strutils, unicode]

import ../store/types
import ./errors_vm
import ./build_diagnostics

type
  EditorDiagnostic* = object
    line*: int
      ## 1-based.
    fromColumn*: int
      ## 0-based character column where the squiggle starts.
    toColumn*: int
      ## Where it ends (exclusive); > `fromColumn`.
    severity*: BuildLineSeverity
    message*: string
    problemIndex*: int
      ## The row's index in `ErrorsVM.problems`.

const
  DiagnosticErrorColour* = "#f85149"
  DiagnosticWarningColour* = "#d29922"
  DiagnosticInfoColour* = "#58a6ff"
    ## The Problems pane's severity colours (`problems.styl`), the squiggles'
    ## and the gutter icons' on GPUI and the desktop.
  BuildDiagnosticsOwner* = "codetracer-build"
    ## Monaco's marker owner for these marks.

proc rank(s: BuildLineSeverity): int =
  case s
  of blsError: 3
  of blsWarning: 2
  of blsInfo: 1
  of blsNone: 0

proc severityWord*(s: BuildLineSeverity): string =
  case s
  of blsError: "error"
  of blsWarning: "warning"
  of blsInfo, blsNone: "info"

proc colourOf*(s: BuildLineSeverity): string =
  case s
  of blsError: DiagnosticErrorColour
  of blsWarning: DiagnosticWarningColour
  of blsInfo, blsNone: DiagnosticInfoColour

proc foldedPath(path: string): string =
  ## `/`-separated, `.` and `..` segments folded, no trailing `/`.
  let p = path.replace('\\', '/')
  let absolute = p.startsWith("/")
  var parts: seq[string]
  for seg in p.split('/'):
    if seg.len == 0 or seg == ".":
      continue
    if seg == ".." and parts.len > 0 and parts[^1] != "..":
      parts.setLen(parts.len - 1)
    else:
      parts.add seg
  result = (if absolute: "/" else: "") & parts.join("/")

proc sameFile*(problemPath, workingDirectory, filePath,
               projectDir: string): bool =
  ## Whether a row's path (as the compiler wrote it, relative to the build's
  ## working directory) names the editor's file (absolute, or relative to the
  ## project folder).
  if problemPath.len == 0 or filePath.len == 0:
    return false
  let a = foldedPath(resolvedPath(problemPath, workingDirectory))
  let b = foldedPath(resolvedPath(filePath, projectDir))
  a == b

proc charColumnOfByte*(text: string; byteColumn: int): int =
  ## The 0-based character column of a 1-based byte column.
  let target = clamp(byteColumn - 1, 0, text.len)
  var i = 0
  while i < target:
    i += max(1, runeLenAt(text, i))
    inc result

proc isWordRune(r: Rune): bool =
  r.isAlpha or (r.int < 128 and char(r.int) in {'0'..'9', '_'})

proc diagnosticSpan*(text: string; byteColumn: int): tuple[fromColumn,
                                                          toColumn: int] =
  ## Where a diagnostic's squiggle goes on its line: from the column to the end
  ## of the word starting there (one character when it is not in a word), or —
  ## no column — the line's text without its indentation. Never empty: a
  ## column past the end of the line marks the last character (or the first
  ## cell of an empty line).
  let runes = text.toRunes
  if byteColumn <= 0:
    var a = 0
    while a < runes.len and runes[a].isWhiteSpace:
      inc a
    var b = runes.len
    while b > a and runes[b - 1].isWhiteSpace:
      dec b
    if b <= a:
      return (0, 1)
    return (a, b)
  var a = charColumnOfByte(text, byteColumn)
  if a >= runes.len:
    a = max(0, runes.len - 1)
    return (a, a + 1)
  var b = a + 1
  if runes[a].isWordRune:
    while b < runes.len and runes[b].isWordRune:
      inc b
  (a, b)

proc diagnosticsForFile*(rows: openArray[BuildProblemLine];
                         workingDirectory, filePath, projectDir: string;
                         lineText: proc(line: int): string): seq[EditorDiagnostic] =
  ## The rows that name `filePath`, as spans of its lines (the module header).
  ## `lineText` answers a 1-based line's text ("" past the end).
  for i, p in rows:
    if p.line <= 0 or p.severity == blsNone:
      continue
    if not sameFile(p.path, workingDirectory, filePath, projectDir):
      continue
    let span = diagnosticSpan(lineText(p.line), p.col)
    result.add EditorDiagnostic(line: p.line, fromColumn: span.fromColumn,
                                toColumn: span.toColumn, severity: p.severity,
                                message: p.message, problemIndex: i)

proc gutterSeverity*(diags: openArray[EditorDiagnostic];
                     line: int): BuildLineSeverity =
  ## The most severe diagnostic on `line`, `blsNone` for none.
  result = blsNone
  for d in diags:
    if d.line == line and rank(d.severity) > rank(result):
      result = d.severity

proc gutterIcon*(diags: openArray[EditorDiagnostic]; line: int): string =
  ## The gutter's icon on `line` (the Problems pane's), "" for none.
  let s = gutterSeverity(diags, line)
  if s == blsNone: "" else: severityIcon(s)

proc hoverText*(diags: openArray[EditorDiagnostic]; line: int): string =
  ## What hovering `line` says: each diagnostic on it, most severe first, one
  ## per line, worded as the module header says.
  var parts: seq[string]
  for want in [blsError, blsWarning, blsInfo]:
    for d in diags:
      if d.line == line and d.severity == want:
        # The compiler's own word when its message starts with one (gcc's
        # `error: …`, `note: …`), else the row's.
        let lower = d.message.toLowerAscii
        var worded = false
        for w in ["error", "warning", "note", "info", "help", "hint"]:
          if lower.startsWith(w & ":") or lower.startsWith(w & "["):
            worded = true
        parts.add(if worded: d.message
                  else: severityWord(d.severity) & ": " & d.message)
  parts.join("\n")

proc diagnosticLines*(diags: openArray[EditorDiagnostic]): seq[int] =
  ## The lines that carry a diagnostic, ascending, each once.
  for d in diags:
    if d.line notin result:
      result.add d.line
  for i in 1 ..< result.len:
    var j = i
    while j > 0 and result[j - 1] > result[j]:
      swap(result[j - 1], result[j])
      dec j

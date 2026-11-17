## test_plat70g_word_oracle.nim — MC-W (Editor-Pane.md MC.3, MC.4): the pointer's
## word and line units against the REAL Monaco code.
##
## No mock and no re-implementation: `monaco_word_oracle.mjs` imports
## `WordOperations` and `CursorMoveCommands` from the bundled `monaco-editor`
## under node and answers for every caret boundary of the fixture and of a
## 2,000-line generated corpus. The only stand-ins are the oracle's plain `model`
## and `viewModel` objects, because those two classes need a browser; they carry
## the same lines with no wrapping, and the wrapped case is in
## `test_plat70g_pointer_vm`. Native only: it starts a process.
##
## Needs `node` and `node_modules/monaco-editor`; without them it fails and says
## so, since a population of zero would prove nothing.

import std/[json, os, osproc, random, strutils, unicode, unittest]

import isonim_tui/text/width

import ../../viewmodel/editing_core

const
  Fixture = [
    "snake_case_name = other.attr(x)", "    leading indentation",
    "a == b", "p->q", "a.b", "", "price λx 3€ end  tab\there",
    "a long line that a soft wrap would fold over more than one display row",
    "last line, no terminator"]
  Parts = ["alpha", "beta_gamma", "λ", "€", "x1", " ", "  ", "\t", ".", "->", "==",
           "::", "(", ")", "\"str\"", "#", "日本語", "😀", "$", "_", "a", "-", "/"]

proc utf16Of(line: string; byteCol: int): int =
  ## The 0-based UTF-16 column of a byte column.
  for r in line[0 ..< byteCol].runes:
    result += (if int(r) > 0xFFFF: 2 else: 1)

proc boundaries(line: string): seq[int] =
  for c in graphemeClusters(line):
    result.add c.start
  result.add line.len

proc corpus(): seq[string] =
  var r = initRand(70)
  for i in 0 ..< 2000:
    var s = ""
    for _ in 0 .. r.rand(12):
      s.add r.sample(Parts)
    result.add s

proc monacoDir(): string =
  if existsEnv("CT_MONACO_DIR"):
    return getEnv("CT_MONACO_DIR")
  var dir = currentSourcePath().parentDir
  while dir.len > 1:
    let candidate = dir / "node_modules" / "monaco-editor"
    if dirExists(candidate):
      return candidate
    dir = dir.parentDir

proc ask(queries: JsonNode): JsonNode =
  let dir = monacoDir()
  doAssert dir.len > 0, "node_modules/monaco-editor not found: run the dev " &
    "shell's hook, this oracle has no other source of truth"
  let file = getTempDir() / ("plat70g-word-" & $getCurrentProcessId() & ".json")
  writeFile(file, $queries)
  defer: removeFile(file)
  let script = currentSourcePath().parentDir / "monaco_word_oracle.mjs"
  let (output, code) = execCmdEx("node " & quoteShell(script) & " " &
                                 quoteShell(dir) & " " & quoteShell(file))
  doAssert code == 0, "the Monaco oracle failed:\n" & output
  parseJson(output)

suite "MC-W: the pointer's units equal Monaco's":
  test "select-word-at at every boundary of the fixture and the corpus":
    let c = wordClassifier()
    var lines: seq[string] = @Fixture
    lines.add corpus()
    var word = newJArray()
    var want: seq[tuple[line: int; at: int]] = @[]
    for i, line in lines:
      for b in boundaries(line):
        word.add %*[i + 1, utf16Of(line, b) + 1]
        want.add (i, b)
    let answer = ask(%*{"lines": lines, "separators": UsualWordSeparators,
                        "word": word, "extendWord": [], "extendLine": []})
    check answer["word"].len == want.len
    check want.len > 20000
    echo "  MC-W word: ", want.len, " boundaries over ", lines.len, " lines"
    var wrong = 0
    for k, w in want:
      let s = c.wordAtBoundary(lines[w.line], w.at)
      let got = [utf16Of(lines[w.line], s.first) + 1,
                 utf16Of(lines[w.line], s.last) + 1]
      let exp = answer["word"][k]
      if got[0] != exp[0].getInt or got[1] != exp[1].getInt:
        inc wrong
        if wrong <= 10:
          checkpoint("line " & $(w.line + 1) & " '" & lines[w.line] & "' at byte " &
                     $w.at & ": ours " & $got & ", Monaco " & $exp)
    check wrong == 0

  test "extend-by-unit-to against word(…, true) and line(…, true)":
    let text = Fixture.join("\n")
    let lines = @Fixture
    var starts: seq[int] = @[]
    var at = 0
    for l in lines:
      starts.add at
      at += l.len + 1
    var extendWord = newJArray()
    var extendLine = newJArray()
    type WordCase = tuple[anchorLine, a, b, line, byteCol: int]
    var wordCases: seq[WordCase] = @[]
    var lineCases: seq[tuple[anchorLine, line, byteCol: int]] = @[]
    let c = wordClassifier()
    for ai, aline in lines:
      for ab in boundaries(aline):
        let s = c.wordAtBoundary(aline, ab)
        for li, l in lines:
          for b in boundaries(l):
            wordCases.add (ai, s.first, s.last, li, b)
            extendWord.add %*[ai + 1, utf16Of(aline, s.first) + 1,
                              utf16Of(aline, s.last) + 1, li + 1,
                              utf16Of(l, b) + 1]
      for li, l in lines:
        for b in boundaries(l):
          lineCases.add (ai, li, b)
          extendLine.add %*[ai + 1, li + 1, utf16Of(l, b) + 1]
    let answer = ask(%*{"lines": lines, "separators": UsualWordSeparators,
                        "word": [], "extendWord": extendWord,
                        "extendLine": extendLine})
    check wordCases.len > 10000
    check lineCases.len > 500
    echo "  MC-W extend: ", wordCases.len, " by word, ", lineCases.len, " by line"

    proc posOf(offset: int): tuple[line, col: int] =
      var i = starts.len - 1
      while i > 0 and starts[i] > offset: dec i
      (i + 1, utf16Of(lines[i], offset - starts[i]) + 1)

    var wrong = 0
    for k, w in wordCases:
      var d = initEditingDocument("/o", text)
      let a = starts[w.anchorLine] + w.a
      let b = starts[w.anchorLine] + w.b
      d.selectSpan(a, b)
      d.state.pointerAnchor = PointerAnchor(unit: puWord, first: a, last: b,
                                            selection: d.state.selection)
      discard d.applyNamed("extend-by-unit-to",
                           OpArgs(number: starts[w.line] + w.byteCol), 0)
      let r = d.state.selection.mainRange
      let (al, ac) = posOf(r.anchor)
      let (hl, hc) = posOf(r.head)
      let e = answer["extendWord"][k]
      if [al, ac, hl, hc] != [e[0].getInt, e[1].getInt, e[2].getInt, e[3].getInt]:
        inc wrong
        if wrong <= 10:
          checkpoint("word anchor " & $w & ": ours " & $[al, ac, hl, hc] &
                     ", Monaco " & $e)
    check wrong == 0

    wrong = 0
    for k, w in lineCases:
      var d = initEditingDocument("/o", text)
      discard d.applyNamed("select-line-at", OpArgs(number: starts[w.anchorLine]), 0)
      discard d.applyNamed("extend-by-unit-to",
                           OpArgs(number: starts[w.line] + w.byteCol), 0)
      let r = d.state.selection.mainRange
      let (al, ac) = posOf(r.anchor)
      let (hl, hc) = posOf(r.head)
      let e = answer["extendLine"][k]
      if [al, ac, hl, hc] != [e[0].getInt, e[1].getInt, e[2].getInt, e[3].getInt]:
        inc wrong
        if wrong <= 10:
          checkpoint("line anchor " & $w & ": ours " & $[al, ac, hl, hc] &
                     ", Monaco " & $e)
    check wrong == 0

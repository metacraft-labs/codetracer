## view_vocabulary/markdown_blocks.nim — the block structure of a `Markdown`
## entry's source, for the front-ends that have no Markdown renderer of their
## own.
##
## ## WHY THIS EXISTS
##
## `Markdown` is specified by its SOURCE; what a front-end shows is what it
## makes of that source. The terminal has a renderer — isonim-tui's
## `widgets/markdown.nim`, a CommonMark-subset parser — and until 2026-09-26
## the web had none, which is why `mappings.webMapping(pkMarkdown)` was
## `msPartial`: every element the rendering needs is an ordinary tag, and
## nothing produced them. This module is the missing half. `web_binding`
## renders a `MdBlocks` document into `<h1>`..`<h6>`, `<p>`, `<ul>`/`<ol>`/
## `<li>`, `<pre><code>`, `<blockquote>`, `<hr>` and the inline `<strong>`,
## `<em>`, `<code>`, `<a>`.
##
## ## WHY IT IS NOT isonim-tui's PARSER
##
## Two reasons, and the second is the one that matters. `src/common` imports
## nothing from `isonim_tui` (the GPUI lane carries no terminal flags, and the
## vocabulary must compile for every front-end); and a web renderer built on
## the terminal's parser would agree with the terminal BY CONSTRUCTION. The
## cross-medium suite compares the two renderings through `outline` — the
## terminal's read out of the widget's own `MdDocument`, the web's read back
## out of the rendered elements — so two parsers written independently over
## the same CommonMark subset are what make that comparison a measurement.
##
## The subset is isonim-tui's: ATX and setext headings, paragraphs with lazy
## continuation, bullet and ordered lists (nested by indentation), fenced and
## indented code, block quotes, thematic breaks; inline emphasis, strong,
## code spans, links and backslash escapes, and hard line breaks. Tables,
## footnotes, raw HTML and reference links are outside it on both sides.
##
## Medium-free: `std/strutils` only, so it compiles on every backend the
## vocabulary does (C, JS, WASM).

import std/strutils

type
  MdSpanKind* = enum
    mskText, mskEmphasis, mskStrong, mskCode, mskLink, mskBreak

  MdSpan* = object
    kind*: MdSpanKind
    text*: string            ## `mskText`, `mskCode`
    url*: string             ## `mskLink`
    children*: seq[MdSpan]   ## `mskEmphasis`, `mskStrong`, `mskLink`

  MdNodeKind* = enum
    mbkParagraph, mbkHeading, mbkCode, mbkQuote, mbkList, mbkRule

  MdBlockNode* = object
    kind*: MdNodeKind
    level*: int              ## `mbkHeading`: 1..6
    spans*: seq[MdSpan]      ## `mbkParagraph`, `mbkHeading`
    info*: string            ## `mbkCode`: the fence's info string
    code*: seq[string]       ## `mbkCode`: its lines
    ordered*: bool           ## `mbkList`
    start*: int              ## `mbkList`, ordered: the first number
    items*: seq[seq[MdBlockNode]]  ## `mbkList`: each item's blocks
    body*: seq[MdBlockNode]  ## `mbkQuote`

# ---------------------------------------------------------------------------
# Inline
# ---------------------------------------------------------------------------

proc parseSpans*(s: string): seq[MdSpan]

proc addText(acc: var seq[MdSpan]; t: string) =
  if t.len == 0: return
  if acc.len > 0 and acc[^1].kind == mskText:
    acc[^1].text.add t
  else:
    acc.add MdSpan(kind: mskText, text: t)

proc closingRun(s: string; start: int; marker: char; need: int): int =
  ## Index of the first run of `marker` at or after `start` that is at least
  ## `need` long, or -1.
  var i = start
  while i < s.len:
    if s[i] == marker:
      var j = i
      while j < s.len and s[j] == marker: inc j
      if j - i >= need: return i
      i = j
    else:
      inc i
  -1

proc parseSpans*(s: string): seq[MdSpan] =
  ## The inline structure of one block's text. Newlines inside `s` are soft
  ## breaks (one space) unless the line ended in two spaces (a hard break).
  var i = 0
  var run = ""
  template flush() =
    result.addText(run)
    run.setLen(0)
  while i < s.len:
    let c = s[i]
    case c
    of '\\':
      if i + 1 < s.len:
        run.add s[i + 1]
        i += 2
      else:
        run.add c
        inc i
    of '`':
      var ticks = 0
      while i + ticks < s.len and s[i + ticks] == '`': inc ticks
      let close = closingRun(s, i + ticks, '`', ticks)
      # A code span closes on a run of EXACTLY the opening length.
      var j = close
      while j >= 0:
        var k = j
        while k < s.len and s[k] == '`': inc k
        if k - j == ticks: break
        j = closingRun(s, k, '`', ticks)
      if j < 0:
        run.add '`'
        inc i
      else:
        flush()
        result.add MdSpan(kind: mskCode,
                          text: s[i + ticks ..< j].strip(chars = {' '}))
        i = j + ticks
    of '*', '_':
      var n = 0
      while i + n < s.len and s[i + n] == c: inc n
      let need = if n >= 2: 2 else: 1
      if n > 2:
        run.add c
        inc i
      else:
        let close = closingRun(s, i + need, c, need)
        if close < 0:
          run.add c
          inc i
        else:
          flush()
          result.add MdSpan(
            kind: (if need == 2: mskStrong else: mskEmphasis),
            children: parseSpans(s[i + need ..< close]))
          # The closer consumes its whole run, as the terminal's does.
          var k = close
          while k < s.len and s[k] == c: inc k
          i = k
    of '[':
      # [text](url "title")
      var depth = 1
      var j = i + 1
      var inner = ""
      while j < s.len and depth > 0:
        if s[j] == '\\' and j + 1 < s.len:
          inner.add s[j + 1]
          j += 2
          continue
        if s[j] == '[': inc depth
        elif s[j] == ']':
          dec depth
          if depth == 0: break
        inner.add s[j]
        inc j
      if j < s.len and s[j] == ']' and j + 1 < s.len and s[j + 1] == '(':
        var k = j + 2
        var url = ""
        while k < s.len and s[k] notin {')', ' '}:
          url.add s[k]
          inc k
        while k < s.len and s[k] != ')': inc k
        if k < s.len:
          flush()
          result.add MdSpan(kind: mskLink, url: url,
                            children: parseSpans(inner))
          i = k + 1
          continue
      run.add '['
      inc i
    of '\n':
      if run.endsWith("  "):
        run.setLen(run.len - 2)
        flush()
        result.add MdSpan(kind: mskBreak)
      elif run.len > 0 and run[^1] != ' ':
        run.add ' '
      inc i
    else:
      run.add c
      inc i
  flush()

# ---------------------------------------------------------------------------
# Block
# ---------------------------------------------------------------------------

func indentOf(line: string): int =
  for c in line:
    if c == ' ': inc result
    elif c == '\t': result += 4 - (result mod 4)
    else: break

func blank(line: string): bool = line.strip.len == 0

func dropIndent(line: string; n: int): string =
  var col = 0
  var k = 0
  while k < line.len and col < n:
    if line[k] == ' ': inc col
    elif line[k] == '\t': col += 4 - (col mod 4)
    else: break
    inc k
  line[k .. ^1]

func ruleLine(line: string): bool =
  if indentOf(line) >= 4: return false
  var marker = '\0'
  var n = 0
  for c in line:
    if c in {' ', '\t'}: continue
    if marker == '\0':
      if c notin {'-', '*', '_'}: return false
      marker = c
    elif c != marker: return false
    inc n
  n >= 3

func atxLevel(line: string): int =
  let ind = indentOf(line)
  if ind >= 4: return 0
  var i = ind
  while i < line.len and line[i] == '#': inc i
  let n = i - ind
  if n < 1 or n > 6: return 0
  if i < line.len and line[i] notin {' ', '\t'}: return 0
  n

func atxText(line: string; level: int): string =
  var t = line.strip[level .. ^1].strip
  # An optional closing run of `#`, separated by a space or alone.
  var e = t.len
  while e > 0 and t[e - 1] == '#': dec e
  if e < t.len and (e == 0 or t[e - 1] == ' '):
    t = t[0 ..< e].strip
  t

func setext(line: string): int =
  ## Interior whitespace is ignored as well as the edges: `= = =` underlines.
  var t = ""
  for c in line:
    if c notin {' ', '\t'}: t.add c
  if t.len == 0: return 0
  if t.allCharsInSet({'='}): return 1
  if t.allCharsInSet({'-'}): return 2
  0

func fence(line: string): tuple[ok: bool; ch: char; n, indent: int;
                                info: string] =
  let ind = indentOf(line)
  if ind >= 4: return
  let t = line.strip(trailing = false)
  if t.len < 3 or t[0] notin {'`', '~'}: return
  var n = 0
  while n < t.len and t[n] == t[0]: inc n
  if n < 3: return
  var info = ""
  for c in t[n .. ^1]:
    if c notin {' ', '\t'}: info.add c
  (true, t[0], n, ind, info)

func closesFence(line: string; ch: char; n: int): bool =
  if indentOf(line) >= 4: return false
  let t = line.strip
  t.len >= n and t.allCharsInSet({ch})

type Marker = tuple[ok, ordered: bool; indent, width, number: int]

func listMarker(line: string): Marker =
  let ind = indentOf(line)
  if ind >= 4: return
  var i = 0
  while i < line.len and line[i] in {' ', '\t'}: inc i
  if i >= line.len: return
  if line[i] in {'-', '*', '+'}:
    if i + 1 < line.len and line[i + 1] notin {' ', '\t'}: return
    return (true, false, ind, (if i + 1 < line.len: 2 else: 1), 0)
  var j = i
  var num = 0
  while j < line.len and line[j].isDigit and j - i < 9:
    num = num * 10 + (ord(line[j]) - ord('0'))
    inc j
  if j == i or j >= line.len or line[j] notin {'.', ')'}: return
  if j + 1 < line.len and line[j + 1] notin {' ', '\t'}: return
  (true, true, ind, j - i + 2, num)

func quoteLine(line: string): bool =
  indentOf(line) < 4 and line.strip(trailing = false).startsWith(">")

func unquote(line: string): string =
  var t = line.strip(trailing = false)
  t = t[1 .. ^1]
  if t.startsWith(" "): t = t[1 .. ^1]
  t

proc parseLines(lines: seq[string]): seq[MdBlockNode]

proc parseLines(lines: seq[string]): seq[MdBlockNode] =
  var i = 0
  # What the previous block was decides whether a 4-space line is code (it
  # is, unless it would continue a paragraph).
  var afterParagraph = false
  while i < lines.len:
    let line = lines[i]
    if blank(line):
      afterParagraph = false
      inc i
      continue
    if ruleLine(line):
      result.add MdBlockNode(kind: mbkRule)
      afterParagraph = false
      inc i
      continue
    let lvl = atxLevel(line)
    if lvl > 0:
      result.add MdBlockNode(kind: mbkHeading, level: lvl,
                             spans: parseSpans(atxText(line, lvl)))
      afterParagraph = false
      inc i
      continue
    let f = fence(line)
    if f.ok:
      var code: seq[string] = @[]
      inc i
      while i < lines.len and not closesFence(lines[i], f.ch, f.n):
        code.add dropIndent(lines[i], f.indent)
        inc i
      if i < lines.len: inc i
      result.add MdBlockNode(kind: mbkCode, info: f.info, code: code)
      afterParagraph = false
      continue
    if indentOf(line) >= 4 and not afterParagraph:
      var code: seq[string] = @[]
      while i < lines.len and (blank(lines[i]) or indentOf(lines[i]) >= 4):
        code.add (if blank(lines[i]): "" else: dropIndent(lines[i], 4))
        inc i
      while code.len > 0 and code[^1].len == 0: code.setLen(code.len - 1)
      result.add MdBlockNode(kind: mbkCode, code: code)
      continue
    if quoteLine(line):
      var inner: seq[string] = @[]
      while i < lines.len and quoteLine(lines[i]):
        inner.add unquote(lines[i])
        inc i
      result.add MdBlockNode(kind: mbkQuote, body: parseLines(inner))
      afterParagraph = false
      continue
    let m = listMarker(line)
    if m.ok:
      var list = MdBlockNode(kind: mbkList, ordered: m.ordered,
                             start: m.number)
      while i < lines.len:
        if blank(lines[i]):
          # A blank line continues the list only if the next item follows.
          var look = i
          while look < lines.len and blank(lines[look]): inc look
          if look >= lines.len: break
          let nx = listMarker(lines[look])
          if not nx.ok or nx.ordered != m.ordered or nx.indent != m.indent:
            break
          i = look
          continue
        let mm = listMarker(lines[i])
        if not mm.ok or mm.ordered != m.ordered or mm.indent != m.indent:
          break
        let content = mm.indent + mm.width
        var item = @[(if content < lines[i].len: lines[i][content .. ^1]
                      else: "")]
        inc i
        while i < lines.len:
          if blank(lines[i]):
            item.add ""
            inc i
          elif indentOf(lines[i]) >= content:
            item.add dropIndent(lines[i], content)
            inc i
          else:
            break
        list.items.add parseLines(item)
      result.add list
      afterParagraph = false
      continue
    # A paragraph, possibly closed by a setext underline.
    var para = @[line]
    inc i
    var level = 0
    while i < lines.len:
      let l = lines[i]
      if blank(l): break
      let sl = setext(l)
      if sl > 0:
        level = sl
        inc i
        break
      if ruleLine(l) or atxLevel(l) > 0 or fence(l).ok or quoteLine(l) or
         listMarker(l).ok:
        break
      para.add l
      inc i
    let text = para.join("\n")
    if level > 0:
      result.add MdBlockNode(kind: mbkHeading, level: level,
                             spans: parseSpans(text))
      afterParagraph = false
    else:
      result.add MdBlockNode(kind: mbkParagraph, spans: parseSpans(text))
      afterParagraph = true

proc parseMdBlocks*(source: string): seq[MdBlockNode] =
  var lines = source.splitLines()
  if lines.len > 0 and lines[^1].len == 0: lines.setLen(lines.len - 1)
  parseLines(lines)

# ---------------------------------------------------------------------------
# The outline — what two renderings are compared on
# ---------------------------------------------------------------------------
#
# One token per structural event, in document order. Every front-end that
# renders Markdown projects ITS OWN rendering onto this shape — the terminal
# out of isonim-tui's `MdDocument`, the web out of the elements it drew — and
# the cross-medium suite compares the two sequences. The spelling is defined
# here, once, so the two projections cannot disagree about it.
#
#   h<N> <inline>          heading
#   p <inline>             paragraph
#   code <info>|<lines>    code block, lines joined by "\n"
#   quote{ ... }           block quote
#   ul{ / ol<start>{ ... } list, each item li{ ... }
#   hr                     thematic break
#
# `<inline>` is the text with the inline structure spelled in brackets:
# `[b:…]` strong, `[i:…]` emphasis, `[c:…]` code, `[a:<url>:…]` link, and
# "\n" for a hard break.

func inlineToken*(kind: MdSpanKind; inner, url: string): string =
  ## The one spelling of an inline element in the outline.
  case kind
  of mskText: inner
  of mskEmphasis: "[i:" & inner & "]"
  of mskStrong: "[b:" & inner & "]"
  of mskCode: "[c:" & inner & "]"
  of mskLink: "[a:" & url & ":" & inner & "]"
  of mskBreak: "\n"

proc spansText*(spans: seq[MdSpan]): string =
  for s in spans:
    case s.kind
    of mskText, mskCode: result.add inlineToken(s.kind, s.text, "")
    of mskBreak: result.add inlineToken(mskBreak, "", "")
    else: result.add inlineToken(s.kind, spansText(s.children), s.url)

proc outline*(blocks: seq[MdBlockNode]): seq[string] =
  for b in blocks:
    case b.kind
    of mbkHeading: result.add "h" & $b.level & " " & spansText(b.spans)
    of mbkParagraph: result.add "p " & spansText(b.spans)
    of mbkCode: result.add "code " & b.info & "|" & b.code.join("\n")
    of mbkRule: result.add "hr"
    of mbkQuote:
      result.add "quote{"
      result.add outline(b.body)
      result.add "}"
    of mbkList:
      result.add (if b.ordered: "ol" & $b.start & "{" else: "ul{")
      for item in b.items:
        result.add "li{"
        result.add outline(item)
        result.add "}"
      result.add "}"

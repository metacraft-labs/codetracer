## word_classifier.nim — the word a pointer selects, from
## `editor.wordSeparators` (Editor-Pane.md MC.3).
##
## This is deliberately not the editing core's `CharCat`, which drives the
## `group-*` motions and `select-inner-word`. `CharCat` calls every
## non-alphanumeric other than `_` "other"; the pointer's word is Monaco's
## three classes, so `€` and `λ` are regular here, and the separator set is a
## user setting that the desktop hands to Monaco unchanged. The three
## front-ends agree because this file transcribes the one algorithm Monaco
## runs: `WordOperations.word`, `_doFindPreviousWordOnLine` and
## `_doFindNextWordOnLine` of `common/cursor/cursorWordOperations.js` at the
## bundled 0.54.0. `test_plat70g_word_oracle` runs the real Monaco code against
## this one at every caret boundary of its corpus.
##
## Everything here is a function of one line, in byte columns of that line. A
## grapheme cluster has the class of its first code point, and the scans walk
## clusters, so a selection can never split one.

import std/[options, unicode]

import isonim_tui/text/width

const
  UsualWordSeparators* = "`~!@#$%^&*()-=+[{]}\\|;:'\",.<>/?"
    ## `USUAL_WORD_SEPARATORS` of Monaco's `core/wordHelper.js`, the default
    ## of the `editor.wordSeparators` setting.

type
  WordClass* = enum
    wcRegular
    wcWhitespace
    wcSeparator

  WordClassifier* = object
    separators*: string
    runes: seq[Rune]

  WordKind = enum
    wkNone
    wkRegular
    wkSeparator

  ClusterClass = object
    start, stop: int
    cls: WordClass

  FoundWord = object
    ## Cluster indices: `first` is the first cluster, `last` one past the end.
    first, last: int
    kind: WordKind

  LineSpan* = object
    ## Byte columns of one line, `[first, last)`.
    first*, last*: int

func wordClassifier*(separators = UsualWordSeparators): WordClassifier =
  WordClassifier(separators: separators, runes: toRunes(separators))

func classOf*(c: WordClassifier; r: Rune): WordClass =
  ## Space and tab are the only whitespace, as `WordCharacterClassifier` sets
  ## them; they win over a separator list that names them, because Monaco
  ## sets them last.
  if r == Rune(0x20) or r == Rune(0x09):
    wcWhitespace
  elif r in c.runes:
    wcSeparator
  else:
    wcRegular

func clustersOf(c: WordClassifier; line: string): seq[ClusterClass] =
  for cluster in graphemeClusters(line):
    result.add ClusterClass(start: cluster.start, stop: cluster.stop,
                            cls: c.classOf(runeAt(cluster.text, 0)))

func clusterAtOrBefore(cl: openArray[ClusterClass]; byteCol: int): int =
  ## The cluster boundary at or before `byteCol`, as a cluster index;
  ## `cl.len` at or past the end of the line.
  for i in 0 ..< cl.len:
    if cl[i].stop > byteCol:
      return i
  cl.len

func endOfWord(cl: openArray[ClusterClass]; kind: WordKind; start: int): int =
  for i in start ..< cl.len:
    case cl[i].cls
    of wcWhitespace: return i
    of wcSeparator:
      if kind == wkRegular: return i
    of wcRegular:
      if kind == wkSeparator: return i
  cl.len

func startOfWord(cl: openArray[ClusterClass]; kind: WordKind;
                 start: int): int =
  for i in countdown(start, 0):
    case cl[i].cls
    of wcWhitespace: return i + 1
    of wcSeparator:
      if kind == wkRegular: return i + 1
    of wcRegular:
      if kind == wkSeparator: return i + 1
  0

func previousWord(cl: openArray[ClusterClass]; at: int): Option[FoundWord] =
  var kind = wkNone
  for i in countdown(at - 1, 0):
    case cl[i].cls
    of wcRegular:
      if kind == wkSeparator:
        return some FoundWord(first: i + 1, last: endOfWord(cl, kind, i + 1),
                              kind: kind)
      kind = wkRegular
    of wcSeparator:
      if kind == wkRegular:
        return some FoundWord(first: i + 1, last: endOfWord(cl, kind, i + 1),
                              kind: kind)
      kind = wkSeparator
    of wcWhitespace:
      if kind != wkNone:
        return some FoundWord(first: i + 1, last: endOfWord(cl, kind, i + 1),
                              kind: kind)
  if kind != wkNone:
    return some FoundWord(first: 0, last: endOfWord(cl, kind, 0), kind: kind)

func nextWord(cl: openArray[ClusterClass]; at: int): Option[FoundWord] =
  var kind = wkNone
  for i in at ..< cl.len:
    case cl[i].cls
    of wcRegular:
      if kind == wkSeparator:
        return some FoundWord(first: startOfWord(cl, kind, i - 1), last: i,
                              kind: kind)
      kind = wkRegular
    of wcSeparator:
      if kind == wkRegular:
        return some FoundWord(first: startOfWord(cl, kind, i - 1), last: i,
                              kind: kind)
      kind = wkSeparator
    of wcWhitespace:
      if kind != wkNone:
        return some FoundWord(first: startOfWord(cl, kind, i - 1), last: i,
                              kind: kind)
  if kind != wkNone:
    return some FoundWord(first: startOfWord(cl, kind, cl.len - 1),
                          last: cl.len, kind: kind)

func byteAt(cl: openArray[ClusterClass]; i: int; line: string): int =
  if i >= cl.len: line.len else: cl[i].start

func wordAtBoundary*(c: WordClassifier; line: string; byteCol: int): LineSpan =
  ## A press at caret boundary `byteCol`: `WordOperations.word(…, false)`.
  ## A regular word touching the boundary, the previous one first; otherwise
  ## everything between the neighbouring words, so whitespace, indentation and
  ## a run of separators select themselves and an empty line selects nothing.
  let cl = c.clustersOf(line)
  let at = cl.clusterAtOrBefore(byteCol)
  let prev = cl.previousWord(at)
  let next = cl.nextWord(at)
  if prev.isSome and prev.get.kind == wkRegular and prev.get.first <= at and
     at <= prev.get.last:
    return LineSpan(first: cl.byteAt(prev.get.first, line),
                    last: cl.byteAt(prev.get.last, line))
  if next.isSome and next.get.kind == wkRegular and next.get.first <= at and
     at <= next.get.last:
    return LineSpan(first: cl.byteAt(next.get.first, line),
                    last: cl.byteAt(next.get.last, line))
  # Inside a run of separators the previous word ends after the next one starts,
  # and Monaco's `Range` constructor puts the two columns in order.
  let a = if prev.isSome: cl.byteAt(prev.get.last, line) else: 0
  let b = if next.isSome: cl.byteAt(next.get.first, line) else: line.len
  LineSpan(first: min(a, b), last: max(a, b))

func wordAtCell*(c: WordClassifier; line: string; byteCol: int): LineSpan =
  ## A press that names a CELL rather than a boundary, the terminal without
  ## DECSET 1016: the regular word, the whitespace gap or the separator run
  ## holding the cell's character. A single separator selects itself here,
  ## which is the one place cell and pixel input differ (MC.3). Past the end of
  ## the line it is the boundary rule.
  let cl = c.clustersOf(line)
  let at = cl.clusterAtOrBefore(byteCol)
  if at >= cl.len:
    return c.wordAtBoundary(line, line.len)
  let cls = cl[at].cls
  var first = at
  while first > 0 and cl[first - 1].cls == cls:
    dec first
  var last = at + 1
  while last < cl.len and cl[last].cls == cls:
    inc last
  LineSpan(first: cl.byteAt(first, line), last: cl.byteAt(last, line))

func wordExtensionAt*(c: WordClassifier; line: string; byteCol: int): LineSpan =
  ## Where a by-word drag may land at `byteCol`, `WordOperations.word(…, true)`
  ## before its anchor test: the regular word the boundary is strictly INSIDE,
  ## otherwise the boundary itself.
  let cl = c.clustersOf(line)
  let at = cl.clusterAtOrBefore(byteCol)
  let prev = cl.previousWord(at)
  let next = cl.nextWord(at)
  if prev.isSome and prev.get.kind == wkRegular and prev.get.first < at and
     at < prev.get.last:
    return LineSpan(first: cl.byteAt(prev.get.first, line),
                    last: cl.byteAt(prev.get.last, line))
  if next.isSome and next.get.kind == wkRegular and next.get.first < at and
     at < next.get.last:
    return LineSpan(first: cl.byteAt(next.get.first, line),
                    last: cl.byteAt(next.get.last, line))
  let here = cl.byteAt(at, line)
  LineSpan(first: here, last: here)

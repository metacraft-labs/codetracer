## test_plat57_find_in_files.nim — PLAT-57: THE Find in Files runner
## (`viewmodel/host/find_in_files`), on both backends (vm-unit, vm-unit-js).
##
## Find-And-Incremental-Search.md §5.4 and FS-8. What is graded:
##
##   * the two engines agree — `rg --json` and the in-process walker give the
##     same rows, in the same order, with the same match positions — on a
##     real corpus on the real filesystem that holds a directory literally
##     named `C:` (a drive-letter-shaped path a colon split breaks on), a line
##     containing `x.nim:12:`, a hidden folder, a binary file, a symbolic link,
##     CRLF line ends, upper-case non-ASCII letters, letters with three case
##     forms (`ς` / `σ` / `Σ`, the Kelvin sign), sibling names that sort
##     differently as paths and as names (`b`, `b-dir`), and a pattern that
##     starts with `-` — for literals and for a corpus of regular expressions
##     under every combination of the toggles;
##   * a regular expression one engine would refuse is refused before either
##     runs, with `rg`'s own reason — and `rg` itself, asked directly, does
##     refuse each such pattern (so the refusal list is `rg`'s, not a guess);
##   * `rg`'s output is read as JSON, never split on colons;
##   * batches of 50, the last one marked done;
##   * a second search started while the first streams leaves no row of the
##     first in the pane's ViewModel, and the first's sink is never called
##     again;
##   * the scope rule (the desktop's `onSearchProgram`, now one function);
##   * the field's toggle keys: `Alt+C` / `Alt+W` / `Alt+R` where Find in
##     Files' field has the focus (the pane's own field, or the palette on a
##     `:grep` line), each base's other `Alt` rows everywhere else.
##
## On the C backend the runner spawns the real `rg` (the dev shells and CI
## carry it). On the JS backend node streams `rg`'s output as events, which a
## synchronous suite cannot wait for, so the JS arm runs the same `rg`
## command through node's `spawnSync` and reads its output with the runner's
## own `parseRgJsonLine` — the differential is the same, the transport is the
## one stand-in, and it is not a mock: it is `rg` itself.
##
## No mocks: a real corpus on disk, the real `rg`, the real walker, the real
## `SearchResultsVM`.

import std/[strutils, unittest]

import ../../host/find_in_files
import ../../viewmodels/search_results_vm
import ../../store/types
import ../../editing_core
import ../../keymap/keymap_router
import ../../keymap/scope_path
import ../../keymap/operation_catalogue   # PaletteTable
from ../../viewmodels/omnibar_vm import paletteFieldOf
import isonim/core/[signals, computation]
import isonim/viewmodel   # ViewModel.dispose

when defined(js):
  import std/jsffi
else:
  import std/[os, osproc, streams, tempfiles]

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 220

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

# ---------------------------------------------------------------------------
# The corpus, on the real filesystem of either backend
# ---------------------------------------------------------------------------

when defined(js):
  proc nodeRequire(name: cstring): JsObject {.importjs: "require(#)".}
  let fs = nodeRequire("fs")
  let nodeOs = nodeRequire("os")
  let cp = nodeRequire("child_process")

  proc makeTempDir(prefix: string): string =
    $fs.mkdtempSync(cstring($nodeOs.tmpdir().to(cstring) & "/" & prefix)).to(cstring)
  proc ensureDir(path: string) =
    discard fs.mkdirSync(cstring(path), js{recursive: true})
  proc writeTo(path, content: string) =
    # Bytes, not UTF-16 text: a Nim string on the JS backend is UTF-8 bytes.
    var arr = newSeq[int](content.len)
    for i, c in content:
      arr[i] = int(c)
    let buf = nodeRequire("buffer").Buffer.`from`(arr.toJs)
    discard fs.writeFileSync(cstring(path), buf)
  proc linkTo(target, path: string) =
    discard fs.symlinkSync(cstring(target), cstring(path))
  proc removeTree(path: string) =
    discard fs.rmSync(cstring(path), js{recursive: true, force: true})

  proc rgDirect(pattern: string; options: TextMatchOptions;
                roots: seq[string]): tuple[code: int, errors: string] =
    ## `rg` itself, asked directly with the runner's argument vector — no
    ## refusal of ours in front of it.
    var argv: seq[cstring] = @[]
    for a in rgArguments(pattern, options, roots):
      argv.add cstring(a)
    let r = cp.spawnSync(cstring(ripgrepOnPath()), argv.toJs,
                         js{encoding: cstring"utf8"})
    (r.status.to(int), $r.stderr.to(cstring))

  proc rgRows(pattern: string; options: TextMatchOptions;
              scope: FindInFilesScope): seq[SearchResultLine] =
    ## `rg` run synchronously (the JS arm's transport, see the header), its
    ## output read by the runner's own parser.
    var argv: seq[cstring] = @[]
    for a in rgArguments(pattern, options, scope.roots):
      argv.add cstring(a)
    let r = cp.spawnSync(cstring(ripgrepOnPath()), argv.toJs,
                         js{encoding: cstring"utf8",
                            maxBuffer: 64 * 1024 * 1024})
    for line in ($r.stdout.to(cstring)).splitLines():
      let parsed = parseRgJsonLine(line, scope)
      if parsed.ok:
        result.add parsed.row
else:
  proc rgDirect(pattern: string; options: TextMatchOptions;
                roots: seq[string]): tuple[code: int, errors: string] =
    ## `rg` itself, asked directly with the runner's argument vector — no
    ## refusal of ours in front of it.
    let p = startProcess(ripgrepOnPath(),
                         args = rgArguments(pattern, options, roots),
                         options = {})
    discard p.outputStream.readAll()
    result.errors = p.errorStream.readAll()
    result.code = p.waitForExit()
    p.close()

  proc makeTempDir(prefix: string): string = createTempDir(prefix, "")
  proc ensureDir(path: string) = createDir(path)
  proc writeTo(path, content: string) = writeFile(path, content)
  proc linkTo(target, path: string) = createSymlink(target, path)
  proc removeTree(path: string) = removeDir(path)

  proc rgRows(pattern: string; options: TextMatchOptions;
              scope: FindInFilesScope): seq[SearchResultLine] =
    var rows: seq[SearchResultLine] = @[]
    let sink = proc(b: FindInFilesBatch) =
      for r in b.rows: rows.add r
    let run = newFindInFilesService().search(1, pattern, options, scope,
                                             sink, engine = fieRipgrep)
    run.runToCompletion()
    doAssert run.engine == fieRipgrep, "rg is not on PATH"
    rows

proc walkerRows(pattern: string; options: TextMatchOptions;
                scope: FindInFilesScope): seq[SearchResultLine] =
  var rows: seq[SearchResultLine] = @[]
  let sink = proc(b: FindInFilesBatch) =
    for r in b.rows: rows.add r
  let run = newFindInFilesService().search(1, pattern, options, scope,
                                           sink, engine = fieWalker)
  run.runToCompletion()
  rows

proc noteOf(pattern: string; options: TextMatchOptions;
            scope: FindInFilesScope; engine: FindInFilesEngine):
    tuple[rows: int, note: string, done: bool] =
  ## What a run of `engine` ends with: its row count and its last note.
  var rows = 0
  var note = ""
  var done = false
  let sink = proc(b: FindInFilesBatch) =
    rows += b.rows.len
    done = b.done
    if b.note.len > 0: note = b.note
  let run = newFindInFilesService().search(1, pattern, options, scope, sink,
                                           engine = engine)
  run.runToCompletion()
  (rows, note, done)

func opts(regex = false; caseSensitive = false;
          wholeWord = false): TextMatchOptions =
  TextMatchOptions(regex: regex, caseSensitive: caseSensitive,
                   wholeWord: wholeWord)

proc corpus(): string =
  ## A recording-shaped tree: `<root>/files/...` is the materialised store.
  result = makeTempDir("p57-corpus-")
  let store = result & "/files"
  ensureDir(store & "/C:/src")
  ensureDir(store & "/proj/.hidden")
  ensureDir(store & "/proj/b-dir")
  ensureDir(store & "/proj/deep/er")
  writeTo(store & "/C:/src/x.nim",
          "let foo = 1\nsee x.nim:12: here, foo\nFoo foo FOO\nfoobar\n")
  writeTo(store & "/proj/a.txt", "nothing\nfoo\r\nend foo\r\n")
  writeTo(store & "/proj/b", "foo top\n-dash and foo\n")
  writeTo(store & "/proj/b-dir/u.txt",
          "foo_bar foo-bar ÄRGER über\n")
  writeTo(store & "/proj/.hidden/h.txt", "foo hidden\n")
  writeTo(store & "/proj/bin.dat", "foo\0binary\n")
  writeTo(store & "/proj/deep/er/z.py", "def foo():\n    return 'Foo'\n")
  # Three case forms of one letter, and the Kelvin sign (`k` / `K` / `\u212A`).
  writeTo(store & "/proj/fold.txt",
          "ΣΟΦΟΣ σοφος\nKelvin \u212A done\nkelvin\nfoo42 bar7: x\n")
  linkTo(store & "/proj/a.txt", store & "/proj/link.txt")

proc key(r: SearchResultLine): string =
  r.path & ":" & $r.line & ":" & $r.matchStart & "+" & $r.matchLength &
    ":" & r.text

proc keys(rows: seq[SearchResultLine]): seq[string] =
  for r in rows: result.add key(r)

suite "the runner's pure parts":

  test "rg is given an argument vector, JSON output and the pattern after --":
    let args = rgArguments("-dash", TextMatchOptions(), ["/a/", "/b"])
    ck args[0] == "--json"
    ck "--fixed-strings" in args and "--ignore-case" in args
    ck "--no-config" in args and "--no-ignore" in args
    let dd = args.find("--")
    ck dd >= 0 and args[dd + 1] == "-dash"
    ck args[^2] == "/a" and args[^1] == "/b"
    let word = rgArguments("x", TextMatchOptions(caseSensitive: true,
                                                  wholeWord: true), ["/r"])
    ck "--case-sensitive" in word and "--word-regexp" in word
    # A regular expression is given as one: no `--fixed-strings`.
    ck "--fixed-strings" notin rgArguments("a.c", opts(regex = true), ["/r"])

  test "rg --json is read as JSON: a drive letter and a path:line: text survive":
    let line = """{"type":"match","data":{"path":{"text":"C:\\proj\\x.nim"},""" &
      """"lines":{"text":"see x.nim:12: here\r\n"},"line_number":7,""" &
      """"absolute_offset":0,"submatches":[{"match":{"text":"x.nim:12:"},""" &
      """"start":4,"end":13}]}}"""
    let parsed = parseRgJsonLine(line, FindInFilesScope())
    ck parsed.ok
    ck parsed.row.path == "C:\\proj\\x.nim"
    ck parsed.row.line == 7
    ck parsed.row.text == "see x.nim:12: here"
    ck parsed.row.matchStart == 4 and parsed.row.matchLength == 9
    # A path rg could not print as UTF-8 arrives as base64 bytes.
    let bytes = """{"type":"match","data":{"path":{"bytes":"L3Ivw7wudHh0"},""" &
      """"lines":{"text":"q\n"},"line_number":1,"submatches":[]}}"""
    let b = parseRgJsonLine(bytes, FindInFilesScope(stripPrefix: "/r"))
    ck b.ok and b.row.path == "/ü.txt" and b.row.matchLength == 0
    ck not parseRgJsonLine("""{"type":"begin","data":{}}""",
                           FindInFilesScope()).ok
    ck not parseRgJsonLine("C:\\proj\\x.nim:12:text", FindInFilesScope()).ok

  test "the matcher: literal, case-folded rune by rune, whole words as rg -w":
    ck matchSpans("Foo foo FOO", "foo", TextMatchOptions()) ==
      @[0 .. 2, 4 .. 6, 8 .. 10]
    ck matchSpans("Foo foo FOO", "foo",
                  TextMatchOptions(caseSensitive: true)) == @[4 .. 6]
    ck matchSpans("foobar foo_bar foo-bar foo", "foo",
                  TextMatchOptions(wholeWord: true)) == @[15 .. 17, 23 .. 25]
    # A word character BEFORE the occurrence disqualifies it too.
    ck matchSpans("_foo xfoo 1foo foo", "foo",
                  TextMatchOptions(wholeWord: true)) == @[15 .. 17]
    # `ä` is two bytes; the offsets are the original line's.
    ck matchSpans("über ÄRGER", "ärger", TextMatchOptions()) == @[6 .. 11]
    ck matchSpans("anything", "", TextMatchOptions()).len == 0
    # A literal's metacharacters stand for themselves.
    ck matchSpans("a.c abc a.c", "a.c", TextMatchOptions()) == @[0 .. 2, 8 .. 10]
    # Unicode simple case folding: `ς`, `σ`, `Σ` are one letter, as are `k`
    # and the Kelvin sign.
    ck matchSpans("ΣΟΦΟΣ σοφος", "σοφος", TextMatchOptions()) ==
      @[0 .. 9, 11 .. 20]
    ck matchSpans("Kelvin \u212A", "k", TextMatchOptions()) == @[0 .. 0, 7 .. 9]

  test "the matcher: regular expressions, and whole words inside the expression":
    ck matchSpans("foo42 bar7: x", "[a-z]+\\d+", opts(regex = true)) ==
      @[0 .. 4, 6 .. 9]
    ck matchSpans("Foo foo", "^foo", opts(regex = true)) == @[0 .. 2]
    ck matchSpans("Foo foo", "^foo", opts(regex = true,
                                         caseSensitive = true)).len == 0
    # The whole-word assertions are part of the expression: the alternative
    # that stands as a word is found, as `rg -w` finds it.
    ck matchSpans("foobar", "foo|foobar", opts(regex = true,
                                               wholeWord = true)) == @[0 .. 5]
    # A pattern's own flag wins over the toggle, as in `rg`.
    ck matchSpans("FOO foo", "(?-i)foo", opts(regex = true)) == @[4 .. 6]
    # An empty match is a match, at no width.
    let c = compileTextMatcher("x*", opts(regex = true))
    ck c.ok and c.matcher.firstMatch("abc") == (true, 0, 0)

  test "a regular expression the two engines do not share is refused, with rg's reason":
    for (pattern, reason) in [
        ("(?=a)b", "look-around, including look-ahead and look-behind, is not supported"),
        ("a(?<!b)", "look-around, including look-ahead and look-behind, is not supported"),
        ("(a)\\1", "back-references are not supported"),
        ("a\\nb", "a pattern cannot match a line break")]:
      let c = compileTextMatcher(pattern, opts(regex = true))
      ck not c.ok and c.error == "invalid regular expression: " & reason
      # As a literal it is only characters.
      ck compileTextMatcher(pattern, opts()).ok
    let unclosed = compileTextMatcher("(foo", opts(regex = true))
    ck not unclosed.ok and unclosed.error.startsWith("invalid regular expression: ")
    # A Unicode class names a general category; a script is refused
    # (nim-regex's own refusal — the module header lists it).
    ck compileTextMatcher("\\p{Lu}", opts(regex = true)).ok
    ck not compileTextMatcher("\\p{Greek}", opts(regex = true)).ok
    # `rg`'s own refusal, read from its error stream.
    ck rgRefusal("regex parse error:\n    (?=a)\n    ^^^\nerror: look-around, " &
                 "including look-ahead and look-behind, is not supported\n") ==
       "invalid regular expression: look-around, including look-ahead and " &
       "look-behind, is not supported"
    ck rgRefusal("rg: the literal \"\\n\" is not allowed in a regex\n" &
                 "Consider enabling multiline mode\n") ==
       "invalid regular expression: the literal \"\\n\" is not allowed in a regex"
    ck rgRefusal("") == ""

  test "the scope: the store when it is preferred and present, else folders":
    let root = corpus()
    let store = root & "/files"
    let s1 = findInFilesScope(store & "/", true, ["/nonexistent"])
    ck s1.roots == @[store] and s1.stripPrefix == store
    let s2 = findInFilesScope(store, false,
                              [store & "/proj", store & "/proj/deep",
                               "/nonexistent", store & "/C:"])
    ck s2.roots == @[store & "/proj", store & "/C:"] and s2.stripPrefix == ""
    let s3 = findInFilesScope("/nonexistent", true, ["/also-not"])
    ck s3.roots.len == 0 and s3.reason.len > 0
    removeTree(root)

suite "FS-8: rg and the walker agree":

  test "every pattern, every option, the same rows in the same order":
    let root = corpus()
    let scope = findInFilesScope(root & "/files", true, [])
    let cases = @[
      ("foo", TextMatchOptions()),
      ("foo", TextMatchOptions(wholeWord: true)),
      ("FOO", TextMatchOptions(caseSensitive: true)),
      ("x.nim:12:", TextMatchOptions()),
      ("ärger", TextMatchOptions()),
      ("-dash", TextMatchOptions()),
      ("σοφος", TextMatchOptions()),
      ("k", TextMatchOptions(wholeWord: true))]
    for (pattern, options) in cases:
      let viaRg = rgRows(pattern, options, scope)
      let viaWalker = walkerRows(pattern, options, scope)
      checkpoint(pattern & " rg: " & $keys(viaRg))
      checkpoint(pattern & " walker: " & $keys(viaWalker))
      ck viaRg.len > 0
      ck keys(viaRg) == keys(viaWalker)
    removeTree(root)

  test "what is searched: no hidden entry, no binary file, no link, the store's prefix gone":
    let root = corpus()
    let scope = findInFilesScope(root & "/files", true, [])
    let rows = walkerRows("foo", TextMatchOptions(), scope)
    var paths: seq[string] = @[]
    for r in rows:
      if r.path notin paths: paths.add r.path
    ck paths == @["/C:/src/x.nim", "/proj/a.txt", "/proj/b",
                  "/proj/b-dir/u.txt", "/proj/deep/er/z.py", "/proj/fold.txt"]
    ck keys(rows)[1] == "/C:/src/x.nim:2:20+3:see x.nim:12: here, foo"
    # CRLF: the line's text ends before the `\r`.
    ck keys(rows)[4] == "/proj/a.txt:2:0+3:foo"
    # A match that reaches into the `\r` (`.` matches it, as in `rg`) is
    # clipped to the text the row shows, on both engines.
    for engineRows in [walkerRows("foo.", opts(regex = true), scope),
                       rgRows("foo.", opts(regex = true), scope)]:
      var crlf = ""
      for r in engineRows:
        if r.path == "/proj/a.txt" and r.line == 2: crlf = key(r)
      ck crlf == "/proj/a.txt:2:0+3:foo"
    removeTree(root)

  test "regular expressions: every pattern, every toggle, the same rows":
    let root = corpus()
    let scope = findInFilesScope(root & "/files", true, [])
    let patterns = ["fo+", "^foo", "foo$", "\\bfoo\\b", "[A-Z]\\w+",
                    "\\d+:", "x\\.nim:\\d+:", "ä|ü", "foo|foobar",
                    "(?-i)\\p{Lu}{2,}", "\\pL+\\d", "[[:digit:]]+", "\\s$", "(?i)ärger",
                    "σ", "-da.h", "o*", "end.*$", "\\x{212A}"]
    var compared = 0
    for pattern in patterns:
      for bits in 0 ..< 4:
        let options = opts(regex = true, caseSensitive = (bits and 1) != 0,
                           wholeWord = (bits and 2) != 0)
        let viaRg = rgRows(pattern, options, scope)
        let viaWalker = walkerRows(pattern, options, scope)
        if keys(viaRg) != keys(viaWalker):
          checkpoint(pattern & " " & $options & " rg: " & $keys(viaRg))
          checkpoint(pattern & " " & $options & " walker: " & $keys(viaWalker))
        ck keys(viaRg) == keys(viaWalker)
        compared += viaRg.len
    # Not an agreement of two empty answers: the corpus matched.
    ck compared > 200
    removeTree(root)

  test "a refused pattern: rg refuses it too, and either engine says why":
    let root = corpus()
    let scope = findInFilesScope(root & "/files", true, [])
    for pattern in ["(?=a)b", "a(?<!b)", "(a)\\1", "a\\nb", "(foo"]:
      let asked = rgDirect(pattern, opts(regex = true), scope.roots)
      checkpoint(pattern & ": rg said " & asked.errors)
      ck asked.code == 2 and rgRefusal(asked.errors).startsWith(
        "invalid regular expression: ")
      let viaRg = noteOf(pattern, opts(regex = true), scope, fieRipgrep)
      let viaWalker = noteOf(pattern, opts(regex = true), scope, fieWalker)
      ck viaRg.rows == 0 and viaWalker.rows == 0
      ck viaRg.done and viaWalker.done
      ck viaRg.note == viaWalker.note and
         viaRg.note.startsWith("invalid regular expression: ")
    removeTree(root)

suite "streaming and cancellation":

  test "batches of 50, the last one done":
    let root = makeTempDir("p57-batch-")
    var text = ""
    for i in 0 ..< 120:
      text.add "needle " & $i & "\n"
    writeTo(root & "/many.txt", text)
    let scope = findInFilesScope(root, false, [root])
    var sizes: seq[int] = @[]
    var dones: seq[bool] = @[]
    var ids: seq[int] = @[]
    let sink = proc(b: FindInFilesBatch) =
      ids.add b.runId
      sizes.add b.rows.len
      dones.add b.done
    let run = newFindInFilesService().search(3, "needle", TextMatchOptions(),
                                             scope, sink, engine = fieWalker)
    run.runToCompletion()
    ck ids == @[3, 3, 3]
    ck sizes == @[50, 50, 20]
    ck dones == @[false, false, true]
    removeTree(root)

  test "a second search leaves no row of the first, however late it streams":
    let root = makeTempDir("p57-cancel-")
    for f in 0 ..< 400:
      var text = ""
      for i in 0 ..< 5:
        text.add "alpha " & $f & " " & $i & "\nbeta " & $f & "\n"
      writeTo(root & "/f" & align($f, 4, '0') & ".txt", text)
    let scope = findInFilesScope(root, false, [root])
    let vm = createSearchResultsVM(nil)
    let service = newFindInFilesService()
    var firstAfterSecond = 0
    var secondStarted = false
    let sink = proc(b: FindInFilesBatch) =
      if secondStarted and b.runId != vm.runId:
        inc firstAfterSecond
      discard vm.acceptBatch(b.runId, b.rows, b.done, b.note)
    vm.onSearch = proc(runId: int; query: string; options: TextMatchOptions) =
      discard service.search(runId, query, options, scope, sink,
                             engine = fieWalker)
    vm.search("alpha")
    let first = service.current
    discard service.pump()          # the first search is streaming…
    ck vm.results.val.len > 0 and vm.searching.val
    secondStarted = true
    vm.search("beta")               # …when the second starts
    ck first.cancelled
    ck not first.pump()             # a cancelled run does nothing more
    service.current.runToCompletion()
    ck firstAfterSecond == 0
    ck vm.results.val.len == 2000
    var allBeta = true
    for r in vm.results.val:
      if not r.text.startsWith("beta"): allBeta = false
    ck allBeta
    ck not vm.searching.val and vm.query.val == "beta"
    # A batch of the first search delivered late is dropped by the VM.
    ck not vm.acceptBatch(vm.runId - 1, @[SearchResultLine(text: "alpha")],
                          true)
    ck vm.results.val.len == 2000
    vm.dispose()
    removeTree(root)

suite "the ViewModel's grouping and walking":

  test "rows grouped by file in arrival order; next and previous wrap":
    let vm = createSearchResultsVM(nil)
    let id = vm.beginSearch("q")
    ck vm.acceptBatch(id, @[
      SearchResultLine(path: "/a.py", line: 1, text: "q1"),
      SearchResultLine(path: "/b.py", line: 2, text: "q2"),
      SearchResultLine(path: "/a.py", line: 3, text: "q3")], true)
    let groups = vm.groups.val
    ck groups.len == 2 and groups[0].path == "/a.py" and
       groups[0].rows.len == 2 and groups[0].rows[1].index == 2
    ck vm.summaryText() == "3 results in 2 files"
    ck vm.stepResult(1) == 0 and vm.stepResult(-1) == 2
    vm.selectResult(2)
    ck vm.stepResult(1) == 0
    ck shortResultPath("/home/u/proj/a.py") == "proj/a.py"
    let parts = rowParts(SearchResultLine(text: "    let foo = 1",
                                          matchStart: 8, matchLength: 3))
    ck parts.matched and parts.before == "let " and parts.hit == "foo" and
       parts.after == " = 1"
    vm.dispose()

suite "§5.3: walking the results is a key of every base that has one":

  test "F4 / Shift+F4 under CUA, Alt+G N / Alt+G P under Emacs, anywhere":
    let delivery = KeyDelivery(frontEnd: feTerminal, platform: pkLinux,
                               keyProtocol: kpKitty)
    let facts = SessionFacts(product: pmDebug, replayLoaded: true,
                             editor: EditorFacts(readOnly: true,
                                                 mode: emInsert))
    let window = element(ekWindow, "window")
    let tab = element(ekTab, "tab:1")
    let paths = @[
      @[window, tab, pane("editor"), element(ekEditor, "editor:main.py")],
      @[window, tab, pane("search"), element(ekRow, "result-0")]]
    proc opOf(base: BaseKeymap; path: ScopePath; keys: varargs[string]): string =
      var r = initKeymapRouter(base, delivery)
      var res: EditingResolution
      var t = 1_000'i64
      for k in keys:
        res = r.route(facts, path, nmNormal, k, t)
        t += 10
      if res.kind == erOperation: res.operation else: $res.kind
    for path in paths:
      ck opOf(bkCua, path, "F4") == "search.next-result"
      ck opOf(bkCua, path, "Shift+F4") == "search.previous-result"
      ck opOf(bkEmacs, path, "Alt+g", "n") == "search.next-result"
      ck opOf(bkEmacs, path, "Alt+g", "p") == "search.previous-result"
    # The prefix `Alt+G` still ends in `goto-line` in the editor.
    ck opOf(bkEmacs, paths[0], "Alt+g", "g") == "palette.go-to-line"

  test "the field's toggles: Alt+C / Alt+W / Alt+R where Find in Files' field has the focus":
    let delivery = KeyDelivery(frontEnd: feTerminal, platform: pkLinux,
                               keyProtocol: kpKitty)
    let window = element(ekWindow, "window")
    let facts = SessionFacts(product: pmDebug, replayLoaded: true,
                             paletteVisible: true)
    # The palette's field is Find in Files' field while it holds `:grep`.
    ck paletteFieldOf(":grep foo") == element(ekInput, SearchQueryInput)
    ck paletteFieldOf(":grep") == element(ekInput, SearchQueryInput)
    ck paletteFieldOf("main.py") == element(ekInput, PaletteQueryInput)
    let grepLine = @[window, element(ekOverlay, "palette"),
                     paletteFieldOf(":grep foo")]
    let paneField = @[window, element(ekTab, "tab:1"), pane("search"),
                      element(ekInput, SearchQueryInput)]
    let elsewhere = @[window, element(ekTab, "tab:1"), pane("calltrace"),
                      element(ekRow, "call-3")]
    proc opOf(base: BaseKeymap; path: ScopePath; key: string;
              palette: bool): string =
      var r = initKeymapRouter(base, delivery)
      if palette:
        discard r.pushLayer(PaletteTable, "window", "PALETTE")
      let res = r.route(facts, path, nmNormal, key, 1_000)
      if res.kind == erOperation: res.operation else: $res.kind
    for base in [bkCua, bkEmacs]:
      for (path, palette) in [(grepLine, true), (paneField, false)]:
        ck opOf(base, path, "Alt+c", palette) == "search.toggle-case"
        ck opOf(base, path, "Alt+w", palette) == "search.toggle-whole-word"
        ck opOf(base, path, "Alt+r", palette) == "search.toggle-regex"
    # Outside the field each base's own `Alt` rows hold: CUA's pane focus and
    # program-menu mnemonics.
    ck opOf(bkCua, elsewhere, "Alt+c", false) == "layout.focus-pane"
    ck opOf(bkCua, elsewhere, "Alt+w", false) == "menu.open-folder"
    ck opOf(bkCua, elsewhere, "Alt+r", false) == "menu.open-folder"

  test "a toggle flips the option and runs the search again, regex included":
    let vm = createSearchResultsVM(nil)
    var asked: seq[TextMatchOptions] = @[]
    vm.onSearch = proc(runId: int; query: string; options: TextMatchOptions) =
      asked.add options
    vm.toggleOption(soRegex)          # no query yet: nothing runs
    ck vm.options.val.regex and asked.len == 0
    vm.search("fo+")
    vm.toggleOption(soWord)
    vm.toggleOption(soRegex)
    ck asked.len == 3
    ck asked[0].regex and not asked[0].wholeWord
    ck asked[1].regex and asked[1].wholeWord
    ck not asked[2].regex and asked[2].wholeWord
    # Each toggle's operation by name, as the keymaps spell it.
    ck searchOptionOf("search.toggle-case") == (true, soCase)
    ck searchOptionOf("search.toggle-whole-word") == (true, soWord)
    ck searchOptionOf("search.toggle-regex") == (true, soRegex)
    ck not searchOptionOf("search.next-result").ok
    vm.dispose()

  test "assertion count":
    check countedAssertions == ExpectedAssertions

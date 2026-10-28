## host/find_in_files.nim — THE Find in Files runner, for every front-end.
##
## Find-And-Incremental-Search.md §5.4: one runner, used by all three
## front-ends. It is compiled to C for the terminal and the GPUI window, and
## to JS for Electron's main process (`index/ipc_utils.onSearchProgram`), so
## the desktop, the terminal and GPUI search the same roots with the same
## rule and stream the same rows.
##
## ## What it does
##
## Given a pattern, the pane's options (`TextMatchOptions`) and a scope
## (`findInFilesScope`, the desktop's rule as one function), it streams
## `SearchResultLine` batches of `FindInFilesBatchSize` (the desktop's 50) to
## a sink, the last one marked `done`. Two engines, one result:
##
## * **`rg --json` when `rg` is on `PATH`**, spawned with an ARGUMENT VECTOR
##   (`rgArguments`), never through a shell, and read as JSON
##   (`parseRgJsonLine`): the desktop used to build a shell string and split
##   `path:line:text` on colons, which breaks on a Windows drive letter and on
##   a line that itself contains `x.nim:12:`.
## * **Otherwise the in-process walker** over the same roots with the shared
##   matcher (`text_match`, the expression `rg` builds from the same
##   flags, on an engine of `rg`'s syntax). It visits what `rg` visits with
##   the flags this module passes — hidden entries and symbolic links
##   skipped, files containing a NUL byte skipped as binary, no ignore files,
##   siblings in byte order of their names (`--sort path`) — so the two
##   engines give the same rows in the same order (FS-8). `rg` is an
##   optimisation, not a dependency.
##
## A pattern is compiled before either engine starts (`compileTextMatcher`):
## a regular expression the two engines do not both accept ends the search
## at once, with the reason as its note, so neither engine ever answers a
## pattern the other would refuse.
##
## ## Streaming and cancellation
##
## A run is a step machine the caller drives: on the C backend the host's
## event loop calls `pump` (the descriptor of `rg`'s output is read with
## `O_NONBLOCK`, as `tui/host/build_runner.nim` measured it must be; the
## walker visits a bounded number of files per call), on the JS backend
## node's events and a zero-delay timer drive it. `FindInFilesService.search`
## cancels the run in flight before it starts the next one — the process is
## killed, the walk stopped — and a cancelled run never calls its sink again,
## so a pane can never show rows of two searches (PLAT-51's latest-wins rule;
## the ViewModel also drops a batch whose run id is not its latest).

import std/[algorithm, base64, json, strutils]

import ../store/types
import ./text_match

export text_match

when defined(js):
  import std/jsffi
else:
  import std/os
  when not defined(wasm32):
    import std/[osproc, streams]
    when defined(posix):
      import std/posix

const
  FindInFilesBatchSize* = 50
    ## Rows per batch: the desktop's `onSearchProgram` sent 50 at a time.
  RipgrepProgram* = "rg"
  WalkerFilesPerPump* = 64
    ## How many files one `pump` of the walker reads, so a large tree never
    ## holds a native front-end's loop for long.
  RgBytesPerPump = 256 * 1024

type
  FindInFilesEngine* = enum
    fieRipgrep = "rg"
    fieWalker = "walker"

  FindInFilesScope* = object
    ## What a search reads. `roots` are directories (or files) searched in
    ## order; `stripPrefix` is removed from the front of every result path
    ## (the materialised `files/` store, so a row names the source path the
    ## recording knows). `reason` says why `roots` is empty.
    roots*: seq[string]
    stripPrefix*: string
    reason*: string

  FindInFilesBatch* = object
    runId*: int
    rows*: seq[SearchResultLine]
    done*: bool
    engine*: FindInFilesEngine
    note*: string
      ## Non-empty on the last batch when the search could not run at all
      ## (no root), so the pane can say why it found nothing.

  FindInFilesSink* = proc(batch: FindInFilesBatch) {.closure.}

  FindInFilesRun* = ref object
    id*: int
    pattern*: string
    options*: TextMatchOptions
    scope*: FindInFilesScope
    engine*: FindInFilesEngine
    sink: FindInFilesSink
    matcher: TextMatcher
    pending: seq[SearchResultLine]
    lineBuf: string
    finished*: bool
    cancelled*: bool
    emitted*: int
      ## Rows handed to the sink so far.
    todo: seq[string]
      ## The walker's work list, last entry next: paths not yet visited.
    errorText: string
      ## What `rg` wrote to its error stream: its reason when it refuses.
    when defined(js):
      child: JsObject
    elif not defined(wasm32):
      process: Process
      fd: cint
      sawEof: bool

  FindInFilesService* = ref object
    ## One per front-end: the run in flight, cancelled when the next starts.
    current*: FindInFilesRun

# ---------------------------------------------------------------------------
# Pure parts — shared verbatim by both backends and both engines
# ---------------------------------------------------------------------------

proc trimRoot(root: string): string =
  ## A root without a trailing separator, so `rg` and the walker spell the
  ## paths under it the same way (`dir/` would otherwise read `dir//a` here).
  result = root
  while result.len > 1 and result[^1] in {'/', '\\'}:
    result.setLen(result.len - 1)

proc outermost(roots: openArray[string]): seq[string] =
  ## The roots no other root contains, in order: a folder inside another is
  ## searched once, as part of its parent.
  for r in roots:
    var inside = false
    for o in roots:
      if o != r and (r.startsWith(o & "/") or r.startsWith(o & "\\")):
        inside = true
        break
    if not inside and r notin result:
      result.add r

proc rgArguments*(pattern: string; options: TextMatchOptions;
                  roots: openArray[string]): seq[string] =
  ## `rg`'s argument vector. JSON output; the pattern literal unless it is a
  ## regular expression; the case and
  ## whole-word toggles; no configuration file and no ignore files, so the
  ## result does not depend on the user's `RIPGREP_CONFIG_PATH` or on a
  ## `.gitignore` the walker does not read; siblings in path order, so the
  ## rows arrive in the walker's order; errors about unreadable files
  ## silenced (they are not rows). `--` ends the options: a pattern starting
  ## with `-` is a pattern.
  result = @["--json", "--no-config"]
  if not options.regex:
    result.add "--fixed-strings"
  result.add(if options.caseSensitive: "--case-sensitive"
             else: "--ignore-case")
  if options.wholeWord:
    result.add "--word-regexp"
  result.add @["--no-ignore", "--no-messages", "--sort", "path", "--",
               pattern]
  for r in roots:
    result.add trimRoot(r)

proc rgText(node: JsonNode): string =
  ## A `{"text": …}` or `{"bytes": <base64>}` field of `rg --json`.
  if node.isNil or node.kind != JObject:
    return ""
  if node.hasKey("text"):
    return node["text"].getStr
  if node.hasKey("bytes"):
    try:
      return decode(node["bytes"].getStr)
    except ValueError:
      return ""
  ""

proc stripLineEnd(text: string): string =
  result = text
  if result.endsWith("\n"):
    result.setLen(result.len - 1)
  if result.endsWith("\r"):
    result.setLen(result.len - 1)

proc resultPath*(scope: FindInFilesScope; path: string): string =
  ## The path a row names: `path` without the scope's `stripPrefix`.
  if scope.stripPrefix.len > 0 and path.startsWith(scope.stripPrefix) and
     path.len > scope.stripPrefix.len:
    path[scope.stripPrefix.len .. ^1]
  else:
    path

proc resultRow*(scope: FindInFilesScope; path: string; line: int;
                rawLine: string; first, stop: int): SearchResultLine =
  ## A row as both engines report it: the line's text without its line end,
  ## and the match `first ..< stop` (bytes of the line as it was searched,
  ## `\r` included) — kept only where it lies in that text, so a match that
  ## reaches into a CRLF's `\r` is a row without a highlight on either
  ## engine.
  result = SearchResultLine(path: scope.resultPath(path), line: line,
                            text: stripLineEnd(rawLine))
  let stop = min(stop, result.text.len)
  if first >= 0 and stop > first:
    result.matchStart = first
    result.matchLength = stop - first

proc parseRgJsonLine*(line: string; scope: FindInFilesScope):
    tuple[ok: bool, row: SearchResultLine] =
  ## One line of `rg --json` output: a row when it is a `match` message,
  ## nothing for the `begin` / `end` / `summary` messages or for a line that
  ## is not JSON at all.
  if line.len == 0 or line[0] != '{':
    return
  var node: JsonNode
  try:
    node = parseJson(line)
  except CatchableError:
    return
  if node.kind != JObject or node{"type"}.getStr != "match":
    return
  let data = node{"data"}
  if data.isNil or data.kind != JObject:
    return
  let path = rgText(data{"path"})
  if path.len == 0:
    return
  var first, stop = -1
  let subs = data{"submatches"}
  if not subs.isNil and subs.kind == JArray and subs.len > 0:
    first = subs[0]{"start"}.getInt(-1)
    stop = subs[0]{"end"}.getInt(-1)
  (true, resultRow(scope, path, data{"line_number"}.getInt,
                   rgText(data{"lines"}), first, stop))

proc matchRowsOf*(path, content: string; matcher: TextMatcher;
                  scope: FindInFilesScope): seq[SearchResultLine] =
  ## The walker's rows for one file's `content`: one row per matching line,
  ## with its first match, as `rg` reports them. A line is searched as `rg`
  ## searches it — up to its `\n`, a CRLF's `\r` still part of it.
  var lineNo = 0
  var start = 0
  while start < content.len:
    var stop = content.find('\n', start)
    if stop < 0:
      stop = content.len
    inc lineNo
    let line = content[start ..< stop]
    let m = matcher.firstMatch(line)
    if m.found:
      result.add resultRow(scope, path, lineNo, line, m.first, m.stop)
    start = stop + 1

# ---------------------------------------------------------------------------
# The platform seam: a directory listing, a file, `rg` on PATH
# ---------------------------------------------------------------------------

type
  WalkEntryKind = enum wekFile, wekDirectory, wekOther

when defined(js):
  proc nodeRequire(name: cstring): JsObject {.importjs: "require(#)".}
  proc jsSetTimeout(cb: proc(); ms: int): JsObject {.importjs: "setTimeout(#, #)".}
  proc isNullish(value: JsObject): bool {.importjs: "((#) == null)".}

  let nodeFs = nodeRequire("fs")
  let nodePath = nodeRequire("path")

  proc listEntries(dir: string): seq[(string, WalkEntryKind)] =
    try:
      let entries = nodeFs.readdirSync(cstring(dir),
                                       js{withFileTypes: true})
      let n = entries.length.to(int)
      for i in 0 ..< n:
        let e = entries[i]
        let name = $(e.name.to(cstring))
        # A `Dirent` carries `lstat`'s type, so a symbolic link is neither a
        # file nor a directory here: it is never followed, as `rg` does not.
        let kind =
          if e.isDirectory().to(bool): wekDirectory
          elif e.isFile().to(bool): wekFile
          else: wekOther
        result.add (name, kind)
    except:
      discard

  proc kindOf(path: string): WalkEntryKind =
    try:
      let st = nodeFs.statSync(cstring(path))
      if st.isDirectory().to(bool): wekDirectory
      elif st.isFile().to(bool): wekFile
      else: wekOther
    except:
      wekOther

  proc readTextFile(path: string): tuple[ok: bool, text: string] =
    ## The file's text, or not ok when it cannot be read or is binary (it
    ## holds a NUL byte, as `rg` decides).
    try:
      let buf = nodeFs.readFileSync(cstring(path))
      if buf.indexOf(0).to(int) >= 0:
        return (false, "")
      (true, $(buf.toString(cstring"utf8").to(cstring)))
    except:
      (false, "")

  proc joinPath(dir, name: string): string =
    if dir.endsWith("/") or dir.endsWith("\\"): dir & name
    else: dir & "/" & name

  proc ripgrepOnPath*(): string =
    ## The `rg` the search would run, or "" when there is none.
    let env = nodeRequire("process").env
    let raw = env["PATH"]
    if isNullish(raw):
      return ""
    let isWindows = $(nodeRequire("process").platform.to(cstring)) == "win32"
    let sep = if isWindows: ';' else: ':'
    for dir in ($(raw.to(cstring))).split(sep):
      if dir.len == 0:
        continue
      for name in (if isWindows: @["rg.exe", "rg"] else: @["rg"]):
        let candidate = $(nodePath.join(cstring(dir), cstring(name)).to(cstring))
        try:
          if nodeFs.statSync(cstring(candidate)).isFile().to(bool):
            return candidate
        except:
          discard
    ""

  proc directoryExists*(path: string): bool =
    kindOf(path) == wekDirectory
else:
  proc listEntries(dir: string): seq[(string, WalkEntryKind)] =
    try:
      for kind, path in walkDir(dir, relative = true, checkDir = true):
        let k =
          case kind
          of pcFile: wekFile
          of pcDir: wekDirectory
          of pcLinkToFile, pcLinkToDir: wekOther
        result.add (path, k)
    except OSError:
      discard

  proc kindOf(path: string): WalkEntryKind =
    if dirExists(path): wekDirectory
    elif fileExists(path): wekFile
    else: wekOther

  proc readTextFile(path: string): tuple[ok: bool, text: string] =
    try:
      let text = readFile(path)
      if text.find('\0') >= 0:
        return (false, "")
      (true, text)
    except CatchableError:
      (false, "")

  proc joinPath(dir, name: string): string =
    if dir.endsWith("/") or dir.endsWith("\\"): dir & name
    else: dir & "/" & name

  proc ripgrepOnPath*(): string =
    ## The `rg` the search would run, or "" when there is none.
    when defined(wasm32):
      # A WASM module cannot spawn host processes, even when its filesystem
      # is backed by Node. The walker remains available on that filesystem.
      ""
    else:
      findExe(RipgrepProgram)

  proc directoryExists*(path: string): bool =
    dirExists(path)

# ---------------------------------------------------------------------------
# The scope — the desktop's rule, as one function
# ---------------------------------------------------------------------------

proc findInFilesScope*(filesStore: string; preferStore: bool;
                       sourceFolders: openArray[string]): FindInFilesScope =
  ## WHAT A SEARCH READS (Find-And-Incremental-Search.md §5.1), the desktop's
  ## `onSearchProgram` rule:
  ##
  ## * a recording whose sources were materialised into its `files/` store
  ##   (`preferStore`: an imported recording on the desktop, every recording
  ##   the native front-ends open) is searched THERE, and the store's prefix is
  ##   removed from each result so a row names the source path the recording
  ##   knows — which is what the Files pane lists and what a click opens;
  ## * otherwise its source folders — the roots the Files pane shows
  ##   (`sourceFoldersFromTracePaths`) — that exist, a folder inside another
  ##   searched once.
  ##
  ## Edit mode passes the project root as the one source folder.
  let store = trimRoot(filesStore)
  if preferStore and store.len > 0 and directoryExists(store):
    return FindInFilesScope(roots: @[store], stripPrefix: store)
  var existing: seq[string] = @[]
  for f in sourceFolders:
    let t = trimRoot(f)
    if t.len > 0 and directoryExists(t):
      existing.add t
  result.roots = outermost(existing)
  if result.roots.len == 0:
    result.reason = "this recording names no source folder on this machine"

# ---------------------------------------------------------------------------
# Runs
# ---------------------------------------------------------------------------

proc emit(run: FindInFilesRun; done: bool; note = "") =
  if run.cancelled or run.sink.isNil:
    return
  let rows = run.pending
  run.pending = @[]
  run.emitted += rows.len
  run.sink(FindInFilesBatch(runId: run.id, rows: rows, done: done,
                            engine: run.engine, note: note))

proc add(run: FindInFilesRun; row: SearchResultLine) =
  run.pending.add row
  if run.pending.len >= FindInFilesBatchSize:
    run.emit(done = false)

proc finish(run: FindInFilesRun; note = "") =
  if run.finished:
    return
  run.finished = true
  run.emit(done = true, note = note)

proc absorbOutput(run: FindInFilesRun; chunk: string) =
  ## `rg`'s output, split into lines, a straddling line carried.
  for c in chunk:
    if c == '\n':
      let parsed = parseRgJsonLine(run.lineBuf, run.scope)
      run.lineBuf.setLen(0)
      if parsed.ok:
        run.add parsed.row
        if run.cancelled:
          return
    else:
      run.lineBuf.add c

proc rgRefusal*(errorText: string): string =
  ## What `rg`'s error stream says when it searched nothing, in the words
  ## the pane shows: the reason it gave (a parse error's `error:` line, else
  ## its first line without the `rg: ` prefix), named a refused regular
  ## expression when it is one. "" for nothing written.
  var reason = ""
  for raw in errorText.splitLines():
    let line = raw.strip()
    if line.startsWith("error: "):
      reason = line["error: ".len .. ^1]
    elif reason.len == 0 and line.len > 0:
      reason = if line.startsWith("rg: "): line[4 .. ^1] else: line
  if reason.len > 0 and "regex" in errorText:
    "invalid regular expression: " & reason
  else:
    reason

proc finishRipgrep(run: FindInFilesRun; exitCode: int) =
  ## `rg` ended: exit status 2 with no row is a search that did not run, and
  ## the pane is told why rather than shown an empty result.
  if exitCode == 2 and run.emitted == 0 and run.pending.len == 0:
    run.finish(note = rgRefusal(run.errorText))
  else:
    run.finish()

proc walkStep(run: FindInFilesRun; budget: int) =
  ## Visit up to `budget` files of the walk.
  var visited = 0
  while run.todo.len > 0 and visited < budget and not run.cancelled:
    let path = run.todo.pop()
    case kindOf(path)
    of wekDirectory:
      var children: seq[(string, WalkEntryKind)] = @[]
      for (name, kind) in listEntries(path):
        # Hidden entries are skipped, as `rg` skips them by default; a
        # symbolic link is never followed (`wekOther`), as `rg` does not.
        if name.len == 0 or name[0] == '.' or kind == wekOther:
          continue
        children.add (name, kind)
      children.sort(proc(a, b: (string, WalkEntryKind)): int = cmp(a[0], b[0]))
      for i in countdown(children.high, 0):
        run.todo.add joinPath(path, children[i][0])
    of wekFile:
      inc visited
      let read = readTextFile(path)
      if read.ok:
        for row in matchRowsOf(path, read.text, run.matcher, run.scope):
          run.add row
          if run.cancelled:
            return
    of wekOther:
      discard
  if run.todo.len == 0 and not run.cancelled:
    run.finish()

proc startWalker(run: FindInFilesRun) =
  run.engine = fieWalker
  for i in countdown(run.scope.roots.high, 0):
    run.todo.add trimRoot(run.scope.roots[i])
  when defined(js):
    # Node drives the walk: one bounded step per timer turn, so the main
    # process keeps serving its other messages while a large tree is read.
    proc step() =
      if run.cancelled or run.finished:
        return
      run.walkStep(WalkerFilesPerPump)
      if not run.finished and not run.cancelled:
        discard jsSetTimeout(step, 0)
    discard jsSetTimeout(step, 0)

when defined(js):
  proc startRipgrep(run: FindInFilesRun; rg: string): bool =
    let cp = nodeRequire("child_process")
    var argv: seq[cstring] = @[]
    for a in rgArguments(run.pattern, run.options, run.scope.roots):
      argv.add cstring(a)
    let stdio = @[cstring"ignore", cstring"pipe", cstring"pipe"]
    try:
      run.child = cp.spawn(cstring(rg), argv.toJs,
                           js{windowsHide: true, stdio: stdio.toJs})
    except:
      return false
    run.engine = fieRipgrep
    run.child.stdout.setEncoding(cstring"utf8")
    run.child.stdout.on(cstring"data", proc(chunk: cstring) =
      if not run.cancelled:
        run.absorbOutput($chunk))
    run.child.stderr.setEncoding(cstring"utf8")
    run.child.stderr.on(cstring"data", proc(chunk: cstring) =
      run.errorText.add $chunk)
    run.child.on(cstring"error", proc(err: JsObject) =
      # `rg` vanished between the PATH probe and the spawn: the walker
      # answers instead, as it would have had `rg` never been there.
      if not run.cancelled and run.emitted == 0 and run.pending.len == 0 and
         not run.finished:
        run.startWalker()
      elif not run.cancelled:
        run.finish())
    run.child.on(cstring"close", proc(code: JsObject) =
      if run.cancelled or run.engine != fieRipgrep:
        return
      if run.lineBuf.len > 0:
        run.absorbOutput("\n")
      run.finishRipgrep(if isNullish(code): -1 else: code.to(int)))
    true

  proc stopProcess(run: FindInFilesRun) =
    if not isNullish(run.child):
      try:
        discard run.child.kill()
      except:
        discard
elif not defined(wasm32):
  proc startRipgrep(run: FindInFilesRun; rg: string): bool =
    try:
      run.process = startProcess(rg, args = rgArguments(run.pattern,
                                                         run.options,
                                                         run.scope.roots),
                                 options = {})
    except OSError, IOError:
      return false
    run.engine = fieRipgrep
    run.fd = run.process.outputHandle
    when defined(posix):
      # `O_NONBLOCK`, as `tui/host/build_runner.nim` measured: a `Stream`
      # read bounded by a byte count still blocks on a silent child.
      let flags = fcntl(run.fd, F_GETFL, 0)
      if flags != -1:
        discard fcntl(run.fd, F_SETFL, flags or O_NONBLOCK)
    true

  proc reapProcess(run: FindInFilesRun): int =
    ## Wait for `rg`, keep what it wrote to its error stream, and answer its
    ## exit status (-1 when there was no process to wait for).
    result = -1
    if run.process.isNil:
      return
    try:
      result = run.process.waitForExit()
      run.errorText = run.process.errorStream.readAll()
      run.process.close()
    except CatchableError:
      discard
    run.process = nil

  proc stopProcess(run: FindInFilesRun) =
    if run.process.isNil:
      return
    try:
      run.process.kill()
    except CatchableError:
      discard
    discard run.reapProcess()

  proc pumpRipgrep(run: FindInFilesRun) =
    when defined(posix):
      var chunk = newString(64 * 1024)
      var total = 0
      while total < RgBytesPerPump and not run.sawEof and not run.cancelled:
        let got = posix.read(run.fd, addr chunk[0], chunk.len)
        if got > 0:
          total += got
          run.absorbOutput(chunk[0 ..< got])
        elif got == 0:
          run.sawEof = true
        else:
          let err = errno
          if err == EINTR:
            continue
          if err == EAGAIN or err == EWOULDBLOCK:
            break
          run.sawEof = true
    else:
      # No non-blocking pipe here: one bounded read of lines per pump.
      let stream = run.process.outputStream
      var line = ""
      var n = 0
      while n < 4096 and not run.cancelled:
        if not stream.readLine(line):
          run.sawEof = true
          break
        run.absorbOutput(line & "\n")
        inc n
    if run.sawEof and not run.cancelled:
      if run.lineBuf.len > 0:
        run.absorbOutput("\n")
      run.finishRipgrep(run.reapProcess())

proc cancel*(run: FindInFilesRun) =
  ## Stop the run: its process killed or its walk dropped, and its sink never
  ## called again.
  if run.isNil or run.cancelled:
    return
  run.cancelled = true
  run.todo = @[]
  run.pending = @[]
  when not defined(wasm32):
    run.stopProcess()

proc start(run: FindInFilesRun; engine: FindInFilesEngine) =
  run.engine = engine
  if run.scope.roots.len == 0:
    run.finish(note = (if run.scope.reason.len > 0: run.scope.reason
                       else: "there is nothing to search"))
    return
  if run.pattern.len == 0:
    run.finish()
    return
  # Compiled before either engine starts: a pattern the two engines would
  # not both accept is refused here, for both, with the reason.
  let compiled = compileTextMatcher(run.pattern, run.options)
  if not compiled.ok:
    run.finish(note = compiled.error)
    return
  run.matcher = compiled.matcher
  when not defined(wasm32):
    if engine == fieRipgrep:
      let rg = ripgrepOnPath()
      if rg.len > 0 and run.startRipgrep(rg):
        return
  run.startWalker()

proc preferredEngine*(): FindInFilesEngine =
  ## `rg` when it is on `PATH`, else the walker.
  if ripgrepOnPath().len > 0: fieRipgrep else: fieWalker

proc pump*(run: FindInFilesRun): bool =
  ## Advance the run. Answers whether it is still running. On the JS backend
  ## node's events drive `rg` (this only reports on it), and a pump advances
  ## the walker as its timer does.
  if run.isNil or run.cancelled or run.finished:
    return false
  case run.engine
  of fieRipgrep:
    when not defined(js) and not defined(wasm32):
      run.pumpRipgrep()
  of fieWalker:
    run.walkStep(WalkerFilesPerPump)
  not run.finished and not run.cancelled

proc runToCompletion*(run: FindInFilesRun) =
  ## Drive a run until it ends — for a CLI or a suite; an interactive host
  ## pumps from its loop instead. On the JS backend only the walker can be
  ## driven to its end synchronously (`rg`'s output arrives as node events).
  while run.pump():
    when defined(js):
      if run.engine == fieRipgrep:
        break
    elif defined(posix) and not defined(wasm32):
      if run.engine == fieRipgrep:
        var fds = [TPollfd(fd: run.fd, events: POLLIN)]
        discard posix.poll(addr fds[0], 1, 50)

proc newFindInFilesService*(): FindInFilesService =
  FindInFilesService()

proc search*(service: FindInFilesService; runId: int; pattern: string;
             options: TextMatchOptions; scope: FindInFilesScope;
             sink: FindInFilesSink;
             engine = preferredEngine()): FindInFilesRun =
  ## Start a search, cancelling the one in flight first: its process is
  ## killed or its walk dropped before this one reads anything, and its sink
  ## is never called again.
  if not service.current.isNil:
    service.current.cancel()
  result = FindInFilesRun(id: runId, pattern: pattern, options: options,
                          scope: scope, sink: sink)
  when not defined(js) and not defined(wasm32):
    result.fd = -1
  service.current = result
  result.start(engine)

proc pump*(service: FindInFilesService): bool =
  ## Advance the run in flight; whether one is still running.
  if service.isNil or service.current.isNil:
    return false
  service.current.pump()

proc cancel*(service: FindInFilesService) =
  if not service.isNil and not service.current.isNil:
    service.current.cancel()

proc running*(service: FindInFilesService): bool =
  not service.isNil and not service.current.isNil and
    not service.current.finished and not service.current.cancelled

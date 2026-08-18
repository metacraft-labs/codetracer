import
  std / [ async, jsffi, os, strformat, strutils, sequtils, jsconsole ],
  electron_vars,
  ../[ config, types, lang ],
  ../lib/[ jslib, electron_lib, misc_lib ],
  ./bootstrap_cache,
  ./layout_config_repair,
  ../../common/[ paths, ct_logging, trace_source_paths, review_source_paths ]

type
  ServerData* = object
    tabs*: JsAssoc[cstring, ServerTab]
    config*: Config
    trace*: Trace
    replay*: bool
    exe*: seq[cstring]
    closedTabs*: seq[cstring]
    closedPanels*: seq[cstring]
    save*: Save
    startOptions*: StartOptions
    start*: int64
    pluginCommands*: JsAssoc[cstring, SearchSource]
    pluginClient*: PluginClient
    # M-REC-2: keyed by UUIDv7 recording-id string.
    debugInstances*: JsAssoc[cstring, DebugInstance]
    recordProcess*: NodeSubProcess
    layout*: js
    helpers*: Helpers
    bootstrapMessages*: seq[BootstrapPayload]
    workspaceFolder*: cstring  # The folder opened in edit mode (persists across mode switches)

  DebugInstance* = object
    process*:       NodeSubProcess
    pipe*:          JsObject

  ServerTab* = ref object
    path*:          cstring
    lang*:          Lang
    fileWatched*:   bool
    ## Epoch-ms deadline until which filesystem events for this file are
    ## attributed to CodeTracer's own write and suppressed.
    ##
    ## This replaces an `ignoreNext: int` counter that was incremented once
    ## per save and decremented once per event.  That only works if a write
    ## produces exactly one event, and it does not: up to three watchers are
    ## registered per file (`fs.watch` on the file, `fs.watch` on its
    ## directory, `fs.watchFile` polling) and a single `writeFile` — open,
    ## truncate, write — yields several inotify `change` events on its own.
    ## Every surplus event walked straight past the mask and raised the
    ## "File changed on disk" dialog for the user's *own* save (issue #603).
    selfWriteUntilMs*: float
    waitsPrompt*:   bool

var data* = ServerData(
  replay: true,
  exe: @[],
  tabs: JsAssoc[cstring, ServerTab]{},
  closedTabs: @[],
  closedPanels: @[],
  bootstrapMessages: @[],
  startOptions: StartOptions(
    loading: true,
    screen: true,
    inTest: false,
    record: false,
    edit: false,
    name: cstring"",
    frontendSocket: SocketAddressInfo(),
    backendSocket: SocketAddressInfo(),
    idleTimeoutMs: 10 * 60 * 1_000,
    rawTestStrategy: cstring""
  ),
  pluginCommands: JsAssoc[cstring, SearchSource]{},
  debugInstances: JsAssoc[cstring, DebugInstance]{}
)

const selfWriteSuppressionMs* = 750.0
  ## How long after one of our own writes filesystem events for that file are
  ## ignored.  Comfortably longer than the 250 ms `fs.watchFile` poll below,
  ## and short enough that a real external edit made right after a save is
  ## still picked up.

proc nowMs(): float {.importjs: "Date.now()".}

proc ensureServerTab(filename: cstring, lang: Lang): ServerTab =
  if not data.tabs.hasKey(filename):
    data.tabs[filename] = ServerTab(path: filename, lang: lang, fileWatched: true)
  data.tabs[filename]

proc suppressSelfWrite*(filename: cstring) =
  ## Mark `filename` as being written by CodeTracer itself, so the watchers
  ## below do not report the write back to the renderer as an external change.
  ##
  ## Call this both immediately before and immediately after the write: the
  ## first arms the window for events raised while the write is in progress,
  ## the second re-anchors it to the moment the file actually settled.
  if data.tabs.hasKey(filename):
    data.tabs[filename].selfWriteUntilMs = nowMs() + selfWriteSuppressionMs

proc notifySourceFileChanged(filename: cstring, lang: Lang) =
  let tab = ensureServerTab(filename, lang)
  if nowMs() < tab.selfWriteUntilMs:
    # Our own write.  Unlike the counter this replaced, a time window absorbs
    # an arbitrary number of events from an arbitrary number of watchers.
    return
  if tab.fileWatched and not tab.waitsPrompt:
    tab.waitsPrompt = true
    mainWindow.webContents.send "CODETRACER::change-file", js{path: filename}

proc addUniquePathCandidate(paths: var seq[cstring], path: cstring) =
  if path.len == 0:
    return
  for existing in paths:
    if $existing == $path:
      return
  paths.add(path)

proc selfContainedReadPathCandidates(trace: Trace, filename: cstring): seq[cstring] =
  if trace.isNil:
    return
  let traceFilesFolder = nodePath.join(trace.outputFolder, cstring"files")
  let sourceFolders = trace.sourceFolders.mapIt($it)
  let payloadCandidates = selfContainedSourcePayloadCandidates(
    $filename, $trace.workdir, sourceFolders)
  for payloadPath in payloadCandidates:
    result.addUniquePathCandidate(nodePath.join(traceFilesFolder, cstring(payloadPath)))

let helpers* {.exportc: "helpers".} = require("./helpers")
var
  fsWriteFileWithErr*  {.  importcpp: "helpers.fsWriteFileWithErr(#, #)"                   .}:  proc(f: cstring, s: cstring):                    Future[js]
  fsCopyFileWithErr    {.  importcpp: "helpers.fsCopyFileWithErr(#, #)"                    .}:  proc(a: cstring, b: cstring):                    Future[js]
  fsMkdirWithErr       {.  importcpp: "helpers.fsMkdirWithErr(#, #)"                       .}:  proc(a: cstring, options: JsObject):             Future[JsObject]
  fsReadFileWithErr*   {.  importcpp: "helpers.fsReadFileWithErr(#)"                       .}:  proc(f: cstring):                                Future[(cstring, js)]
  fsUnlinkWithErr*     {.  importcpp: "helpers.fsUnlinkWithErr(#)"                         .}:  proc(f: cstring):                                Future[js]

proc readFirstAvailable(pathCandidates: seq[cstring]):
    Future[tuple[source: cstring, err: js, openedPath: cstring]] {.async.} =
  if pathCandidates.len == 0:
    return (cstring"", cstring"no source path candidates".toJs, cstring"")
  for path in pathCandidates:
    let (source, err) = await fsReadFileWithErr(path)
    if err.isNil:
      return (source, err, path)
    result = (source, err, path)

type
  ReviewSourceLookup = object
    ## What the review dataset can say about one requested path.
    ## Module-private: `open` below is the only caller.
    claimed: bool
      ## The dataset has an entry for this path, so the review — not the
      ## working tree — is the authority on the file's text.
    text: cstring
      ## That entry's `sourceContent`.  Empty when the collector could not
      ## read the file at collect time (`collector.rs`'s `read_source`
      ## returns an empty string rather than failing the collection), which
      ## is the one case a review cannot serve and must report.

proc reviewSourceLookup(data: ServerData, filename: cstring): ReviewSourceLookup =
  ## The dataset's text for `filename`, when a review is what is open.
  ##
  ## DeepReview-GUI.md §5.1 wants the full file "fully loaded ... with diff
  ## highlights on the modified lines".  The text those highlights are drawn
  ## over cannot be whatever the working tree holds right now: the hunks'
  ## `newLine` values index the file **as of the reviewed commit**, so any
  ## other text puts the decorations on the wrong lines.  The dataset carries
  ## exactly that revision, in `DeepReviewFileData.sourceContent`, and the
  ## index process is already handed the whole dataset at startup
  ## (`index/args.nim`'s `--deepreview` branch) — it simply never read it.
  ##
  ## Serving from the dataset is also what makes a review portable.  Before
  ## this, opening a file resolved the dataset's repo-relative path against
  ## whatever repository the *terminal* happened to be in, so a review of
  ## somebody else's dataset — the normal case for a dataset attached to a
  ## ticket — read a path that did not exist and gave up silently.
  result = ReviewSourceLookup(claimed: false, text: cstring"")
  if not data.startOptions.withDeepReview or data.startOptions.deepReview.isNil:
    return
  var paths: seq[string] = @[]
  for file in data.startOptions.deepReview.files:
    paths.add($file.path)
  let index = reviewFileIndexForPath(paths, $filename)
  if index < 0:
    return
  let file = data.startOptions.deepReview.files[index]
  result.claimed = true
  if not file.sourceContent.isNil:
    result.text = cstring($file.sourceContent)

proc sendTabInfo(main: js, location: types.Location, filename, source: cstring,
                 editorView: EditorView, messagePath: string, lang: Lang) =
  ## Hand one loaded document back to the renderer.
  ##
  ## Factored out of `open` so the disk-backed path and the review path answer
  ## `tab-load` with the *same* message — the renderer resolves its pending
  ## `tab-load` future by `argId`, and a second spelling of this send would be
  ## a second chance for a tab to hang on "Loading…" forever.
  var sourceText = source
  var sourceLines = sourceText.split(jsNl)

  var name = cstring""
  var argId = cstring""

  if location.isExpanded:
    sourceLines = sourceLines.slice(location.expansionFirstLine - 1, location.expansionLastLine)
    sourceText = sourceLines.join(jsNl) & jsNl
    name = location.functionName
    argId = name
  else:
    name = basename(filename)
    # TODO maybe remove if we don't hit that for some time
    if name == cstring"expanded.nim":
      errorPrint "expanded.nim with isExpanded == false ", filename
      return
    argId = filename

  if editorView == ViewCalltrace:
    name = location.path & cstring":" & location.functionName & cstring"-" & location.key
    argId = name
    sourceLines = sourceLines.slice(location.functionFirst - 1, location.functionLast)
    sourceText = sourceLines.join(jsNl) & jsNl

  main.webContents.send "CODETRACER::" & messagePath, js{
    "argId": argId,
    "value": TabInfo(
      overlayExpanded: -1,
      highlightLine: -1,
      location: location,
      source: sourceText,
      sourceLines: sourceLines,
      received: true,

      name: name,
      path: filename,
      lang: lang
    )
  }

proc open*(data: ServerData, main: js, location: types.Location, editorView: EditorView, messagePath: string, replay: bool, exe: seq[cstring], lang: Lang, line: int): Future[void] {.async.} =
  var source = cstring""
  # var tokens: seq[seq[Token]] = @[]
  var symbols = JsAssoc[cstring, seq[js]]{}
  if location.highLevelPath == cstring"unknown":
    return
  let filename = location.highLevelPath

  # DeepReview §5.1/§5.3: a review's full-file tab is served from the dataset,
  # never from the working tree, and no file watcher is registered for it — the
  # text is a snapshot of a commit, so there is nothing to watch for changes.
  let review = data.reviewSourceLookup(filename)
  if review.claimed:
    if review.text.len > 0:
      sendTabInfo(main, location, filename, review.text, editorView, messagePath, lang)
      return
    # The dataset names this file but carries no text for it.  Say so instead
    # of falling through to a disk read that resolves against the wrong
    # repository and then returns in silence — the failure mode this branch
    # exists to replace.  The remedy differs by cause, so both are named.
    let message =
      "Review: no source text for '" & $filename & "'.\n" &
      "The review dataset carries none for this file, so the full file " &
      "cannot be shown. Re-collect it from inside the reviewed repository " &
      "(`ct review collect --repo <repository> …`); the diff tab still works."
    errorPrint message
    # Sent to `main` — the window that asked for this tab — rather than to the
    # module-level `mainWindow`, which is the same window in the normal case
    # but is not the one this request came from and is not guaranteed to be
    # assigned yet.  Addressing the requester is also what makes the notice
    # arrive in the window the user is looking at.
    main.webContents.send "CODETRACER::new-notification",
      newNotification(NotificationKind.NotificationError, message)
    return
  # TODO path for low level?
  # if data.tabs.hasKey(filename):
  #   return

  # TODO: explicitly ask for trace source of direct file
  # e.g. source location/debugger always => trace source
  # ctrlp/filesystem: maybe based on where the file comes from:
  #   trace paths/trace sourcefolder or direct filesystem/other
  # ctrl+o/similar => direct
  let traceImported = not data.trace.isNil and data.trace.imported
  let readCandidates =
    if traceImported:
      selfContainedReadPathCandidates(data.trace, filename)
    else:
      @[filename]

  var
    err: js
    openedPath = if readCandidates.len > 0: readCandidates[0] else: filename
  let readResult = await readFirstAvailable(readCandidates)
  source = readResult.source
  err = readResult.err
  openedPath = readResult.openedPath
  if not err.isNil:
    # source = cstring"<file missing>!"
    # filename = cstring"<file missing: " & filename & cstring">"
    # missing = true
    console.log "error reading file directly ", filename, " ", err
    if traceImported:
      # try original filename if
      # it was first tried with a trace copy path
      (source, err) = await fsReadFileWithErr(filename)
      if err.isNil:
        openedPath = filename

      if not err.isNil:
        console.log "error reading file from trace ", filename, " ", err
        return
    else:
      # we tried the original filename if not imported:
      # directly stop
      console.log "error: trace not imported, but file couldn't be read ", filename
      return
    # bug "file missing " & $filename

  if err.isNil:
    if not data.tabs.hasKey(filename):
      data.tabs[filename] = ServerTab(path: filename, lang: lang, fileWatched: true)
      let watchedDir = nodePath.dirname(openedPath)
      let watchedBase = nodePath.basename(openedPath)
      # Hot-reload file watchers are a developer convenience.  ``fs.watch`` can
      # fail with ``ENOSPC`` when the system-wide inotify watch budget is
      # exhausted (common during long Playwright runs that spawn many ``ct
      # host`` processes), or with ``EPERM`` / ``ENOENT`` for transient trace
      # directories.  The synchronous throw used to abort ``open()`` before
      # ``CODETRACER::tab-load-received`` was sent back to the renderer,
      # leaving the Monaco editor stuck on "Loading…" forever — see
      # M10/M9 in ``GUI-Test-Stabilization-2026-05.status.org``.  Swallow the
      # error so the source-load contract is not coupled to inotify health.
      #
      # M11: even when ``fs.watch`` does not throw, it may silently fail to
      # deliver events on tmpfs/overlayfs or when no inotify instances are
      # available.  And when it *does* throw ENOSPC, M10 disabled hot-reload
      # entirely.  Both cases break ``file_conflicts.spec.ts``.  As a
      # robust fallback we additionally register ``fs.watchFile`` which
      # uses ``stat(2)`` polling, never throws ENOSPC, and works on any
      # filesystem.  The slight extra wake-up cost (one stat per file per
      # poll interval) is negligible for the small set of files a user
      # has open at any one time.
      var watchAttached = false
      try:
        fs.watch(openedPath) do (e: cstring, filenameArg: cstring):
          if e == cstring"change" or e == cstring"rename":
            notifySourceFileChanged(filename, lang)
        watchAttached = true
      except:
        warnPrint "fs.watch failed for ", openedPath, ": ",
          getCurrentExceptionMsg()
      if watchedDir.len > 0 and watchedDir != openedPath:
        try:
          fs.watch(watchedDir) do (e: cstring, filenameArg: cstring):
            if e == cstring"change" or e == cstring"rename":
              if filenameArg.isNil or filenameArg.len == 0 or
                  nodePath.basename(filenameArg) == watchedBase:
                notifySourceFileChanged(filename, lang)
          watchAttached = true
        except:
          warnPrint "fs.watch failed for directory ", watchedDir, ": ",
            getCurrentExceptionMsg()
      # Always also register the polling watcher.  This is intentional: even
      # when ``fs.watch`` *appears* to succeed, it can silently never fire on
      # certain mounts (in Playwright + Electron + tmpfs scenarios we observed
      # zero ``change`` events).
      #
      # These watchers DO double-notify.  A single ``writeFile`` (open,
      # truncate, write) raises several inotify ``change`` events, each of
      # which is delivered to both ``fs.watch`` registrations, and the poller
      # can add one more.  ``tab.waitsPrompt`` only dedupes events that arrive
      # while a prompt is already outstanding.  Suppressing our own writes is
      # therefore ``selfWriteUntilMs``'s job, not a counter's — see
      # ``notifySourceFileChanged`` above and issue #603.
      try:
        fs.watchFile(openedPath, js{interval: 250, persistent: false}) do (curr: js, prev: js):
          # ``curr.mtimeMs`` and ``prev.mtimeMs`` are numeric epoch ms;
          # when the file is deleted ``curr.mtimeMs == 0``.  Treat any
          # change in mtime or size as an external edit.
          let currMtime = curr["mtimeMs"]
          let prevMtime = prev["mtimeMs"]
          let currSize = curr["size"]
          let prevSize = prev["size"]
          let mtimeChanged = (not currMtime.isNil) and (not prevMtime.isNil) and
            currMtime.to(float) != prevMtime.to(float)
          let sizeChanged = (not currSize.isNil) and (not prevSize.isNil) and
            currSize.to(float) != prevSize.to(float)
          if mtimeChanged or sizeChanged:
            notifySourceFileChanged(filename, lang)
      except:
        warnPrint "fs.watchFile failed for ", openedPath, ": ",
          getCurrentExceptionMsg()
        if not watchAttached:
          data.tabs[filename].fileWatched = false

  echo "index_config open: file read succesfully"
  sendTabInfo(main, location, filename, source, editorView, messagePath, lang)


proc findConfig(folder: cstring, configPath: cstring): cstring =
  var current = folder
  var config = false
  while true:
    let path = nodePath.join(current, configPath)
    if fs.existsSync(path):
      return path
    else:
      if config:
        return cstring""
      let parent = nodePath.dirname(current)
      # On Linux/macOS, the root is "/".  On Windows, path.dirname("D:\")
      # returns "D:\" (i.e. parent == current).  Detect both cases.
      if parent == cstring"/" or parent == current:
        current = userConfigDir
        config = true
      else:
        current = parent

proc loadConfig*(main: js, startOptions: StartOptions, home: cstring = cstring"", send: bool = false): Future[Config] {.async.} =
  var file = findConfig(startOptions.folder, configPath)
  if file.len == 0:
    file = userConfigDir / configPath

    let errMkdir = await fsMkdirWithErr(cstring(userConfigDir), js{recursive: true})
    if not errMkdir.isNil:
      errorPrint "mkdir for config folder error: exiting: ", errMkdir
      quit(1)

    let errCopy = await fsCopyFileWithErr(
      cstring(fmt"{configDir / defaultConfigPath}"),
      cstring(fmt"{userConfigDir / configPath}")
    )

    if not errCopy.isNil:
      errorPrint "can't copy .config.yaml to user config dir:"
      errorPrint "  tried to copy from: ", cstring(fmt"{configDir / defaultConfigPath}")
      errorPrint "  to: ", fmt"{userConfigDir / configPath}"
      quit(1)

  infoPrint "index: load config ", file
  let (s, err) = await fsreadFileWithErr(file)
  if not err.isNil:
    errorPrint "read config file error: ", err
    quit(1)
  try:
    let config = cast[Config](yaml.load(s))
    config.shortcutMap = initShortcutMap(config.bindings)
    return config
  except CatchableError:
    errorPrint "load config or init shortcut map error: ", getCurrentExceptionMsg()
    quit(1)

proc ensureLayoutContentPanel(config: js; contentId: int; label: cstring): js {.importjs:
  """(function(config, contentId, label) {
    if (!config) return config;
    const target = Number(contentId);
    const root = config.root || config;
    const stateOf = (node) => node && node.componentState ? node.componentState : {};
    const walk = (node, visit) => {
      if (!node) return;
      visit(node);
      if (Array.isArray(node.content)) {
        for (const child of node.content) walk(child, visit);
      }
    };
    let hasTarget = false;
    walk(root, (node) => {
      if (node.type === 'component' && Number(stateOf(node).content) === target) {
        hasTarget = true;
      }
    });
    if (hasTarget) return config;

    let eventLogStack = null;
    let firstStack = null;
    walk(root, (node) => {
      if (node.type !== 'stack') return;
      if (!firstStack) firstStack = node;
      if (eventLogStack) return;
      if (Array.isArray(node.content) && node.content.some((child) =>
        child && child.type === 'component' && Number(stateOf(child).content) === 8)) {
        eventLogStack = node;
      }
    });

    const targetStack = eventLogStack || firstStack;
    if (!targetStack) return config;
    if (!Array.isArray(targetStack.content)) targetStack.content = [];
    targetStack.content.push({
      type: 'component',
      componentType: 'genericUiComponent',
      componentState: {
        id: 0,
        label: String(label),
        content: target
      },
      title: 'genericUiComponent'
    });
    // Appending only grows the array, so a previously in-range
    // activeItemIndex stays in range.  Clamp anyway: this is the same
    // invariant that, when it was left unmaintained on the *removal* path,
    // produced the permanently unloadable layouts of the saved-layout
    // corruption bug.  GoldenLayout enforces it with a throw
    // (node_modules/golden-layout/src/ts/items/stack.ts:169-171).
    if (targetStack.activeItemIndex !== undefined &&
        targetStack.activeItemIndex !== null) {
      const index = Number(targetStack.activeItemIndex);
      targetStack.activeItemIndex = Number.isFinite(index)
        ? Math.min(Math.max(index, 0), targetStack.content.length - 1)
        : 0;
    }
    return config;
  })(#, #, #)""".}
  ## Ensure a core panel exists in an otherwise valid GoldenLayout config.
  ## This preserves user layouts while adding panels introduced after their
  ## saved config was created.

proc ensureReplayLayoutPanels(config: js): js =
  ensureLayoutContentPanel(config, ord(Content.Timeline), cstring"timelineComponent-0")

proc isValidLayoutConfig(config: js; autoHideState: js = nil): bool =
  ## Check if a layout config has the minimum required structure for GoldenLayout.
  ## This helps detect corrupt or incompatible layout files from different branches.
  ##
  ## NOTE: this is a *compatibility* check, not a soundness check.  Everything
  ## GoldenLayout would actually throw on is handled by `repairLayoutConfig`
  ## (`index/layout_config_repair.nim`) before we get here — historically this
  ## predicate was the only gate, which is why an out-of-range
  ## `activeItemIndex` sailed straight through it and aborted startup.
  if config.isNil:
    return false
  # GoldenLayout requires at least a 'root' property with a 'type' and 'content'
  let root = config["root"]
  if root.isNil:
    return false
  let rootType = root["type"]
  if rootType.isNil:
    return false
  # A debug-mode `default_layout.json` must contain the Filesystem panel.
  # The DeepReview standalone mode renders only the VCS / DeepReview /
  # calltrace panels; if that layout ever leaks into `default_layout.json`
  # (e.g. a `--deepreview` launch followed by an ordinary `ct` trace
  # launch) the ordinary debug session would come up missing its
  # filesystem / editor / event-log / state / terminal panels.  Treat a
  # layout without the Filesystem panel as incompatible so the loader
  # resets it to the bundled default.
  #
  # The panel counts as present when it is pinned to a screen edge, too:
  # `auto_hide.pinPanel` REMOVES the component from the GoldenLayout tree and
  # keeps it in the auto-hide state instead.  Without that second lookup,
  # pinning FILES made this predicate false and `resetLayoutToDefault`
  # deleted the user's layout file — the "customizations silently lost"
  # half of issue #608.
  if not layoutHasRequiredPanel(config, autoHideState, ord(Content.Filesystem)):
    return false
  # Basic structure looks valid
  return true

proc tryParseJson(raw: cstring): js {.importjs:
  """(function(raw) {
    try {
      return { ok: true, value: JSON.parse(raw) };
    } catch (error) {
      return {
        ok: false,
        error: error && error.message ? String(error.message) : String(error)
      };
    }
  })(#)""".}

proc parseLayoutJson(raw: cstring; context: string): js =
  ## JSON.parse raises a JavaScript SyntaxError that Nim's try/except does not
  ## reliably catch in this backend. Keep the parse guard on the JavaScript
  ## side so corrupt layout files can be reset instead of aborting startup.
  let parsed = tryParseJson(raw)
  if parsed["ok"].to(bool):
    return parsed["value"]
  warnPrint context, ": ", parsed["error"].to(cstring)
  return nil

proc sanitizeEditLayoutConfig*(config: js; editorContent: int;
                               hiddenContents: seq[int]): js =
  ## Strip per-trace editor tabs (and, in edit mode, the replay-only panels)
  ## from a layout config before persisting it.
  ##
  ## The implementation lives in `index/layout_config_repair.nim` so it can be
  ## exercised headlessly — see
  ## `src/tests/gui/tests/layout/layout_config_roundtrip_test.nim`.  The
  ## in-line version this replaced deleted components from stacks but never
  ## remapped the enclosing stack's `activeItemIndex`, so every replay-mode
  ## save of a mixed stack (editor tabs next to "NO SOURCE" / "CALLS") wrote
  ## a layout file GoldenLayout refuses to restore — issue #608.
  sanitizeLayoutConfig(config, editorContent, hiddenContents)

proc editModeHiddenContentIds(): seq[int] =
  @[
    ord(Content.Trace),
    ord(Content.State),
    ord(Content.Scratchpad),
    ord(Content.Repl),
    ord(Content.EventLog),
    ord(Content.Timeline),
    ord(Content.TerminalOutput),
    ord(Content.StepList),
    ord(Content.Calltrace),
    ord(Content.CalltraceEditor),
    ord(Content.TraceLog),
    ord(Content.AgentActivity),
    ord(Content.AgentActivityDeepReview),
    # Content.FrameViewer removed in M3 — pane no longer dispatched.
    ord(Content.PixelHistory),
    ord(Content.ShaderDebug),
    ord(Content.VideoPlayer)
  ]

proc reviewPillarContentIds(): seq[int] =
  ## The panels a DeepReview session is assembled from and must therefore
  ## keep, even though an *editing* session hides them.
  ##
  ## DeepReview-GUI.md: "DeepReview introduces no panel of its own.  It is a
  ## combination of features of three existing surfaces: 1. the Editor,
  ## 2. the VCS panel, 3. the Agent Activity panel".  The Editor
  ## (`Content.EditorView`) and the VCS panel (`Content.VCS`) are not in
  ## `editModeHiddenContentIds` to begin with — an editing session has both —
  ## so the Agent Activity panel and the DeepReview section that renders
  ## inside it are the whole of the difference between the two modes.
  ##
  ## `Content.AgentActivityDeepReview` is a DIFFERENT id from the retired
  ## `Content.DeepReview` (36); see the note on the `Content` enum.  It is
  ## listed here because a saved layout may host it as a pane of its own.
  @[
    ord(Content.AgentActivity),
    ord(Content.AgentActivityDeepReview)
  ]

proc reviewModeHiddenContentIds(): seq[int] =
  ## Edit mode's hidden set, minus DeepReview's own pillars — RV-2.
  ##
  ## The rule itself lives in `index/layout_config_repair` so it can be
  ## exercised without electron or `fs`
  ## (`src/tests/gui/tests/layout/review_layout_test.nim`); this proc supplies
  ## the two `Content` ordinals by name so they exist in exactly one place.
  layout_config_repair.reviewModeHiddenContentIds(
    editModeHiddenContentIds(), reviewPillarContentIds())

proc stringifyJson(value: js): cstring {.importjs: "JSON.stringify(#)".}

proc sanitizeEditLayoutJson*(raw: cstring): cstring =
  let config = parseLayoutJson(raw, "Edit layout config JSON parse error while saving")
  if config.isNil:
    return raw
  let sanitized = sanitizeEditLayoutConfig(
    config, ord(Content.EditorView), editModeHiddenContentIds())
  return stringifyJson(sanitized)

proc sanitizeDefaultLayoutJson*(raw: cstring): cstring =
  ## Strip per-trace editor tabs from the persisted replay-mode layout.
  ##
  ## Panel arrangement (state / calltrace / event log / filesystem / ...)
  ## is preserved — only `Content.EditorView` entries are dropped because
  ## their `componentState.fullPath` refers to absolute source files from
  ## whatever program was being debugged at save time.  Re-instantiating
  ## those entries in a later session that loads a *different* trace
  ## leaves the editor in a broken state: the irrelevant tabs race with
  ## the source-request for the actually-active trace and Monaco never
  ## mounts.
  ##
  ## Reuses the existing `sanitizeEditLayoutConfig` helper with an empty
  ## hidden-content list so it only filters editor tabs.
  let config = parseLayoutJson(raw, "Default layout config JSON parse error while saving")
  if config.isNil:
    return raw
  let sanitized = sanitizeEditLayoutConfig(
    config, ord(Content.EditorView), @[])
  return stringifyJson(sanitized)

proc autoHideStatePath*(): string =
  ## Where the pinned/auto-hidden panel set is persisted.
  ##
  ## Deliberately a sibling of `default_layout.json` rather than a field
  ## inside it: pinned panels are removed from the GoldenLayout tree, so they
  ## are not part of the GoldenLayout config and must survive the layout
  ## sanitisers untouched.
  userLayoutDir / "auto_hide_state.json"

proc loadAutoHideState*(): Future[js] {.async.} =
  ## Read the persisted auto-hide state, or nil when there is none.
  ##
  ## A missing file is the normal first-run case and is not an error.
  var state: js = nil
  let (raw, err) = await fsReadFileWithErr(cstring(autoHideStatePath()))
  if err.isNil:
    state = parseLayoutJson(raw, "Auto-hide state JSON parse error")
  return state

const bundledDefaultLayoutJson = staticRead("../../config/default_layout.json")
  ## The default layout, compiled in, so recovering from a corrupt or
  ## unreadable one never depends on a file being present on disk. Mirrors the
  ## renderer-side copy in `ui/layout.nim`.

proc resetLayoutToDefault*(filename: string): Future[js] {.async.} =
  ## Move the unusable layout file aside and copy the bundled default.
  ## Returns the fresh default config.
  warnPrint "Resetting layout to default due to corrupt/incompatible config: ", filename

  # Keep a copy rather than destroying the user's arrangement outright: this
  # path used to be reached for layouts that were merely *unrecognised*
  # (a pinned Filesystem panel was enough), and the only trace left behind
  # was a warning in the log.  `.broken` makes the loss recoverable and gives
  # a bug report something to attach.
  let brokenCopy = filename & ".broken"
  let errBackup = await fsCopyFileWithErr(cstring(filename), cstring(brokenCopy))
  if errBackup.isNil:
    warnPrint "Previous layout kept for inspection at: ", brokenCopy
  else:
    warnPrint "Could not preserve the previous layout file: ", errBackup

  # Try to delete the corrupt file
  let errUnlink = await fsUnlinkWithErr(cstring(filename))
  if not errUnlink.isNil:
    warnPrint "Could not delete corrupt layout file (may not exist): ", errUnlink

  let directory = filename.parentDir
  # Use newJsObject with []= to avoid jsffi gensym collisions
  var mkdirOpts = newJsObject()
  mkdirOpts["recursive"] = true
  let errMkdir = await fsMkdirWithErr(cstring(directory), mkdirOpts)
  if not errMkdir.isNil:
    errorPrint "mkdir for layout config folder error: ", errMkdir
    # Don't quit - try to continue with bundled default

  let errCopy = await fsCopyFileWithErr(
    cstring(fmt"{configDir / defaultLayoutPath}"),
    cstring(filename)
  )

  if errCopy.isNil:
    # Read the fresh copy
    let (freshData, freshErr) = await fsreadFileWithErr(cstring(filename))
    if freshErr.isNil:
      let parsedFresh = parseLayoutJson(freshData,
        "Layout config JSON parse error after reset")
      if not parsedFresh.isNil:
        return parsedFresh

  # Next: read the installed default directly, without saving.
  warnPrint "Could not copy default layout, reading bundled default directly"
  let (bundledData, bundledErr) = await fsreadFileWithErr(cstring(fmt"{configDir / defaultLayoutPath}"))
  if bundledErr.isNil:
    let parsedBundled = parseLayoutJson(bundledData,
      "Bundled layout config JSON parse error")
    if not parsedBundled.isNil:
      return parsedBundled

  # Last resort: the compiled-in copy.
  #
  # `configDir` points at the INSTALLED tree (`codetracerPrefix / "config"`),
  # which does not exist in a plain `build-debug` checkout — so every branch
  # above can legitimately fail and this proc used to `quit(1)` there, taking
  # the whole index process down. A layout file the user cannot even see is
  # then fatal at startup with no way back except deleting it by hand, which
  # is the failure #608 was reported for. Recovering from a corrupt layout
  # must never depend on a file that may not be deployed; embed it instead.
  # `ui/layout.nim` already keeps the same compiled-in copy for the renderer
  # side of this fallback.
  warnPrint "No readable default layout on disk; using the compiled-in copy"
  let parsedEmbedded = parseLayoutJson(
    cstring(bundledDefaultLayoutJson), "Compiled-in layout config parse error")
  if not parsedEmbedded.isNil:
    return parsedEmbedded

  errorPrint "index: critical - cannot load any layout config"
  quit(1)

proc repairAndPersistLayout(config: js; filename: string;
                            context: string): Future[js] {.async.} =
  ## Bring a just-parsed layout config back into the subset GoldenLayout
  ## accepts and, when anything had to change, rewrite the file so the same
  ## repair is not re-applied on every single launch.
  ##
  ## Returns nil when nothing usable could be salvaged — the caller then
  ## falls back to the bundled default.
  ##
  ## This is the step that was missing entirely: the loader validated the
  ## *parse* (`parseLayoutJson`) and a shallow *shape* (`isValidLayoutConfig`)
  ## but never the semantics GoldenLayout enforces, so a file with an
  ## out-of-range `activeItemIndex` passed every check and then threw a native
  ## `Error` out of `loadLayout`, aborting `initLayout` half-way through.
  let unusable: js = nil
  let repair = repairLayoutConfig(config)
  if not repair.ok:
    warnPrint context, ": layout config is unusable: ", filename
    for issue in repair.issues:
      warnPrint "  ", issue
    return unusable
  if repair.changed:
    warnPrint context, ": repaired layout config: ", filename
    for issue in repair.issues:
      warnPrint "  ", issue
    let errWrite = await fsWriteFileWithErr(
      cstring(filename), stringifyJson(repair.config))
    if not errWrite.isNil:
      warnPrint context, ": could not rewrite the repaired layout: ", errWrite
  return repair.config

proc loadLayoutConfig*(main: js, filename: string): Future[js] {.async.} =
  let (data, err) = await fsreadFileWithErr(cstring(filename))
  if err.isNil:
    let parsed = parseLayoutJson(data, "Layout config JSON parse error")
    if parsed.isNil:
      return await resetLayoutToDefault(filename)
    let config = await repairAndPersistLayout(parsed, filename, "replay layout")
    if config.isNil:
      return await resetLayoutToDefault(filename)
    # Validate the loaded config structure.  The auto-hide state is consulted
    # so a panel the user pinned to an edge still counts as present.
    let autoHide = await loadAutoHideState()
    if not isValidLayoutConfig(config, autoHide):
      warnPrint "Layout config is invalid or incompatible: ", filename
      return await resetLayoutToDefault(filename)
    return ensureReplayLayoutPanels(config)
  else:
    let directory = filename.parentDir
    let errMkdir = await fsMkdirWithErr(cstring(directory), js{recursive: true})
    if not errMkdir.isNil:
      errorPrint "mkdir for layout config folder error: exiting: ", errMkdir
      quit(1)

    let errCopy = await fsCopyFileWithErr(
      cstring(fmt"{configDir / defaultLayoutPath}"),
      cstring(filename)
    )

    if errCopy.isNil:
      return await loadLayoutConfig(main, filename)
    else:
      errorPrint "index: load layout config error: ", errCopy
      quit(1)

proc resetHiddenPanelLayoutToDefault(filename: string;
                                     hiddenContents: seq[int]): Future[js] {.async.} =
  ## `resetLayoutToDefault` for a mode that hides panels.
  ##
  ## `resetLayoutToDefault` hands back the bundled `default_layout.json` —
  ## the DEBUGGING layout, EVENT LOG / CALLTRACE / TIMELINE / TERMINAL OUTPUT
  ## and all.  Returning that raw to an edit-mode or review-mode caller
  ## restores exactly the panels those modes exclude, which is the failure
  ## RV-2's fourth deliverable asks about ("Confirm `loadEditLayoutConfig`'s
  ## fallback does not silently reintroduce the debugging layout").  The
  ## *absent-file* fallback below always sanitised; these reset paths — a
  ## corrupt, unrepairable or incompatible layout file — did not, so a single
  ## bad byte in `default_edit_layout.json` turned a review back into a
  ## debugging window with panels no dataset can fill.
  ##
  ## Every recovery path therefore ends in the same sanitiser as the happy
  ## path, with the caller's own hidden set.
  let config = await resetLayoutToDefault(filename)
  if config.isNil:
    # `resetLayoutToDefault` exits rather than returning nil, but a nil here
    # must not become a crash inside the sanitiser.
    return config
  return sanitizeEditLayoutConfig(
    config, ord(Content.EditorView), hiddenContents)

proc loadEditLayoutConfig*(main: js, filename: string;
                           hiddenContents: seq[int] = editModeHiddenContentIds()):
                          Future[js] {.async.} =
  ## Load a layout for a mode that hides the replay-only panels.
  ##
  ## `hiddenContents` defaults to edit mode's set; `loadReviewLayoutConfig`
  ## below passes the review's, which is the same set minus DeepReview's own
  ## pillars.  The two modes share this loader rather than a copy of it so a
  ## fix to one (the reset paths above, say) cannot reach only one of them.
  let (data, err) = await fsreadFileWithErr(cstring(filename))
  if err.isNil:
    let parsed = parseLayoutJson(data, "Edit layout config JSON parse error")
    if parsed.isNil:
      return await resetHiddenPanelLayoutToDefault(filename, hiddenContents)
    let config = await repairAndPersistLayout(parsed, filename, "edit layout")
    if config.isNil:
      return await resetHiddenPanelLayoutToDefault(filename, hiddenContents)
    # Validate the loaded config structure
    let autoHide = await loadAutoHideState()
    if not isValidLayoutConfig(config, autoHide):
      warnPrint "Edit layout config is invalid or incompatible: ", filename
      return await resetHiddenPanelLayoutToDefault(filename, hiddenContents)
    return sanitizeEditLayoutConfig(
      config, ord(Content.EditorView), hiddenContents)
  else:
    # Edit mode layout file doesn't exist yet - use default debug layout as fallback
    let defaultLayoutFile = userLayoutDir / "default_layout.json"
    let (defaultData, defaultErr) = await fsreadFileWithErr(cstring(defaultLayoutFile))
    if defaultErr.isNil:
      let parsedDefault = parseLayoutJson(defaultData,
        "Default layout config JSON parse error")
      if parsedDefault.isNil:
        return await resetHiddenPanelLayoutToDefault(defaultLayoutFile, hiddenContents)
      let config = await repairAndPersistLayout(
        parsedDefault, defaultLayoutFile, "replay layout")
      if config.isNil:
        return await resetHiddenPanelLayoutToDefault(defaultLayoutFile, hiddenContents)
      let autoHide = await loadAutoHideState()
      if not isValidLayoutConfig(config, autoHide):
        warnPrint "Default layout config is invalid: ", defaultLayoutFile
        return await resetHiddenPanelLayoutToDefault(defaultLayoutFile, hiddenContents)
      return sanitizeEditLayoutConfig(
        ensureReplayLayoutPanels(config), ord(Content.EditorView), hiddenContents)
    else:
      # Fall back to the bundled default layout
      let errCopy = await fsCopyFileWithErr(
        cstring(fmt"{configDir / defaultLayoutPath}"),
        cstring(filename)
      )
      if errCopy.isNil:
        return await loadEditLayoutConfig(main, filename, hiddenContents)
      else:
        errorPrint "index: load edit layout config error: ", errCopy
        quit(1)

proc loadReviewLayoutConfig*(main: js, filename: string): Future[js] {.async.} =
  ## Load the layout a DeepReview session over an exported dataset opens in.
  ##
  ## RV-2 / DeepReview-GUI.md §1.1: "`ct review` opens the editor layout, not
  ## the debugging layout.  A review over a dataset is an editing-and-reading
  ## task, not a replay session.  The editor layout omits the panels a dataset
  ## cannot populate (EVENT LOG, CALLTRACE, TIMELINE, TERMINAL OUTPUT), so a
  ## review does not present empty panels that imply missing data."
  ##
  ## It is the *edit-mode* layout, read from the same
  ## `default_edit_layout.json` an editing session uses — a review adds no
  ## layout of its own, exactly as it adds no panel of its own
  ## (DeepReview-GUI.md §7).  The one difference is the hidden set: the Agent
  ## Activity panel is the review's third pillar and must survive.
  ##
  ## Only the *dataset* launch (`ct review <PATH>`) comes here.  A review over
  ## a diff-associated trace, and an agentic handoff that recorded one, keep
  ## the debugging layout: they have a recording, so those panels are
  ## populated and belong.  Neither passes through this loader — they enter
  ## the review from the renderer, on the layout the session already has.
  return await loadEditLayoutConfig(main, filename, reviewModeHiddenContentIds())

proc loadValues*(a: js, id: cstring): JsAssoc[cstring, cstring] =
  var fields = JsAssoc[cstring, js]{}
  var values = JsAssoc[cstring, cstring]{}
  if id == cstring"CODETRACER::updated-slice":
    return values
  if isJsObject(a):
    fields = cast[JsAssoc[cstring, js]](a)
  elif isJsArray(a):
    for i, element in a:
      fields[i.toCString] = element
  else:
    fields[cstring""] = a
  for field, value in fields:
    if field == cstring"source":
      continue
    elif not value.isNil:
      values[field] = value.toCString
    elif value.isNil:
      values[field] = cstring"undefined"
    else:
      values[field] = cstring"nil"
  return values

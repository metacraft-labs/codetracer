## A browser-produced Noir trace, as the files the replay engine's VFS wants.
##
## ## The problem this solves
##
## `noir-tracer` answers a `MemoryTrace` document — `{events, paths,
## line_lengths, source_views, capabilities, workdir}`. The engine's browser
## entry point (`dap_server.rs::setup_from_vfs`) reads a *different* shape: a
## bare `Vec<TraceLowLevelEvent>` at `<folder>/trace.json`, plus an optional
## `<folder>/trace_metadata.json` from which it reads exactly one key,
## `workdir`. So somebody has to take the document apart, and that somebody is
## this module.
##
## ## Why the SOURCE files are here too, and why that was in doubt
##
## `trace.json` is an event array. It has nowhere to put source text, and the
## engine's legacy branch decodes it as an array — `source_views` would be
## discarded even if it were spliced in. But a trace made in a browser tab is
## the only copy of its own source that anything will ever have: there is no
## working tree behind it, and on `wasm32-unknown-unknown` `fs::read_to_string`
## is `Unsupported` and `Path::exists()` is hardwired `false`, so *every*
## recorded path is the missing-source case.
##
## The engine reads source text through `ExprLoader`, and `ExprLoader` now
## falls back to the same in-memory VFS the trace arrives in. That one fallback
## serves both consumers that were feared to be separate:
##
##   * `Location.missing_path`, which `editor_service.nim` reads to choose
##     between the editor pane and the NO SOURCE view, and
##   * `get_source_line_v2`, the sole source-line supply for the §6.1
##     origin-chain classifier — the `origin-classifier` crate parses exactly
##     that string.
##
## They are the same read, keyed on the same recorded path. So writing the
## views is not a separate feature from resolving positions; it is the thing
## that makes both work.
##
## ## The key is the RECORDED path, verbatim
##
## The engine's VFS is a flat `HashMap<String, Vec<u8>>` with no path handling
## whatsoever, and three separate probes inside the engine spell a source path
## three ways: `find_real_path` uses the bare recorded string, `StepLinesLoader`
## always uses `workdir.join(recorded)`, and the origin chain uses
## `workdir.join(recorded)`-or-bare. For an ABSOLUTE recorded path
## `PathBuf::join` discards the base and all three collapse onto one string —
## which is why `replayVfsDefects` refuses a trace whose paths are relative
## rather than writing keys that only one of the three probes would ever ask
## for.
##
## ## No `when defined(js)`
##
## Everything here is a pure transform from one string to a list of files, so
## it compiles and runs on both backends and the `vm-unit` lane can assert on
## it without a browser. The host that actually posts these to a worker lives
## in `host/web_browser.nim`.

import std/[json, os, strutils]

type
  VfsFile* = object
    ## One entry to write into the engine's VFS before `start`.
    path*: string
      ## The VFS key. Exact-match; nothing normalises it.
    content*: string
      ## Raw bytes. A Nim `string` rather than `seq[byte]` because the JS
      ## backend has to hand these to `vfs_write_file` as a `Uint8Array` and
      ## the conversion is one place, in the host.

  ReplayVfsPayload* = object
    ## What a `MemoryTrace` becomes.
    traceFolder*: string
    files*: seq[VfsFile]
    steps*: int
      ## Counted here rather than recounted by a caller, because "loaded and
      ## reported success while carrying zero steps" is the false pass this
      ## whole path has, and a caller that has to ask a second question to
      ## find out is a caller that will not ask it.
    calls*: int
    sourceViews*: int
      ## How many recorded paths got their text written. Zero means every
      ## position in the session will come back `missingPath`.
    defects*: seq[string]
      ## Non-empty means DO NOT LAUNCH. Each entry names what is wrong in the
      ## terms a user could act on.

const
  traceFileName* = "trace.json"
    ## `setup_from_vfs` probes `join_vfs(folder, "trace.json")` and
    ## `browser_detect_trace_file_in_vfs` probes `["trace.ct", "trace.json"]`
    ## under the folder. Both spellings must be this one.
  traceMetadataFileName* = "trace_metadata.json"
    ## The engine reads ONE key out of it, `workdir`, and falls back to the
    ## trace folder when it cannot. Writing it anyway is what makes the
    ## fallback never fire, so a relative recorded path would resolve against
    ## the recording's own workdir rather than against the literal string
    ## `"trace"`.

proc vfsJoin*(folder, name: string): string =
  ## The engine's `join_vfs`: a single `/`, never the host separator.
  ##
  ## `os.`/`` would emit `\` on a Windows build of the test lane, and the VFS
  ## key is compared as a byte string against a `/`-joined probe. This is a
  ## one-line function so that the rule has one place to be wrong.
  if folder.len == 0: name
  elif folder.endsWith("/"): folder & name
  else: folder & "/" & name

proc pathJoin*(base, path: string): string =
  ## Rust's `Path::join`, which is NOT this module's `vfsJoin`.
  ##
  ## The engine performs BOTH operations on the same store and they differ in
  ## the case that matters. `join_vfs(folder, name)` is a string concatenation
  ## and is how the trace folder's own files are addressed; `PathBuf::join` is
  ## how a source path is joined onto the workdir, and it DISCARDS the base
  ## when the path is already absolute.
  ##
  ## Spelling both as concatenation was a real defect and the suite caught it:
  ## an absolute recorded path produced a second key `/workdir//abs/path`,
  ## which no probe ever asks for, and `sourceFileCount` — a number a caller
  ## asserts on — silently doubled.
  if path.len == 0: return base
  if path.isAbsolute: return path
  if base.len == 0: return path
  if base.endsWith("/"): base & path
  else: base & "/" & path

proc decodeContent(node: JsonNode): string =
  ## `SourceView.content` is a `Vec<u8>` serialised by plain serde, so it
  ## arrives as a JSON array of integers and NOT as a string. Decoding it as a
  ## string would silently produce empty source for every file.
  result = newStringOfCap(if node.kind == JArray: node.len else: 0)
  if node.kind != JArray: return
  for byteNode in node:
    if byteNode.kind != JInt: return ""
    let value = byteNode.getInt
    if value < 0 or value > 255: return ""
    result.add chr(value)

proc vfsKeysFor*(recordedPath, workdir: string): seq[string] =
  ## Every spelling of `recordedPath` the engine might probe, deduplicated.
  ##
  ## ## Why this is a LIST and not the recorded string
  ##
  ## The engine's VFS is a flat `HashMap<String, Vec<u8>>` with no path
  ## handling at all, and three separate probes inside it spell a source path
  ## differently: `ExprLoader::find_real_path` uses the bare recorded string,
  ## `StepLinesLoader` always uses `workdir.join(recorded)`, and the origin
  ## chain uses one or the other. For an ABSOLUTE recorded path `PathBuf::join`
  ## discards the base and all three collapse onto one key.
  ##
  ## This module used to REFUSE a relative recorded path on exactly that
  ## reasoning, and the reasoning was right while the conclusion was wrong.
  ## Measured against the product rather than the engine: the browser Noir
  ## compiler is handed a virtual package tree and records
  ## `hello_noir/src/main.nr` — relative, because that is the key it was given.
  ## Every trace a tab can produce is the refused case, so the refusal would
  ## have rejected all of them and the session would have reported a defect
  ## naming the engine's probe order to a user who had done nothing wrong.
  ##
  ## Writing both spellings costs one extra map entry per source file and
  ## makes the probe order stop mattering. The list is deduplicated so the
  ## absolute case still writes exactly one.
  if recordedPath.len == 0: return @[]
  result = @[recordedPath]
  if workdir.len > 0:
    let joined = pathJoin(workdir, recordedPath)
    if joined != recordedPath: result.add joined

proc replayVfsPayload*(rawMemoryTrace: string;
                       traceFolder = "trace"): ReplayVfsPayload =
  ## Take a `MemoryTrace` document apart into the files the engine reads.
  ##
  ## Never raises: a malformed document comes back as a payload with defects
  ## and no files, because the caller's job is to show the user a reason, not
  ## to catch an exception from a JSON parser.
  result.traceFolder = traceFolder
  result.files = @[]
  result.defects = @[]

  if rawMemoryTrace.len == 0:
    result.defects.add "the tracer produced no output at all"
    return

  var document: JsonNode
  try:
    document = parseJson(rawMemoryTrace)
  except:
    # A BARE except, and for the reason `parseDeploymentDescriptor` gives for
    # its own: under `nim js` the failure that reaches here is not always a
    # `CatchableError`, so a typed handler lets a malformed trace escape as an
    # unhandled rejection instead of becoming the defect a user can read.
    document = nil
  if document.isNil or document.kind != JObject:
    result.defects.add "the tracer's output is not a MemoryTrace document"
    return

  let events =
    if document.hasKey("events") and document["events"].kind == JArray:
      document["events"]
    else:
      newJArray()
  for event in events:
    if event.kind != JObject: continue
    if event.hasKey("Step"): inc result.steps
    elif event.hasKey("Call"): inc result.calls

  # The false pass this path has, named and refused here rather than at the
  # end of a replay session that reported `ok` over an empty timeline. An
  # artifact compiled without debug instrumentation traces to one event and no
  # steps, and both wasm modules answer `ok` over it.
  if events.len == 0:
    result.defects.add "the trace carries no events"
  elif result.steps == 0:
    result.defects.add(
      "the trace carries " & $events.len & " events and no steps, so there " &
      "is nothing to step through — the program was compiled without debug " &
      "instrumentation")

  var paths: seq[string] = @[]
  if document.hasKey("paths") and document["paths"].kind == JArray:
    for path in document["paths"]:
      if path.kind == JString: paths.add path.getStr
  if paths.len == 0:
    result.defects.add "the trace registered no source paths"

  # THE WORKDIR IS WRITTEN, ALWAYS, AND THE KEYS ARE DERIVED FROM THE SAME
  # VALUE. `setup_from_vfs` falls back to the trace folder when
  # `trace_metadata.json` names no workdir, so a payload that omitted it would
  # leave the engine joining against `"trace"` while this module joined
  # against something else — the two spellings would miss each other and every
  # position would resolve to source the engine cannot read. Deriving both
  # sides from one variable makes that disagreement unrepresentable.
  let workdir =
    if document.hasKey("workdir") and document["workdir"].kind == JString and
       document["workdir"].getStr.len > 0:
      document["workdir"].getStr
    elif paths.len > 0 and paths[0].isAbsolute:
      # An absolute recording knows where it ran; `PathBuf::join` discards the
      # base for these anyway, so this only affects what the metadata says.
      paths[0].parentDir
    else:
      # A relative recording — every trace a browser tab can produce, because
      # the Noir compiler is handed a virtual package tree and records the key
      # it was given. The engine's own fallback is the trace folder, so naming
      # it here says out loud what would otherwise be assumed.
      traceFolder

  if result.defects.len > 0: return

  result.files.add VfsFile(
    path: vfsJoin(traceFolder, traceFileName), content: $events)
  result.files.add VfsFile(
    path: vfsJoin(traceFolder, traceMetadataFileName),
    content: $(%*{"workdir": workdir}))

  # The source text, filed under the recorded path each view belongs to.
  # `SourceView` carries no path of its own — it carries a `path_id` into the
  # `paths` array — so a view written under `view_name` rather than under
  # `paths[path_id]` would be a key nothing ever asks for.
  if document.hasKey("source_views") and document["source_views"].kind == JArray:
    for view in document["source_views"]:
      if view.kind != JObject: continue
      if not view.hasKey("path_id") or view["path_id"].kind != JInt: continue
      let pathId = view["path_id"].getInt
      if pathId < 0 or pathId >= paths.len: continue
      if not view.hasKey("content"): continue
      let text = decodeContent(view["content"])
      if text.len == 0: continue
      for key in vfsKeysFor(paths[pathId], workdir):
        result.files.add VfsFile(path: key, content: text)
      inc result.sourceViews

  if result.sourceViews == 0:
    result.defects.add(
      "the trace embeds no source text, so every position in the session " &
      "would resolve to a line the engine cannot display")

  # A defective payload carries NO files. The alternative is a caller that
  # reads `defects`, decides to warn rather than refuse, and launches anyway
  # over a list that is right there — which is how a session opens onto a
  # trace nobody vouched for. The two defects that can only be discovered
  # after the files are built (no source view) are the reason this is a sweep
  # at the end rather than an early return at each check.
  if result.defects.len > 0:
    result.files = @[]

proc rendererSpelling*(recordedPath, packageDir, projectRoot: string): string =
  ## The recorded path, in the spelling the renderer opens tabs by.
  ##
  ## ## Why a translation is needed at all
  ##
  ## Two spellings of one file, and both are correct for their own side. The
  ## browser Noir compiler is handed a virtual package tree and records
  ## `hello_noir/src/main.nr`, because that is the key it was given, and the
  ## engine echoes that string back in every `ct/complete-move` location. The
  ## renderer keys tabs, file-tree rows and breakpoints by
  ## `/hello_noir/src/main.nr` — `utils.openTab` treats a relative name as a
  ## path it must rescue by tail-matching, and `edit_mode.sourceScore` awards
  ## a bonus for a leading `/src/` segment.
  ##
  ## So a location handed to `editor_service` in the compiler's spelling opens
  ## a SECOND, empty tab beside the one the user is looking at — the failure
  ## that looks like it worked. `noir_build_producer.rendererPath` makes this
  ## same conversion for diagnostics and gives the same reasons; this is the
  ## same rule for locations, in the pure layer, so the browser host can apply
  ## it without owning it.
  ##
  ## A path the prefix does not match is passed through unchanged rather than
  ## having a slash bolted on: the stdlib's own sources reach locations
  ## occasionally, and inventing a project-relative identity for them would
  ## make a location claim the project contains a file it does not.
  if recordedPath.len == 0 or packageDir.len == 0: return recordedPath
  let prefix = packageDir & "/"
  if recordedPath.startsWith(prefix):
    return projectRoot & "/" & recordedPath[prefix.len .. ^1]
  recordedPath

proc retargetLocationPaths*(frame: JsonNode; packageDir, projectRoot: string):
    int =
  ## Rewrite every `path` under a DAP frame's `location` objects, in place.
  ##
  ## Returns how many were rewritten, so a caller can assert a number rather
  ## than assert that a walk happened. Zero over a frame that carries a
  ## location is the silent case: the session steps, the position resolves,
  ## and the editor opens a second empty tab.
  ##
  ## The walk is over the whole frame rather than one known key because the
  ## engine puts a `Location` in several places — `ct/complete-move`'s body is
  ## one, a call's `location` is another — and a rewrite that knew only the
  ## first would leave the calltrace pointing at the compiler's spelling.
  if frame.isNil: return 0
  case frame.kind
  of JObject:
    for key, value in frame.pairs:
      if key == "path" and value.kind == JString:
        let retargeted =
          rendererSpelling(value.getStr, packageDir, projectRoot)
        if retargeted != value.getStr:
          frame[key] = newJString(retargeted)
          result += 1
      else:
        result += retargetLocationPaths(value, packageDir, projectRoot)
  of JArray:
    for item in frame.items:
      result += retargetLocationPaths(item, packageDir, projectRoot)
  else: discard

proc sourceFileCount*(payload: ReplayVfsPayload): int =
  ## Files that are source rather than trace plumbing.
  ##
  ## Derived from the same list the host posts, so a caller asserting on it is
  ## asserting the thing that was written and not a number kept beside it.
  for file in payload.files:
    if not file.path.startsWith(payload.traceFolder & "/"): inc result

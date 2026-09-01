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

  for path in paths:
    if not path.isAbsolute:
      result.defects.add(
        "the trace records `" & path & "` as a relative path; the engine " &
        "probes a source path both bare and joined onto the workdir, and " &
        "only an absolute path is the same VFS key under both")
      break

  let workdir =
    if document.hasKey("workdir") and document["workdir"].kind == JString:
      document["workdir"].getStr
    elif paths.len > 0:
      paths[0].parentDir
    else:
      ""
  if workdir.len == 0:
    result.defects.add "the trace names no workdir and has no path to derive one from"

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
      result.files.add VfsFile(path: paths[pathId], content: text)
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

proc sourceFileCount*(payload: ReplayVfsPayload): int =
  ## Files that are source rather than trace plumbing.
  ##
  ## Derived from the same list the host posts, so a caller asserting on it is
  ## asserting the thing that was written and not a number kept beside it.
  for file in payload.files:
    if not file.path.startsWith(payload.traceFolder & "/"): inc result

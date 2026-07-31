## Detection of the on-disk *shape* of a recording folder.
##
## CodeTracer's importer historically accepted exactly one shape: a CTFS
## container file (``trace.ct``, or any ``*.ct`` file) inside the trace
## folder.  That is the shape ``ct record`` produces for every
## process-local recorder, and M-REC-1.5 deliberately retired the
## ``trace_db_metadata.json`` sidecar that used to duplicate its
## metadata.
##
## It is however **not** the only shape the product replays.  The
## browser recorder — ``ct record-web``, implemented in
## ``src/backend-manager`` — writes the *materialized* `runtime_tracing`
## shape straight to disk:
##
## ```
##   <recording>/
##     trace.json            # runtime_tracing event stream (or trace.bin)
##     trace_metadata.json   # {"program", "args", "workdir", "recorder"}
##     trace_paths.json      # ["<absolute source path>", ...]
## ```
##
## The Rust replay engine reads that shape natively — see
## ``db-backend/src/dap_server.rs::auto_detect_materialized_trace_file``
## and ``legacy_materialized_trace_file_in_dir`` — which is why the
## headless DAP suites replay browser recordings today.  Only the Nim
## importer refused them, so a browser recording could be replayed by
## every test in the repo yet never opened by the GUI.
##
## This module is the single place that answers "what kind of recording
## is this folder?", so ``importTrace`` and ``ct host`` agree, and so the
## *failure* message can say what was actually found rather than
## repeating a fixed expectation.
##
## References:
## - runtime_tracing on-disk format: https://github.com/metacraft-labs/runtime_tracing
## - the Rust-side detector this mirrors: ``src/db-backend/src/dap_server.rs``

import std / [ os, strutils, algorithm ]

const
  ## Canonical CTFS container name.  Any ``*.ct`` file is accepted, but
  ## this one wins when several are present.
  CANONICAL_CT_FILE* = "trace.ct"

  ## CTFS container magic bytes.
  ## Reference: codetracer-native-recorder/ct_recorder/src/ct_recorder/ctfs_nim.nim
  CtfsMagic*: array[5, byte] = [0xC0'u8, 0xDE, 0x72, 0xAC, 0xE2]

  ## Event-stream file names of the materialized `runtime_tracing`
  ## shape.  Mirrors ``is_legacy_materialized_trace`` in
  ## ``dap_server.rs`` — keep the two lists in sync.
  MATERIALIZED_TRACE_EVENT_FILES* = ["trace.json", "trace.bin"]

  ## Sidecars the materialized shape carries next to its event stream.
  MATERIALIZED_TRACE_METADATA_FILE* = "trace_metadata.json"
  MATERIALIZED_TRACE_PATHS_FILE* = "trace_paths.json"

  ## Multi-recording session manifest (spec ``Trace-Files/Session-Manifest.md`` §5).
  ## Parsed by ``db-backend/src/session_manifest.rs``; ``ct`` only ever
  ## detects it here and delegates the parse.
  SESSION_MANIFEST_FILE* = "session.toml"

type
  TraceFolderShapeKind* = enum
    ## Nothing replayable was found.
    TraceShapeMissing
    ## A CTFS container file (``*.ct``).
    TraceShapeCtfs
    ## A materialized `runtime_tracing` directory (``trace.json`` /
    ## ``trace.bin`` plus sidecars), as written by ``ct record-web``.
    TraceShapeMaterialized
    ## A multi-recording ``session.toml`` manifest.
    TraceShapeSession

  TraceFolderShape* = object
    ## The resolved shape of a folder, plus the concrete path the
    ## downstream reader should open.
    kind*: TraceFolderShapeKind
    ## For ``TraceShapeCtfs``: the ``*.ct`` container.
    ## For ``TraceShapeMaterialized``: the event-stream file.
    ## For ``TraceShapeSession``: the ``session.toml`` path.
    ## Empty for ``TraceShapeMissing``.
    path*: string
    ## The folder the shape was detected in.
    folder*: string

proc hasCtfsMagic*(path: string): bool =
  ## Read the first 5 bytes of `path` and check them against the CTFS
  ## magic.  Returns false if the file is too small, unreadable, or does
  ## not match.
  var f: File
  if not open(f, path, fmRead):
    return false
  defer: f.close()
  var buf: array[5, byte]
  let bytesRead = f.readBytes(buf, 0, 5)
  if bytesRead < 5:
    return false
  for i, b in CtfsMagic:
    if buf[i] != b:
      return false
  true

proc findCtFileInFolder*(folder: string): string =
  ## Locate the canonical ``trace.ct`` (falling back to any ``*.ct``
  ## **file** carrying the CTFS magic) in `folder`.  Returns "" when the
  ## folder holds no CTFS container.
  ##
  ## Two properties are load-bearing and used to live in two separate
  ## near-duplicates of this routine (``storage_and_import`` accepted any
  ## ``*.ct`` file, ``online_sharing/mcr_enrichment`` additionally
  ## verified the magic).  They are unified here:
  ##
  ## * only *files* qualify — a **directory** named ``foo.ct`` is not a
  ##   container.  Session fixtures name their per-process recording
  ##   directories ``frontend.ct`` / ``backend.ct``, so this distinction
  ##   is exactly what ``describeMissingTraceContainer`` has to explain
  ##   when the lookup fails;
  ## * the file must actually be CTFS, so a stray ``notes.ct`` cannot
  ##   shadow the real container.
  if not dirExists(folder):
    return ""
  let canonical = folder / CANONICAL_CT_FILE
  if fileExists(canonical) and hasCtfsMagic(canonical):
    return canonical
  for kind, path in walkDir(folder):
    if kind in {pcFile, pcLinkToFile} and path.endsWith(".ct") and
        hasCtfsMagic(path):
      return path
  ""

proc findMaterializedTraceEventFile*(folder: string): string =
  ## Locate the materialized `runtime_tracing` event stream in `folder`,
  ## or "" when absent.
  for name in MATERIALIZED_TRACE_EVENT_FILES:
    if fileExists(folder / name):
      return folder / name
  ""

proc findSessionManifestInFolder*(folder: string): string =
  ## Locate a ``session.toml`` multi-recording manifest in `folder`, or
  ## "" when absent.
  let candidate = folder / SESSION_MANIFEST_FILE
  if fileExists(candidate):
    return candidate
  ""

proc detectTraceFolderShape*(folder: string, allowSession: bool = true,
                             descend: bool = true): TraceFolderShape =
  ## Classify `folder`.
  ##
  ## Order matters: a session manifest wins over any single recording
  ## that happens to sit beside it, because a folder that carries a
  ## manifest *is* a session — opening one arbitrary member of it would
  ## silently show the user a third of their program.  Callers that
  ## deliberately want the single-recording interpretation (the
  ## per-``[[trace]]`` import inside a session, say) pass
  ## ``allowSession = false``.
  ##
  ## CTFS wins over the materialized shape so that a recording carrying
  ## both keeps its container as the source of truth (M-REC-1.5).
  ##
  ## ``descend``: when the folder itself holds no recording, look one
  ## level below it.  Some recorders treat ``--out-dir`` as the PARENT of
  ## the recording rather than the recording itself:
  ##
  ## * codetracer-js-recorder writes ``<out-dir>/trace-<n>/`` (which is
  ##   why `just demo-request-panel js` has to `find` for ``trace-*`` and
  ##   leave the path in a ``.trace_dir`` marker file);
  ## * codetracer-php-recorder writes ``<out-dir>/worker_<pid>/`` when it
  ##   is recording a multi-worker server (`just demo-request-panel php`
  ##   reads its ``.worker_dir`` marker for the same reason).
  ##
  ## Without this ``ct record app.js`` recorded successfully and then
  ## died in `importTrace` with "no recording found", because the
  ## container was one directory deeper than the search looked.
  ##
  ## Descent is deliberately constrained in two ways, because "look
  ## harder" is exactly the change that can silently open a *fraction* of
  ## a multi-recording session:
  ##
  ## * it never happens in a folder carrying a ``session.toml``, even
  ##   under ``allowSession = false``.  The session fixtures put a real
  ##   CTFS container at ``backend.ct/server.ct`` and materialized
  ##   recordings at ``frontend.ct/``, so an unguarded one-level search
  ##   finds exactly one container there and would open the backend alone
  ##   — the whole regression the manifest exists to prevent;
  ## * exactly one nested recording is unambiguous.  Several means the
  ##   folder holds several recordings (a recorded server with several
  ##   workers), and picking one arbitrarily would silently open the
  ##   wrong one — the caller has to say which.
  if allowSession:
    let manifest = findSessionManifestInFolder(folder)
    if manifest.len > 0:
      return TraceFolderShape(
        kind: TraceShapeSession, path: manifest, folder: folder)

  let ctPath = findCtFileInFolder(folder)
  if ctPath.len > 0:
    return TraceFolderShape(kind: TraceShapeCtfs, path: ctPath, folder: folder)

  let eventFile = findMaterializedTraceEventFile(folder)
  if eventFile.len > 0:
    return TraceFolderShape(
      kind: TraceShapeMaterialized, path: eventFile, folder: folder)

  # Last resort only: everything above looked at `folder` itself.
  if descend and dirExists(folder) and
      findSessionManifestInFolder(folder).len == 0:
    var nested: seq[TraceFolderShape] = @[]
    for kind, path in walkDir(folder):
      if kind notin {pcDir, pcLinkToDir}:
        continue
      # `descend = false`: one level, never a recursive crawl.  A nested
      # `session.toml` is a session in its own right and is reported as
      # such rather than being flattened into one of its members.
      let inner = detectTraceFolderShape(
        path, allowSession = true, descend = false)
      if inner.kind != TraceShapeMissing:
        nested.add(inner)
        if nested.len > 1:
          break
    if nested.len == 1:
      return nested[0]

  TraceFolderShape(kind: TraceShapeMissing, path: "", folder: folder)

proc describeMissingTraceContainer*(folder: string): string =
  ## Build the diagnostic emitted when `folder` holds no recognisable
  ## recording.
  ##
  ## The pre-existing message was a flat "trace folder missing `.ct`
  ## CTFS container", which reads as a CodeTracer bug when printed
  ## against a folder that visibly contains ``backend.ct`` — the entry
  ## is there, it is just a *directory* rather than a container file.
  ## So we report what we found, not only what we wanted.
  if not dirExists(folder):
    if fileExists(folder):
      return "not a trace folder: " & folder &
        " is a file (pass the folder that contains the recording, " &
        "or a `*.ct` CTFS container directly)"
    return "trace folder does not exist: " & folder

  var ctDirs: seq[string] = @[]
  var otherEntries: seq[string] = @[]
  for entry in walkDir(folder, relative = true):
    if entry.kind == pcDir and entry.path.endsWith(".ct"):
      ctDirs.add(entry.path)
    else:
      otherEntries.add(entry.path)
  sort(ctDirs)
  sort(otherEntries)

  result = "no recording found in " & folder & ": expected a `*.ct` CTFS " &
    "container file, a materialized recording (" &
    MATERIALIZED_TRACE_EVENT_FILES.join(" or ") & "), or a `" &
    SESSION_MANIFEST_FILE & "` session manifest"
  # `detectTraceFolderShape` also searched one level down (for the
  # recorders whose --out-dir names the recording's parent), and treats
  # several nested recordings as ambiguous rather than picking one.  When
  # that is why detection failed, saying so is far more useful than
  # listing the folder's contents: the fix is to name the exact recording.
  var nestedRecordings: seq[string] = @[]
  for kind, path in walkDir(folder, relative = true):
    if kind notin {pcDir, pcLinkToDir}:
      continue
    if detectTraceFolderShape(folder / path, allowSession = true,
                              descend = false).kind != TraceShapeMissing:
      nestedRecordings.add(path)
  sort(nestedRecordings)

  if nestedRecordings.len > 1:
    result.add("; found " & $nestedRecordings.len & " recordings one level " &
      "below it (" & nestedRecordings.join(", ") & ") — that is ambiguous, " &
      "so pass the exact recording (e.g. `--trace-path " &
      folder / nestedRecordings[0] & "`), or describe them together with a `" &
      SESSION_MANIFEST_FILE & "` in " & folder)
  elif ctDirs.len > 0:
    result.add("; found the directory(-ies) " & ctDirs.join(", ") &
      " whose name ends in `.ct` but which are not container files — " &
      "a multi-recording session must be described by a `" &
      SESSION_MANIFEST_FILE & "` next to them, and a single recording " &
      "directory must be passed directly (e.g. `--trace-path " &
      folder / ctDirs[0] & "`)")
  elif otherEntries.len == 0:
    result.add("; the folder is empty")

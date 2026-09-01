## The Noir wasm toolchain's REQUEST AND RESPONSE SHAPES, as values.
##
## NS3 landed the registry, the worker protocol and the transport; NS9 merged
## the bundles so the renderer can see the platform that owns them. What was
## still missing between a Build button and 19 MB of working compiler is this
## module and the producer beside it: **nothing converted a project into a
## `nv_compile_vfs` request, and nothing read the answer back**.
##
## `wasm_worker_browser.js` marshals nothing. Its `compileVfs` takes
## `JSON.parse(request.stdin)` and hands it straight to the module; its
## `traceArtifact` takes `payload.artifact` and `payload.inputs`. So the
## `stdin` of a `start` message IS the wasm ABI's own JSON, and composing it is
## the caller's job. This module is that composition, and the decoding of what
## comes back.
##
## ## Why it is pure, and on both backends
##
## The same discipline `wasm_registry.nim` and `noir_wasm_modules.nim` state in
## their own headers: no browser, no worker, no `when defined(js)`. The
## host-free gate type-checks all of it on C and `vm-unit-js` runs all of it on
## the backend the renderer ships on. A marshaller that could only be exercised
## in a tab is a marshaller whose field names are checked by nobody.
##
## ## THE FIELD NAMES ARE THE CONTRACT, and they are `compile_vfs.rs`'s
##
## The producing side is the `noir` fork's `compiler/wasm/src/compile_vfs.rs`
## (`VfsRequest` / `VfsResponse`) and `compiler/wasm/src/vfs.rs`
## (`PositionedDiagnostic`). Every name below is that struct's `serde`
## spelling, and where the two could drift the Rust side is quoted in place.
## `snake_case` throughout, because that is what `serde` emits by default and
## nothing in that crate renames.
##
## ## THREE FACTS MEASURED AGAINST THE REAL MODULE, not inferred
##
## Run against `noir_wasm.wasm` built from the `codetracer` branch, over the
## bundled template (2026-09-01, aarch64-darwin):
##
## 1. **`warnings` and `diagnostics` are ABSENT, not empty, when there are
##    none.** Both carry `#[serde(skip_serializing_if = "Vec::is_empty")]`, so
##    a successful compile answers `{"ok":true,"plan":…,"artifact":…}` with no
##    `warnings` key at all. A decoder that indexed rather than probed would
##    raise on every successful build. `hasKey` is used throughout for this.
##
## 2. **`mode: "debug"` silences warnings; `mode: "program"` does not.**
##    `vfs.rs`'s `debugging_compile_options()` sets `silence_warnings: true`
##    (nargo's own choice — the instrumenter imports `__debug` functions the
##    user did not write). Measured, over one program carrying both an unused
##    expression and an unresolved path:
##
##        mode=program   ok=false   2 diagnostics   warning + error
##        mode=debug     ok=false   1 diagnostic    error
##
##    That is why `nbmProgram` is what a BUILD asks for and `nbmDebug` is what
##    a RUN asks for, and it is not an optimisation: a Build in debug mode
##    would silently drop every warning the user could act on, and a Run in
##    program mode produces an artifact the tracer walks in **one event and
##    zero steps** (`vfs.rs::context_for` records that measurement).
##
## 3. **A refusal before compilation carries no `diagnostics` at all.**
##    `VfsResponse::refused` fills `stage`/`kind`/`message`/`manifest`/`line`/
##    `column` and leaves `diagnostics` empty — so a `Nargo.toml` naming a git
##    dependency, or a missing manifest, produces ZERO diagnostics and one
##    positioned message. A pane that only rendered `diagnostics` would paint
##    nothing for the two most likely first-run mistakes. `manifestProblem`
##    exists for exactly that, and it is why `refusalPosition` is a separate
##    accessor rather than folded into the diagnostic list.

import std/[json, strutils]

type
  NoirBuildMode* = enum
    ## `VfsRequest.mode`. `resolve` and `contract` exist in the Rust enum and
    ## are deliberately absent here: the worker dispatches exactly two
    ## subcommands, and a mode this product never asks for would be a value
    ## with no caller and no test.
    nbmProgram = "program"
      ## The circuit — what `nargo compile` means. Reports warnings.
    nbmDebug = "debug"
      ## Instrumented, `force_brillig` — the ONLY artifact a tracer can
      ## consume. Silences warnings; see fact 2 in the header.

  NoirSourceEntry* = object
    ## One file in the virtual filesystem handed to the compiler.
    ##
    ## `path` is a VFS key, always `/`-separated and never host-absolute: it
    ## includes the package directory as its first segment, because
    ## `package_dir` is a prefix OF these paths rather than a root they are
    ## relative to. `compare.mjs` shows the same shape — `proj/Nargo.toml`
    ## beside `package_dir: "proj"`.
    path*: string
    content*: string

  NoirDiagnosticSeverity* = enum
    ## `PositionedDiagnostic.severity`, which `vfs.rs` produces as
    ## `format!("{:?}", diagnostic.kind).to_lowercase()` over
    ## `noirc_errors::DiagnosticKind` — an enum with exactly four cases.
    ndsError    ## `DiagnosticKind::Error`
    ndsWarning  ## `DiagnosticKind::Warning`
    ndsBug      ## `DiagnosticKind::Bug` — an internal compiler fault
    ndsInfo     ## `DiagnosticKind::Info`
    ndsUnknown
      ## A spelling this build does not know. NOT folded into `ndsError`:
      ## that is the corruption the desktop text matcher is being repaired
      ## for, and a decoder that silently calls everything an error cannot be
      ## told apart from one that reads the field correctly. A caller decides
      ## what to do with it, and `severityText` still carries the raw word so
      ## the fact is never lost.

  NoirDiagnostic* = object
    ## `vfs.rs::PositionedDiagnostic`, field for field.
    message*: string
    file*: string
      ## The VFS path, exactly as the caller registered it — `vfs.rs` says
      ## "`file_manager.path()` returns exactly what was registered". So it
      ## carries the package-dir prefix and is NOT the path the renderer keys
      ## tabs by; `noir_build_producer` maps it.
    line*: int        ## 1-based. `0` when the frontend had no position.
    column*: int      ## 1-based.
    endLine*: int
    endColumn*: int
    startByte*: int   ## `start` in the wire shape; renamed here because
    endByte*: int     ## `end` is a Nim keyword.
    secondaryMessages*: seq[string]
    notes*: seq[string]
    severity*: NoirDiagnosticSeverity
    severityText*: string
      ## Verbatim. Kept beside the enum so `ndsUnknown` names the word it did
      ## not recognise instead of erasing it.

  NoirCompileResponse* = object
    ## `compile_vfs.rs::VfsResponse`.
    ok*: bool
    stage*: string     ## `request`, `resolve` or `compile`. Absent on success.
    kind*: string      ## `bad-request`, `git-dependency-refused`,
                       ## `missing-manifest`, `compile-error`, …
    message*: string
    manifest*: string  ## The `Nargo.toml` a resolve refusal is about.
    line*: int         ## Position of a RESOLVE refusal, inside `manifest`.
    column*: int
    diagnostics*: seq[NoirDiagnostic]
    warnings*: seq[NoirDiagnostic]
    artifact*: JsonNode  ## `nil` unless the compile succeeded.
    decoded*: bool
      ## False when the text was not a `VfsResponse` at all. A worker that
      ## answered with something else must be reported as such rather than as
      ## a compile that produced no diagnostics — the two look identical in
      ## every field above and are completely different faults.
    raw*: string
      ## What could not be decoded, for the message. Empty when `decoded`.

  NoirTraceSummary* = object
    ## What a trace IS, counted — the shape `ci/test/noir-wasm-worker/
    ## compare.mjs` asserts on, because "it returned" is not a result.
    ##
    ## `compare.mjs`'s own header records why the counts matter: the same two
    ## modules once answered `ok` over a trace of ONE event and ZERO steps,
    ## and every obvious assertion passed. A pane that said "traced" over that
    ## would be repeating the mistake to a user.
    decoded*: bool
    events*: int
    steps*: int
    calls*: int
    paths*: seq[string]
    bytes*: int

const
  noirCompileSubcommand* = "compile"
  noirTraceSubcommand* = "trace"
    ## The two the worker implements. Spelled here as well as in
    ## `noir_wasm_modules.nim` would be two statements of one fact, so they
    ## are NOT: see `noirCompileArgs` / `noirTraceArgs`, which take them.

# ---------------------------------------------------------------------------
# The request
# ---------------------------------------------------------------------------

proc noirVfsPath*(packageDir, relative: string): string =
  ## A project-relative path as a VFS key.
  ##
  ## The package directory is a PREFIX of every source path, not a root they
  ## hang off — `resolve_vfs(&tree, "proj")` looks for the literal key
  ## `proj/Nargo.toml` in the map. So this is a join, and the one place that
  ## knows it.
  ##
  ## NO LEADING SLASH, and that is load-bearing. The renderer keys its tabs by
  ## `/hello_noir/src/main.nr` (`web_entry_surface.templateProjectRoot`'s
  ## header explains why the leading slash is required THERE), and handing
  ## that spelling to the compiler would ask it to resolve a package at an
  ## absolute path in a tree whose keys have none. The two spellings are
  ## different on purpose and `noir_build_producer` converts between them.
  if packageDir.len == 0: relative
  else: packageDir & "/" & relative

proc noirVfsRequest*(files: seq[NoirSourceEntry]; packageDir: string;
                     mode: NoirBuildMode): JsonNode =
  ## `VfsRequest`, as the JSON the worker's `stdin` carries.
  ##
  ## `files` is an OBJECT keyed by path rather than an array of pairs, because
  ## `VfsRequest.files` is a `BTreeMap<String, String>`. An array would
  ## deserialize to `Err` and come back as `kind: "bad-request"` — a refusal
  ## naming serde rather than the project, which is the least useful thing a
  ## first Build could say.
  var tree = newJObject()
  for entry in files:
    tree[entry.path] = %entry.content
  %*{
    "files": tree,
    "package_dir": packageDir,
    "mode": $mode
  }

proc noirTraceRequest*(artifact: JsonNode; inputs: string): JsonNode =
  ## The `trace` subcommand's `stdin`.
  ##
  ## `wasm_worker_browser.js` reads exactly two fields off it —
  ## `payload.artifact` and `payload.inputs` — and hands them to `ct_trace` as
  ## two separately allocated buffers. `inputs` is the TEXT of a `Prover.toml`
  ## (`tracer_wasm/src/lib.rs`: "`inputs` is the text of a `Prover.toml` (or
  ## the equivalent JSON)"), and the worker passes `inputs_are_json = 0`, so
  ## it must be TOML and not a JSON object.
  %*{
    "artifact": (if artifact.isNil: newJNull() else: artifact),
    "inputs": inputs
  }

proc noirCompileArgs*(): seq[string] = @[noirCompileSubcommand]
  ## The `args` of a compile `start`. The worker routes on
  ## `args.find(a => !a.startsWith('-'))`, and `wasm_registry.subcommandOf`
  ## resolves the same way, so the two agree by construction rather than by
  ## both being written out at a call site.

proc noirTraceArgs*(): seq[string] = @[noirTraceSubcommand]

# ---------------------------------------------------------------------------
# The response
# ---------------------------------------------------------------------------

proc noirSeverityOf*(text: string): NoirDiagnosticSeverity =
  ## The four spellings `DiagnosticKind`'s `Debug` impl produces, lowercased.
  ##
  ## Case-insensitive because the transformation on the Rust side is a
  ## `to_lowercase()` that a refactor could drop; matching only the lowered
  ## form would then reclassify every diagnostic as unknown at once.
  case text.toLowerAscii
  of "error": ndsError
  of "warning": ndsWarning
  of "bug": ndsBug
  of "info": ndsInfo
  else: ndsUnknown

proc getStrOr(node: JsonNode; key: string; fallback = ""): string =
  if node.isNil or node.kind != JObject or not node.hasKey(key): return fallback
  if node[key].kind != JString: return fallback
  node[key].getStr

proc getIntOr(node: JsonNode; key: string; fallback = 0): int =
  if node.isNil or node.kind != JObject or not node.hasKey(key): return fallback
  if node[key].kind != JInt: return fallback
  node[key].getInt

proc getStrSeq(node: JsonNode; key: string): seq[string] =
  if node.isNil or node.kind != JObject or not node.hasKey(key): return @[]
  if node[key].kind != JArray: return @[]
  for item in node[key]:
    if item.kind == JString: result.add item.getStr

proc parseNoirDiagnostic*(node: JsonNode): NoirDiagnostic =
  ## One `PositionedDiagnostic`. Every field is probed rather than indexed:
  ## the wire shape omits empty vectors (header fact 1) and a future field
  ## rename must degrade to a row that still names its file and message
  ## rather than raising inside a build.
  let severityText = getStrOr(node, "severity")
  NoirDiagnostic(
    message: getStrOr(node, "message"),
    file: getStrOr(node, "file"),
    line: getIntOr(node, "line"),
    column: getIntOr(node, "column"),
    endLine: getIntOr(node, "end_line"),
    endColumn: getIntOr(node, "end_column"),
    startByte: getIntOr(node, "start"),
    endByte: getIntOr(node, "end"),
    secondaryMessages: getStrSeq(node, "secondary_messages"),
    notes: getStrSeq(node, "notes"),
    severity: noirSeverityOf(severityText),
    severityText: severityText)

proc parseDiagnosticList(node: JsonNode; key: string): seq[NoirDiagnostic] =
  if node.isNil or node.kind != JObject or not node.hasKey(key): return @[]
  if node[key].kind != JArray: return @[]
  for item in node[key]:
    if item.kind == JObject: result.add parseNoirDiagnostic(item)

proc undecodedResponse(raw: string): NoirCompileResponse =
  NoirCompileResponse(ok: false, decoded: false, raw: raw,
                      diagnostics: @[], warnings: @[], artifact: nil)

proc parseNoirCompileResponse*(raw: string): NoirCompileResponse =
  ## Decode a `VfsResponse` out of the worker's stdout.
  ##
  ## `decoded: false` is a THIRD outcome beside ok/refused, and it exists
  ## because the two failures are indistinguishable in every other field: a
  ## compile that produced no diagnostics and a worker that answered with
  ## something that is not a `VfsResponse` both give `ok == false` and an
  ## empty list. The second is a protocol fault and the first is a program the
  ## user can fix, and telling a user the wrong one wastes their afternoon.
  if raw.len == 0:
    return undecodedResponse("")
  var parsed: JsonNode
  try:
    parsed = parseJson(raw)
  except:
    # A BARE `except` for `wasm_worker.deliver`'s reason, which applies
    # unchanged here: on the JS backend `parseJson` defers to V8's
    # `JSON.parse`, which throws a raw `SyntaxError` that `except
    # CatchableError` does NOT catch. The narrow form handled malformed input
    # correctly on C and crashed the tab on JS — the backend this ships on.
    return undecodedResponse(raw)
  if parsed.isNil or parsed.kind != JObject or not parsed.hasKey("ok"):
    return undecodedResponse(raw)

  var artifact: JsonNode = nil
  if parsed.hasKey("artifact") and parsed["artifact"].kind != JNull:
    artifact = parsed["artifact"]

  NoirCompileResponse(
    ok: parsed["ok"].kind == JBool and parsed["ok"].getBool,
    stage: getStrOr(parsed, "stage"),
    kind: getStrOr(parsed, "kind"),
    message: getStrOr(parsed, "message"),
    manifest: getStrOr(parsed, "manifest"),
    line: getIntOr(parsed, "line"),
    column: getIntOr(parsed, "column"),
    diagnostics: parseDiagnosticList(parsed, "diagnostics"),
    warnings: parseDiagnosticList(parsed, "warnings"),
    artifact: artifact,
    decoded: true,
    raw: "")

proc hasRefusalPosition*(response: NoirCompileResponse): bool =
  ## Whether a refusal named a place in a manifest.
  ##
  ## Header fact 3: `VfsResponse::refused` is the only producer of these
  ## fields, and it fills them from `VfsError::position()`, which is `None`
  ## for a refusal with nowhere to point (a missing manifest has a file but no
  ## line). So a caller must check rather than assume, or it paints row
  ## `0:0` — a jump target that navigates a user to nothing.
  response.manifest.len > 0

proc refusalIsPositioned*(response: NoirCompileResponse): bool =
  ## Whether that place is a LINE, not merely a file. `missing-manifest`
  ## answers a manifest and no line; `git-dependency-refused` answers both.
  hasRefusalPosition(response) and response.line > 0

proc diagnosticCount*(response: NoirCompileResponse): int =
  response.diagnostics.len + response.warnings.len

proc countBySeverity*(diagnostics: seq[NoirDiagnostic];
                      severity: NoirDiagnosticSeverity): int =
  ## Counted, because "there are diagnostics" is satisfied by any diagnostics.
  ## A caller asserting on this is asserting a number, which is what makes a
  ## mutation that changes ONE row's severity visible.
  for diagnostic in diagnostics:
    if diagnostic.severity == severity: inc result

# ---------------------------------------------------------------------------
# The trace
# ---------------------------------------------------------------------------

proc summariseNoirTrace*(raw: string): NoirTraceSummary =
  ## Count what a trace contains, without holding a second copy of it.
  ##
  ## The tracer answers a `MemoryTrace` document — `{events, paths,
  ## line_lengths, source_views, capabilities, workdir}` — and its `events`
  ## array is externally tagged: a step is `{"Step": {...}}`, a call is
  ## `{"Call": {...}}`. That is the same discrimination `compare.mjs` makes
  ## (`e => 'Step' in e`), and it is made here for the same reason: a trace
  ## with events but no steps is the failure mode both wasm modules can report
  ## `ok` over.
  ##
  ## `bytes` is recorded even when decoding fails, so a trace too large or too
  ## malformed to parse is still reported as a SIZE rather than as nothing.
  result.bytes = raw.len
  result.paths = @[]
  if raw.len == 0: return
  var parsed: JsonNode
  try:
    parsed = parseJson(raw)
  except:
    return
  if parsed.isNil or parsed.kind != JObject: return
  result.decoded = true
  if parsed.hasKey("events") and parsed["events"].kind == JArray:
    for event in parsed["events"]:
      inc result.events
      if event.kind != JObject: continue
      if event.hasKey("Step"): inc result.steps
      elif event.hasKey("Call"): inc result.calls
  if parsed.hasKey("paths") and parsed["paths"].kind == JArray:
    for path in parsed["paths"]:
      if path.kind == JString: result.paths.add path.getStr

proc isTrivialTrace*(summary: NoirTraceSummary): bool =
  ## `compare.mjs`'s ONE-EVENT-ZERO-STEPS check, as a value the product can
  ## read rather than a check only CI makes.
  ##
  ## Reported to the user rather than hidden: an artifact compiled without
  ## instrumentation traces to one event and no steps, both modules answer
  ## `ok`, and a pane that said "traced" over it would be the chain of
  ## agreements this campaign keeps finding. The Run path asks for
  ## `nbmDebug` precisely so this cannot happen — so if it happens anyway,
  ## something changed and the pane must say so.
  not summary.decoded or summary.events <= 1 or summary.steps == 0

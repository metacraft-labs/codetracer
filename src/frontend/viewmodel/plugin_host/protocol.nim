## plugin_host/protocol.nim — the plugin protocol's wire format
## (Extensibility-Model.md §11.4). ONE module owns it: the framing, the
## message types in both directions, the handshake, the version rule, the epoch
## stamp, the `ViewNode` codec and the limits the host enforces. Both halves
## import it — the host's supervisor (`supervisor.nim`) and the plugin SDK a
## native plugin links (`src/plugin_sdk/codetracer_plugin_sdk.nim`) — so the
## two cannot drift, and `test_plugin_protocol_schema.nim` pins it.
##
## Pure: no I/O, no reactive graph, no process. It compiles on both backends.
##
## ## FRAMING
##
## A frame is a 4-byte BIG-ENDIAN unsigned length, then that many bytes of
## UTF-8 JSON. §11.4.1 asks for the length-prefixed reader §8.1's codec
## helpers already provide; `plugin_io.encodeFrame(frLengthPrefixed)` is
## big-endian, so this is too (the spec's "little-endian" was a slip, and pm
## records the correction). The cap is 4 MiB per frame, not `plugin_io`'s
## 64 MiB: a plugin talking to CodeTracer has no business sending one message
## that large, and a large view tree goes as patches.
##
## ## WHY THE READER KEEPS AN OFFSET
##
## `plugin_io.takeFrame` slices the buffer on every frame, which copies the
## tail each time. A plugin that floods sends thousands of small frames per
## read, and a quadratic decoder is how a flood becomes a host stall before
## the rate limit has a chance to count it. `FrameReader` consumes from an
## offset and compacts once per `feed`.

import std/[json, strutils, tables]

import ../../../common/view_vocabulary/vocabulary as view_vocabulary

export view_vocabulary.ViewNode

const
  ProtocolMajor* = 1
  ProtocolMinor* = 0
  SupportedMajors* = 1 .. 1
    ## The majors this host speaks. A process outside it fails to load, and
    ## the message names the plugin, its version and this range (§11.4.3).

  MaxProtocolFrameBytes* = 4 * 1024 * 1024
    ## §11.4.7. A frame larger than this is a protocol violation.

  # ---- §11.4.7 limits, per plugin -------------------------------------------
  MaxMessagesPerSecond* = 500
  MaxMessageBurst* = 2000
  FloodStrikeAfterMs* = 5_000
    ## A sustained breach — messages dropped for this long — is a strike.
  MaxViewNodes* = 20_000
  MaxDecorationsPerDocument* = 10_000
  MaxLayersPerPlugin* = 4
  MaxContextKeysPerPlugin* = 64

  # ---- §11.4.2, §11.6.2 timers ----------------------------------------------
  HelloDeadlineMs* = 5_000
  PingIdleIntervalMs* = 10_000
  PingBusyIntervalMs* = 2_000
  PongDeadlineMs* = 2_000
  BusyHangMs* = 5_000

  # ---- §11.7.4 input deadlines ----------------------------------------------
  AckBudgetMs* = 50
  InputDeadlineMs* = 500

  # ---- §11.8 shutdown --------------------------------------------------------
  ShutdownGraceMs* = 2_000
  TermGraceMs* = 1_000

  # ---- §11.4.1 the channel's descriptors -------------------------------------
  ChannelEnv* = "CODETRACER_PLUGIN_CHANNEL"
    ## Set by the host for every plugin process it starts, to
    ## `fds:<in>,<out>,<ping-in>,<pong-out>`. The protocol does not use the
    ## process's standard streams: stdin is `/dev/null`, and stdout and stderr
    ## both go to the plugin's log, so a stray `echo` in a plugin (or a child
    ## it starts with inherited stdio) is a log line, never a broken frame.
  ProtocolInFd* = 3
    ## Host to process: every message but `ping`.
  ProtocolOutFd* = 4
    ## Process to host: every message but `pong`.
  LivenessInFd* = 5
    ## Host to process: `ping` only, read by the SDK's watchdog thread.
  LivenessOutFd* = 6
    ## Process to host: `pong` only, written by the watchdog thread alone, so
    ## a `pong` never waits behind a frame the main thread is writing.
  ChannelEnvValue* = "fds:" & $ProtocolInFd & "," & $ProtocolOutFd & "," &
    $LivenessInFd & "," & $LivenessOutFd

  HostToProcessTypes* = [
    "hello", "signal-snapshot", "signal-batch", "view-event", "invoke",
    "query", "cancel", "activate", "deactivate", "settings-changed",
    "layer-popped", "ping", "shutdown"]
    ## §11.4.4, host to process. `hello` is the handshake's first message.

  ProcessToHostTypes* = [
    "hello", "activated", "activation-failed", "action", "publish-batch",
    "view", "view-patch", "decorations", "status", "enablement", "context",
    "push-layer", "pop-layer", "ack", "answer", "rows", "done", "error",
    "log", "progress", "pong"]
    ## §11.4.4, process to host, with the handshake's replies.

  UnattributedTypes* = ["hello", "pong"]
    ## The only process messages that name no plugin. Every other one must
    ## (§11.4.4: "Every message from a plugin names its plugin").

  RequiredFields*: array[0 .. 12, (string, seq[string])] = [
    ("activated", @["plugin"]),
    ("activation-failed", @["plugin", "reason"]),
    ("action", @["plugin", "vm", "action"]),
    ("publish-batch", @["plugin", "viewModel", "batch", "epoch"]),
    ("view", @["plugin", "surface", "tree"]),
    ("view-patch", @["plugin", "surface", "patch"]),
    ("status", @["plugin", "item"]),
    ("enablement", @["plugin", "op", "enabled"]),
    ("context", @["plugin", "key"]),
    ("push-layer", @["plugin", "token", "owner", "bindings"]),
    ("pop-layer", @["plugin", "token"]),
    ("ack", @["plugin", "id"]),
    ("decorations", @["plugin", "document", "items"])]
    ## The fields a process message must carry beyond `type`. Replies
    ## (`answer`, `rows`, `done`, `error`) carry `id`, checked where they are
    ## matched to their request.

type
  Epoch* = object
    ## §11.4.5: where the primary session was when a message was computed.
    session*: string
    position*: int64
      ## The replay position (the step the debugger is at).
    revision*: int
      ## The publisher's batch revision.

  FrameReader* = object
    buf: string
    pos: int

  FrameStatus* = enum
    fsFrame
    fsIncomplete
    fsOversize

  HelloCheck* = object
    ok*: bool
    problems*: seq[string]
    pluginIds*: seq[string]
    features*: seq[string]

# ---------------------------------------------------------------------------
# Framing
# ---------------------------------------------------------------------------

func encodeFrame*(payload: string): string =
  ## The wire form of one message; "" when it is larger than the cap.
  let n = payload.len
  if n > MaxProtocolFrameBytes:
    return ""
  result = newStringOfCap(n + 4)
  result.add chr((n shr 24) and 0xff)
  result.add chr((n shr 16) and 0xff)
  result.add chr((n shr 8) and 0xff)
  result.add chr(n and 0xff)
  result.add payload

proc encodeMessage*(msg: JsonNode): string =
  encodeFrame($msg)

proc feed*(r: var FrameReader; data: string) =
  ## Append bytes read from the channel.
  if r.pos > 0 and r.pos >= r.buf.len div 2:
    r.buf = r.buf[r.pos .. ^1]
    r.pos = 0
  r.buf.add data

func buffered*(r: FrameReader): int = r.buf.len - r.pos

proc next*(r: var FrameReader; frame: var string): FrameStatus =
  ## One frame out of the buffer, if it holds one. An oversize length is
  ## reported before a byte of its payload is buffered for it.
  if r.buf.len - r.pos < 4:
    return fsIncomplete
  let p = r.pos
  let n = (ord(r.buf[p]) shl 24) or (ord(r.buf[p+1]) shl 16) or
          (ord(r.buf[p+2]) shl 8) or ord(r.buf[p+3])
  if n > MaxProtocolFrameBytes:
    return fsOversize
  if r.buf.len - p - 4 < n:
    return fsIncomplete
  frame = r.buf[p + 4 ..< p + 4 + n]
  r.pos = p + 4 + n
  fsFrame

# ---------------------------------------------------------------------------
# Epochs
# ---------------------------------------------------------------------------

func toJson*(e: Epoch): JsonNode =
  %*{"session": e.session, "position": e.position, "revision": e.revision}

func epochFrom*(n: JsonNode): Epoch =
  if n.isNil or n.kind != JObject:
    return Epoch(position: -1, revision: -1)
  Epoch(session: n{"session"}.getStr(""),
        position: n{"position"}.getBiggestInt(-1),
        revision: n{"revision"}.getInt(-1))

func samePosition*(a, b: Epoch): bool =
  ## Whether an answer computed at `a` is current at `b` (§11.4.5). The
  ## revision moves with every batch, the position only when the debugger
  ## moves, and an answer is stale exactly when the position moved.
  a.session == b.session and a.position == b.position

# ---------------------------------------------------------------------------
# The handshake (§11.4.2, §11.4.3)
# ---------------------------------------------------------------------------

proc hostHello*(version, frontEnd, platform: string;
                features: seq[string] = @[]): JsonNode =
  %*{"type": "hello",
     "protocol": {"major": ProtocolMajor, "minor": ProtocolMinor},
     "host": {"version": version, "frontEnd": frontEnd, "platform": platform},
     "features": features}

proc processHello*(package: string; plugins: seq[(string, string)];
                   features: seq[string] = @[]): JsonNode =
  ## What a plugin process answers: its package and every plugin it hosts.
  var list = newJArray()
  for (id, version) in plugins:
    list.add %*{"id": id, "version": version}
  %*{"type": "hello",
     "protocol": {"major": ProtocolMajor, "minMinor": 0,
                  "maxMinor": ProtocolMinor},
     "package": package, "plugins": list, "features": features}

proc checkProcessHello*(msg: JsonNode; package: string;
                        manifestPlugins: seq[string]): HelloCheck =
  ## §11.4.2: the process's plugin list must equal the manifest's. Every
  ## problem names the plugin it is about.
  result.ok = true
  if msg.isNil or msg.kind != JObject or msg{"type"}.getStr("") != "hello":
    result.ok = false
    result.problems.add "package '" & package &
      "': the first message was not a hello"
    return
  let major = msg{"protocol"}{"major"}.getInt(-1)
  if major notin SupportedMajors:
    result.ok = false
    for id in manifestPlugins:
      result.problems.add "plugin '" & id & "' speaks plugin protocol " &
        $major & ".x; this CodeTracer speaks " & $SupportedMajors.a & ".." &
        $SupportedMajors.b & ".x"
    return
  let pkg = msg{"package"}.getStr("")
  if pkg != package:
    result.ok = false
    result.problems.add "package '" & package & "': the process says it is '" &
      pkg & "'"
  let plugins = msg{"plugins"}
  if not plugins.isNil and plugins.kind == JArray:
    for p in plugins:
      let id = p{"id"}.getStr("")
      if id.len > 0:
        result.pluginIds.add id
  for id in manifestPlugins:
    if id notin result.pluginIds:
      result.ok = false
      result.problems.add "plugin '" & id &
        "' is in the package manifest but the process does not register it"
  for id in result.pluginIds:
    if id notin manifestPlugins:
      result.ok = false
      result.problems.add "plugin '" & id &
        "' is registered by the process but has no manifest entry"
  let feats = msg{"features"}
  if not feats.isNil and feats.kind == JArray:
    for f in feats:
      result.features.add f.getStr("")

# ---------------------------------------------------------------------------
# Message validation (§11.6.1's "protocol violation")
# ---------------------------------------------------------------------------

proc violation*(msg: JsonNode; registered: seq[string]): string =
  ## Why `msg` is a protocol violation; "" when it is not. Checks the type is
  ## known, that a message naming a plugin names one this process registered,
  ## and that the type's required fields are present. Whether the plugin is
  ## ACTIVE is the supervisor's question, not the wire's.
  if msg.isNil or msg.kind != JObject:
    return "a frame that is not a JSON object"
  let t = msg{"type"}.getStr("")
  if t notin ProcessToHostTypes:
    return "unknown message type '" & t & "'"
  if t in UnattributedTypes:
    return ""
  let plugin = msg{"plugin"}.getStr("")
  if plugin.len == 0:
    return "a '" & t & "' message that names no plugin"
  if plugin notin registered:
    return "a '" & t & "' message for plugin '" & plugin &
      "', which this process did not register"
  for (name, fields) in RequiredFields:
    if name == t:
      for f in fields:
        if not msg.hasKey(f):
          return "a '" & t & "' message without '" & f & "'"
  if t in ["answer", "rows", "done"] and not msg.hasKey("id"):
    return "a '" & t & "' reply without 'id'"
  ""

# ---------------------------------------------------------------------------
# The ViewNode codec
# ---------------------------------------------------------------------------

const KindNames = block:
  var t: seq[(string, ViewKind)]
  for k in ViewKind:
    t.add (vocabularyName(k), k)
  t

func kindByName(name: string; dest: var ViewKind): bool =
  for (n, k) in KindNames:
    if n == name:
      dest = k
      return true
  false

proc toJson*(n: ViewNode): JsonNode =
  ## A view tree as JSON. Fields at their zero value are left out, so a tree
  ## of 20,000 `Text` nodes stays small on the wire.
  if n.isNil:
    return newJNull()
  result = %*{"kind": vocabularyName(n.kind), "id": n.id}
  if n.label.len > 0: result["label"] = %n.label
  if n.text.len > 0: result["text"] = %n.text
  if n.disabled: result["disabled"] = %true
  if n.checked: result["checked"] = %true
  if n.options.len > 0:
    var opts = newJArray()
    for o in n.options:
      var oj = %*{"id": o.id, "label": o.label}
      if o.disabled: oj["disabled"] = %true
      opts.add oj
    result["options"] = opts
  if n.selected != -1: result["selected"] = %n.selected
  if n.highlight != -1: result["highlight"] = %n.highlight
  if n.open: result["open"] = %true
  if n.expanded: result["expanded"] = %true
  if n.cursor != 0: result["cursor"] = %n.cursor
  if n.column != 0: result["column"] = %n.column
  if n.columns.len > 0: result["columns"] = %n.columns
  if n.rows.len > 0: result["rows"] = %n.rows
  if n.children.len > 0:
    var kids = newJArray()
    for c in n.children:
      kids.add c.toJson
    result["children"] = kids
  if n.progress != 0: result["progress"] = %n.progress
  if n.mediaType.len > 0: result["mediaType"] = %n.mediaType
  if n.mediaBytes != 0: result["mediaBytes"] = %n.mediaBytes
  if n.alt.len > 0: result["alt"] = %n.alt
  var acts = newJArray()
  for a in n.activation:
    acts.add %(if a == acKeyboard: "keyboard" else: "pointer")
  if acts.len > 0: result["activation"] = acts
  if n.nativeMedium.len > 0: result["nativeMedium"] = %n.nativeMedium
  if n.nativeView.len > 0: result["nativeView"] = %n.nativeView

type
  TreeDecode* = object
    tree*: ViewNode
    nodes*: int
    error*: string

proc decodeNode(j: JsonNode; budget: int; count: var int;
                error: var string): ViewNode =
  if error.len > 0:
    return nil
  inc count
  if count > budget:
    error = "the tree has more than " & $budget & " nodes"
    return nil
  if j.isNil or j.kind != JObject:
    error = "a view node that is not an object"
    return nil
  var k: ViewKind
  let kname = j{"kind"}.getStr("")
  if not kindByName(kname, k):
    error = "a view node of unknown kind '" & kname & "'"
    return nil
  let n = ViewNode(kind: k, id: j{"id"}.getStr(""),
                   label: j{"label"}.getStr(""), text: j{"text"}.getStr(""),
                   disabled: j{"disabled"}.getBool(false),
                   checked: j{"checked"}.getBool(false),
                   selected: j{"selected"}.getInt(-1),
                   highlight: j{"highlight"}.getInt(-1),
                   open: j{"open"}.getBool(false),
                   expanded: j{"expanded"}.getBool(false),
                   cursor: j{"cursor"}.getInt(0),
                   column: j{"column"}.getInt(0),
                   progress: j{"progress"}.getInt(0),
                   mediaType: j{"mediaType"}.getStr(""),
                   mediaBytes: j{"mediaBytes"}.getInt(0),
                   alt: j{"alt"}.getStr(""),
                   nativeMedium: j{"nativeMedium"}.getStr(""),
                   nativeView: j{"nativeView"}.getStr(""))
  if n.nativeMedium.len > 0 or n.nativeView.len > 0:
    # §11.11, answered 2026-11-20: third-party plugins draw no native views.
    error = "node '" & n.id & "' is a native view; a plugin composes the " &
      "shared vocabulary, images and sandboxed frames only"
    return nil
  let opts = j{"options"}
  if not opts.isNil and opts.kind == JArray:
    for o in opts:
      n.options.add ViewOption(id: o{"id"}.getStr(""),
                               label: o{"label"}.getStr(""),
                               disabled: o{"disabled"}.getBool(false))
  let cols = j{"columns"}
  if not cols.isNil and cols.kind == JArray:
    for c in cols: n.columns.add c.getStr("")
  let rows = j{"rows"}
  if not rows.isNil and rows.kind == JArray:
    for r in rows:
      var row: seq[string]
      if r.kind == JArray:
        for c in r: row.add c.getStr("")
      n.rows.add row
  let acts = j{"activation"}
  if not acts.isNil and acts.kind == JArray:
    for a in acts:
      case a.getStr("")
      of "keyboard": n.activation.incl acKeyboard
      of "pointer": n.activation.incl acPointer
      else: discard
  let kids = j{"children"}
  if not kids.isNil and kids.kind == JArray:
    for c in kids:
      let child = decodeNode(c, budget, count, error)
      if error.len > 0:
        return nil
      n.children.add child
  n

proc decodeViewTree*(j: JsonNode; budget = MaxViewNodes): TreeDecode =
  ## A pushed tree, refused (with the reason) when it is malformed, larger
  ## than `budget` nodes, or carries a native view.
  var count = 0
  var error = ""
  let tree = decodeNode(j, budget, count, error)
  if error.len > 0:
    return TreeDecode(error: error, nodes: count)
  TreeDecode(tree: tree, nodes: count)

proc findById(n: ViewNode; id: string): ViewNode =
  if n.isNil: return nil
  if n.id == id: return n
  for c in n.children:
    let f = findById(c, id)
    if not f.isNil: return f
  nil

proc countNodes*(n: ViewNode): int =
  if n.isNil: return 0
  result = 1
  for c in n.children:
    result += countNodes(c)

proc applyViewPatch*(tree: ViewNode; patch: JsonNode;
                     budget = MaxViewNodes): TreeDecode =
  ## A `view-patch`: `[{"id": <node id>, "node": <replacement>}, …]`, each
  ## replacing the node with that `ViewNode.id` (and its subtree) in place.
  ## The patched tree is held to the same node budget as a whole tree.
  if tree.isNil:
    return TreeDecode(error: "a patch for a surface that has no tree")
  if patch.isNil or patch.kind != JArray:
    return TreeDecode(error: "a patch that is not an array")
  for entry in patch:
    let id = entry{"id"}.getStr("")
    let target = findById(tree, id)
    if target.isNil:
      return TreeDecode(error: "a patch for node '" & id &
                        "', which the tree does not have")
    let dec = decodeViewTree(entry{"node"}, budget)
    if dec.error.len > 0:
      return dec
    target[] = dec.tree[]
  let total = countNodes(tree)
  if total > budget:
    return TreeDecode(error: "the patched tree has " & $total &
                      " nodes, more than " & $budget, nodes: total)
  TreeDecode(tree: tree, nodes: total)

# ---------------------------------------------------------------------------
# Key binding rows (§11.7.2) and layers (§11.7.3)
# ---------------------------------------------------------------------------

type
  PluginBinding* = object
    key*: string
      ## The key in the user-layer grammar: `ctrl+k`, `g`, `escape`.
    op*: string
      ## An operation the plugin contributes.
    scope*: string
      ## `window`, or a qualified surface id.
    whenClause*: string
      ## A conjunction of context keys (`a && !b`); "" always holds.

proc bindingsFrom*(j: JsonNode): seq[PluginBinding] =
  if j.isNil or j.kind != JArray:
    return
  for b in j:
    result.add PluginBinding(key: b{"key"}.getStr("").toLowerAscii,
                             op: b{"op"}.getStr(b{"command"}.getStr("")),
                             scope: b{"scope"}.getStr("window"),
                             whenClause: b{"when"}.getStr(""))

proc toJson*(b: PluginBinding): JsonNode =
  %*{"key": b.key, "op": b.op, "scope": b.scope, "when": b.whenClause}

proc evalWhen*(clause: string; context: Table[string, bool]): bool =
  ## A `when` clause: `&&`-joined terms, each a context key or `!key`. An
  ## unknown key is false. "" holds.
  let c = clause.strip
  if c.len == 0:
    return true
  for raw in c.split("&&"):
    var term = raw.strip
    var negate = false
    while term.startsWith("!"):
      negate = not negate
      term = term[1 .. ^1].strip
    let v = context.getOrDefault(term, false)
    if v == negate:
      return false
  true

## acme_tools_plugins.nim — the test PACKAGE of Extensibility-Model.md §11:
## one native executable hosting two plugins, `acme-tools.metrics` and
## `acme-tools.flame`, written against `codetracer_plugin_sdk` exactly as a
## third party would write them.
##
## It is a real plugin, not a stand-in: the suites install it as a component,
## CodeTracer starts it as a process, and everything it does crosses the pipe.
##
## `metrics` is the well-behaved one. Its pane shows the debugger's current
## line from its MIRRORED session, stamped with the epoch it was computed at;
## its command steps the primary forward through the action relay; it pushes a
## status item, enablement and a context key, and answers `values` queries
## for a visualiser. It also DECORATES the current line of the source the
## debugger is in (`decorations`, a marker reading `metrics: line N`),
## re-pushed at every stop, so the decoration follows a step; and it MARKS
## the same line through its declared `hotspot` marker surface (a `★` in the
## gutter's mark column).
##
## `flame`'s list answers `view-event`: activating a row (Enter, or a click)
## re-pushes the list with that row marked `✓` and selected, which is how a
## front-end's round trip through the plugin is seen on screen.
##
## `flame` misbehaves on request. Its `mode` setting picks the fault the
## misbehaving-plugin suite drives:
##
##   normal          behaves
##   segfault        dereferences nil on activation (a real SIGSEGV)
##   hang-invoke     loops forever inside its `flame.refresh` handler
##   hang-activate   loops forever inside activation
##   flood           pushes status items as fast as it can for `floodMs`
##   swallow-input   pushes a window layer binding every printable key, and
##                   never acknowledges the keys it gets
##   slow-ack        acknowledges each key after `ackDelayMs`
##   raise           raises a CatchableError in `flame.refresh`
##   exit            exits with status 3 on `flame.refresh`
##   protocol        writes a frame of garbage on `flame.refresh`

import std/[monotimes, os, posix, strutils, times, volatile]

import codetracer_plugin_sdk

proc currentLine(p: Plugin): string =
  let s = p.session
  if s.isNil or s.store.isNil:
    return "(no session)"
  let d = s.store.debugger.val
  d.location.file.extractFilename & ":" & $d.location.line

proc pushLineDecoration(p: Plugin; lastDoc: var string) =
  ## A marker on the debugger's current line, in the document the mirrored
  ## session names; the document it was on before is cleared.
  let s = p.session
  if s.isNil or s.store.isNil: return
  let d = s.store.debugger.val
  let doc = d.location.file
  if doc.len == 0 or d.location.line <= 0: return
  if lastDoc.len > 0 and lastDoc != doc:
    p.pushDecorations(lastDoc, newJArray())
  lastDoc = doc
  p.pushDecorations(doc, %*[{"line": d.location.line, "glyph": "◆",
                             "text": "metrics: line " & $d.location.line,
                             "kind": "marker"}])

proc pushHotspot(p: Plugin) =
  ## The `hotspot` MARKER surface: a gutter mark on the debugger's current
  ## line, pushed as the marker table a front-end reads (`file`, `line`,
  ## `glyph`, `text`).
  let s = p.session
  if s.isNil or s.store.isNil: return
  let d = s.store.debugger.val
  if d.location.file.len == 0 or d.location.line <= 0: return
  p.pushView("hotspot", viewTable("metrics.hotspot",
    @["file", "line", "glyph", "text"],
    @[@[d.location.file, $d.location.line, "★", "hotspot"]]))

proc metricsView(p: Plugin): ViewNode =
  let e = p.epoch
  viewTreeNode("metrics.root", "Metrics", @[
    viewText("metrics.line", "line " & p.currentLine),
    viewText("metrics.epoch", "position " & $e.position),
    viewText("metrics.settings", "label " & p.settings{"label"}.getStr("metrics"))],
    expanded = true)

proc setupMetrics(sdk: PluginSdk) =
  let m = sdk.addPlugin("acme-tools.metrics", "1.0.0")
  var decorated = ""
  m.onActivate = proc(p: Plugin) =
    p.pushView("overview", metricsView(p))
    p.pushLineDecoration(decorated)
    p.pushHotspot()
    p.pushStatus("metrics.status", viewText("metrics.status", "metrics ok"))
    p.pushEnablement("metrics.step", true)
    p.pushContext("ready", %true)
    # A per-type visualiser for the value panes (PLAT-12's plugin tier): data,
    # not code — the host presents the value with it.
    p.publish("visualisers", %*[
      {"id": "matrix", "typeMatch": "Matrix", "matchKind": "typeName",
       "summary": "matrix (acme-tools)", "rank": 1}])
  m.onSignals = proc(p: Plugin) =
    p.pushView("overview", metricsView(p))
    p.pushLineDecoration(decorated)
    p.pushHotspot()
  m.onSettingsChanged = proc(p: Plugin) =
    p.pushView("overview", metricsView(p))
  m.onInvoke("metrics.step", proc(p: Plugin; args: JsonNode; req: Request) =
    p.relay("debugControls", "stepForward")
    p.done(req))
  m.onInvoke("metrics.echo", proc(p: Plugin; args: JsonNode; req: Request) =
    p.answer(req, %*{"key": args{"key"}, "line": p.currentLine}))
  m.onQuery("values", proc(p: Plugin; input: JsonNode; req: Request) =
    let delay = input{"delayMs"}.getInt(0)
    if delay > 0: os.sleep(delay)
    p.answer(req, %*{"line": p.currentLine, "position": p.epoch.position}))
  m.onQuery("bigview", proc(p: Plugin; input: JsonNode; req: Request) =
    let n = input{"n"}.getInt(0)
    var kids: seq[ViewNode]
    for i in 0 ..< 1000:
      kids.add viewText("big." & $i, "seq " & $n & " row " & $i)
    p.pushView("overview", viewTreeNode("big", "big", kids, expanded = true))
    p.answer(req, %*{"n": n}))
  m.onQuery("visualise", proc(p: Plugin; input: JsonNode; req: Request) =
    # A value visualiser's producer: the value it was given, as a table.
    let v = input{"value"}
    var rows: seq[seq[string]]
    if not v.isNil and v.kind == JArray:
      for i, x in v.getElems:
        rows.add @[$i, $x]
    else:
      rows.add @["value", $v]
    p.answer(req, viewTable("metrics.visual", @["index", "value"], rows).toJson))

proc spin(p: Plugin) =
  var x = 0
  while true:
    x = (x + 1) mod 1000
    if p.isNil: break

const FlameRows = [("a", "main 60%"), ("b", "work 40%")]

proc flameList(activated: int): ViewNode =
  ## The flame list, with the row a front-end activated marked and selected.
  var options: seq[ViewOption]
  for i, (id, label) in FlameRows:
    options.add ViewOption(id: id,
      label: (if i == activated: "✓ " & label & " (activated)" else: label))
  result = viewList("flame.list", options,
                    highlight = (if activated >= 0: activated else: 0))
  result.selected = activated

proc setupFlame(sdk: PluginSdk) =
  let f = sdk.addPlugin("acme-tools.flame", "1.0.0")
  var layerToken = ""
  f.onViewEvent = proc(p: Plugin; surface: string; event: JsonNode) =
    # §11.4.4 `view-event`: the host's `applyKey` activated a row of the
    # list. The answer is a new tree, marking it.
    p.log("view-event " & surface & " " & $event)
    if surface == "flame" and event{"transition"}.getStr("") == "trActivate":
      p.pushView("flame", flameList(event{"index"}.getInt(-1)))
  f.onActivate = proc(p: Plugin) =
    let mode = p.settings{"mode"}.getStr("normal")
    case mode
    of "segfault":
      # A REAL invalid access, and one no optimiser may remove: the address is
      # known only at run time and the store is volatile. A plain
      # `q[] = 1` through a nil `ptr` is undefined behaviour that clang
      # deleted in a release build on aarch64-darwin (measured 2026-11-21: the
      # plugin activated instead of crashing).
      let address = parseInt(getEnv("ACME_TOOLS_FAULT_ADDRESS", "0"))
      volatileStore(cast[ptr int](address), 1)
    of "hang-activate":
      p.spin()
    of "flood":
      # A SUSTAINED breach (§11.4.7): pushes as fast as it can for
      # `floodMs`, not one burst the bucket absorbs.
      let until = getMonoTime() + initDuration(milliseconds =
        p.settings{"floodMs"}.getInt(3_000))
      var i = 0
      while getMonoTime() < until:
        p.pushStatus("flame.flood", viewText("flame.flood", $i))
        inc i
    of "swallow-input", "slow-ack":
      p.autoAck = false
      var bs: seq[PluginBinding]
      for c in "abcdefghijklmnopqrstuvwxyz0123456789":
        bs.add PluginBinding(key: $c, op: "flame.key", scope: "window")
      bs.add PluginBinding(key: "escape", op: "flame.key", scope: "window")
      layerToken = p.pushLayer("window", bs, "flame")
    else:
      discard
    p.pushView("flame", viewList("flame.list",
      @[ViewOption(id: "a", label: "main 60%"),
        ViewOption(id: "b", label: "work 40%")]))
    p.pushEnablement("flame.refresh", true)
  f.onLayerPopped = proc(p: Plugin; token, reason: string) =
    p.log("layer " & token & " popped: " & reason)
  f.onInvoke("flame.key", proc(p: Plugin; args: JsonNode; req: Request) =
    let mode = p.settings{"mode"}.getStr("normal")
    if mode == "slow-ack":
      os.sleep(p.settings{"ackDelayMs"}.getInt(300))
      p.ack(req)
      p.done(req)
    elif mode == "swallow-input":
      discard   # takes the key and never answers
    else:
      p.ack(req)
      p.done(req))
  f.onInvoke("flame.refresh", proc(p: Plugin; args: JsonNode; req: Request) =
    case p.settings{"mode"}.getStr("normal")
    of "hang-invoke":
      p.spin()
    of "raise":
      raise newException(IOError, "flame data is unreadable")
    of "exit":
      quit(3)
    of "protocol":
      discard posix.write(1, "\x00\x00\x00\x05hello".cstring, 9)
    else:
      p.pushView("flame", viewList("flame.list",
        @[ViewOption(id: "a", label: "main 55%"),
          ViewOption(id: "b", label: "work 45%")]))
      p.done(req))

when isMainModule:
  let sdk = newPluginSdk("acme-tools")
  setupMetrics(sdk)
  setupFlame(sdk)
  sdk.run()

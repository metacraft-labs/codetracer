## frame_events_core.nim — a core that draws through IsoNim's frame renderer
## and listens for every event the shipped panes listen for, built twice
## (`nim js` and wasm32) by `ci/test/frame-applier-browser.sh`.
##
## The page (`page.html`) mounts it through `frame_applier.js` and a real
## browser drives it with real input. Each handler reports what it received
## by writing text through the renderer, so every assertion the browser test
## makes is about the DOCUMENT — the round trip host → core → frame → host.
##
## The events are the ones `views/` adds through the renderer: click, input,
## change, blur, focus, submit, paste, wheel and keydown.

import std/strutils

import isonim/web/frame_renderer

let r = FrameRenderer()
var
  log: FrameNode
  lines: seq[string] = @[]
  field, select, form, formField, pre, outer, inner, button: FrameNode
  clicks = 0

proc report(line: string) =
  ## One line per event, newest last, in a `<pre>` the test reads.
  lines.add line
  r.setTextContent(log, lines.join("\n"))

proc el(tag: string; parent: FrameNode; id: string): FrameNode =
  result = r.createElement(tag)
  r.setAttribute(result, "id", id)
  r.appendChild(parent, result)

proc mount() {.exportc: "feMount".} =
  resetFrameRenderer()
  resetFrameHandlers()
  lines.setLen(0)
  clicks = 0
  let root = el("div", NoFrameNode, "fe-root")
  button = el("button", root, "fe-button")
  r.setTextContent(button, "press")
  r.addEventListener(button, "click", proc() =
    inc clicks
    # The same value as the last write on every second press: elided, and
    # the document must still read right.
    r.setAttribute(button, "data-parity", if clicks mod 2 == 0: "even" else: "odd")
    report("click " & $clicks))

  field = el("input", root, "fe-field")
  r.addEventListener(field, "input", proc() =
    report("input " & r.inputValue(field)))
  r.addEventListener(field, "focus", proc() = report("focus"))
  r.addEventListener(field, "blur", proc() =
    report("blur " & r.inputValue(field)))

  select = el("select", root, "fe-select")
  for v in ["one", "two"]:
    let o = r.createElement("option")
    r.setAttribute(o, "value", v)
    r.setTextContent(o, v)
    r.appendChild(select, o)
  r.addEventListener(select, "change", proc() =
    report("change " & r.inputValue(select)))

  form = el("form", root, "fe-form")
  formField = el("input", form, "fe-form-field")
  r.addEventListener(form, "submit", proc(ev: FrameEvent) =
    ev.preventDefault()
    report("submit " & ev.value))

  pre = el("pre", root, "fe-shell")
  r.setAttribute(pre, "tabindex", "0")
  r.setStyle(pre, "height", "40px")
  r.setStyle(pre, "overflow", "auto")
  r.addEventListener(pre, "paste", proc(ev: FrameEvent) =
    ev.preventDefault()
    report("paste " & ev.value))
  r.addEventListener(pre, "wheel", proc(ev: FrameEvent) =
    ev.preventDefault()
    report("wheel " & (if ev.deltaY > 0: "down" elif ev.deltaY < 0: "up" else: "none")))
  r.addEventListener(pre, "keydown", proc(ev: FrameEvent) =
    # A modifier pressed on its own is not a key the shell acts on.
    if ev.key in ["Control", "Shift", "Alt", "Meta"]: return
    var mods = ""
    if fmCtrl in ev.modifiers: mods.add "ctrl+"
    if fmShift in ev.modifiers: mods.add "shift+"
    report("keydown " & mods & ev.key))

  # stopPropagation: the inner handler stops the click before the outer one.
  outer = el("div", root, "fe-outer")
  inner = el("span", outer, "fe-inner")
  r.setTextContent(inner, "inner")
  r.addEventListener(outer, "click", proc() = report("outer"))
  r.addEventListener(inner, "click", proc(ev: FrameEvent) =
    ev.stopPropagation()
    report("inner"))

  log = el("pre", root, "fe-log")

# The entry points the page binds, the same names on both builds.
proc feReadCrossings(): int {.exportc.} = readCrossings
proc feOps(): int {.exportc.} = wireOpCount()
proc feReset() {.exportc.} = wireReset()
proc feManifest() {.exportc.} = writeOpManifest()
proc feFrameBase(): int {.exportc.} = wireBase()
proc feFrameLen(): int {.exportc.} = wireBytes()
proc feDispatch(id: int; eventType, value, key: cstring; deltaY: float;
                modifiers: int): int {.exportc.} =
  dispatchFrameEvent(id, $eventType, $value, $key, deltaY, modifiers)

when defined(js):
  {.emit: """
globalThis.feCore = {
  mount: feMount, readCrossings: feReadCrossings, ops: feOps, reset: feReset,
  manifest: feManifest, dispatch: feDispatch,
  frameBytes: function() { return globalThis.isonimFrameBytes(); },
};
""".}

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime()
      {.importc: "emscripten_exit_with_live_runtime", header: "<emscripten.h>".}

when isMainModule:
  when defined(emscripten):
    # The host calls in after `main`; returning would let ORC destroy this
    # module's globals first.
    emscriptenExitWithLiveRuntime()

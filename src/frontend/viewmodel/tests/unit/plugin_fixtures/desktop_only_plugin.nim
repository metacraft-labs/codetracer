## desktop_only_plugin.nim — PLAT-9's §6.3 fixture: a plugin that is excellent
## on the desktop and has to be honest about the terminal.
##
## It contributes two panes, and the pair is the point:
##
##   * `flamegraph` is `required` and supplies a NATIVE view for the web
##     front-end only. §6.2's second arm — "written against a specific
##     renderer, for a surface the vocabulary cannot express — a custom
##     visualisation, a canvas, a graph". There is no abstract baseline,
##     because a flame graph is not expressible in sixteen widgets.
##   * `summary` is `optional` and is written in the shared vocabulary, so it
##     runs everywhere. §6.2's first arm.
##
## Under `--ui=electron` both surfaces exist. Under `--ui=tui` the required one
## has no view, so §6.3 makes the whole plugin fail to activate, naming the
## front-end and the surface. That is the behaviour the milestone's first
## integration test drives, and this fixture exists so the test drives a real
## manifest through the real parser and the real resolver rather than a
## hand-built `PluginManifest`.
##
## ## IT WOULD DO SOMETHING IF IT LOADED
##
## `activator` contributes both views and increments `activations`. The test
## asserts that counter stayed at ZERO under the terminal — §6.3's "What must
## not happen is an extension that appears to load and then silently does
## nothing" is only checkable against a plugin that WOULD have done something.

import codetracer_plugin

const ManifestJson* = """
{
  "id": "acme.flame",
  "displayName": "Flame graphs",
  "version": "1.0.0",
  "requires": { "core": ">=1.0.0 <2.0.0" },
  "activation": [
    { "event": "trace-opened" }
  ],
  "contributes": {
    "pane": [
      { "id": "flamegraph",
        "title": "Flame graph",
        "requirement": "required",
        "nativeViews": ["electron"] },
      { "id": "summary",
        "title": "Summary",
        "requirement": "optional",
        "views": ["Table", "Text"] }
    ]
  }
}
"""

const PortableManifestJson* = """
{
  "id": "acme.flame-portable",
  "displayName": "Flame graphs, portably",
  "version": "1.0.0",
  "requires": { "core": ">=1.0.0 <2.0.0" },
  "activation": [
    { "event": "trace-opened" }
  ],
  "contributes": {
    "pane": [
      { "id": "flamegraph",
        "title": "Flame graph",
        "requirement": "required",
        "views": ["Table", "Text"],
        "nativeViews": ["electron"] }
    ]
  }
}
"""
  ## THE CONTROL FOR THE REFUSAL, and it differs from `ManifestJson` in one
  ## line: the same required surface, with an abstract baseline beside the
  ## native view. §6.2 calls that "the honest arrangement — it lets an
  ## extension be excellent on the desktop without being absent in the
  ## terminal", and it is what makes the refusal above a statement about the
  ## MISSING VIEW rather than about required surfaces in general.

type
  DesktopOnlyPlugin* = ref object
    activations*: int
      ## How many times `activate` was entered. The assertion for "it does not
      ## load and silently do nothing" is that this is zero on the terminal
      ## and non-zero on the desktop — one counter, two front-ends.
    viewRenders*: int

proc newDesktopOnlyPlugin*(): DesktopOnlyPlugin = DesktopOnlyPlugin()

proc activator*(p: DesktopOnlyPlugin): proc(ctx: PluginContext) =
  result = proc(ctx: PluginContext) =
    inc p.activations
    ctx.contributeView("flamegraph", proc(): ViewNode =
      inc p.viewRenders
      # A native view names its medium rather than pretending to be portable.
      # `portability.checkPortable` REFUSES a tree containing one, which is
      # how the vocabulary tells "runs everywhere" and "runs here" apart.
      nativeEscape("acme.flame.canvas", "web", "flamegraph-canvas"))
    if ctx.manifest.declaresSurface("summary"):
      ctx.contributeView("summary", proc(): ViewNode =
        inc p.viewRenders
        viewTable("acme.flame.summary", @["frame", "self"],
                  @[@["main", "12ms"], @["parse", "80ms"]]))

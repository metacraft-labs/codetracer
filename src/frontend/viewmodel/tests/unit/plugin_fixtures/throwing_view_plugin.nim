## throwing_view_plugin.nim — PLAT-9's §7 fixture: a view that throws on every
## frame, and a well-behaved sibling in the same plugin.
##
## §7: "A failing extension must not take down the debugger … a fault renders a
## reported failure in that surface, not a blank screen or a crash"; "A fault
## is attributed"; "Repeated faults disable the extension for the session, with
## a report. A view that throws on every frame is worse than one that is
## absent."
##
## Two surfaces again, and for the same reason as `tool_surface_plugin`'s two:
## a fixture with one surface cannot distinguish "the fault was contained to
## that surface" from "everything stopped".
##
## ## IT THROWS EVERY TIME, NOT ONCE
##
## The one-shot case is the easy one and it is not what §7 is about: a boundary
## that catches once and then hands the same broken view back to the next frame
## is a boundary that fires forever. `explodeCalls` counts how many times the
## body was entered, so the suite can assert that the host STOPPED calling it
## after the limit rather than merely stopped propagating.

import codetracer_plugin

const ExplosionMessage* = "the view could not build its tree"

const ManifestJson* = """
{
  "id": "acme.unstable",
  "displayName": "Unstable views",
  "version": "1.0.0",
  "requires": { "core": ">=1.0.0 <2.0.0" },
  "activation": [
    { "event": "trace-opened" }
  ],
  "contributes": {
    "pane": [
      { "id": "explodes",
        "title": "Explodes",
        "requirement": "optional",
        "views": ["Text"] },
      { "id": "steady",
        "title": "Steady",
        "requirement": "optional",
        "views": ["Text"] }
    ]
  }
}
"""

const SteadyText* = "this surface has never faulted"

type
  ThrowingViewError* = object of CatchableError
    ## Its own type, so the fault report can be asserted on the NAME rather
    ## than on the message text — the same reason `PluginErrorCode` is separate
    ## from `detail`.

  ThrowingViewPlugin* = ref object
    explodeCalls*: int
    steadyCalls*: int
    activations*: int

  NilViewPlugin* = ref object
    ## The other way a view produces a blank region: it returns `nil` instead
    ## of raising. §6.1's rule is about the REGION being blank, not about how
    ## it got that way, so the host treats this as a fault too and this fixture
    ## is what proves it does.
    calls*: int

const NilViewManifestJson* = """
{
  "id": "acme.nilview",
  "displayName": "A view that returns nothing",
  "version": "1.0.0",
  "requires": { "core": ">=1.0.0 <2.0.0" },
  "activation": [
    { "event": "trace-opened" }
  ],
  "contributes": {
    "pane": [
      { "id": "empty", "title": "Empty", "views": ["Text"] }
    ]
  }
}
"""

proc newThrowingViewPlugin*(): ThrowingViewPlugin = ThrowingViewPlugin()
proc newNilViewPlugin*(): NilViewPlugin = NilViewPlugin()

proc activator*(p: ThrowingViewPlugin): proc(ctx: PluginContext) =
  result = proc(ctx: PluginContext) =
    inc p.activations
    ctx.contributeView("explodes", proc(): ViewNode =
      inc p.explodeCalls
      raise newException(ThrowingViewError, ExplosionMessage))
    ctx.contributeView("steady", proc(): ViewNode =
      inc p.steadyCalls
      viewText("acme.unstable.steady", SteadyText))

proc activator*(p: NilViewPlugin): proc(ctx: PluginContext) =
  result = proc(ctx: PluginContext) =
    ctx.contributeView("empty", proc(): ViewNode =
      inc p.calls
      nil)

# ---------------------------------------------------------------------------
# A view that raises a `Defect` — the fault class the boundary used to miss
# ---------------------------------------------------------------------------
#
# `ThrowingViewError` above is a `CatchableError`, and a plugin author who
# writes one has already thought about failing. The ordinary way plugin code
# fails at runtime is an out-of-range read, which raises `IndexDefect` — NOT a
# `CatchableError`, so until 2026-09-11 it went straight past
# `renderSurface`'s `except` and out of the application. This fixture is that
# case, written the way it actually occurs: no `raise` statement anywhere, just
# an index that is not in the sequence.
#
# TWO SURFACES AGAIN, and here the second one carries more weight than it does
# in the fixtures above: a `Defect` disables THE SURFACE and not the plugin, so
# `steady` rendering afterwards is what distinguishes that policy from the
# `CatchableError` path's plugin-wide disable.

const DefectSteadyText* = "this surface never read past the end of anything"

type
  DefectViewPlugin* = ref object
    calls*: int
      ## How many times the out-of-range view was ENTERED. The whole claim of
      ## "not re-armed" is that this stops at one.
    steadyCalls*: int
    activations*: int

const DefectViewManifestJson* = """
{
  "id": "acme.defect",
  "displayName": "A view that reads past the end",
  "version": "1.0.0",
  "requires": { "core": ">=1.0.0 <2.0.0" },
  "activation": [
    { "event": "trace-opened" }
  ],
  "contributes": {
    "pane": [
      { "id": "outofrange",
        "title": "Out of range",
        "requirement": "optional",
        "views": ["Text"] },
      { "id": "steady",
        "title": "Steady",
        "requirement": "optional",
        "views": ["Text"] }
    ]
  }
}
"""

proc newDefectViewPlugin*(): DefectViewPlugin = DefectViewPlugin()

proc activator*(p: DefectViewPlugin): proc(ctx: PluginContext) =
  result = proc(ctx: PluginContext) =
    inc p.activations
    ctx.contributeView("outofrange", proc(): ViewNode =
      inc p.calls
      # THE INDEX IS COMPUTED, not a literal. A constant subscript on an empty
      # literal is a compile-time error in Nim, which would make this fixture a
      # build failure rather than a runtime `Defect` — and a fixture that
      # cannot be built is not a fixture.
      var rows: seq[string] = @[]
      let wanted = p.calls + 1
      viewText("acme.defect.outofrange", rows[wanted]))
    ctx.contributeView("steady", proc(): ViewNode =
      inc p.steadyCalls
      viewText("acme.defect.steady", DefectSteadyText))

const RaisingActivateManifestJson* = """
{
  "id": "acme.badboot",
  "displayName": "A plugin that throws during activate",
  "version": "1.0.0",
  "requires": { "core": ">=1.0.0 <2.0.0" },
  "activation": [
    { "event": "trace-opened" }
  ],
  "contributes": {
    "pane": [
      { "id": "never", "title": "Never", "views": ["Text"] }
    ]
  }
}
"""

proc raisingActivator*(): proc(ctx: PluginContext) =
  ## §7's containment applied to the plugin's FIRST line rather than to its
  ## views. A plugin that throws before it contributes anything has no surface
  ## for a boundary to sit in, so the host is the only thing that can contain
  ## it.
  result = proc(ctx: PluginContext) =
    raise newException(ThrowingViewError, "activate() could not start")

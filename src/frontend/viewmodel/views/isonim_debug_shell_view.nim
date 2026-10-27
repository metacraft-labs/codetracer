## IsoNim view for the global debug shell.
##
## The shell is the small chrome host that keeps the command palette mount point
## available near the top menu. The actual debug controls toolbar is mounted
## separately into ``#isonim-debug-controls`` by ``ui/debug_toolbar.nim``.

import isonim/dsl/ui
import isonim/core/[signals, computation]
import isonim/dsl/components
import isonim/testing/mock_dom

# The generic proc expands the DSL at its caller.
export signals, computation, components

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

const
  DebugShellId* = "debug"
  DebugShellClass* = "ct-header"
  DebugCommandPaletteHostClass* = "component-container"
  DebugCommandPaletteHostPrefix* = "commandPaletteComponent-"

proc commandPaletteHostId*(componentId: int): string =
  DebugCommandPaletteHostPrefix & $componentId

proc renderDebugChromePanel*[R, N](
    r: R;
    commandPaletteComponentId: int): N =
  ## The debug shell: the header host that keeps the command palette's mount
  ## point near the top menu. One proc for every renderer.
  ui(r):
    tdiv(id = DebugShellId, class = DebugShellClass):
      if commandPaletteComponentId >= 0:
        tdiv(
            id = commandPaletteHostId(commandPaletteComponentId),
            class = DebugCommandPaletteHostClass):
          discard

when defined(js):
  proc renderDebugChromeInto*(
      r: WebRenderer;
      container: isonim_dom.Element;
      commandPaletteComponentId: int) =
    let containerNode = isonim_dom.Node(container)
    while not isonim_dom.isNodeNil(containerNode.firstChild):
      discard isonim_dom.removeChild(containerNode, containerNode.firstChild)

    isonim_dom.setAttribute(
      container,
      cstring"class",
      cstring DebugShellClass)

    let shell = renderDebugChromePanel[WebRenderer, isonim_dom.Element](
      r, commandPaletteComponentId)
    let shellNode = isonim_dom.Node(shell)
    while not isonim_dom.isNodeNil(shellNode.firstChild):
      discard isonim_dom.appendChild(containerNode, shellNode.firstChild)

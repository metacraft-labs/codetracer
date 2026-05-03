## IsoNim view for the global debug shell.
##
## The shell is the small chrome host that keeps the command palette mount point
## available near the top menu. The actual debug controls toolbar is mounted
## separately into ``#isonim-debug-controls`` by ``ui/debug.nim``.

import isonim/dsl/ui
from isonim/core/computation import createRenderEffect
import isonim/testing/mock_dom

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

proc renderDebugChromePanel*(
    r: MockRenderer;
    commandPaletteComponentId: int): MockNode =
  ui(r):
    tdiv(id = DebugShellId, class = DebugShellClass):
      if commandPaletteComponentId >= 0:
        tdiv(
            id = commandPaletteHostId(commandPaletteComponentId),
            class = DebugCommandPaletteHostClass):
          discard

when defined(js):
  proc renderDebugChromePanel*(
      r: WebRenderer;
      commandPaletteComponentId: int): isonim_dom.Element =
    ui(r):
      tdiv(id = DebugShellId, class = DebugShellClass):
        if commandPaletteComponentId >= 0:
          tdiv(
              id = commandPaletteHostId(commandPaletteComponentId),
              class = DebugCommandPaletteHostClass):
            discard

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

    let shell = renderDebugChromePanel(r, commandPaletteComponentId)
    let shellNode = isonim_dom.Node(shell)
    while not isonim_dom.isNodeNil(shellNode.firstChild):
      discard isonim_dom.appendChild(containerNode, shellNode.firstChild)

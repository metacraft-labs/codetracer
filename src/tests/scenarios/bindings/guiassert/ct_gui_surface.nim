## ct_gui_surface.nim — what the GPUI binding reads off saved frames: the tree
## of role instances `readSurface` derives from each PNG named on the command
## line (a scenario run's stills, `steps/<n>-<kind>.png`), printed one
## instance a line. For working on the binding without starting the window.
##
##   ct-gui-surface <frame.png>...     (CT_GUI_BINDING_DEBUG=1 for its traces)
##   ct-gui-surface --zgui <frame.png>...   the zgui window's binding's reading

import std/[json, os, strutils]
import demo_video_script_guiassert
import ./ct_gui_binding
import ./ct_zgui_binding as zgui

proc dump(t: Tree; n: SurfaceNode; depth: int) =
  var props = ""
  for k, v in n.props:
    if not k.startsWith("$"): props.add " " & k & "=" & $v
  echo repeat("  ", depth), n.role, " @", int(n.x), ",", int(n.y), " ", int(n.w), "x", int(n.h), props
  for c in t.kids(n): dump(t, c, depth + 1)

let ctx = newOfflineContext(getTempDir() / ("ct-gui-surface-" & $getCurrentProcessId()))
var zguiFrames = false
for png in commandLineParams():
  if png == "--zgui":
    zguiFrames = true
    continue
  echo "== ", png
  let t = if zguiFrames: zgui.readSurface(ctx, frameOf(png))
          else: ct_gui_binding.readSurface(ctx, frameOf(png))
  dump(t, t.root, 0)
removeDir(ctx.workDir)

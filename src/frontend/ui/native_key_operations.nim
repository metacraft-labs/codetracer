## The desktop leaves base operations belonging to native controls to those
## controls. User rows deliberately dispatch through the application instead.
## Pure so the resolver tests exercise the same decision as the DOM router.

import ../viewmodel/keymap/[editing_keymap, scope_path, operation_catalogue]
import std/strutils

func isNativeBaseOperation*(res: EditingResolution): bool =
  if res.kind != erOperation or res.layer.startsWith("user"):
    return false
  let separator = res.layer.find(':')
  let table = if separator >= 0: res.layer[separator + 1 .. ^1] else: ""
  table in [InputTable, PaletteTable, ContextMenuTable, FindTable]

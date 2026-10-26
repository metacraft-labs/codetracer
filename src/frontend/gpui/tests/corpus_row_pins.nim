## Shared corpus-pin reader, exercised independently of the live replay engine.
import std/json

proc admissibleRows*(pin: JsonNode; key: string; darwin = defined(macosx)): seq[string] =
  ## The set of `editor-row-count` answers this arm is pinned to, as a `seq`.
  ##
  ## ALWAYS AN ARRAY IN THE FILE, even for the four scenarios whose answer is a
  ## single value. A schema where one entry is a string and another is a list is
  ## a schema in which the reader decides, and the reader would then be the
  ## second place the rule lives. Trap 13: a `proc`, returning a value, calling
  ## `check` nowhere.
  result = @[]
  # A platform is a choice of pin, never an extra admissible answer. Only
  # GPUI has this override; Electron's captured answers retain their own keys.
  let selected =
    if darwin and key == "gpuiEditorRows" and pin.hasKey(key & "Darwin"):
      key & "Darwin"
    else: key
  if not pin.hasKey(selected): return
  if pin[selected].kind != JArray: return
  for v in pin[selected]:
    if v.kind != JString: return @[]
    result.add v.getStr

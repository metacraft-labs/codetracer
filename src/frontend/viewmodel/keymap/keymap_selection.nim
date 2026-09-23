## keymap_selection.nim — PLAT-43: CHOOSING A KEYMAP MODEL BY NAME.
##
## PLAT-31 built three keymap models (`editing_keymap.KeymapModel`) and PLAT-34
## made `EditingDocument` take one as a parameter, but no key the shipped
## binaries accept chose between them. This module is the one place a NAME
## becomes a model, and every front-end asks it:
##
##   * the terminal's `:keymap <name>` command (`tui/app/commands/interpreter`),
##   * the stored preference both native hosts read at start-up
##     (`viewmodel/host/keymap_preference`).
##
## ONE FUNCTION, SO THE SET CANNOT DRIFT (Verification-Harness-Traps §30b). The
## accepted names are DERIVED from the enum, never listed: a fourth model is
## selectable the moment it compiles, and a name that is not a member is
## refused BY NAME, with the accepted set — PLAT-1's refusal shape
## (`ct/ui_selection.unknownValueMessage`). Nothing here falls back silently to
## the default: a selector that does is one a user cannot tell from a broken
## one.
##
## PURE. No I/O, no `getEnv`; it runs on the C, JS and wasm backends like the
## rest of `viewmodel/keymap/`.

import std/strutils

import ./editing_keymap

export editing_keymap.KeymapModel

type
  KeymapSelection* = object
    ## The answer to "which model does this name mean".
    ok*: bool
    model*: KeymapModel
      ## Meaningful only when `ok`. Left at `kmProductDefault` otherwise, and
      ## a caller that ignored `ok` would therefore select the default — which
      ## is why `refusal` is non-empty exactly when `ok` is false and every
      ## caller in the tree reads it.
    refusal*: string

const
  KeymapSourceCommand* = ":keymap"
    ## How the terminal's command names itself in a refusal.
  KeymapSourceStored* = "stored keymap"
    ## How a refusal names the preference file's contents.

func selectableKeymapNames*(): seq[string] =
  ## Every `KeymapModel` member's name, in declaration order. DERIVED from the
  ## enum, so the partition law (every member selectable, every selectable
  ## name a member) holds by construction and a test asserts it anyway.
  for m in KeymapModel:
    result.add $m

func acceptedKeymapNamesText*(): string =
  selectableKeymapNames().join(", ")

func unknownKeymapMessage*(value, sourceText: string): string =
  ## The refusal, in one line, naming the value and the accepted set.
  "unknown " & sourceText & " value '" & value &
    "'; the accepted values are " & acceptedKeymapNamesText()

func selectKeymap*(name: string; sourceText = KeymapSourceCommand): KeymapSelection =
  ## The ONE mapping from a name to a model.
  ##
  ## Case-sensitive and not trimmed, like `ui_selection.parseUiFrontEnd`: a
  ## selector that normalises what was typed behaves differently from what
  ## was typed. (The stored preference strips its own trailing newline before
  ## it gets here — that is the file's framing, not the user's spelling.)
  for m in KeymapModel:
    if name == $m:
      return KeymapSelection(ok: true, model: m, refusal: "")
  KeymapSelection(ok: false, model: kmProductDefault,
                  refusal: unknownKeymapMessage(name, sourceText))

func encodeKeymapPreference*(model: KeymapModel): string =
  ## The preference file's whole content: the model's name and a newline.
  $model & "\n"

func decodeKeymapPreference*(text: string): KeymapSelection =
  ## A stored preference, through the same `selectKeymap`. Only the file's
  ## framing — surrounding whitespace and the final newline — is removed.
  selectKeymap(text.strip(), KeymapSourceStored)

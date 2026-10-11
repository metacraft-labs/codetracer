## keymap_selection.nim — PLAT-43: CHOOSING A BASE KEYMAP BY NAME.
##
## PLAT-31 built three keymap models (now PLAT-68's four base keymaps,
## `editing_keymap.BaseKeymap`) and PLAT-34
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

export editing_keymap.BaseKeymap

type
  KeymapSelection* = object
    ## The answer to "which model does this name mean".
    ok*: bool
    model*: BaseKeymap
      ## Meaningful only when `ok`. Left at `bkCua` otherwise, and
      ## a caller that ignored `ok` would therefore select the default — which
      ## is why `refusal` is non-empty exactly when `ok` is false and every
      ## caller in the tree reads it.
    refusal*: string
    migrated*: bool
      ## PLAT-68: the stored name was `default` — what PLAT-43 wrote for a
      ## user who chose the product default — read as `cua`. The host says so
      ## once and rewrites the file (Base-Keymaps-And-Layer-Stack.md §3.6).

const
  KeymapSourceCommand = ":keymap"
    ## How the terminal's command names itself in a refusal.
  KeymapSourceStored* = "stored keymap"
    ## How a refusal names the preference file's contents.
  RetiredDefaultName* = "default"
    ## The product default's stored name before PLAT-68. **The only alias**:
    ## the stored-preference decoder reads it as `cua`; the typed command
    ## refuses it by name like any other non-member, so the set stays derived
    ## from the enum everywhere else.
  RetiredDefaultNotice* = "keymap 'default' is now 'cua'"

func selectableKeymapNames*(): seq[string] =
  ## Every `BaseKeymap` member's name, in declaration order. DERIVED from the
  ## enum, so the partition law (every member selectable, every selectable
  ## name a member) holds by construction and a test asserts it anyway.
  for m in BaseKeymap:
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
  for m in BaseKeymap:
    if name == $m:
      return KeymapSelection(ok: true, model: m, refusal: "", migrated: false)
  KeymapSelection(ok: false, model: bkCua,
                  refusal: unknownKeymapMessage(name, sourceText),
                  migrated: false)

func encodeKeymapPreference*(model: BaseKeymap): string =
  ## The preference file's whole content: the model's name and a newline.
  $model & "\n"

func decodeKeymapPreference*(text: string): KeymapSelection =
  ## A stored preference, through the same `selectKeymap`. Only the file's
  ## framing — surrounding whitespace and the final newline — is removed. The
  ## retired `default` is read as `cua`, `migrated` (see `RetiredDefaultName`).
  let name = text.strip()
  if name == RetiredDefaultName:
    return KeymapSelection(ok: true, model: bkCua, refusal: "", migrated: true)
  selectKeymap(name, KeymapSourceStored)

# ---------------------------------------------------------------------------
# The palette's command (Base-Keymaps-And-Layer-Stack.md §3.6)
# ---------------------------------------------------------------------------

const
  SelectBaseKeymapLabel* = "Preferences: Select Base Keymap"
    ## VS Code's own label for its keymap picker, so the palette finds it by
    ## the words a VS Code user types.
  BaseKeymapCommandPrefix* = "baseKeymap:"
    ## The target of a palette entry that selects a base: `baseKeymap:<name>`.

func baseKeymapCommandTarget*(model: BaseKeymap): string =
  BaseKeymapCommandPrefix & $model

func parseBaseKeymapCommand*(target: string): tuple[ok: bool; model: BaseKeymap] =
  ## `baseKeymap:<name>` → the base, through `selectKeymap`.
  if not target.startsWith(BaseKeymapCommandPrefix):
    return (false, bkCua)
  let selection = selectKeymap(target[BaseKeymapCommandPrefix.len .. ^1])
  (selection.ok, selection.model)

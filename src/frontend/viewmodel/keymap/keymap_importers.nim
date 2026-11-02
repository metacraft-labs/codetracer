## keymap_importers.nim — THE OLD CONFIGURATION SURFACES, translated ONCE into
## `keybindings.json` rows.
##
## Owns: Base-Keymaps-And-Layer-Stack.md §3.5's importers — the terminal's
## `.cttui-keys` (`MODE chord… = action`), the desktop's YAML `bindings:`
## block (the rows a user EDITED, against the shipped defaults), and the
## desktop's stepping preset stored in `localStorage` — each a pure function
## from the old text to user rows and a PLAT-36-style report: *N of M lines
## translated; the first gap and why*.
##
## Refuses to own: WHEN an import runs and where the files are (the hosts:
## `host/keybindings_file` reads, imports once, writes; the desktop's preset
## import runs in its renderer), and what a row means (`user_keymap`).
##
## The old files are left untouched and are not read again (§3.5).
##
## Pure; compiles on C, JS and wasm32.

import std/[json, strutils, tables]

import ./base_rows
import ./client_actions
import ./editing_keymap
import ./navigation_keymap

type
  ImportGap* = object
    line*: int
      ## 1-based line in the old file; 0 for a preset.
    text*: string
    reason*: string

  ConfigImport* = object
    source*: string
      ## What was read: `.cttui-keys`, `.config.yaml`, `stepping preset`.
    rows*: seq[JsonNode]
      ## `keybindings.json` rows.
    translated*: int
    total*: int
    gaps*: seq[ImportGap]

const
  # `.cttui-keys` action ids (the terminal's retired `KeyAction` names) →
  # operations. Complete over the action ids the format accepted.
  CttuiActions* = {
    "focus-next-pane": "layout.focus-next-pane",
    "focus-prev-pane": "layout.focus-previous-pane",
    "focus-left": "layout.focus-left", "focus-down": "layout.focus-down",
    "focus-up": "layout.focus-up", "focus-right": "layout.focus-right",
    "select-call-stack": "layout.focus-pane(call-trace)",
    "select-source": "layout.focus-pane(editor)",
    "select-variables": "layout.focus-pane(variables)",
    "select-event-log": "layout.focus-pane(event-log)",
    "maximize-pane": "layout.maximize-pane",
    "step-over": "debugger.step-over",
    "reverse-step-over": "debugger.reverse-step-over",
    "step-into": "debugger.step-into",
    "reverse-step-into": "debugger.reverse-step-into",
    "step-out": "debugger.step-out",
    "reverse-step-out": "debugger.reverse-step-out",
    "continue": "debugger.continue",
    "reverse-continue": "debugger.reverse-continue",
    "prev-call": "debugger.previous-call", "next-call": "debugger.next-call",
    "prev-mutation": "debugger.previous-mutation",
    "next-mutation": "debugger.next-mutation",
    "jump-to-start": "debugger.jump-to-start",
    "jump-to-end": "debugger.jump-to-end",
    "seek-to-tick": "debugger.seek-to-tick",
    "value-origin": "editor.jump-to-value-origin",
    "reverse-origin": "debugger.reverse-origin",
    "scroll-line-down": "editor.scroll-line-down",
    "scroll-line-up": "editor.scroll-line-up",
    "half-page-up": "editor.scroll-half-page-up",
    "half-page-down": "editor.scroll-half-page-down",
    "center-on-pointer": "editor.center-on-pointer",
    "toggle-breakpoint": "editor.toggle-breakpoint",
    "expand-node": "list.expand", "collapse-node": "list.collapse",
    "toggle-hex-dec": "variables.toggle-hex-dec",
    "view-memory-dump": "variables.view-memory-dump",
    "command-palette": "palette.open-commands",
    "search-forward": "find.open", "search-backward": "find.open-backward",
    "next-match": "find.next", "prev-match": "find.previous",
    "open-command-prompt": "command-line.open",
    "return-to-normal": "modal.return-to-normal", "quit": "app.quit",
    "enter-inspect": "inspect.open", "commit-prompt": "input.commit",
    "prompt-backspace": "input.delete-backward",
    "toggle-product-mode": "session.toggle-product-mode",
    "next-session-tab": "session-tabs.next",
    "previous-session-tab": "session-tabs.previous"}.toTable

  StepPresets* = ["codetracer", "vscode", "chorded", "none"]
    ## The desktop dialog's preset ids (`ui/shortcut_presets.ShortcutPresetId`
    ## wire spellings). `codetracer` is CUA's own rows: importing it writes
    ## nothing.

func row(key, command: string; whenText = ""): JsonNode =
  result = %*{"key": key, "command": command}
  if whenText.len > 0: result["when"] = %whenText

proc gap(imp: var ConfigImport; line: int; text, reason: string) =
  imp.gaps.add ImportGap(line: line, text: text, reason: reason)

# ---------------------------------------------------------------------------
# `.cttui-keys`
# ---------------------------------------------------------------------------

proc importCttuiKeys*(text: string): ConfigImport =
  ## Each `NORMAL chord… = action` line becomes a row over every base (a
  ## user who wrote it wanted the chord whatever they now choose); `= -`
  ## becomes the removal of every row bound to that chord in NORMAL (§4.2's
  ## table is the modal bases' navigation table, so the removal is
  ## `base`-restricted to them). A line in COMMAND, SEARCH or INSPECT is a
  ## gap: no context key names the terminal's modal state, and the CUA and
  ## Emacs bases have none.
  result = ConfigImport(source: ".cttui-keys")
  var lineNo = 0
  for raw in text.splitLines():
    inc lineNo
    var line = raw
    let hash = line.find('#')
    if hash >= 0: line = line[0 ..< hash]
    line = line.strip()
    if line.len == 0: continue
    inc result.total
    let eq = line.find('=')
    if eq < 0:
      result.gap(lineNo, raw, "no '=' on the line")
      continue
    let fields = line[0 ..< eq].strip().splitWhitespace()
    let action = line[eq + 1 .. ^1].strip()
    if fields.len < 2:
      result.gap(lineNo, raw, "a mode and at least one chord come before '='")
      continue
    if fields[0].toUpperAscii != "NORMAL":
      result.gap(lineNo, raw, "a " & fields[0].toUpperAscii & "-mode " &
                 "binding: no context key names the terminal's modal state")
      continue
    # `.cttui-keys` chords are canonical NAMES (`G`, `Ctrl+w`, `r f`);
    # `keybindings.json` keys are written notation.
    let key = writtenSequence(fields[1 .. ^1].join(" "))
    if normalizeChordSequence(key).len == 0:
      result.gap(lineNo, raw, "'" & fields[1 .. ^1].join(" ") &
                 "' names no key")
      continue
    if action == "-":
      # The removal names the command §4.2's NORMAL row binds to the chord;
      # that table is the modal bases' alone, so the removal is theirs.
      var removed = false
      for r in NavigationRows:
        if nmNormal in r.navModes and
           normalizeChordSequence(r.chords) == normalizeChordSequence(key):
          let (removedOp, removedArg) = splitOperation(r.operation)
          for base in ["vim", "kakoune"]:
            var removal = %*{"key": key, "command": "-" & removedOp,
                             "base": base}
            if removedArg.len > 0: removal["args"] = %removedArg
            result.rows.add removal
          removed = true
      if removed: inc result.translated
      else: result.gap(lineNo, raw, "'" & key & "' is bound to nothing " &
                       "in NORMAL, so there is nothing to remove")
      continue
    if not CttuiActions.hasKey(action):
      result.gap(lineNo, raw, "'" & action & "' is not an action")
      continue
    let (name, arg) = splitOperation(CttuiActions[action])
    var r = row(key, name)
    if arg.len > 0: r["args"] = %arg
    result.rows.add r
    inc result.translated

# ---------------------------------------------------------------------------
# The desktop's YAML `bindings:` block
# ---------------------------------------------------------------------------

func bindingsBlock(yamlText: string): OrderedTable[string, string] =
  ## `action: "CHORD CHORD"` lines of the top-level `bindings:` block —
  ## the block's own shape (`window_top_bar.desktopBindings` reads it the
  ## same way).
  result = initOrderedTable[string, string]()
  var inBindings = false
  for raw in yamlText.splitLines():
    if raw.len == 0: continue
    if not raw[0].isSpaceAscii and raw[0] != '#':
      inBindings = raw.startsWith("bindings:")
      continue
    if not inBindings: continue
    let line = raw.strip()
    if line.startsWith("#"): continue
    let colon = line.find(':')
    if colon <= 0: continue
    var value = line[colon + 1 .. ^1].strip()
    if value.len >= 2 and value[0] == '"' and value[^1] == '"':
      value = value[1 .. ^2]
    result[line[0 ..< colon].strip()] = value

proc importYamlBindings*(userYaml, defaultYaml: string): ConfigImport =
  ## Every action whose chords the user CHANGED from the shipped default:
  ## its default chords removed, the user's bound. An action left as shipped
  ## is not a row — the base already has it.
  result = ConfigImport(source: ".config.yaml")
  let user = bindingsBlock(userYaml)
  let shipped = bindingsBlock(defaultYaml)
  for action, chords in user:
    if shipped.getOrDefault(action) == chords: continue
    inc result.total
    let full = operationOfClientAction(action)
    if full.len == 0:
      result.gap(0, action & ": " & chords, "'" & action & "' has no " &
                 "operation a base binds")
      continue
    let (op, arg) = splitOperation(full)
    proc bound(key, command: string): JsonNode =
      result = row(key, command)
      if arg.len > 0: result["args"] = %arg
    for old in shipped.getOrDefault(action).splitWhitespace():
      result.rows.add bound(old, "-" & op)
    var ok = true
    for c in chords.splitWhitespace():
      if normalizeChord(c).len == 0:
        ok = false
        result.gap(0, action & ": " & chords, "'" & c & "' names no key")
        break
      result.rows.add bound(c, op)
    if ok: inc result.translated

# ---------------------------------------------------------------------------
# The desktop's stepping preset
# ---------------------------------------------------------------------------

proc importStepPreset*(presetId: string): ConfigImport =
  ## The preset the desktop's dialog stored → the matching `include`
  ## (§3.4). `codetracer`, CUA's own, is nothing to write.
  result = ConfigImport(source: "stepping preset", total: 1)
  if presetId notin StepPresets:
    result.gap(0, presetId, "'" & presetId & "' is not a stepping preset")
    return
  inc result.translated
  if presetId != "codetracer":
    result.rows.add %*{"include": "stepping:" & presetId}

func summary*(imp: ConfigImport): string =
  result = imp.source & ": " & $imp.translated & " of " & $imp.total &
           " translated into keybindings.json"
  if imp.gaps.len > 0:
    let g = imp.gaps[0]
    result.add "; first gap" &
      (if g.line > 0: " at line " & $g.line else: "") & ": " & g.reason

proc keybindingsText*(imports: openArray[ConfigImport]): string =
  ## A `keybindings.json` with the imported rows, each source introduced by
  ## a comment carrying its summary (JSONC, as VS Code's file is).
  var parts: seq[string] = @[]
  for imp in imports:
    var section = "  // imported from " & imp.summary
    for r in imp.rows:
      section.add "\n  " & $r & ","
    parts.add section
  "// CodeTracer key bindings — one file for every front-end.\n" &
    "[\n" & parts.join("\n") & "\n]\n"

proc withImported*(text: string; imp: ConfigImport): string =
  ## `text` — a `keybindings.json` that already exists — with `imp`'s rows
  ## added after the user's own, introduced by its summary comment: the
  ## desktop's stepping preset arriving after the file was first written (it
  ## lives in the renderer's `localStorage`, which the main process that
  ## writes the file cannot read). Rows go before the array's closing `]`;
  ## a file that is no array (empty, or not yet written) becomes one.
  var section = "  // imported from " & imp.summary
  for r in imp.rows:
    section.add "\n  " & $r & ","
  let close = text.rfind(']')
  if close < 0 or text.find('[') < 0:
    return keybindingsText([imp])
  var lines = text[0 ..< close].strip(leading = false).splitLines()
  # The last row (not a comment line) gets the comma that separates it from
  # ours, unless it carries one.
  for i in countdown(lines.high, 0):
    let t = lines[i].strip()
    if t.len == 0 or t.startsWith("//"): continue
    if t.endsWith("}"): lines[i].add ","
    break
  lines.join("\n") & "\n" & section & "\n" & text[close .. ^1]

proc withSteppingPreset*(text, presetId: string): string =
  ## `text` with its stepping preset made `presetId`'s: any `stepping:`
  ## include the file holds (and the comment the import put above it) is
  ## taken out, and the chosen one's include goes in — the desktop's
  ## shortcuts dialog choosing a preset, which IS choosing an include set
  ## (§3.4). `codetracer` is CUA's own stepping, so it leaves no row.
  var kept: seq[string] = @[]
  for line in text.splitLines():
    let t = line.strip()
    if t.contains("\"stepping:") and t.contains("\"include\""): continue
    if t.startsWith("// imported from stepping preset"): continue
    kept.add line
  let rest = kept.join("\n")
  let imp = importStepPreset(presetId)
  if imp.rows.len == 0:
    return rest
  withImported(rest, imp)

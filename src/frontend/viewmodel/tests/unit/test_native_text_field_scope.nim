## test_native_text_field_scope.nim — a native text field is an INPUT
## element of the scope path, so the keys typed into it are its own.
##
## Base-Keymaps-And-Layer-Stack.md §4.2 defines `textInputFocus` as "the
## focused element accepts text: a writable editor, a prompt, a find field,
## the palette", and §6.2 has the desktop read its scope path off
## `document.activeElement` and its ancestors. The desktop's producer used to
## read ONLY the elements that carry `data-scope-kind` / `data-scope-id`, so
## a `<textarea>` without them — the Agent Activity prompt — was the pane
## itself. Agent Activity is a list pane, so the focus was `listFocus`, `Enter`
## resolved to `list.activate`, the desktop ran it, and the router stopped the
## event before the textarea's own handler could submit the prompt
## (codetracer-pm issue 2026-10-21, "Pressing Enter in the Agent Activity
## prompt box does not submit the prompt").
##
## What this file holds the shared half to:
##   * `isNativeTextField` / `withNativeTextField`: which focused DOM element
##     is a text field (text-entry `<input>` types, `<textarea>`,
##     contenteditable), and that one already carrying its own scope
##     attribute, or sitting inside an editor element (Monaco's own hidden
##     textarea), is left exactly as the attributes say;
##   * the shipped CUA router: with the field on the path, `Enter` is the
##     field's (`textInputFocus`, not `listFocus`), and `Shift+Enter` and the
##     letters are too. The path WITHOUT the field still resolves `Enter` to
##     `list.activate` — the positive control showing the table above really
##     discriminates the defect.
##
## The DOM half (reading those facts off `document.activeElement`) is
## `ui/key_router.desktopScopePath`, graded end to end by
## `src/tests/gui/tests/agent-activity/enter_submits_prompt.spec.ts`.
##
## ## No mocks
## The shipped CUA base and the shipped router, driven with canonical key
## names; scope paths and focused-element facts are written as the data they
## are.

import std/unittest

import ../../keymap/keymap_router
import ../../keymap/scope_path
import ../../keymap/context_keys
import ../../keymap/editing_keymap

const
  Desktop = KeyDelivery(frontEnd: feDesktop, platform: pkLinux,
                        keyProtocol: kpNative)

let
  Window = element(ekWindow, "window")
  AgentPane = pane("agentActivity")
  # What the desktop produced for the focused prompt before the fix: the
  # textarea carried no scope attribute, so the pane was the focus.
  OldPromptPath = @[Window, AgentPane]
  PromptPath = @[Window, AgentPane, element(ekInput, AgentPromptInput)]
  EditorChain = @[Window, pane("editor"), element(ekEditor, "editor")]

proc debugFacts(): SessionFacts =
  ## What `key_router.desktopFacts` reports in a loaded Debug-mode replay.
  SessionFacts(product: pmDebug, replayLoaded: true,
               editor: sourceViewFacts())

proc field(tag: string; inputType = ""; contentEditable = false; id = "";
           carriesScope = false): FocusedFieldFacts =
  FocusedFieldFacts(tagName: tag, inputType: inputType,
                    contentEditable: contentEditable, id: id,
                    carriesScope: carriesScope)

proc op(res: EditingResolution): string =
  case res.kind
  of erOperation:
    if res.argument.len > 0: res.operation & "(" & res.argument & ")"
    else: res.operation
  of erCharacter: "char:" & res.character
  of erPending: "pending"
  of erNothing: "nothing"

proc leftToElement(res: EditingResolution): bool =
  ## Whether the desktop leaves this resolution to the focused DOM element:
  ## unresolved, a character, or a base row of the input table (the first
  ## rule of `key_router.runDesktopOperation`, whose `NativeTables` holds
  ## `InputTable`).
  res.kind in {erNothing, erCharacter} or
    (res.kind == erOperation and res.layer == "base:" & InputTable)

suite "which focused element is a native text field":
  test "a textarea and the text-entry input types are; other controls are not":
    check isNativeTextField(field("TEXTAREA"))
    check isNativeTextField(field("textarea"))
    for t in ["", "text", "search", "email", "url", "tel", "password",
              "number", "TEXT"]:
      checkpoint("type=" & t)
      check isNativeTextField(field("INPUT", t))
    for t in ["checkbox", "radio", "button", "submit", "reset", "range",
              "color", "file", "image", "hidden"]:
      checkpoint("type=" & t)
      check not isNativeTextField(field("INPUT", t))
    check not isNativeTextField(field("BUTTON"))
    check not isNativeTextField(field("DIV"))
    check not isNativeTextField(field("BODY"))

  test "a contenteditable element is, whatever its tag":
    check isNativeTextField(field("DIV", contentEditable = true))
    check isNativeTextField(field("SPAN", contentEditable = true))

suite "the scope path a focused native text field produces":
  test "an unstamped field becomes the path's input element":
    let path = withNativeTextField(OldPromptPath,
                                   field("TEXTAREA", id = "agent-query-text-7"))
    check path.len == 3
    check path.focused.kind == ekInput
    check path.focused.id == "agent-query-text-7"
    check path[0 .. 1] == OldPromptPath

  test "a field with no DOM id gets the stable fallback identity":
    let path = withNativeTextField(OldPromptPath, field("INPUT"))
    check path.focused.kind == ekInput
    check path.focused.id == NativeTextFieldInput

  test "a field that carries its own scope attribute keeps its own element":
    # Find in Files' query field and the stamped Agent Activity prompt: the
    # attribute chain already ends in their input element.
    check withNativeTextField(PromptPath,
      field("TEXTAREA", carriesScope = true)) == PromptPath
    let fif = @[Window, pane("search"), element(ekInput, SearchQueryInput)]
    check withNativeTextField(fif, field("INPUT", "text",
                                         carriesScope = true)) == fif

  test "inside an editor element nothing is added (Monaco's own textarea)":
    check withNativeTextField(EditorChain,
      field("TEXTAREA", id = "inputarea")) == EditorChain
    # Monaco's find widget's field sits inside the editor element too.
    let find = EditorChain & @[element(ekOverlay, "find")]
    check withNativeTextField(find, field("TEXTAREA")) == find

  test "a chain that already ends in an input element is not doubled":
    let wrapped = @[Window, pane("state"), element(ekInput, "filter")]
    check withNativeTextField(wrapped, field("INPUT", "text")) == wrapped

  test "anything that is not a text field leaves the path alone":
    check withNativeTextField(OldPromptPath, field("BUTTON")) == OldPromptPath
    check withNativeTextField(OldPromptPath,
      field("INPUT", "checkbox")) == OldPromptPath
    check withNativeTextField(@[Window], field("BODY")) == @[Window]

suite "the CUA router in a text field inside a list pane":
  test "positive control: the pane alone takes Enter as list.activate":
    var r = initKeymapRouter(bkCua, Desktop)
    let keys = r.contextFor(debugFacts(), OldPromptPath)
    check keys.values[ckListFocus] == "true"
    check keys.values[ckTextInputFocus] == "false"
    check r.route(debugFacts(), OldPromptPath, nmNormal, "Enter", 1_000).op ==
      "list.activate"

  test "with the prompt on the path, Enter is the field's, not the list's":
    var r = initKeymapRouter(bkCua, Desktop)
    let keys = r.contextFor(debugFacts(), PromptPath)
    check keys.values[ckListFocus] == "false"
    check keys.values[ckTreeFocus] == "false"
    check keys.values[ckTextInputFocus] == "true"
    check keys.values[ckElementKind] == "input"
    check keys.values[ckPaneKind] == "agentActivity"
    check coherent(keys)
    let enter = r.route(debugFacts(), PromptPath, nmNormal, "Enter", 1_000)
    checkpoint(enter.op & " @ " & enter.layer)
    check enter.op != "list.activate"
    check enter.leftToElement

  test "the producer's own output resolves Enter for the field":
    # The same claim through `withNativeTextField`, so the router sees the
    # path the desktop now builds for an unstamped textarea.
    var r = initKeymapRouter(bkCua, Desktop)
    let path = withNativeTextField(OldPromptPath, field("TEXTAREA"))
    let enter = r.route(debugFacts(), path, nmNormal, "Enter", 1_000)
    checkpoint(enter.op & " @ " & enter.layer)
    check enter.leftToElement

  test "Shift+Enter, the letters and the caret keys are the field's too":
    # Shift+Enter is the prompt's newline (the view's handler ignores it);
    # `n` is a character, not Debug mode's step-over; Up / Home / Ctrl+C are
    # the field's caret and clipboard, not the list's.
    var r = initKeymapRouter(bkCua, Desktop)
    for key in ["Shift+Enter", "n", "p", "Up", "Down", "Home", "End",
                "PageUp", "Ctrl+c"]:
      let res = r.route(debugFacts(), PromptPath, nmNormal, key, 1_000)
      checkpoint(key & " -> " & res.op & " @ " & res.layer)
      check res.leftToElement
    # Control: `n` in the list pane itself still steps.
    check r.route(debugFacts(), OldPromptPath, nmNormal, "n", 1_000).op ==
      "debugger.step-over"

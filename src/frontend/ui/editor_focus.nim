## ui/editor_focus.nim — moving the editor's caret to a line WITHOUT taking the
## keyboard from a text field the user is typing in.
##
## ## THE DEFECT
##
## `utils.focusLine` revealed the line, set the caret and called Monaco's
## `focus()` unconditionally. It runs on its own schedule: the replay's first
## stop opens its file in a new editor tab, and the tab's open polls on a
## 10 ms timer until Monaco exists before calling it (`utils.openNewEditorView`).
## A user typing into the State pane's watch box while that timer fired lost
## the rest of their keystrokes to the read-only editor, and their `Enter`
## then submitted the prefix: watches named `ast` and `aste` for
## `asteroid_masses_positive[1]`, measured under `ct host`
## (codetracer-pm issues/2026-10-22-a-watch-typed-in-the-browser-never-
## produces-a-row.md).
##
## ## THE RULE
##
## A programmatic editor focus never takes the focus from a TEXT FIELD outside
## the editor: an `<input>` that takes text, a `<textarea>`, contenteditable
## content, or a writable Monaco instance other than this one — the same
## definition the key router uses for §4.2's `textInputFocus`
## (`scope_path.isNativeTextField`), so "the user is typing here" means one
## thing for keys and for focus. The line is still revealed and the caret
## still placed: only the keyboard stays where the user put it. A focus
## already inside the editor (its own text area, its find widget) or on
## something that takes no text (a button, a list, the page) is moved as
## before.
##
## Browser-target module (it reads `document.activeElement`); tested in a real
## page by `src/frontend/tests/editor_focus_chromium_test.nim`.

import std/jsffi

import ../viewmodel/keymap/scope_path

proc activeElementOrNil(): JsObject {.importjs: "(document.activeElement)".}

proc nodeContains(node, other: JsObject): bool {.importjs:
  "(!!#.contains(#))".}

proc inWritableMonacoOtherThan(a, own: JsObject): bool {.importjs: """
  ((a, own) => {
    const m = globalThis.monaco;
    if (!a || !m || !m.editor || typeof m.editor.getEditors !== 'function')
      return false;
    const ro = m.editor.EditorOption ? m.editor.EditorOption.readOnly
                                     : undefined;
    return m.editor.getEditors().some(e => {
      const node = e.getDomNode();
      return !!node && node !== own && node.contains(a) &&
             !(ro !== undefined && e.getOption(ro));
    });
  })(#, #)""".}
  ## Whether `a` is inside a WRITABLE Monaco instance other than the one whose
  ## DOM node is `own` (a tracepoint editor's IME textarea is `readonly` and
  ## its EditContext input is not contenteditable, so the DOM alone does not
  ## call it a field; `ui/key_router.focusInWritableMonaco` asks the same way).

proc fieldFactsOf(a: JsObject; own: JsObject): FocusedFieldFacts =
  proc str(v: JsObject): string =
    if v.isNil or v.isUndefined: "" else: $v.to(cstring)
  proc flag(v: JsObject): bool =
    not v.isNil and not v.isUndefined and v.to(bool)
  FocusedFieldFacts(
    tagName: str(a[cstring"tagName"]),
    inputType: str(a[cstring"type"]),
    contentEditable: flag(a[cstring"isContentEditable"]),
    id: str(a[cstring"id"]),
    readOnly: flag(a[cstring"readOnly"]),
    disabled: flag(a[cstring"disabled"]),
    monacoText: inWritableMonacoOtherThan(a, own))

proc focusIsTypingOutside*(editorNode: JsObject): bool =
  ## Whether the keyboard is in a text field that is not inside
  ## `editorNode` (the editor's DOM node, `getDomNode()`), so a programmatic
  ## focus of that editor must leave it there.
  let a = activeElementOrNil()
  if a.isNil or a.isUndefined:
    return false
  if not editorNode.isNil and not editorNode.isUndefined and
     nodeContains(editorNode, a):
    return false
  isNativeTextField(fieldFactsOf(a, editorNode))

proc revealLineAndFocus*(monacoEditor: JsObject; line, col: int) =
  ## Move the caret to `line` (and `col`; Monaco columns are 1-based, and one
  ## below 1 is clamped to 1), scroll it into the centre, and give the editor
  ## the keyboard — unless the user is typing in a text field elsewhere
  ## (`focusIsTypingOutside`). Monaco API:
  ## https://microsoft.github.io/monaco-editor/typedoc/interfaces/editor.ICodeEditor.html
  if monacoEditor.isNil or monacoEditor.isUndefined:
    return
  discard monacoEditor.revealLineInCenter(line)
  discard monacoEditor.setPosition(js{lineNumber: line, column: max(col, 1)})
  if not focusIsTypingOutside(monacoEditor.getDomNode()):
    discard monacoEditor.focus()

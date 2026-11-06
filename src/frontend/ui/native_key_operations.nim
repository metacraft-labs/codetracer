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

func desktopAnswerOf*(operation: string; path: ScopePath; mac: bool): string =
  ## The status-bar answer the desktop gives INSTEAD of running `operation`
  ## in the focus `path`, or "" when the desktop runs it (or says nothing).
  ##
  ## `list.activate-redirected` (`Ctrl+Enter`, CUA-Keymap.md §3.6) is bound
  ## on the desktop (`frontEnd != web`), and §3.6 says a list whose rows have
  ## no second destination answers that it has none. Every desktop list is
  ## one: its Test Results pane takes no keys (Test-Results-Pane.md §8.4) and
  ## no other list redirects an open. So the key is answered and stopped —
  ## not left to the element after a console warning. The Test Results pane
  ## names its pointer reach, Ctrl (Cmd on macOS) on the `⏵` press (§9.3).
  if operation != "list.activate-redirected":
    return ""
  let at = path.innermostPane
  let paneKind = if at >= 0: path[at].paneKind else: ""
  if paneKind == "testResults":
    let click = if mac: "Cmd+click" else: "Ctrl+click"
    "Open in the Other Tab: the Test Results pane takes no keys on the " &
      "desktop; " & click & " a test's ⏵ to open it in the other tab"
  else:
    "Open in the Other Tab: this list's rows have no second destination"

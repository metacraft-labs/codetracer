## ct_resolver.nim — the CodeTracer pack's binding resolver for the native
## front-ends (DemoVideoScript-Format §4.3.4, *chords by binding*).
##
## A scenario names a chord by the operation it is bound to
## (`chord: { bound: editor.trace-macro-at-cursor }`); the runner asks the
## pack which chord that is, then sends it as real keys. The answer is the
## application's own: the shared keymap router (`viewmodel/keymap/
## keymap_router`, PLAT-64's lookup, Input-Routing-And-Keymaps.md §4.4) —
## the same code the terminal and the GPUI window resolve keys with — built
## the way they build it (the base keymap the run started with, then the
## user's `keybindings.json` from the run's configuration directory), and
## asked `chordFor` at the scope the screen shows: the window, the focused
## pane, the editor when it holds the focus, in the product mode the window
## is in.
##
## Nothing is invented here. A user row in `keybindings.json` rebinding the
## operation changes the answer exactly as it changes what the application
## does with the key, and an operation nothing reaches answers none — the
## step then fails; it never falls back to running the operation.
##
## The desktop's binding asks the running window instead
## (`window.__CODETRACER_TEST__.chordForOperation`, a read-only seam over the
## same router).

import std/[options, os, strutils]

import ../../../frontend/viewmodel/keymap/[keymap_router, context_keys,
                                           scope_path, editing_keymap]
import ../../../frontend/viewmodel/keymap/user_keymap
import ../../../frontend/viewmodel/viewmodels/product_mode

type
  ResolverScope* = object
    ## What the binding read off the screen: the facts the router's context
    ## keys derive from.
    product*: ProductMode
    replayLoaded*: bool
    editorFocused*: bool
    editorReadOnly*: bool
    focusedPane*: string     ## the pane holding the focus ("" when none)
    paletteOpen*: bool
    contextMenuOpen*: bool

proc baseOf*(name: string): BaseKeymap =
  case name.toLowerAscii
  of "", "cua", "default": bkCua
  of "emacs": bkEmacs
  of "vim": bkVim
  of "kakoune": bkKakoune
  else: raise newException(ValueError, "unknown keymap '" & name & "'")

proc routerFor*(base: BaseKeymap; delivery: KeyDelivery;
                keybindingsJson: string): KeymapRouter =
  ## The router the front-end resolves with: the base, then the user's rows.
  result = initKeymapRouter(base, delivery)
  if keybindingsJson.len > 0 and fileExists(keybindingsJson):
    result.applyUserKeymap(parseUserKeymap(readFile(keybindingsJson)))

proc scopePathOf*(scope: ResolverScope): ScopePath =
  ## The scope path the front-end would hand the router for this screen:
  ## the window, then a window-owned overlay, or the focused pane and the
  ## editor element it holds.
  result = @[element(ekWindow, "window")]
  if scope.paletteOpen:
    result.add element(ekOverlay, "palette")
    return
  if scope.contextMenuOpen:
    result.add element(ekOverlay, "context-menu")
    return
  if scope.editorFocused:
    result.add pane("editor")
    result.add element(ekEditor, "editor")
  elif scope.focusedPane.len > 0:
    result.add pane(scope.focusedPane)

proc factsOf*(scope: ResolverScope): SessionFacts =
  var editor = EditorFacts()
  if scope.editorFocused:
    editor = if scope.editorReadOnly: sourceViewFacts()
             else: EditorFacts(readOnly: false)
  SessionFacts(product: scope.product, replayLoaded: scope.replayLoaded,
               editor: editor, paletteVisible: scope.paletteOpen,
               contextMenuVisible: scope.contextMenuOpen)

proc formatChord*(display: string): string =
  ## The router's display form (`Ctrl+K T M`, the letters capitalised as the
  ## keymap documents write them) in the format's key spelling: a bare letter
  ## is the letter key, lower case — `T` in the format would be Shift+t.
  ## A letter with Shift keeps it explicitly.
  var parts: seq[string] = @[]
  for chord in display.splitWhitespace():
    var keys = chord.split('+')
    let last = keys[^1]
    if last.len == 1 and last[0] in {'A'..'Z'}:
      keys[^1] = $last[0].toLowerAscii
    parts.add keys.join("+")
  parts.join(" ")

proc resolveChord*(router: KeymapRouter; operation: string;
                   scope: ResolverScope): Option[string] =
  ## The chord that runs `operation` where the screen's focus is, in the
  ## format's key spelling (`Ctrl+K T M`); none when no key reaches it.
  var name = operation
  var arg = ""
  let paren = operation.find('(')
  if paren > 0 and operation.endsWith(")"):
    name = operation[0 ..< paren]
    arg = operation[paren + 1 .. ^2]
  let chord = router.chordFor(name, factsOf(scope), scopePathOf(scope),
                              nmNormal, arg)
  if chord.len == 0: none(string) else: some(formatChord(chord))

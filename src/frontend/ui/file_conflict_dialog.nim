## The "file changed on disk" overlay, and the one rule it has to keep.
##
## This lives in its own leaf module — importing nothing but `kdom` and
## `std/jsffi` — for two reasons.  The first is that `renderer.nim` is the
## Electron renderer entry point and cannot be loaded by a test.  The second
## is the rule itself:
##
##   **the dialog's markup is a constant, and the path is TEXT.**
##
## It used to be one `&"""..."""` interpolation that spliced `path` straight
## into `overlay.innerHTML`.  A path is not markup and was never meant to be:
## `<`, `>`, `"` and `'` are all legal in a POSIX filename, the path reaching
## this dialog is whatever a trace, a workspace or an ACP agent named, and the
## element it lands in is an Electron renderer with `nodeIntegration` reach.
## So the interpolation is gone, and `pathTextFor` is where the path goes.
##
## `src/frontend/tests/htmlSinks.test.mjs` drives `buildFileConflictOverlay`
## with hostile paths through jsdom and asserts nothing renders.

when defined(js):
  import std/jsffi
  import kdom

  const FileConflictDialogMarkup* = """
    <div class="file-conflict-dialog" role="dialog" aria-modal="true">
      <h2>File changed on disk</h2>
      <p><span class="file-conflict-dialog-path"></span> changed on disk while the editor has unsaved changes.</p>
      <div class="file-conflict-dialog-actions">
        <button type="button" data-action="discard">Discard and reload</button>
        <button type="button" data-action="save">Save in-memory version</button>
        <button type="button" data-action="merge">Open three-way merge</button>
        <button type="button" data-action="keep">Keep editing</button>
      </div>
    </div>
  """
    ## Constant.  Nothing is interpolated into it, and
    ## `htmlSinks.test.mjs` asserts that by scanning this file for a `{`.

  proc buildFileConflictOverlay*(path: cstring): kdom.Element =
    ## Build the overlay for `path`.  The caller wires the four
    ## `[data-action=...]` buttons and appends the result to the document.
    let overlay = kdom.document.createElement(cstring"div")
    overlay.class = cstring"file-conflict-dialog-backdrop"
    overlay.innerHTML = cstring(FileConflictDialogMarkup)
    # `textContent`, not interpolation: whatever the path contains, the DOM
    # treats it as one text node.  This assignment IS the fix.
    let pathEl = overlay.toJs.querySelector(cstring".file-conflict-dialog-path")
    if not pathEl.isNil:
      pathEl.textContent = path
    overlay

## How CodeTracer's Monaco editors look: the code face and the two colour
## themes, `codetracerDark` and `codetracerWhite`.
##
## A leaf module (it imports nothing of the app) so that every Monaco host can
## reach the one definition: the app's editors through `renderer.nim`
## (`ensureMonacoThemesDefined`, `monacoThemeName`) and `utils.nim`
## (`CODE_FONT_FAMILY`), and the StoryBook bundle
## (`storybook_components.nim`), which has no `Data` to reach `renderer.nim`
## through. A second copy of either would be the drift `renderer.nim`'s notes
## on Monaco's silent theme fallback describe.
##
## The theme documents are the checked-in Monaco theme JSONs under
## `src/public/third_party/monaco-themes/themes/customThemes/json/`, read at
## Nim compile time and emitted as object literals, so no runtime fetch (and
## no ordering against the asset pipeline) is involved. Monaco's theme API:
## https://microsoft.github.io/monaco-editor/docs.html#functions/editor.defineTheme.html

const
  CodeFontFamily* = "SpaceMono, monospace"
    ## The face for every code surface in the app: the editors, the trace and
    ## agent editors, and the unified diff.
  DefaultEditorFontSize* = 16
    ## The editors' font size until the user changes it (`data.ui.fontSize`).
  CodeTracerWhiteTheme* = "codetracerWhite"
  CodeTracerDarkTheme* = "codetracerDark"
  whiteThemeDef =
    staticRead("../../public/third_party/monaco-themes/themes/customThemes/json/codetracerWhite.json")
  darkThemeDef =
    staticRead("../../public/third_party/monaco-themes/themes/customThemes/json/codetracerDark.json")

func monacoThemeFor*(appTheme: string): string =
  ## The Monaco theme that matches CodeTracer's colour theme. `default_white`
  ## is the only light theme CodeTracer ships; `default_dark`,
  ## `default_black` and `mac_classic` all map to `codetracerDark`.
  if appTheme == "default_white": CodeTracerWhiteTheme else: CodeTracerDarkTheme

when defined(js):
  proc defineCodeTracerMonacoThemes*() =
    ## Register both themes with the page's `monaco`. Raises (a JavaScript
    ## error) when Monaco has not loaded; callers that may run before it
    ## catch that and retry later.
    {.emit: "monaco.editor.defineTheme('" & CodeTracerWhiteTheme & "', " & whiteThemeDef & ")\n".}
    {.emit: "monaco.editor.defineTheme('" & CodeTracerDarkTheme & "', " & darkThemeDef & ")\n".}

type
  GutterTraceMark* = enum
    ## The tracepoint slot of a gutter line.
    gtmNone, gtmEnabled, gtmDisabled
  GutterBreakpointMark* = enum
    ## The breakpoint slot of a gutter line.
    gbmNone, gbmEnabled, gbmDisabled

when defined(js):
  func `&`(a, b: cstring): cstring {.importjs: "(# + #)".}
    ## JavaScript string concatenation (this leaf module imports no helper
    ## library that defines it).

  func gutterSlot(class: cstring): cstring =
    ## One slot of the gutter. Every node stops `mousedown`: that is what
    ## keeps a press on the gutter from selecting the line or folding the
    ## function under it (`ui/trace.nim` `editorLineNumber` records the
    ## measurements).
    cstring"<div class='" & class & cstring"' onmousedown='event.stopPropagation()'></div>"

  func editorGutterLineHtml*(lineText: cstring; lineClass: cstring = "";
                             runTestHtml: cstring = ""; executionLine = false;
                             trace = gtmNone;
                             breakpoint = gbmNone): cstring =
    ## The custom gutter of one editor line: the HTML CodeTracer hands to
    ## Monaco's `lineNumbers` option, which Monaco puts in the line-number
    ## cell (https://microsoft.github.io/monaco-editor/typedoc/interfaces/editor.IEditorOptions.html#lineNumbers).
    ## The stylesheet (`styles/components/text_editor.styl`, `.gutter` and
    ## its lanes) lays the slots out left to right: the run-test slot, the
    ## execution-pointer arrow (`gutter-highlight-active` on the line the
    ## replay is stopped on), the line number, the VCS band, the tracepoint
    ## and the breakpoint, clear of Monaco's folding lane. A plain number
    ## instead of this markup is stretched across the whole margin and runs
    ## into the code.
    ##
    ## The app's editors (`EditorViewComponent.editorLineNumber`) and the
    ## StoryBook editor build their gutter here, so both draw the same one.
    let highlight =
      if executionLine: gutterSlot(cstring"gutter-highlight-active")
      else: gutterSlot(cstring"gutter-no-highlight")
    let traceSlot = case trace
      of gtmNone: gutterSlot(cstring"gutter-no-trace")
      of gtmEnabled: gutterSlot(cstring"gutter-trace")
      of gtmDisabled: gutterSlot(cstring"gutter-disabled-trace")
    let breakpointSlot = case breakpoint
      of gbmNone: gutterSlot(cstring"gutter-no-breakpoint")
      of gbmEnabled: gutterSlot(cstring"gutter-breakpoint-enabled")
      of gbmDisabled: gutterSlot(cstring"gutter-breakpoint-disabled")
    let lineHtml = cstring"<div class='gutter-line' onmousedown='event.stopPropagation()'>" &
      lineText & cstring"</div>"
    # The run slot goes in FIRST, before the highlight, so its `z-index`
    # contest with the current-line arrow is decided by the stylesheet rather
    # than by document order, and the markup reads in the lane order the
    # stylesheet's header describes.
    cstring"<div class='gutter " & lineClass & cstring"' data-line=" & lineText &
      cstring" onmousedown='event.stopPropagation()'>" & runTestHtml & highlight &
      lineHtml & gutterSlot(cstring"diff-line") & traceSlot & breakpointSlot &
      cstring"</div>"

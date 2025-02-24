import
  ui_imports

proc showCode* (id: cstring, path: cstring, fromLine: int, toLine: int, codeLine: int): VNode =
  if data.ui.editors.hasKey(path):
    let editor = data.ui.editors[path]
    let first = max(0, fromLine)
    let last = max(0, min(toLine, len(editor.tabInfo.sourceLines) - 1))
    let sourceCode: seq[cstring] = editor.tabInfo.sourceLines[first..last]

    result = buildHtml(
      ul(
        id = id & "-tooltip",
        class = "code-tooltip"
      )
    ):
      li(): code(class = "excerpt-code"): text &"{path}"
      br()

      for i, val in sourceCode:
        let currentLine: int = first + i + 1

        # Checks if first and last lines of the excerpt are empty
        if len(val.trim()) == 0 and (i == 0 or currentLine - 1 == last):
          continue

        let line: string = &"{currentLine}|{val}"

        if currentLine == codeLine:
          li(class = "active-line"): code(class = "excerpt-code"): text line
        else:
          li(): code(class = "excerpt-code"): text line
  else:
    # TODO: loading the actual file content if file not open
    cwarn "TODO: showCode: for non-loaded files"

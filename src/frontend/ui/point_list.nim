import ui_imports, ../types

proc pointListView*: VNode =
  buildHtml(tdiv(class = "point-list")):
    tdiv(class = "list-name"):
      h2:
        text "breakpoints"
    tdiv(class = "list-name"):
      h2:
        text "tracepoints"
    table(id = "breakpoint-list")
    table(id = "tracepoint-list")

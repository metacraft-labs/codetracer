import
  ../ui_helpers,
  ui_imports, ../types

method render*(self: ErrorsComponent): VNode =
  result = buildHtml(tdiv):
    tdiv(id = "errors"):
      tdiv(
        class = "error",
        oncick = proc = discard jumpLocation(location)
      ):
        for (location, raw) in self.errors:
          tdiv(class = "error-location"):
            text $location
          tdiv(class = "error-raw"):
            text raw

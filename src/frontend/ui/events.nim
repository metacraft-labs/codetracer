import
  ../types,
  ui_imports, colors

proc eventsView*: VNode =
  var outputStyle = @[
    style(
      (StyleAttr.color, DEFAULT_FORE),
      (StyleAttr.backgroundColor, DEFAULT_BACK),
      (StyleAttr.fontWeight, DEFAULT_WEIGHT)
    )
  ]
  result = buildHtml(tdiv(class = "events"))

import isonim/web/dom_api as isonim_dom

proc resetStyle(node: isonim_dom.Element) {.importjs: "#.style = {}".}

type
  StyleAttr* {.pure.} = enum
    backgroundSize
    cssFloat
    fontFamily
    fontSize
    height
    left
    lineHeight
    marginLeft
    textAlign
    top
    width

  VStyle* = ref object
    attrs*: seq[(cstring, cstring)]

proc attrName(attr: StyleAttr): cstring =
  cstring($attr)

proc style*(pairs: varargs[(StyleAttr, cstring)]): VStyle =
  result = VStyle(attrs: @[])
  for (attr, value) in pairs:
    result.attrs.add((attr.attrName, value))

proc style*(attr: StyleAttr; value: cstring): VStyle =
  style((attr, value))

proc setAttr*(s: VStyle; attr: StyleAttr; value: cstring) =
  let key = attr.attrName
  for i in 0 ..< s.attrs.len:
    if s.attrs[i][0] == key:
      s.attrs[i][1] = value
      return
  s.attrs.add((key, value))

proc getAttr*(s: VStyle; attr: StyleAttr): cstring =
  let key = attr.attrName
  if s.isNil:
    return cstring""
  for (name, value) in s.attrs:
    if name == key:
      return value
  cstring""

proc applyStyle*[T](node: T; s: VStyle) =
  if s.isNil:
    return
  let element = cast[isonim_dom.Element](node)
  element.resetStyle()
  for (name, value) in s.attrs:
    isonim_dom.setStyleProperty(element, name, value)

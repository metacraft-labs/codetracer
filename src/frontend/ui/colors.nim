# display colored terminal output
const
  ESCAPE* = "\x1b"

  FORE*: array[8, cstring] = [
    cstring"#000000", # black
    cstring"#FF0000", # red
    cstring"#00FF00", # green
    cstring"#00FFFF", # yellow
    cstring"#0000FF", # blue
    cstring"#FF00FF", # magenta
    cstring"#00FFFF", # cyan
    cstring"#FFFFFF"  # white
  ]

  BACK*: array[8, cstring] = FORE

  WEIGHT*: array[2, cstring] = [
    cstring"normal",
    cstring"bold"
  ]

  DEFAULT_FORE* = FORE[7]
  DEFAULT_BACK* = FORE[0]
  DEFAULT_WEIGHT* = WEIGHT[0]
import
  ../lib

# display colored terminal output

const ESCAPE* = "\x1b"

const FORE*: array[8, cstring] = [
  j"#000000", # black
  j"#FF0000", # red
  j"#00FF00", # green
  j"#00FFFF", # yellow
  j"#0000FF", # blue
  j"#FF00FF", # magenta
  j"#00FFFF", # cyan
  j"#FFFFFF"  # white
]

const BACK*: array[8, cstring] = FORE

const WEIGHT*: array[2, cstring] = [
  j"normal",
  j"bold"
]

const DEFAULT_FORE* = FORE[7]
const DEFAULT_BACK* = FORE[0]
const DEFAULT_WEIGHT* = WEIGHT[0]

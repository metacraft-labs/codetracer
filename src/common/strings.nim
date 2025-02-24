import strformat

proc theFormatIsCorrect {.noreturn.} =
  raiseAssert "The format should be correct"

template fmt2*(x: untyped): untyped =
  ## This works like the regular `fmt` function, but plays nicer with the
  ## exception tracking mechanism. The default one raises a silly ValueError
  ## that has to be discarded all the time.
  try: fmt(x)
  except ValueError: theFormatIsCorrect()

export strformat

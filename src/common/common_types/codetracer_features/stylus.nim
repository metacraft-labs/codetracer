type
  StylusTransaction* = ref object
    txHash*: cstring
    isSuccessful*: bool
    fromAddress*: cstring
    toAddress*: cstring
    time*: cstring

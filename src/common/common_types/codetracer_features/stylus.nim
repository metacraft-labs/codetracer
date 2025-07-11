type
  StylusTransaction* = ref object
    txHash*: langstring
    isSuccessful*: bool
    fromAddress*: langstring
    toAddress*: langstring
    time*: langstring

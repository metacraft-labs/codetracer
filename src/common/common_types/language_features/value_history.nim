# Should have been in value.nim but is needed to fix a circular dependency
type
  CtLoadHistoryArguments* = ref object
    expression*: langstring

  HistoryResult* = object ## HistoryResult object
    location*: Location
    value*: Value
    time*: BiggestInt
    description*: langstring

  ValueHistory* = ref object ## ValueHistory object Contains a sequence of historical results and the values location
    location*: Location
    results*: seq[HistoryResult]

  HistoryUpdate* = object
    expression*: string
    results*: seq[HistoryResult]
    finish*: bool

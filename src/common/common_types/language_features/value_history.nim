# Should have been in value.nim but is needed to fix a circular dependency
type
  HistoryResult* = object ## HistoryResult object
    location*: Location
    value*: Value
    time*: BiggestInt
    description*: langstring

  ValueHistory* = ref object ## ValueHistory object Contains a sequence of historical results and the values location
    location*: Location
    results*: seq[HistoryResult]

  HistoryUpdate* = object
    expression*: langstring
    address*: int
    results*: seq[HistoryResult]
    finish*: bool

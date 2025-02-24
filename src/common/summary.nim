type
  ReplaySummary* = object
    entry*: ReplayMomentSummary

  ReplayMomentSummary* = object
    path*: string
    line*: int

proc replaySummaryForEntry*(path: string, line: int): ReplaySummary =
  ReplaySummary(entry: ReplayMomentSummary(path: path, line: line))

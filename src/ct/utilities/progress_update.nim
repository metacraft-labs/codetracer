import std/[strformat, strutils, terminal, json ]

proc logUpdate*(progress: int, msg: string) =
  if not isatty(stdout):
    echo fmt"""{{"progress": {progress}, "message": "{msg}"}}"""
    flushFile(stdout)
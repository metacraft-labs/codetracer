import std/[strformat, terminal ]

proc logUpdate*(progress: int, msg: string) =
  if not isatty(stdout):
    echo fmt"""{{"progress": {progress}, "message": "{msg}"}}"""
    flushFile(stdout)
  else:
    stdout.eraseLine()
    stdout.write(&"{msg} {progress}%")
    stdout.flushFile()

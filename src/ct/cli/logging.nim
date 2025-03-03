import std/[ strformat ]

template errorMessage*(message: string) =
  echo message

proc notSupportedCommand*(commandName: string) =
  echo fmt"{commandName} not supported with this backend"
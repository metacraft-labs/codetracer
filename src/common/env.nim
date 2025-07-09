# workaround to use from renderer/frontend: just returning the default/not failing

when not defined(js):
  import os
  proc get*(a: string, default: string = ""): string =
    os.getEnv(a, default)
else:
  # import jsffi

  type
    NodePath* = ref object
      join*: proc: cstring {.varargs.}
      resolve*: proc(path: cstring): cstring
      dirname*: proc(path: cstring): cstring
      basename*: proc(path: cstring): cstring

  proc jsGetEnv*(a: cstring): cstring {.importcpp: "process.env[#]".}

  var nodeFilename* {.importcpp: "__filename".}: cstring

  proc get*(a: string, default: string = ""): string =
    when not defined(ctRenderer):
      var r = jsGetEnv(cstring(a))
      if r.len > 0:
        return $r
      else:
        return default
    else:
      return default

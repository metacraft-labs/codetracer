## wasm_test_plugins.nim — the WebAssembly plugins `test_plugin_host_wasm.nim`
## runs in one real `ct-plugin-host`. One source, built once per package
## (`-d:ctWasmTestPackage=<name>`), against the real `codetracer_plugin_sdk`
## compiled to wasm32: each is an ordinary plugin, and each misbehaves the way
## its case needs, inside its own instance.
##
## | package | plugin | what it does |
## |---|---|---|
## | `wasm-faults` | `wasm-faults.spin` | `spin.run` loops for ever |
## | `wasm-faults` | `wasm-faults.hog` | `hog.run` allocates until its memory limit stops it |
## | `wasm-steady` | `wasm-steady.echo` | answers `echo` queries with their input, counts them in a status item |
## | `wasm-steady` | `wasm-steady.busy` | `busy.run` keeps its call running for `ms` milliseconds (the host is killed meanwhile) |
## | `wasm-reader` | `wasm-reader.files` | `files.read` reads `path` through the host's `readPath` import |

import std/[monotimes, times]
import codetracer_plugin_sdk
import ../../../../../plugin_sdk/wasm_io

const ctWasmTestPackage {.strdefine.} = "wasm-steady"

let sdk = newPluginSdk(ctWasmTestPackage)

when ctWasmTestPackage == "wasm-faults":
  let spin = sdk.addPlugin("wasm-faults.spin", "1.0.0")
  spin.onActivate = proc(p: Plugin) =
    p.pushStatus("spin.status", viewText("spin.status", "spin: ready"))
  spin.onInvoke("spin.run", proc(p: Plugin; args: JsonNode; req: Request) =
    # Unsigned, so it wraps: an `int` is 32 bits on wasm32, and a compiled
    # engine counts past 2^31 inside a 3 s deadline (an OverflowDefect, not
    # the overrun this plugin exists to cause; measured on wasmtime).
    var n {.volatile.}: uint32 = 0
    while true:
      n = n + 1)

  let hog = sdk.addPlugin("wasm-faults.hog", "1.0.0")
  hog.onActivate = proc(p: Plugin) =
    p.pushStatus("hog.status", viewText("hog.status", "hog: ready"))
  hog.onInvoke("hog.run", proc(p: Plugin; args: JsonNode; req: Request) =
    var keep: seq[string]
    while true:
      var chunk = newString(1024 * 1024)
      chunk[0] = 'x'
      chunk[^1] = 'y'
      keep.add chunk
    p.done(req))

elif ctWasmTestPackage == "wasm-steady":
  let echoer = sdk.addPlugin("wasm-steady.echo", "1.0.0")
  var answered = 0
  echoer.onActivate = proc(p: Plugin) =
    p.pushStatus("echo.status", viewText("echo.status", "echo: 0"))
  echoer.onQuery("echo", proc(p: Plugin; input: JsonNode; req: Request) =
    inc answered
    p.answer(req, %*{"echo": input, "answered": answered})
    p.pushStatus("echo.status", viewText("echo.status", "echo: " & $answered)))

  let busy = sdk.addPlugin("wasm-steady.busy", "1.0.0")
  busy.onActivate = proc(p: Plugin) =
    p.pushStatus("busy.status", viewText("busy.status", "busy: ready"))
  busy.onInvoke("busy.run", proc(p: Plugin; args: JsonNode; req: Request) =
    let until = getMonoTime() + initDuration(milliseconds = args{"ms"}.getInt(1000))
    while getMonoTime() < until:
      discard
    p.done(req))

elif ctWasmTestPackage == "wasm-reader":
  let files = sdk.addPlugin("wasm-reader.files", "1.0.0")
  files.onInvoke("files.read", proc(p: Plugin; args: JsonNode; req: Request) =
    let f = p.readPath(args{"path"}.getStr(""))
    f.addCallback proc() =
      let o = f.read
      p.answer(req, %*{"status": $o.status, "data": o.data,
                       "message": o.message}))

else:
  {.error: "unknown test package " & ctWasmTestPackage.}

sdk.run()

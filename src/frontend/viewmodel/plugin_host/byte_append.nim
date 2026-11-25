## plugin_host/byte_append.nim — append one byte string to another, safely for
## any length, on every backend.
##
## WHY THIS EXISTS. On the JavaScript backend a Nim `string` is an array of
## byte values, and Nim up to 2.2.4 compiles `dst.add src` to
## `dst.push.apply(dst, src)`: one call whose ARGUMENT LIST is every byte of
## `src`. (Later compilers, 2.2.10 and the codetracer fork 2.3.1, call the
## runtime's `nimAddStrStr` loop instead — measured with each on the same
## three-line program.) The desktop's and `ct host`'s JavaScript is built with
## stock Nim 2.2.4 (`repro.nim`, `nixpkgs#nim`), and this wire is compiled by
## plugin authors with any Nim the SDK accepts (`nim >=2.2`), so it must be
## correct under that codegen too — as `plugin_io.spawnGrouped` stopped
## depending on 2.2.4's `osproc` for the same reason (codetracer-pm issues/
## 2026-11-23-stock-nim-2-2-4-osproc-ignores-podaemon-on-linux-so-a-tool-deadline-leaves-its-grandchildren.md).
## The dev shell's compiler is the fork, so a suite run there cannot see the
## difference; the `ct host` GUI suite, which runs the shipped bundle, can.
## JavaScript engines cap the
## arguments a call may take (V8 throws `RangeError: Maximum call stack size
## exceeded` once they no longer fit on its stack — a little over 100 000 on
## Node), so appending a large buffer throws instead of appending. See
## https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Function/apply#using_apply_and_built-in_functions
## ("you run the risk of exceeding the JavaScript engine's argument length
## limit").
##
## The plugin wire runs on that backend in the desktop's main process and in
## `ct host` (`process_link`'s `child_process` arm). A frame over the limit —
## a mirrored batch carrying a module's locals, `__builtins__` included — threw
## out of `protocol.encodeFrame`, the batch was never sent, and the plugin's
## mirror, which needs every revision in order (`sync_subscriber.onMessage`),
## refused every batch after it: the plugin saw the session frozen at the stop
## before (codetracer-pm issues/
## 2026-11-24-under-ct-host-a-plugins-mirror-never-learns-what-a-step-changed.md).
##
## Every place that appends a buffer whose size it does not bound — a frame's
## payload, a queue of frames, a chunk read from a pipe — goes through
## `appendBytes`.

func appendBytes*(dst: var string; src: string) =
  ## `dst.add src`, for a `src` of any length. Natively it IS `add`; on the
  ## JavaScript backend the bytes are copied one by one, which no engine
  ## limits.
  when defined(js):
    let start = dst.len
    dst.setLen(start + src.len)
    for i in 0 ..< src.len:
      dst[start + i] = src[i]
  else:
    dst.add src

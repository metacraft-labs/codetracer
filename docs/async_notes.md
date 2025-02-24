
async/iterator stepping:

  * Current state: stepping literally, special keys, start of a multi-lang support focused on concurrency/async(?)
  * Think of C/C++/Rust as well
  * Think of both `stdlib`(and our patched version of it) `asyncdispatch` and `chronos`
  * What is co-step-in:
      It's continuing to next line in the current context(iterator/async function) or entering a call called by us:
        even if it happens later and invokes additional calls internally(? if awaited, otherwise not)
  * What is co-next:
      It's continue to next line in current context(iterator/async function) or if context finished, on callsite if possible(? maybe we jump/finish in other place because of a signal or other)
  * What is co-step-in for iterators:

  	Taken from stdlib of nim: `sequtils.nim`, filter
  	credit to authors and maintainers of the nim stdlib

    ```nim
    for i in 0 ..< s.len:
      if pred(s[i]):
        yield s[i]
     ```

    Normal step-in if no yield
    Step-in for yield as well? Stepping in caller which should send to actual user
  * What is co-next for iterators:
  	normal next if no yield
    continue to next entrance in internal function (probably name_iter) if yield or step-out if finished(but this should happen on last entrance in internal function? Maybe we might not hit that if something happens while yielding)
  * What about async:
    Expand a bit of code

  * Eventually TODO: fix `colonenv_ = .. newObj(..);` location directive from `internalNew` in `system.nim` to local function

  * C++: coroutines: c++ co-next seems to work, but still requires sometimes two steps and is probably buggy, co-step-in doesn't
  * C `libdill`: TODO
  * Rust async_std/tokio: TODO
  * Nim `asyncdispatch`/`chronos`: TODO


  * Detect context:
    * Co-step-in:
      * Normal: do a normal step-in and then check context again: if normal/generator: ok, else if wrapper: run to generator context
      * Wrapper: run to generator context(find equivalent generator function, make a breakpoint there, disable others, continue to it, delete the breakpoint, enable others): TODO what if we are finished, and we don't hit the generator? Maybe check some fields? After run, check context: if generator: ok, else: error(not expected)
      * Async generator/generator: (same as normal) do a normal step-in/co-next and then check context again: if normal/same generator: ok, else if wrapper: if not finished: run to same generator context, else: next to normal/other generator

    * Co-next:
      * Normal: do a normal next and then check context again: if normal/generator: ok, else if wrapper: run to generator context(maybe we finish a function and return to a wrapper)
      * Wrapper: run to generator context, after run check context: if generator: ok, else: error(not expected)
      * Async generator/generator: do a normal next, check context again: if not in the same generator: we probably returned(yielded) so if not finished: run to same generator context, else: next to normal/other generator
        else: ok

   OK, for C++ it's different: we might keep a separate logic for now
   
   libdill: 
     * normal-or-worker context, prologue, wrapper, potential-switch context

     step-in or next: beginning, otherwise same

     normal-or-worker: step-in/next and check context again: then for normal-or-worker: ok, otherwise do the same as others
     prologue: finish, step-in again
     wrapper: continue to potential-switch context and then next until normal-or-worker
     potential-switch: next until normal-or-worker

  rust:
    async-std:
      we hit a rr(?) problem when reverse-next in async function: maybe because of smart next handling/custom gdb rust commands?
      otherwise step and use `{{closure}}` version as equivalent to generator context

    tokio:
      similar rr(?) problem when reverse-next in async function
      otherwise step and use `{{closure}}` similarly to async-std

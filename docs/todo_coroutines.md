

// rust: async_std, tokio(?)
// c++ coroutine
// c libmill, libdill(?)
// nim: chronos, asyncdispatch(?)

async_std: ~ok
tokio: ~ok similar to async_std
coroutine: ~todo a bit: works for their example
libmill: doesn't seem to work well: segfault on my system
libdill: seems to work: but it's longjmp-based, not lambda based
chronos: ~ok



match
continue
back
filter


detect and use

b dill_longmp or dill_cont or dill_wait
also skip dill_prologue
and detect enter portions: different than lambda coroutines
cr.c:444

detect poll place where we call new functions
and next entrance in async

detect if we are inside an async context

ok:
  then just go over or skip until we find the next function

for nim, improve linedir

for asynccheck:
  # co-step-in as step-in
  # co-next go over or skip

  aIter_async.

  if up in callstack
  then we setup a breakpoint and continue
  but we put a breakpoint on ret of a_async if possible?
  huh it seems we dont need
  if we hit complete and break
  fix linedir
  step-in:
    simple step-in:
      detect it's a async function of type and maybe other symbols
    break aIter
    step after resultIdent line


c++:
  we have to detect usage of await operators
  as they can be used for no-coroutine functionality
  maybe then we should still use the same logic
  for now for their example it can work by detecting await_suspend await_resume await_ready

c:
  skip dill_prologue
  detect cr.c:504 (libdill 2.14)
  check for next
  detect coroutine by calls to dill_ functions? or source code?

steps: what to do by default?
maybe next should be co-next for async context
and we should have a normal-next and normal-step-in
when we make sure it's .. normal
as a fallback
but how to do it as shortcuts
we can have some highlight to show the normal step is now async
and to show additional buttons in those cases (or different color)

flow: it can just use automatically co-next for the context
without making the next similar
but it might be good to cache at least part of this
also think more of calltrace, easier with dynamic for now

c++: detect return typ a: a::promise_type with get_return_object
     next: s

detect return type
next:
  if in async context:
    if in beginning:
      breakpoint on special function after initial async
        `suspend_never::await_resume` for c++ coroutines
      continue
      delete the breakpoint
      finish
    else:
      step-in until in same function, but different line or in await switch context
        await switch context:
          `await_ready`: await step-in context for c++ coroutines
          `resume`: await resume context for c++ coroutines

      if in await switch context:
        breakpoint on special function after resume
          `await_resume` for c++
        loop:
          enable the breakpoint
          continue
          disable the breakpoint
          finish
          check if in start function if yes:
            delete the breakpoint
            eventually next if in end/entrypoint
          else:
            continue in loop
      else:
        ok
  else:
    next


step-in:
  if in async context:
    if in beginning:
      breakpoint on special function after initial async
        `suspend_never::await_resume` for c++ coroutines
      continue
      delete the breakpoint
      finish
      (similar to next)
    else:
      step-in until in function next in callstack, but different line or in await switch context
        await switch context:
          `await_ready`: await step-in context for c++ coroutines
          `resume`: await resume context for c++ coroutines

      if in await switch context:
        breakpoint on special function for suspend
          `await_suspend` for c++
        continue
        delete the breakpoint
        eventually next if in end/entrypoint
      else:
        ok
  else:
    next

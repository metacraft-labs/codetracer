
### CI

* We pass `-Ddisable32bit=ON` to rr on CI because I might need to set up additional g++ things (g++-9 ?)
* We build builds with more cached binaries/sources (e.g. rr, nim) for master push-es and "full rebuild" for merge requests, pushing directly to stable is forbidden from GitLab settings
* I should stop changing `/home/codetracer/codetracer/` state on server out of builds

### Local

I sometimes do 
`set -gx PATH /home/al/codetracer/src/build-debug $PATH`
to get many codetracer-related binaries in my path: `codetracer`, `tester` and maybe others

# Fix preloading

# Fix history

# Fix the tests to work on nim and c++

# Monitor memory performance: and maybe gc values

# Pseudo: show how sum is working, stepping through complexity with preloading multiline/parallel

# Nim: nilcheck, go through the whole nilcheck with breakpoint/jump function with preloading multiline/parallel

# Nim: nilcheck, fix a bug in ref checking

# Tracepoints:
  Tracepoint: `active` and `not active`, `valid` and `invalid`
  
  Trace: `running` and `stopped`.

  We can just run one trace at a time.
  It always runs all the `active` and `valid` tracepoints.
  Basically it works like inserted logging.

  We can add a tracepoint to path and line for now.
  If we want conditional tracepoints, we use `if`.
  We can't add two tracepoints to the same location.
  If the path and location exist, it's valid.


# Actions:
  `debug`: `loading`, `ready`, `running` and `finished`.

  # `interrupt` ?

  We can only run moves when it's `ready`. Otherwise, we ignore the moves: we don't buffer them
  or something.

  Or we buffer them: and we try to show the remaining items: however can we "ignore" those? maybe no, because we can go back easily.

  With `loading` we don't buffer yet.

  If we get stuck, we should `pause` which should get us into `ready` state.

  Errors: we just show the place where we are. we get to `ready`.

  `finished` : just have a "run" which should get us to a breakpoint or main if no breakpoint?

  Should we hit main if we have a breakpoint?

# event-jump:
  We jump to an event:
    If we hit an error, we should try to present an ok error message and just leave where we are
  
    If we dont : we get to the new position or we pause

    Can we cancel ? Pausing should be basically cancelling and should try to get us back to the previous location
    but maybe thats cancel? And pausing should just interrupt? But then resuming is hard
    so in this case probably keep a pause/cancel for now.

# calltrace-jump:
  We jump to an event:
    error: error message, leave where we are
    else: new position or pause

# events prestarting:
  We just get to those








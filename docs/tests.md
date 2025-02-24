
notes or todo-s about tests

old/todo:

### running property-based scenario generator test

We generate based on current time a seed and randomize it, then generate a scenario by
repeatedly generating random actions.

Each kind of action usually has a before and after(check) functions, which are invoked as hooks.
Before functions usually might set up something and after(check) functions check properties / other stuff

We should log what happens, so one can easily see how an error happened.


Regressions: 
we can save the steps in a file by passing `--file`, instead of running those automatically again: currently its easier to add them to a normal repl test. `quicktest` did have some option for that, but for now this seems to work fine i guess
(we don't really use much of `quicktest` here honestly, as we mostly focus on operation-specific property functions)

Running:

```bash
src/build-debug/tests/run/a_test <traceID>
src/build-debug/tests/run/a_test examples/sum.nim
```

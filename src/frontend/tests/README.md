# tests

## example-based

just test examples


## quicktests

random actions
=>
generate json with the example

```nim
tests/quicktests/
  reproductions/
    quicktest_basename/
      repr_id.json

  	failing tests that we eventually fixed
  	random subset of succeeding tests

  	make sure that stuff that worked before, still works
  	and that stuff that is fixed is still fixed
```

change test code => doesn't matter, should run with the new one
change the repl code => add new gen file




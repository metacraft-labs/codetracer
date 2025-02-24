call interleave
==================

An idea for a possible feature:

We can interleave event and other info with callstack
and calltrace:

```markdown
---
  |___ a1()
      |
      | <output 2>
      |
      | <signal error>
```

This way we can have an easier way to see order of events and
to correlate them.

It can make easy some workflows:
e.g. seeing call and arg development and important events
and being able to quickly click for history of variable
and getting to a root cause there.


* Design: use the existing calltrace design: work on lines still TODO and show events with some styling under the call name/args vertically

* Backend support: should be just a recombination of existing data, it would be good to have good history support

* Search: we can have some kind of syntax / options for searching calls with certain events

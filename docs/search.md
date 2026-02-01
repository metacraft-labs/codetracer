search
==========

An idea for a possible feature:

Search the events and data of a trace using a search box

Have two components in the box: a kind of search and a query

Functionality:

Search, filter, map, work with results or run a command
get a single result, or a list of results, or run a command.

Run a command with arguments or apply operations functionally one after each other until a result is a produced

Data:

Search in recorded events, calls and using debugging scripting: e.g.
running queries using the python or native rr lldb/gdb engines.
also run a program command as a shortcut

* Events
* Runtime values
* Calls, calltrace
* Errors
* Memory


Syntax:

Use a simple syntax with names and parens, maybe `.` or `|` for piping / operations

`call`

`call(arg, arg2)`

`call(arg, arg2) | operation`

`call.field`

`call[subrange:subrange_end]`

Implementation :

Parse to nodes.
Based on kind, run a command or search for results
start with first subexpression


1) For each subexpression find a source based on call name or argument/arguments


* Existing data: e.g. events, paths, calls
* Search through memory/debug info using scripting/stepping
* Result of previous sub-expression
* Online result
* Some kind of file / json data
* Other

2) Run the expression in the source:

3) Get result/results asynchronously and pass them to next step

4) Run next subexpressions if we have some, show some progress

5) If at the end, show in search results (or run a command if this is possible)

Notes:

If a new search is performed, or the current one is cancelled, cancel the existing search

Cache some of the results or info found that can be relevant: for current session, eventually for new sessions

Sources:

1) Existing data: managed by backend, but it's possible to have an optimization which uses data cached in frontend: mostly filter/search there

2) Search through memory/debug info: managed by the backend and probably python/native modules in a separate process

3) Result of previous sub-expression: should stay on backend for now, note this can be cached, so we can easily change the end of expression

4) Online result: TODO maybe load from some kind of existing storage if needed

5) Some kind of file/json data: TODO we can read a file with addresses or names needed for search

Operations:

1) Depending on source and data

2) `map`: just mapping a field or sub range

3) Access to field

4) Access to sub range

5) Filtering based on a condition

6) Grouping based on a function

7) Other operations: TODO

8) Graph operations

We can show results several ways

Displayers

1) HTML results: show normal results maybe with some links as an element/list

2) Graphics/plots: show based on some calls similar to R/chart.js using chart.js in a graphics box/boxes in the search results

3) Custom display: maybe we can have a javascript plugin option where we can show custom HTML/displays (e.g. a custom graph lib display or animation)

End of implementation section

Examples:

`events(WRITE)`

```
a     (onclick jumps there)
b     (onclick jumps there)
```

TODO more

Design:

Reuse ctrlp/menu design for now and graph/chart design for charts.
Make a nice user input interface with color/progress coloring: however those are nice to have-s, not critical for now

Notes:

That's a big feature: it can be very useful, as almost a central way to analyze a program/trace, but also very complicated and time-consuming. I'd propose to write a small part of the functionality/sources code to showcase how useful it can be/to have a working example : as part of the work on normal ctrlp/search functionality (which needs some of this already).
this can be done in limited amount of hours reserved for more experimental/rest from normal tasks work, or out of my work hours possibly.

However, the focus is on documenting the idea and discussing it: it's clear that it's just one possible direction of codetracer

@events |? WRITE

-> Filter(Name("events"), FilterArg::NameMatch("WRITE"))
-> events returns an events object it implements filter_by_name_match which returns needed

value == 5

-> Cmp(Op::Eq, Name("value"), Int(5))

-> values source: implements find_by_cmp(op, expr, other_expr)
-> return stream/list of results: objects which can be chained, but if evaluated to final results:
  text content, some kind of mark/kind, location for onjump/short location or line snippet

value > 5 # same

value | line-chart

draw line chart

@calls |? parse_* |? .depth > 4

@parse_* & depth > 4 & value > 5

@calls | parse_* | .depth > 4 | value > 5

At: -> CallFilter
. Cmp(Field("depth"), 4))
. Cmp(Expr("value"), int)
-> Pipe ->

search through

Calls -> parse iterator
combined with depth filter
final one runs after

so -> running combine CallSource filter_multiple: on each checks both
and in the en

CallSource, vec of parts and ValueSource with final part

In the end for each of those also check final: ValueSource in those places filter_cmp -> produce results send back show

For simplest for now


Query parsing: maybe backend <-> frontend for highlighting/completion: yes because completion easier from backend!
so send query to backend!
parse ->


frontend -program-query-> backend
backend:
  parse -> ProgramQueryPipeline(Vec<PipelineStep>) or error(send to frontend)
  PipelineStep -> {Source, ProgramSubQuery}
  ProgramSubQuery -> Filter/Calculation/Command/displayer or other

  ->
  combine several filters for the same sources ? maybe later postprocessing

  Source : run filter for that kind of query
  it can be a kind of iterator if not the final one!
  for the final one actually collect results and send back!
  (or send error!)
frontend:
  with results: show them similar to files for now
  or similar to commands
  or for error: just show the error: notification or as a single result?

first:
  sending query
  normal is just normal
  ! is for commands
  ? for search

  parsing, sending results

  if hard, minimal interface


terminal:
  show if under some limit
  if over, for now only show up to it (or eventually by scrolling?)


view: pattern

autocomplete view / br

view

autocomplete function names TODO path:line and path for path:line

view! -> results in a special panel

navigate in results

ctrlp: `open`

open

autocomplete for paths

`open!` -> results in a special panel

Autocomplete defined by command,
some commands don't have autocomplete
e.g. for now `rg` etc.
In some autocomplete ~= results
e.g. `view` and functions.
In others it can be different, e.g.
`c-location <pattern>` for functions.
There whenever we enter/choose autocomplete, we get
results in different style,
but on input/change, we get into autocomplete again/
If one wants to see both, he can use `c-location!`
now.
We might want to have panels which maintain their own queries
(or just keep them open).
One possibility is to *keep* them.
A button/shortcut which makes them a tab that is not replaced
in special panel and let them show their query
I prefer a single input box though.
Maybe we can have a shortcut that re-types their query in the input box and updates the same panel with results

Now, functions need to be preloaded and prepared for quicker filtering.
Maybe in core, not always in python.
Even if based on debug info,
for faster search and autocomplete,
we *can* also just load them in frontend, they shouldn't be too many
similarly to paths
for fuzzy search, but then plugins need to have
optional renderer logic, which might be ok

```
command.rendererAutocomplete = proc(data: Data2, query: cstring): Future[seq[SearchResult]] {.async.} =
  return await fuzzysort.goAsync(
    query,
    data.services.search.functionsPrepared,
    FUZZY_OPTIONS)
```



Save last query when closing/opening query


For ideas document, not for now:

* History/REPL
* A bit more advanced language
* More separate parts: source/displayers to be able to have more involved searching mechanisms

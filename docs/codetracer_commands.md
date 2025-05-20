### codetracer api


### `codetracer record`

You can record a trace with `codetracer record`.
It usually wraps a normal run of a binary: e.g. instead of `program args ...` you run `codetracer record program args ...`.
It can receive additional arguments however:
  * `-o/--output-folder <output-folder>`: the output folder where the trace should be stored (if it doesn't get exports as an archive)
  * `-e/--export <export-zip-path>`: export the trace as a zip file at the arg path

By default, it stores the trace as a directory inside `$HOME/.local/share/codetracer/trace-<trace-id>`.
(TODO: some parts of the code expect `$XDG_DATA_HOME` instead of `$HOME`: we should do it one way).

The archive options is useful when you want to send the trace to someone, or to upload it to a server or the cloud.
It can also be used by `codetracer shell`, when the `-e/--export` flag is passed to it(however, you might enable it using an environment variable `CODETRACER_EXPORT_RECORD_FOLDER=<shell-records-output-folder>` TODO this functionality).

The record should generate a directory including:
  * The rr trace after `rr pack` ! (it includes a copy of the original binary, and `rr pack` adds more data, so it can run in a portable manner on other machines)
  * Source (the source files : using source/ as prefix and appending to it as if it is root(both for absolute and for relative files))
  * `function_index.json` (the function index, however do we also copy all of those files there? or only the sources?)
  * `trace_metadata.json` (trace data that we store in db now, maybe some additional like arch/compiler/date/user?)

The record can be run with `codetracer run` on desktop, or `codetracer host` for a browser session
(or if we upload it: from the web interface)

### `codetracer run`

You can run a trace with `codetracer run`.

TODO

### `codetracer import`

```bash
codetracer import trace.zip # imports trace.zip into folder `trace` and local db
codetracer import trace.zip $TMPDIR/trace # import trace.zip into folder `$TMPDIR/trace` and local db
```

TODO

`codetracer run folder` (# search in local db for program and args and trace_metadata.json timestamp : if different/no match, assume it's a new/unknown one
and import, run for the id)
same with `codetracer import folder.zip; codetracer host folder`

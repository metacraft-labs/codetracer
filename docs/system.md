

## system

UI
==

UI is important.

We have most of our code in `ui/`.
`ui_js.nim` is the main file.
We define the root view.

Most of the components are defined in their own modules:

* `calltrace` the calltrace, expanding and collapse
* `chronology` the chronology and input
* `colors` some constants
* `debug` the debug toolbar
* `editor` the main editor, uses monaco: kinda weird with karax
* `events` support coloring the output code as in terminal
* `flow` the preload ui
* `history` the history ui which reuses the value ui
* `inline_editor` uses monaco, the editor open for traces
* `layout` the overall layout
* `loading` the loading screen
* `start` would be useful as default screen
* `state` the state view with changing variables
* `trace` the trace view: now we show traces inline, so maybe remove
* `ui_imports` exports most dependencies for ui
* `value` reused by views that show values or expand them

Important stuff:

* Use style for css (karax) and stylus for css files
* You can watch debug output in the console
* Monaco, datatables and charts have a weird integration as they're not a karax tree
* Layouts can be loaded from files: look at `config.nim`, we have to fix this
* We have themes: defined by variables in name_theme.styl
* Redraw needs to be manual sometimes: karax does it after event listeners, but e.g. it can't guess ipc listeners
* A lot of the helper code is in `types.nim`(types) or `lib.nim` (signatures for third party or our helpers)
* We use `view` in the name of views to easily spot them, normal functions don't need it
* When we're changing css, it's best to change the current code: remove literals and define them in defaults and theme styles, we might get the designer to color pick better colors and new themes
* We use vex-js for dialogs
* Please check id-s and classes if you remove them: we might need them for ui testing
* test_base includes most of the logic for ui testing, we use spectron

Events

You define a callback in renderer and you update state.
Most of our state is in the `data` global. It can certainly be optimized.
We maintain our panel in `sys`.

When you need to talk with the server, you send a message using `ipc.send`.
We apply the "CODETRACER::" namespace. In a browser this is a socket message, in
Electron we send it to the main process.
The main process responds, and usually you register a listener with ipcConfigure.

You can also define an async function which makes a promise which is resolved after a listener is called.



Testing

==

We have to fix the tests.

However let's look at the three main sets:

```bash
example-based/  nim.cfg  programs/  quicktests/  README.md  reproductions/  run/  Tupfile
```

In `example-based` we have normal tests.

In `quicktests` we have property tests. Their results are sometimes added to `reproductions`.

In `run` we store the compiled tests.

In `programs` we have the example programs.

We also have tests for python commands: but I must find them, probably git.

This is an old note:

```
tests/quicktests/
  reproductions/
    quicktest_basename/
      repr_id.json

    failing tests that we eventually fixed
    random subset of succeeding tests

    make sure that stuff that worked before, still works
    and that stuff that is fixed is still fixed
```

Each test folder has lang tests. They are often similar, so I am not sure if we need to parametrize them.
We define most of the main logic in test_base.

We also have `nim-ui` in `example-based` and `quicktests`.
They are based on Spectron.

They use a dsl, so you don't need to always access elements manually.
If you need to, please write a helper which can be reused.

==

Debugger

==

We are working with rr here. RR provides most of our low level functionality.

We use gdb-js, a custom fork of the original repo with minor differences: several helpers.

Most of the code is in `debugger/`

The base types are either in `types` and `core` usually.

We have a `Pool` which is currently only one.
A `Pool` has a list of `Process` which are currently rr instances.
By default, we have a `stable` process which runs most of the usual steps.
A `trace` process which runs trace debug, a `history` process which runs history search.
A `preload` process which preloads future values and `args_preload` which preloads args.
We also have `prestart` process which starts in the beginning and loads chronology: mostly writes and reads for now.

Let's take a look:

* `args_preloader` defines `loadCallTraceArgs` which loads args
* `core` contains shared logic and types for the debugger
* `debugger` is the central module
* `flow_preloader` defines the preloading code
* `history` defines the history code
* `move` runs most of the jumps
* `process_gdb` is where most of our helpers and other shortcuts live
* `py_command` is a wrapper around our python commands giving a type safe API
* `scheduler` was an experiment in mirroring stable steps in preload
* `sync_preload` is used to sync the preload process to the stable process

We also have `cgdb` which should eventually deal with gdb as a pure nim solution and give as a way to rewrite debugger with the C backend.

Basically we define a pool in the beginning and the server sends initial data to it.
After that the server starts the pre-start process which loads info while running the program
and starts the other needed processes.

The stable process jumps to main and calls back the server so the ui can show the main program.

We have a listener for gdb events and use a system of JavaScript promises to await actions.
The problem is that an action usually ends before the info of the new location arrives, so we have our own
helpers in process_gdb which we should use.

The other bizarre part is the export api: it defines with a macro the debugger interface and generates export code for it. We expose a type to other modules, so they can call our functions in a type safe way.
The debugger module can be used directly (import) or in a different process. The second thing is usually better, as
it can crash or block the main process.

It communicates using helpers and ipc send. This is also complicated internally as on desktop it uses electron, and on server `node-ipc` mapping the calls (probably).

We have some helpers to report errors and to load stuff from the server.
A lot of the moves are basically taking arguments from the server , invoking typed functions which implement the logic
and call python commands as primitives. Some actions periodically update the server , e.g. preloading.

Args preloading is a bit hard to optimize for bigger programs, so we have to work a bit on it: it visits all the call children of the current call and logs the args.

Flow preloading can be slow: most of the logic is in Python commands. We try to limit the number of steps taken there
and repeatedly call it , sending updates to the server until we are stopped by a new preloading context or finished.

We cache a lot of stuff like preload results, AST etc. Some of the caches are on function-level, some on filename-level etc.

A lot of the logic is in Python commands: usually if something needs to use a series of gdb commands or to analyze in a more powerful way the program , we create a command, it's best if it is general enough to be reused in many actions.

Parsing the modules is good for preloading: we load the labels for each line.

Overall
==


Electron:

We have several components.

The backend, the archive runner, the archive server, the shell support, codetracer, plugins, the commands, language forks, the server, the renderer and the debugger.


Codetracer calls the server, a local database and Redis.

The server is the main Electron process which dispatches tasks and messages to the renderer and the debugger.

It also maintains a running plugin for the current language and communicates on stdout with json.
It communicates on the stdout with `nimsuggest` when in a Nim project too: we have to test if this is working now.

The plugins can parse expressions and modules: expressions are parsed as QueryNode which can be interpreted by our debugger, the modules as a language-unified AST.

The QueryNode-s are interpreted with the class Loader. We visit the nodes and map each one to a gdb expression, which most of the time accesses some kind of variable or a call which can start a rr fork.

The server currently assumes it has only one renderer. We have to parametrize it.

Now, we map the messages to ipc on desktop and sockets in browser.

The renderer just talks with the server in all scenarios, for now we assume it's always a single project in a renderer.

The debugger also connects to the server for additional functionality: e.g. plugin call.
It maintains a sequence of RR debuggers with sockets and communicates with them using gdb-js either directly or with commands.

The python commands are loaded when the debugger starts: we also reuse the CPython gdb commands for Python.
They are executed only in a single RR process.

The telemetry is used for logging by me most of the time: it logs to the screen and in a file. In most of the code you can log using `event` or other shortcuts in `telemetry`. You can turn it off or on in `.config.yaml`, you can eventually share a structured log in `telemetry.log`. We probably can use nim-chronicles, but it has to be flexible enough and work on the JavaScript backend.


Plugin communicator
==

Plugins are supposed to analyze language-specific things using the language tools.
For Nim, we just import the compiler.
For C++, currently we parse clang's dump output: we have to write a plugin in C++ which actually analyzes the AST, but I had some problems with the parser API: TODO.

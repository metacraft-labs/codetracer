
## Core

A short description of the core component of CodeTracer:

It is implementing the internal core of the CodeTracer's functionality.
It exposes an API to communicate with clients and maintains the internal
rr/gdb processes that we use to automate debugging operations.

The core consists mostly of two actual folders of code:

* `src/core`, which includes the middleware sitting between clients and the actual rr/gdb processes. it is written in Nim and implements a named socket-based typed rpc-like api by which it receives calls from clients and responds with serialized results.
* `src/gdb`, which includes our code which scripts the internal rr/gdb processes. it is written in Python, and it uses the gdb's Python API. It communicates with the middleware using direct gdb API custom command calls for input and internal json append-only files for result output.

### Starting the rr/gdb processes

The component that actually *starts* the rr/gdb processes currently, is a Python script
`tools/codetracer_rr_gdb_manager.py`. It is used internally in the `codetracer` binary,
which calls it in a proper way to set up the different commands and the `core`: e.g.
in the beginning of `codetracer run`, `codetracer host` or `codetracer start_rr_gdb_and_core.

We probably want to rework this python script into a better and more general pool-maintaining tool, written in a better way.


### Task processes

We have several groups of tasks that we usually run in separate core processes.

Let's take a look:

* stable: the main experience for the user, where he steps, jumps and moves in the program
* trace: a process, where we evaluate tracepoints
* history: a process, where we try to evaluate the history of variables/expressions
* flow: here we preload the flow and local expression values for certain calls
* calltrace: here we preload the graph of some of the next calls after some point

It's possible to expand some of those processes to several sub-processes, e.g. for
parallelism. It's also possible to add new task groups.

Zahary had a better design in mind, where the core can dynamically
load processes with various properties
from some kind of service(e.g. generalized version of the codetracer rr/gdb manager) and use them in a more flexible way for different tasks.

However, currently the way it works is static, where we create the needed processes before starting core (as explained in the previous section) and eventually we
interrupt and restart some of those if needed (e.g. if a new flow request comes which invalidates the older running one)

### Core middleware

The core middleware implements:
  * A typed API for communication with clients, specified with the macro `handle` in the end of `dispatcher.nim`(a corresponding one for the web client is defined with `defineAPI` in src/index_config.nim. we can somehow unify them, but they're currently separate).
  * A typed API for communication with our custom rr/gdb python commands, specified in `py_command.nim`
  * The logic for some of the debugging operations, e.g. most of the tracepoint logic in `trace_engine.nim`, some of the flow preloading logic in `flow_preloader.nim`, the event log
  loading logic in `eventLoad` in `dispatcher.nim`, etc
  * A central dispatcher which sits between the client and the task-specific internal processes
  * Task process entrypoint which runs tasks from different task groups in different task processes with their dedicated rr/gdb process(e.g. flow tasks in the flow task process with a flow rr/gdb process)
  * A named socket-based mechanism for communication between the dispatcher and the internal task processes (in `dispatcher.nim`, `dispatcher_global.nim` and `task_process.nim`)
  * Different utilities

### rr/gdb scripts

the rr/gdb custom scripts we have implement some of the core logic of CodeTracer. Critical parts of flow, calltrace and primitives for most other tasks are implemented as python commands and methods:

  * A set of Python GDB API commands corresponding to the primitives available for core
  * A hierarchy of classes corresponding to different lang implementation:
    * LangImpl
      * NativeBackend
        * COrCpp
          * C
          * Cpp
        * Rust
        * Nim
        * Go
      * VMBackend
        * Python
  * classes for several task groups:
    * `CallsAndArgsEngine` in `calltrace.py`
    * `Evaluator` in `tracepoint.py`
    * A module with event jump logic in `event_jumps.py`
    * Experimental/not finished: concurrent/async handlers in `concurrent_handlers.py`
  * Utilities
  * A small amount of tests for tracepoints/loading values in in `src/gdb/tests/`

### Logging/debugging

Currently one of the main ways to debug the core is using its logs.

A better way would be a debugger, but I haven't worked out that well. ( :) )

We generate many log files, and we provide some helper commands to view them
based on the `just` tool.

Most of the log files include the initial codetracer process pid, called `caller pid`(not a great name maybe, we can change it).

In the nim middleware (`src/core`) we log using the `chronicles` library.

We usually generate a `dispatcher_<caller pid>.log`, and also a `task_process_<caller pid>_<group name>.log` for each task group.

In the python rr/gdb scripts (`src/gdb`) we log usually using a helper called `nested_log`.
We generate most of the logs in `$TMPDIR/codetracer/log_<caller pid>_<group name>.log`.

We save the `rr/gdb` raw process text in `/dev/shm/codetracer/<group name>_<caller pid>.txt`.

We store the `rr/gdb` script results as a line with id and json in `$TMPDIR/codetracer/<caller pid>_<group name>`.

You can see some of the helper commands using `just -l`.
Related to logs are:

* `just core-logs <pid>` # nim middleware logs
* `just rr-gdb-logs <pid>` # raw process logs
* `just script-logs <pid>` # rr/gdb python script logs
* `just command-results` # id/json python command results
* `just last-dispatcher-logs`
* `just last-task-logs <name>`
* `just last-script-logs <name>`
* `just last-command-results <name>`
* `just clean-logs`

(the `last-*` commands depend currently on the user closing the application first with e.g. `ALT+F4`, which is not good, we have to improve that)

### Assumptions/limitations

TODO: write down some important assumptions, part of the system
TODO: write down current limitations

### Caching

Currently, we have a limited amount of caching logic in the core,
but we have to optimize that

### Data types

Currently, the nim core middleware and the frontend reuse the same `src/types.nim` as shared type definitions. The python code defines many of those types by itself using classes or `mypy`/`typing` definitions.

We use the `nim-json-serialization` and `nim-serialization` libraries to serialize/deserialize most of those values around.

### Clients

Currently, we maintain mostly the `electron`/`server+browser web` client based on `src/index.nim`, `src/index_config.nim` and `src/ui`.

We also have an experimental repl client in `src/repl.nim` and we have a prototype for a tui one in `src/tui.nim`, they both depend on `src/ui_data.nim`: repl was used in the past for
core integration and property tests, and can be potentially useful by itself for people
that prefer the console instead of rich desktop/browser apps.

Theoretically, in the future, additional clients can be written down, however the current abstractions and methods of communications are probably suboptimal, so this has to be planned and improved first, probably.

### Languages

Currently, we are trying to support

* C
* C++
* Rust
* Nim
* Go(not a lot of work has been done here, mostly a prototype)
* Python(more work here, but again, more experimental, mostly for internal usage)

We had prototypes for Ruby/Lua in the past, and support for other native language implementations or simple interpreters(no JIT) shouldn't be too hard if we need it:

Eventually TODO more detailed documentation of core from a lang support view.


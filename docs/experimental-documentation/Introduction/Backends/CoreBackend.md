The Core backend is used for systems programming languages, like:

1. [C & C++](https://dev-docs.codetracer.com/Introduction/Backends/CoreBackend/CAndCpp)
1. [Goland](https://dev-docs.codetracer.com/Introduction/Backends/CoreBackend/Golang)
1. [Nim](https://dev-docs.codetracer.com/Introduction/Backends/CoreBackend/Nim)
1. [Rust](https://dev-docs.codetracer.com/Introduction/Bacends/CoreBackend/Rust)

Under the hood, it uses a patched version of the [rr debugger](https://rr-project.org/), as well as the standard
GDB debugger.

The Core backend is based on a dispatcher that maintains a pool of rr replay processes. These processes allow you to jump back and forward in time, while also
preloading information, such as the information, needed for omniscience and calltrace, as well as managing other features, such as tracepoints. This logic is
implemented using python code using the gdb API.

These are the main differences, when compared to the DB Backend:

1. Only non-deterministic events are recorded
1. The program's different sates are navigated through re-execution
1. Practical for recording real-world software(rr was originally created by Mozilla to debug Firefox)
1. Some features of CodeTracer are more challenging to implement, compared to the [DB Backend](https://dev-docs.codetracer.com/Introduciton/Backends/DBBackend)

This backend is in active development, and is yet to be released to the wider public. 

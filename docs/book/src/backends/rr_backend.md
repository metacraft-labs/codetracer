## RR backend

The RR backend is used for systems programming languages, like:

1. [C & C++](./rr-backend/c_and_cpp.md)
1. [Rust](./rr-backend/rust.md)
1. [Nim](./rr-backend/nim.md)
1. [Go](./rr-backend/go.md)

Under the hood, it uses a patched version of the [RR debugger](https://rr-project.org/), as well as the standard
GDB debugger.

We are still not distributing it, but we might need to rethink the GDB usage before that.

The Core backend is based on a dispatcher that maintains a pool of rr replay processes. These processes allow you to jump back and forward in time, while also
preloading information, such as the information, needed for omniscience and calltrace, as well as managing other features, such as tracepoints. This logic is
currently implemented using python code using the gdb API. 
(If required, this can be changed to use the lldb API or something more custom, like a dwarf lib-based solution. We are currently using the rust `gimli` DWARF lib for a tool, that helps with recording/metadata in the RR backend).

These are the main differences, when compared to the DB Backend, based on the way RR works:

1. Only non-deterministic events are recorded.
1. The program's different states are navigated through re-execution.
1. More practical for recording real-world software(RR was originally created by Mozilla to debug Firefox)
1. Some features of CodeTracer are more challenging to implement, compared to the [DB Backend](./backends/db-backend.md)

> ![NOTE]
> This backend is in active development, and is yet to be released to the wider public. 
>
> It is currently proprietary and it might remain closed source. 
> Open sourcing it is also possible, if we find a suitable business model.


## Codetracer Shell

> [!NOTE]
> This feature is in its infancy, but in development. API may be subject to change!
>
> It's not a part of the public CodeTracer features or source code for now.

CodeTracer Shell is a special feature of CodeTracer that creates an environment, and optionally an interactive shell,
that can be used to build applications with complex, or unorthodox build systems.

CodeTracer requires some additional compile flags and instrumentation functions to be built with your application.
Because of this, CodeTracer only supports building from a single file. Support for multi-file projects using build systems
is instead relegated to CodeTracer Shell.

When you execute commands in the CodeTracer Shell's interactive shell, or environment, CodeTracer Shell inserts itself into
the subprocesses that are launched during the build process of your application, making building and running applications
with more complex build systems easier.

For example, let's say you want to compile a C/C++ application using CMake. With CodeTracer Shell you can do either:
```
user $ ct shell
(ct shell) user $ mkdir build && cd build
(ct shell) user $ cmake ..
(ct shell) user $ make 
```
using the interactive shell, or the following using commands:
```
user $ ct shell -- bash -c "mkdir build && cd build && cmake .. && make"
```


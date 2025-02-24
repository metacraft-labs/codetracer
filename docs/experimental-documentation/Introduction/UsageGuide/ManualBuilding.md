## Manually building applications for Codetracer

> [!WARNING]
> This only applies to applications that are run through the 
> [Core backend](https://dev-docs.codetracer.com/Introduction/Backends/CoreBackend)!

If your application is more than 1 file long, or if the file has a complex build system, 
[Codetracer shell](https://dev-docs.codetracer.com/Introduction/UsageGuide/CodetracerShell) might not be able
to build your project successfully. In this case, you can make a special compile mode for when you want to debug with
Codetracer, and you can add the following compile flags:

1. `-g3` - optimised debugging support only for GDB
1. `-O0` - no optimisations
1. `-finstrument-functions` - Generates instrumentation calls for entry and exit to functions used for the call graph
1. `-fcf-protection=none` - Turns off instrumentation of control flow transfers

After that, you also need to link to `src/native/trace.c`, which contains the needed callback functions for Codetracer
to successfully profile and instrument your application for the call graph to work correctly.

### Example CMake setup
In CMake, you can add the following line to enable the required compile flags in debug mode:
```cmake
option(CODETRACER_DEBUG "Build for debugging with codetracer" OFF)
if (LINUX AND CODETRACER_DEBUG)
    add_compile_options(-g3 -O0 -finstrument-functions -fcf-protection=none)
endif()

# Set up your project further...

add_library(trace trace.c) # Copy `src/native/trace.c` to your project
target_link_libraries(<MY_PROJECT_NAME> PUBLIC trace)

# ...
```

### Example Rust setup
In most cases, the manual way of building using `trace.c` is not needed, due to our additional Rust wrapper utilities.
For projects that want to have a more advanced call graph representation, you can try linking to `trace.c` manually
using the following options:

1. `-Z instrument-functions`
1. `-C passes=ee-instrument<post-inline>`
1. `-C link-arg=${tracePath}`

It is recommended to use Codetracer's Rust compiler fork. You can use it by setting 
`export RUSTC="${codetracer_rust_wrapped_output_dir}/bin/rustc"`

The `tracePath` variable is calculated in the following way:

1. It looks for the `CODETRACER_C_TRACE_OBJECT_FILE_PATH` environment variable and uses it if it exists
1. If it does not exist, it uses `${linksPath}/libs/trace.o`, where `linksPath` is calculated in the following way:
   - If the links path constant is not empty(when compiling for the Nix package) it is set to the links path constant
   - Otherwise, codetracer looks for the `CODETRACER_LINKS_PATH` environment variable and uses it if it exists
   - If it does not exist, it uses `${codetracerExeDirDefault}`, which varies in values between the usage of Codetracer
     1. If using as a pure web application, it's set to `${exe.splitFile.dir.parentDir}`
     1. For our Electron backend, it's calculated in the following way:
        - If the `NIX_CODETRACER_EXE_DIR` environment variable exists, it's used
        - Otherwise, it's calculated using the following function `$(nodePath.dirname(nodePath.dirname(nodeFilename)))`,
          where `nodeFilename` is the file name of the node executable we're using

## Running tests using `tester`
To run standard tests, run the following:

1. `tester build` - builds the test applications
1. `tester parallel` - runs the tests

The built test applications can be found under the following folders:

1. `tests/binaries`
1. `tests/programs` - for scripting languages

> [!NOTE]
> Most additional options of the `tester` application are experimental, and may, or may not currently work!

## Real-world testing
CodeTracer is developed as a solution for debugging complex applications, so the simple tests are not enough for testing
in real-world scenarios.

For this reason, we have a number of highly complex applications real-world applications/libraries that can be used to
test complex usages of CodeTracer.

> [!NOTE]
> C/C++/Rust examples are for internal use, since the backend for systems programming languages is yet to be released
> publicly.

> [!TIP]
> Though currently unstable, this backend has been proved to work with these applications without many issues. You can
> check them out yourself as a way to gauge how effective CodeTracer would be in your project.

> [!NOTE]
> The custom patches to the C/C++ applications are required because CodeTracer Shell is currently not capable of 
> bootstrapping complex C/C++ projects. Integrations with most of the popular build tools are coming soon!

### Noir applications
Coming soon!

### UntitledDBusUtils(C++)
The [UntitledDBusUtils](https://github.com/MadLadSquad/UntitledDBusUtils) library is a C++ metaprogramming wrapper on 
top of the low level [D-Bus](https://en.wikipedia.org/wiki/D-Bus) C API. The code for deserialisation of data has highly
complex control flow that is hard to track with a normal debugger when a bug is introduced.

Running steps:

1. Clone the library: `git clone https://github.com/metacraft-labs/UntitledDBusUtils.git --recursive`
1. Enter the cloned folder:
   - On NixOS, run `nix-shell`
   - On any other distribution, install the following:
     - D-Bus
     - CMake
     - GNU Make
     - GCC & G++
     - rr
     - GDB
     - OpenSSL
1. Copy `<codetracer directory>/src/native/trace.c` into the root project directory. [Documentation](https://dev-docs.codetracer.com/Introduction/UsageGuide/ManualBulidingCOrCpp)
1. Create a `build` directory and enter it
1. Run `cmake .. -DCMAKE_BUILD_TYPE=DEBUG`
1. Compile with `make -j <number of jobs>`
1. Go to your local copy of `codetracer-desktop`(make sure you're still in the Nix shell if on NixOS)
1. Run `ct record <UntitledDBusUtils location>/build/test`
1. Once the process hangs run the following command in another terminal, in order to feed the application data:
   ```
    user $ gdbus call --session --dest org.test.Test --object-path /org/test/Test --method org.test.Test.Test --timeout=1 1 2 "test" "(([3,4,5,6],[7,8,9,10]),11,12,([13,14,15,16],[17,18,19,20]))" "test2"
   ```
1. Run `ct replay <UntitledDBusUtils location>/build/test`

### UntitledImGuiFramework/UImGuiDemo(C++)
The [UntitledImGuiFramework](https://github.com/MadLadSquad/UntitledImGuiFramework) is an example of a highly-complex
application that also deals with graphics and constant interactions between it, the user, and the underlying operating
system.

To test it, we're using the [UImGuiDemo](https://github.com/MadLadSquad/UImGuiDemo) example application.

Installation instructions:

1. Clone the framework: `git clone https://github.com/MadLadSquad/UntitledImGuiFramework.git --recursive`
1. Enter the cloned folder:
   - If on NixOS, run `nix-shell`
   - If on any other distribution, install all dependencies you may need, as listed in the [Installation guide](https://github.com/MadLadSquad/UntitledImGuiFramework/wiki/Install-guide)
1. Run `user $ ./install.sh`
1. Wait for it to finish
1. Add the following line to `Framework/cmake/UImGuiHeader.cmake`: `add_compile_options(-g3 -O0 -finstrument-functions -fcf-protection=none)`
1. Apply changes similar to this patch to `Framework/cmake/CompileProject.cmake`:
   ```patch
   diff --git a/Framework/cmake/CompileProject.cmake b/Framework/cmake/CompileProject.cmake
   index f79592a..db6afb3 100644
   --- a/Framework/cmake/CompileProject.cmake
   +++ b/Framework/cmake/CompileProject.cmake
   @@ -18,7 +18,7 @@ else()
   endif()
   add_executable(${APP_TARGET} ${EXECUTABLE_SOURCES})
   endif()
   -
   +add_library(trace Source/trace.c)
   include(SetupTargetSettings)
   
   # ----------------------------------------------------------------------------------------------------------------------
   @@ -38,9 +38,9 @@ elseif (EMSCRIPTEN)
   endforeach()
   else ()
   target_link_libraries(UntitledImGuiFramework ${GLFW_LIBRARIES_T} ${GLEW_LIBRARIES_T} ${OPENGL_LIBRARIES_T} pthread
   -            ${YAML_CPP_LIBRARIES_T} ${FREETYPE_LIBRARIES} ${VULKAN_LIBRARIES_T} ${X11_LIBRARIES} dl util)
   -    target_link_libraries(${APP_LIB_TARGET} UntitledImGuiFramework pthread dl ${YAML_CPP_LIBRARIES_T} util)
   -    target_link_libraries(${APP_TARGET} UntitledImGuiFramework ${APP_LIB_TARGET} ${YAML_CPP_LIBRARIES_T} dl util)
   +            ${YAML_CPP_LIBRARIES_T} ${FREETYPE_LIBRARIES} ${VULKAN_LIBRARIES_T} ${X11_LIBRARIES} dl util trace)
   +    target_link_libraries(${APP_LIB_TARGET} UntitledImGuiFramework pthread dl ${YAML_CPP_LIBRARIES_T} util trace)
   +    target_link_libraries(${APP_TARGET} UntitledImGuiFramework ${APP_LIB_TARGET} ${YAML_CPP_LIBRARIES_T} dl util trace)
   
        if (APPLE)
        target_link_libraries(UntitledImGuiFramework "-framework Cocoa" "-framework IOKit" "-framework CoreFoundation"
   ```
1. Go to the `Projects` directory and clone the demo application: `git clone https://github.com/MadLadSquad/UImGuiDemo`
1. Go to `../UVKBuildTool/build` and run `./UVKBuildTool --generate ../../Projects/UImGuiDemo`
1. Go back to `../../Projecs/UImGuiDemo/`
1. Copy `<codetracer-directory>/src/native/trace.c` to `Source/`
1. Create a `build` folder and enter it
1. Run `cmake .. -DCMAKE_BUILD_TYPE_DEBUG`
1. Run `make -j <number of jobs>`
1. Get the path to the CodeTracer executable. If developing locally go to the CodeTracer source directory and type `which ct`
1. Add the path to the CodeTracer executable to your path
1. Run `ct record ./UImGuiDemo` and close the application after you're done recording
1. Replay using `ct replay ./UImGuiDemo`

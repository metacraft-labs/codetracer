## Environment variables

CodeTracer exposes a number of environment variables that you can use to override some of its behaviours:

for many of the flags, we expect "1" to enable them

1. `CODETRACER_ELECTRON_ARGS` - adds arguments for launching Electron. Useful for debugging production builds
1. `CODETRACER_WRAPPER_PID` - overrides the process ID of the `ct` CodeTracer wrapper
1. `CODETRACER_CALLTRACE_MODE` - changes the calltrace mode
1. `CODETRACER_RECORD_CORE` - this does nothing as it is only related to the unreleased system backend
1. `CODETRACER_SHELL_SOCKET` - this sets the socket path for sending events to the CI integration from `ct record`(or eventually `ct shell`)
1. `CODETRACER_SHELL_ADDRESS` - this sets the address for sending events to the CI integration from `ct record`(or eventually `ct shell`)
1. `CODETRACER_SHELL_EXPORT` - this enables export mode for `ct record` on: exporting the traces into zip files in the folder that is the value of this env variables; (similarly to the `ct record -e=<zippath>` option, but for all records while the variable is enabled). The trace archives try to use a globally unique id in their filenames, from `std/oids` in the nim stdlib: https://nim-lang.org/docs/oids.html
1. `CODETRACER_DEBUG_CURL` - if "1", print debug output for the raw objects sent with curl for the CI integration from `ct record`(or eventually `ct shell`)
1. `CODETRACER_DEBUG_CT_REMOTE` - if "1", print debug output(for now process command name and arguments) for the trace sharing code and commands that call `ct-remote`(desktopclient), e.g. `ct upload`, `ct download`, `ct login`, `ct set-default-org`

## CodeTracer Shell
These are generally not functional right now, since they affect CodeTracer Shell, which is currently not stable/in very prototypical state:

1. `CODETRACER_SHELL_BASH_LOG_FILE` - overrides the log file
1. `CODETRACER_SHELL_ID` - overrides the shell ID
1. `CODETRACER_SESSION_ID` - overrides the CodeTracer Shell session ID so that the current commands affect a previous shell session
1. `CODETRACER_SHELL_REPORT_FILE` - overrides the report file of CodeTracer Shell
1. `CODETRACER_SHELL_USE_SCRIPT` - ?
1. `CODETRACER_SHELL_RECORDS_OUTPUT` - ?
1. `CODETRACER_SHELL_CLEANUP_OUTPUT_FOLDER` - ?

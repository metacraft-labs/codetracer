CodeTracer exposes a number of environment variables that you can use to override some of its behaviours:

1. `CODETRACER_ELECTRON_ARGS` - adds arguments for launching Electron. Useful for debugging production builds
1. `CODETRACER_WRAPPER_PID` - overrides the process ID of the `ct` CodeTracer wrapper
1. `CODETRACER_CALLTRACE_MODE` - changes the calltrace mode
1. `CODETRACER_RECORD_CORE` - this does nothing as it is only related to the unreleased system backend

## CodeTracer Shell
These are generally not functional right now, since they affect CodeTracer Shell, which is currently not implemented:

1. `CODETRACER_SHELL_BASH_LOG_FILE` - overrides the log file
1. `CODETRACER_SHELL_ID` - overrides the shell ID
1. `CODETRACER_SESSION_ID` - overrides the CodeTracer Shell session ID so that the current commands affect a previous shell session
1. `CODETRACER_SHELL_REPORT_FILE` - overrides the report file of CodeTracer Shell
1. `CODETRACER_SHELL_USE_SCRIPT` - ?
1. `CODETRACER_SHELL_RECORDS_OUTPUT` - ?
1. `CODETRACER_SHELL_EXPORT` - ?
1. `CODETRACER_SHELL_CLEANUP_OUTPUT_FOLDER` - ?
1. `CODETRACER_SHELL_SOCKET` and `CODETRACER_SHELL_ADDRESS` - they override the socket location and address respectively
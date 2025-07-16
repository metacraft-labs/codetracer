## CLI

This page details some of the options, available to you through the `ct` CLI command.

### Usage

When you launch the CodeTracer GUI, it will offer you the option to also install the CodeTracer CLI. It provides convenient ways to create and load trace files from the command-line or to integrate CodeTracer with CI processes.

Run `ct --help` to see the full list of supported subcommands, but the most commonly used ones are the following:

`<application>` can be a source file or a project folder (depending on the language):

1. `ct run <application>` - Creates a recording and load it in CodeTracer with a single command.
1. `ct record <application>` - Creates a trace file that can be loaded later or shared.
1. `ct replay` - Launches the CodeTracer GUI with a previously recorded trace file. Common usages are:
   - `ct replay` - Opens a simple console-based dialog to choose what recording you want to replay.
   - `ct replay <program-name>` - Opens the last trace of an application.
   - `ct replay --id=<trace-id>` - Opens a trace by its trace id.
   - `ct replay --trace-folder=<trace-folder>` - Opens a trace by its trace folder.
1. `ct` - Launches the startup screen of the CodeTracer GUI.
1. `ct help`/`ct --help` - Gives you a help message.
1. `ct version`/`ct --version` - Returns the current version of CodeTracer.

Unlike other debuggers, where the debugger is attached to your application process, here you have to launch your application
through the CodeTracer CLI with commands like `ct run` or `ct record`(or through the user interface, which is documented in the next chapter).

Think of debugging your application with CodeTracer as recording a video and then replaying it in order to find
the information you need. This is why we use commands like `record` and `replay`.

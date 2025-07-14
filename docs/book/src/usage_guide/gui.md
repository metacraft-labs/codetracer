# Graphical User Interface (GUI)

The CodeTracer GUI is the primary tool for replaying and analyzing trace files. It provides a rich, interactive environment to inspect every detail of your program's execution.

You can launch the GUI in a few ways:
*   Run `ct` in your terminal to open the Startup Screen.
*   Run `ct replay` to choose a recent trace and open it in the Replay Interface.
*   Run `ct run <application>` to record a new trace and immediately open it for replay.

## Startup Screen

The Startup Screen is your entry point into the CodeTracer GUI. You can open it by running `ct` in your terminal.

From here, you can:
*   **View and open recent traces:** The main list shows traces you have recently recorded or opened. You can click on any trace to open it in the Replay Interface.
*   **Open a local trace:** Click the "Open local trace" button to open a trace file from your computer. This is useful for opening traces that are not in your recent list or for opening traces shared by others.
*   **Record a new trace:** The "Record new trace" button allows you to start a new recording session. This is currently supported for Noir projects. You will be prompted to select the root folder of your Noir project, and CodeTracer will handle the rest. Once the recording is complete, the new trace will open automatically.

## Replay Interface

The Replay Interface is where you will spend most of your time analyzing traces. It is composed of several panels, each providing a different view into your program's state.

Watch this video for a demonstration of the key features:

[![CodeTracer Replay Demo](https://img.youtube.com/vi/xZsJ55JVqmU/maxresdefault.jpg)](https://www.youtube.com/watch?v=xZsJ55JVqmU)

Here is a brief overview of the main components:

*   **Source Code Panel:** Displays your source code. The currently executing line is highlighted. You can click on any line to see the program's state at that point in time. You can also right-click to add tracepoints.
*   **Filesystem Panel:** Provides a tree-like view of the project's source code, allowing you to browse and open files.
*   **Calltrace Panel:** Shows the entire execution trace as a hierarchical list of function calls. You can navigate through the program's execution by jumping to any point in the call trace, and expand or collapse function calls to inspect the program flow.
*   **State Panel:** Displays the state of all local variables at the currently selected point in the execution. As you navigate through the code, this panel updates to reflect the current state.
*   **Scratchpad Panel:** Allows you to "watch" specific variables. You can add any variable to the scratchpad to keep an eye on its value as you move through the program's execution.
*   **Event Log:** A log of all significant events that occurred during the execution.
*   **Terminal Output Panel:** Shows the terminal output (stdout/stderr) of the traced program, updated to the current point in execution.

This interface allows you to move freely through your program's execution, making it easy to pinpoint the cause of bugs or understand complex behavior.

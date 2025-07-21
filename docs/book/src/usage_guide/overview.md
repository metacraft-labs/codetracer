# Overview

Welcome to the CodeTracer Usage Guide. This guide will help you understand how to use CodeTracer effectively to debug your applications.

## Core Concept: Record and Replay

Unlike traditional debuggers that attach to a running process, CodeTracer works by first **recording** your application's execution into a trace file. This trace captures everything that happens during the run.

Once a recording is made, you can **replay** it as many times as you need in the CodeTracer GUI. This allows you to inspect the application's state at any point in time, move forwards and backwards through the execution, and use powerful features like tracepoints without having to run your application again.

Think of it like recording a video of your program's execution that you can then analyze in detail.

## How to Use This Guide

This guide is structured to help you get started quickly and then dive deeper into the features that interest you.

*   **To learn about the different ways to interact with CodeTracer**, see the following sections:
    *   [**Graphical User Interface (GUI)**](./gui.md): Learn how to use the visual interface to replay traces, inspect state, and set tracepoints.
    *   [**Command-Line Interface (CLI)**](./cli.md): Discover how to record traces and manage trace files from your terminal.
*   **To learn about specific features**, see these sections:
    *   [**Tracepoints**](./tracepoints.md): A deep dive into using tracepoints for advanced debugging scenarios.
*   **For advanced use cases**, explore these topics:
    *   [**CodeTracer Shell**](./codetracer_shell.md): For integrating CodeTracer with complex or custom build systems.
*   **Getting started section**, Each programming languages has it's own rules when recording and replaying program, see how to get stared using the following languages:
    *   [**Noir**](./getting_started/noir.md)
    *   [**Stylus**](./getting_started/stylus.md)
    *   [**WASM**](./getting_started/wasm.md)
    *   [**Ruby**](./getting_started/euby.md)
    
    

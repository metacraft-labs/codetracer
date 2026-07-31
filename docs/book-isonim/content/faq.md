---
title: FAQ
description: Answers to common questions about CodeTracer — what it is, which languages it supports, recording and replaying traces, tracepoints, and installation.
hidden: true
---
# FAQ

Answers to common questions about CodeTracer. Can't find what you need? [Reach out to support](/support).

:::faq
:::q title="What is CodeTracer?"
CodeTracer is a user-friendly time-traveling debugger. It records a program's execution into a shareable, self-contained trace file that you can replay — stepping forward and backward to inspect the state of memory and variables at any point.
:::q title="Which languages does CodeTracer support?"
CodeTracer can record and replay programs written in Noir, Stylus, WASM, Ruby and Python. See the Getting Started guides for language-specific instructions.
:::q title="How do I record and replay a trace?"
Use the command-line interface: `ct record <program>` produces a trace and `ct replay` opens it in the GUI. The Usage Guide covers the CLI and the replay interface in detail.
:::q title="What are tracepoints?"
Tracepoints let you log expressions at specific lines across the entire recorded execution at once, without re-running the program. See the Tracepoints page in the Usage Guide.
:::q title="How do I install CodeTracer?"
On Linux and macOS you can install the latest binaries with a single command, or build from source. Full steps are on the Installation page.
:::

## Popular articles

:::cards variant="compact"
:::card title="Installation" href="/getting_started/installation"
Getting Started
:::card title="Graphical interface" href="/usage_guide/gui"
Usage Guide
:::card title="Overview" href="/getting_started"
Getting Started
:::card title="Environment variables" href="/reference/environment_variables"
Reference
:::card title="Stylus" href="/getting_started/stylus"
Getting Started
:::card title="Noir" href="/getting_started/noir"
Getting Started
:::

## Still have questions?

Browse the documentation from the navigation, or [reach out to our support team](/support) and we'll help you out.

<!-- This page's structure feels really off, please help me rewrite it -->

# Intro to usage guide

CodeTracer is a semi-portable piece of technology, so its usage varies, the following subpages explain how you can
interact with it through different interfaces, as well as, how to use its signature features:

- [CLI](https://dev-docs.codetracer.com/Introduction/UsageGuide/CLI)
- [GUI](https://dev-docs.codetracer.com/Introduction/UsageGuide/BasicGUI)
- [Tracepoints](https://dev-docs.codetracer.com/Introduction/UsageGuide/Tracepoints)
- [CodeTracer Shell](https://dev-docs.codetracer.com/Introduction/UsageGuide/CodetracerShell)
- [Building C/C++ applications manually](https://dev-docs.codetracer.com/Introduction/UsageGuide/ManualBuilding)

## Frontends

CodeTracer currently only has a GUI frontend, though some interactions, like recording and replaying applications are
activated through the CLI. For example, one can launch `ct replay` and the GUI will launch, where you will do all your
work after that initial start from the CLI

The GUI frontend is implemented using web technologies. When running as a desktop application, it uses Electron in order to integrate with
your host operating system. You can also use CodeTracer in a web browser.

> [!NOTE]
> Running CodeTracer in your web browser is not a currently released feature, although we have a working version internally

There are plans for an additional future frontend, such as a REPL or TUI frontend.

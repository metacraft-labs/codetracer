# Reprobuild HCR In CodeTracer Fixture

This fixture is intentionally shaped for the full Reprobuild HCR in
CodeTracer gate, not the older same-process direct-patch prototype.

The accepted test path is:

- Reprobuild builds the initial native target with HCR-required compiler
  flags and build graph metadata.
- CodeTracer launches the target under MCR recording from process start.
- The edit driver replaces `src/patchable.c` with generation 1 through a
  normal filesystem write.
- The production Reprobuild HCR coordinator rebuilds the changed translation
  unit and delivers a direct patch to the in-process agent.
- CodeTracer DAP validates old and new source generations in live recording
  and replay.

The fixture files deliberately avoid any in-process shortcut to the patching
layer. The Rust gate scans this directory for those shortcuts before running.

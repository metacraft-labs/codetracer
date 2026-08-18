## A standalone `ct agent …` entry point, for suites that must observe the
## command as a **process** rather than as a call.
##
## The agentic-coding suites assert that `ct agent evidence` writes the RPC
## file a running CodeTracer picks up, which is a property of a separate
## process with its own environment — an in-process call shares this test's
## environment and cannot show it.  Linking the whole `ct` binary is the
## alternative, and the ViewModel lane does not build one
## (`just vm-test-prereqs` stops at the tailwind extract).
##
## It lives in the repository rather than being generated into a temporary
## directory because `src/ct/agent_cli.nim` reaches `nim-agents` and
## `nim-everywhere` through `config.nims`, which Nim reads from the compiled
## file's own project directory — a generated file outside the tree gets none
## of those paths and fails to import.
##
## Not named `*_test.nim`, so the ViewModel lanes' globs do not try to run it.

import std/os

import ../../../../ct/agent_cli

quit(runAgentCli(commandLineParams()))

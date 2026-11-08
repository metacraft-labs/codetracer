## Trace Static Block Execution (CTFS-M-StaticBlockTrace) — and the
## constant initializer, which the compiler traces at the same entry point.
##
## Sibling of `trace_macro.nim` (M11), and like it a call into the shared
## ViewModel (`viewmodel/viewmodels/nim_tracing_vm`): the offer (a `static:`
## block, a `static(expr)`, a `const` declaration), the line the compiler
## matches (a block's first statement), the request and its failures are
## decided there for every front-end. The language server forwards
## `nim/traceStaticBlock` to nimsuggest's `tracestatic`, which writes a `.ct`
## under the nimcache; `trace_macro.sendNimTrace` opens it in a new session
## tab through the same `CODETRACER::load-trace-file` pathway.

import
  ui_imports,
  trace_macro

proc traceStaticBlock*(data: Data; filePath: cstring; line, column: int;
                       lines: seq[string]) =
  ## "Trace Static Block Execution" at the editor's 1-based `line:column`.
  startNimTrace(data, ntaStaticBlock, filePath, line, column, lines)

proc traceConstant*(data: Data; filePath: cstring; line, column: int;
                    lines: seq[string]) =
  ## "Trace Constant Initializer" at the editor's 1-based `line:column`.
  startNimTrace(data, ntaConstant, filePath, line, column, lines)

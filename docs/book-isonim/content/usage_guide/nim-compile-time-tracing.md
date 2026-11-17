---
title: Tracing Nim compile-time code
order: 13
---
# Tracing Nim's compile-time code

CodeTracer records what the Nim compiler runs at compile time — a macro's
expansion, a `static:` block, a constant's initializer, a NimScript file — and
opens the recording beside the one you are looking at, in a new session tab.

## Tracing a macro

Put the caret on a macro call — click it, or move to it with the keys — and
press **Ctrl+K T M** (*Trace macro at cursor*; the shortcut follows your
keymap, and the command palette and the editor's context menu list it too).

<!-- capture scenario=docs/terminal-trace-macro capture=caret-on-the-macro-call -->
```text
▕≡▏  ↶  ↷  ⇣  ↓  ⇡  ↑  ⏴  ⏵  ⏮   ■                          ▕⌕ Navigate to file or run a :command  ▏  +   [ct] | trace: nim-start | tick: 0 / 27 [0.0%] [PAUSED]
 Files   VCS   Test▏ nim-project/tracing.nim                           the recording's source ▏ Variables   Scratchpad        ▏ Call Trace   Agent Activity     
▼ source folders   ▏  1     import std/macros                                                 ▏L   empty at this position     ▏                                 
  ▼ nim-project    ▏  2                                                                       ▏A   no per-frame argument surfa▏                                 
      build.nims   ▏  3     macro twice(body: untyped): untyped =                             ▏G   store.locals.globals is fil▏                                 
      tracing.nim  ▏  4       result = newStmtList(body, body)                                ▏R   no return-value surface in ▏                                 
                   ▏  5                                                                       ▏X   registers are projected onl▏                                 
                   ▏  6     proc compute(n: int): int =                                       ▏W   + Add watch expression…    ▏                                 
                   ▏  7       result = 0                                                      ▏                               ▏                                 
                   ▏  8       for i in 1..n:                                                  ▏                               ▏                                 
                   ▏  9         result += i * i                                               ▏                               ▏                                 
                   ▏ 10                                                                       ▏                               ▏                                 
                   ▏ 11     const squares = compute(3)                                        ▏                               ▏                                 
                   ▏ 12                                                                       ▏                               ▏                                 
                   ▏ 13     const                                                             ▏                               ▏                                 
                   ▏ 14       limit = 4                                                       ▏                               ▏                                 
                   ▏ 15       cubes = compute(limit)                                          ▏                               ▏                                 
                   ▏ 16                                                                       ▏                               ▏                                 
                   ▏ 17     static:                                                           ▏                               ▏                                 
                   ▏ 18  ▸    var acc = 0                                                     ▏                               ▏                                 
                   ▏ 19       for i in 0..<limit:                                             ▏ Event Log   Terminal Output                                     
                   ▏ 20         acc += i                                                      ▏    tick    # kind output                                        
                   ▏ 21       echo "acc=", acc                                                ▏      27    0 out  acc=6                                         
                   ▏ 22                                                                       ▏                                                                 
                   ▏ 23     echo "after"                                                      ▏                                                                 
                   ▏ 24     let folded = static(compute(5))                                   ▏                                                                 
                   ▏ 25                                                                       ▏                                                                 
                   ▏ 26     twice:                                                            ▏                                                                 
                   ▏ 27       echo squares                                                    ▏                                                                 
                   ▏                                                                          ▏                                                                 
                   ▏                                                                          ▏                                                                 
                   ▏                                                                          ▏                                                                 
                   ▏                                                                          ▏                                                                 
                   ▏                                                                          ▏                                                                 
                   ▏                                                                          ▏                                                                 
                   ▏                                                                          ▏                                                                 
                   ▏                                                                          ▏                                                                 
                   ▏                                                                          ▏                                                                 
                   ▏                                                                          ▏                                                                 
################################################################################################################################################################
```
<!-- /capture -->

The compiler expands the macro under the tracer, and the recording opens in a
new session tab, stopped in the macro's body. The tab you started from stays
open beside it.

<!-- capture scenario=docs/terminal-trace-macro capture=the-macro-traced-in-a-new-tab -->
```text
▕≡▏  ↶  ↷  ⇣  ↓  ⇡  ↑  ⏴  ⏵  ⏮   ■  ▕⌕ Navigate to file or run a :command  ▏  nim-start ×   tracing-macro ×    +  [ct] | trace: tracing-macro | tick: 0 [PAUSED]
 Files   VCS   Test▏ nim-project/tracing.nim                           the recording's source ▏ Variables   Scratchpad        ▏ Call Trace   Agent Activity     
▼ source folders   ▏  1     import std/macros                                                 ▏L   empty at this position     ▏                                 
  ▼ nim-project    ▏  2                                                                       ▏A   no per-frame argument surfa▏                                 
      build.nims   ▏  3     macro twice(body: untyped): untyped =                             ▏G   store.locals.globals is fil▏                                 
      tracing.nim  ▏  4  ▸    result = newStmtList(body, body)                                ▏R   no return-value surface in ▏                                 
                   ▏  5                                                                       ▏X   registers are projected onl▏                                 
                   ▏  6     proc compute(n: int): int =                                       ▏W   + Add watch expression…    ▏                                 
                   ▏  7       result = 0                                                      ▏                               ▏                                 
                   ▏  8       for i in 1..n:                                                  ▏                               ▏                                 
                   ▏  9         result += i * i                                               ▏                               ▏                                 
                   ▏ 10                                                                       ▏                               ▏                                 
                   ▏ 11     const squares = compute(3)                                        ▏                               ▏                                 
                   ▏ 12                                                                       ▏                               ▏                                 
                   ▏ 13     const                                                             ▏                               ▏                                 
                   ▏ 14       limit = 4                                                       ▏                               ▏                                 
                   ▏ 15       cubes = compute(limit)                                          ▏                               ▏                                 
                   ▏ 16                                                                       ▏                               ▏                                 
                   ▏ 17     static:                                                           ▏                               ▏                                 
                   ▏ 18       var acc = 0                                                     ▏                               ▏                                 
                   ▏ 19       for i in 0..<limit:                                             ▏ Event Log   Terminal Output                                     
                   ▏ 20         acc += i                                                      ▏    tick    # kind output                                        
                   ▏ 21       echo "acc=", acc                                                ▏no recorded events                                               
                   ▏ 22                                                                       ▏                                                                 
                   ▏ 23     echo "after"                                                      ▏                                                                 
                   ▏ 24     let folded = static(compute(5))                                   ▏                                                                 
                   ▏ 25                                                                       ▏                                                                 
                   ▏ 26     twice:                                                            ▏                                                                 
                   ▏ 27       echo squares                                                    ▏                                                                 
                   ▏                                                                          ▏                                                                 
                   ▏                                                                          ▏                                                                 
                   ▏                                                                          ▏                                                                 
                   ▏                                                                          ▏                                                                 
                   ▏                                                                          ▏                                                                 
                   ▏                                                                          ▏                                                                 
                   ▏                                                                          ▏                                                                 
                   ▏                                                                          ▏                                                                 
                   ▏                                                                          ▏                                                                 
                   ▏                                                                          ▏                                                                 
################################################################################################################################################################
```
<!-- /capture -->

The same actions trace a `static:` block (**Ctrl+K T S**), a constant's
initializer (**Ctrl+K T C**) and a NimScript file (**Ctrl+K T E**). They need
CodeTracer's trace-enabled `nimsuggest` and Nim compiler
(`CODETRACER_NIMSUGGEST`, `CODETRACER_NIM`); without them the action says what
is missing and starts nothing.

The pictures on this page are made by the scenario
`docs/terminal-trace-macro` in CodeTracer's repository, which also checks
what they show.

# Nim

We have partial support for the Nim backend, with it being somewhat behind in features compared to C, but ahead,
compared to C++.

The Nim backend only supports Nim 1 as of today, but there are plans to add support for Nim 2.


Some additional future goals that have been announced in the Nim forum are:

* First-class support for macro-generated code - macro generated code should be indistinguishable from regular code. You can expand it layer by layer, set breakpoints and tracepoints anywhere within it, and step through it in all the familiar ways. (or at least part of those)
* Precise debug info - you should be able to set breakpoints and tracepoints at the level of individual sub-expressions and you can switch between debugging Nim, C or assembly code at any time.
* Compile-time debugging - with few clicks in your text editor, you should be able to trace the execution of the Nim VM itself.

> [!NOTE]
> For now we're focused on the beta and initial releases of the RR backend though, and on initial releases for some of the language supports.
> This means the initial support for Nim would be focused on the same features as the other languages: stepping, tracepoints, event log, calltrace, omniscience, state, history. We do hope we'll be able to continue with some of the more advanced goals afterwards.


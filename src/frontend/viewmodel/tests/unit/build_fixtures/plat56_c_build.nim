## build_fixtures/plat56_c_build.nim — PLAT-56: the real C project whose
## builds every Build Output suite runs, on every front-end.
##
## A library the suites import, not a suite. The SAME files the desktop's
## Electron capture writes (`src/tests/gui/tests/build/
## plat56-build-output-capture.spec.ts`, byte for byte), built by the real
## `gcc` with its diagnostics in colour (`-fdiagnostics-color=always`), so the
## output carries real ANSI SGR runs and `ESC [ K` erases:
##
##   * `src/main.c` FAILS (exit 1): two errors, a warning and a note, each a
##     `file:line:col:` line in its severity's colour, the quoted source and
##     its caret lines between them, and two "In function" lines that name a
##     file and no line;
##   * `src/ok.c` PASSES (exit 0) with one coloured warning.
##
## `Plat56FailTranscript` / `Plat56PassTranscript` are those builds' stderr as
## the pipe received it — `gcc (GCC) 14.3.0`, recorded 2026-10-27 — which the
## suites that cannot run a process (the JavaScript lane) read, and which the
## native suites assert the real compiler still writes.
##
## NO MOCK: a real project on a real filesystem, built by the real `gcc`.

when not defined(js):
  import std/[os, tempfiles]

const
  Plat56MainC* = """#include <stdio.h>

int twice(int v) {
    int unused = 1;
    return v * 2
}

int main(void) {
    printf("%d\n", twice(21));
    return undefined_name;
}
"""
  Plat56OkC* = """#include <stdio.h>

int main(void) {
    int spare = 0;
    printf("ok\n");
    return 0;
}
"""
  Plat56FailCommand* = "gcc -Wall -fdiagnostics-color=always -c src/main.c -o /dev/null"
  Plat56PassCommand* = "gcc -Wall -fdiagnostics-color=always -c src/ok.c -o /dev/null"

  Plat56FailLocated*: array[4, tuple[severity, path: string; line, col: int]] = [
    ("error", "src/main.c", 5, 17), ("warning", "src/main.c", 4, 9),
    ("error", "src/main.c", 10, 12), ("info", "src/main.c", 10, 12)]
    ## The failing build's lines that name a location, in order: what every
    ## front-end draws as a jump target in its severity's colour.

  Plat56FailTranscript* = @[
    "\e[01m\e[Ksrc/main.c:\e[m\e[K In function ‘\e[01m\e[Ktwice\e[m\e[K’:",
    "\e[01m\e[Ksrc/main.c:5:17:\e[m\e[K \e[01;31m\e[Kerror: \e[m\e[Kexpected ‘\e[01m\e[K;\e[m\e[K’ before ‘\e[01m\e[K}\e[m\e[K’ token",
    "    5 |     return v * 2",
    "      |                 \e[01;31m\e[K^\e[m\e[K",
    "      |                 \e[32m\e[K;\e[m\e[K",
    "    6 | \e[32m\e[K}\e[m\e[K",
    "      | \e[32m\e[K~\e[m\e[K                ",
    "\e[01m\e[Ksrc/main.c:4:9:\e[m\e[K \e[01;35m\e[Kwarning: \e[m\e[Kunused variable ‘\e[01m\e[Kunused\e[m\e[K’ [\e[01;35m\e[K-Wunused-variable\e[m\e[K]",
    "    4 |     int \e[01;35m\e[Kunused\e[m\e[K = 1;",
    "      |         \e[01;35m\e[K^~~~~~\e[m\e[K",
    "\e[01m\e[Ksrc/main.c:\e[m\e[K In function ‘\e[01m\e[Kmain\e[m\e[K’:",
    "\e[01m\e[Ksrc/main.c:10:12:\e[m\e[K \e[01;31m\e[Kerror: \e[m\e[K‘\e[01m\e[Kundefined_name\e[m\e[K’ undeclared (first use in this function)",
    "   10 |     return \e[01;31m\e[Kundefined_name\e[m\e[K;",
    "      |            \e[01;31m\e[K^~~~~~~~~~~~~~\e[m\e[K",
    "\e[01m\e[Ksrc/main.c:10:12:\e[m\e[K \e[01;36m\e[Knote: \e[m\e[Keach undeclared identifier is reported only once for each function it appears in"]
    ## `Plat56FailCommand`'s stderr, line by line (exit 1).
  Plat56PassTranscript* = @[
    "\e[01m\e[Ksrc/ok.c:\e[m\e[K In function ‘\e[01m\e[Kmain\e[m\e[K’:",
    "\e[01m\e[Ksrc/ok.c:4:9:\e[m\e[K \e[01;35m\e[Kwarning: \e[m\e[Kunused variable ‘\e[01m\e[Kspare\e[m\e[K’ [\e[01;35m\e[K-Wunused-variable\e[m\e[K]",
    "    4 |     int \e[01;35m\e[Kspare\e[m\e[K = 0;",
    "      |         \e[01;35m\e[K^~~~~\e[m\e[K"]
    ## `Plat56PassCommand`'s stderr, line by line (exit 0).

when not defined(js):
  proc writePlat56Project*(prefix = "ct-plat56-project-"): string =
    ## A fresh copy of the project in a temporary directory; its path.
    result = createTempDir(prefix, "")
    createDir(result / "src")
    writeFile(result / "src" / "main.c", Plat56MainC)
    writeFile(result / "src" / "ok.c", Plat56OkC)

"""loop_heavy_writes — a dashboard loop that writes straight from `main`.

The shape of the program that made a stop in `main` take about thirty seconds
to reach (codetracer-pm issue 2026-10-06, "a stop inside a loop-heavy Python
function takes thirty seconds"): `main` runs a 30-iteration loop, and each
iteration builds a few kilobytes of escape sequences through calls to small
helpers and writes them with `w = sys.stdout.write`, so every write's stop is
a line of `main` and the flow of `main` walks hundreds of steps.

Deterministic: no clock, no randomness, no environment.
"""

import sys

CSI = "\x1b["
COLS = 80
ROWS = 24
FRAMES = 30
TASKS = ["compile", "link", "test", "package", "upload", "verify"]


def at(row, col):
    return CSI + str(row) + ";" + str(col) + "H"


def frame_box(title):
    out = [CSI + "0m", at(1, 1), "+" + "-" * (COLS - 2) + "+"]
    for r in range(2, ROWS - 1):
        out.append(at(r, 1) + "|" + at(r, COLS) + "|")
    out.append(at(ROWS - 1, 1) + "+" + "-" * (COLS - 2) + "+")
    out.append(at(1, 3) + CSI + "1;36m " + title + " " + CSI + "0m")
    return "".join(out)


def meter(done, total, width):
    filled = done * width // total
    return (CSI + "42m" + " " * filled + CSI + "0m" +
            CSI + "100m" + " " * (width - filled) + CSI + "0m")


def table(frame):
    out = [at(3, 3) + CSI + "1;4m" + "TASK      STATE      PROGRESS" + CSI +
           "0m"]
    for i, name in enumerate(TASKS):
        progress = min(100, max(0, (frame - i * 3) * 10))
        state = ("done" if progress >= 100 else
                 "running" if progress > 0 else "waiting")
        out.append(at(5 + i, 3) + CSI + "K" + name.ljust(10) +
                   state.ljust(11) + str(progress).rjust(3) + "%")
    return "".join(out)


def main():
    w = sys.stdout.write
    w(CSI + "?1049h" + CSI + "?25l" + CSI + "2J")
    w(frame_box("dashboard"))
    for frame in range(FRAMES):
        if frame == FRAMES // 2:
            w(CSI + "2J" + frame_box("dashboard (second half)"))
        done = min(FRAMES, frame + 1)
        w(table(frame) +
          at(ROWS - 3, 3) + meter(done, FRAMES, 40) + " " +
          str(done).rjust(2) + "/" + str(FRAMES) +
          at(12, 3) + CSI + "K" +
          "tick " + str(frame))
    w(CSI + "?25h" + CSI + "?1049l")
    w("dashboard finished: " + str(len(TASKS)) + " tasks, " +
      str(FRAMES) + " frames\n")


main()

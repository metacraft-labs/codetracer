#!/usr/bin/env python3
"""terminal_screen — a full-screen terminal program: a process dashboard.

It drives the terminal as a SCREEN, the way `top`, `htop` or a curses
application does: it switches to the alternate screen, hides the cursor,
clears it, draws a framed panel by absolute cursor addressing, redraws a
table and a coloured meter in place frame after frame (erase-in-line,
insert / delete line, a scroll region), clears the screen once in the
middle, then returns to the main screen and prints one summary line — so its
output is meaningless as a list of lines and is reconstructed as a screen by
the Terminal Output pane (Terminal-Output-Pane.md §3).

Each frame is ONE write, flushed, through one helper (`emit`) as a
curses-style program's output layer does, so the recording has one write per
frame and the pane's built-in scrubber steps through them.

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
    out = [CSI + "0m", at(1, 1), "┌" + "─" * (COLS - 2) + "┐"]
    for r in range(2, ROWS - 1):
        out.append(at(r, 1) + "│" + at(r, COLS) + "│")
    out.append(at(ROWS - 1, 1) + "└" + "─" * (COLS - 2) + "┘")
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
        colour = {"done": "32", "running": "33", "waiting": "90"}[state]
        out.append(at(5 + i, 3) + CSI + "K" + name.ljust(10) +
                   CSI + colour + "m" + state.ljust(11) + CSI + "0m" +
                   str(progress).rjust(3) + "%")
        out.append(at(5 + i, COLS))
        out.append("│")
    return "".join(out)


def log_region(frame):
    # A scroll region for the log lines (rows 14..20): each new line is
    # written at the region's bottom and scrolls the older ones up.
    out = [CSI + "14;20r", at(20, 3),
           "\n" if frame > 0 else "",
           at(20, 3) + CSI + "K" + CSI + "2m" + "frame " + str(frame) +
           ": " + TASKS[frame % len(TASKS)] + CSI + "0m",
           CSI + "r"]
    return "".join(out)


def emit(text):
    sys.stdout.write(text)
    sys.stdout.flush()


def main():
    w = emit
    w(CSI + "?1049h" + CSI + "?25l" + CSI + "2J")
    w(frame_box("dashboard"))
    for frame in range(FRAMES):
        if frame == FRAMES // 2:
            # A full clear mid-run: the scrubber marks it.
            w(CSI + "2J" + frame_box("dashboard (second half)"))
        done = min(FRAMES, frame + 1)
        w(table(frame) + log_region(frame) +
          at(ROWS - 3, 3) + meter(done, FRAMES, 40) + " " +
          str(done).rjust(2) + "/" + str(FRAMES) +
          # Insert and delete a line inside the frame, then put it back.
          at(12, 3) + CSI + "L" + CSI + "M" + at(12, 3) + CSI + "K" +
          "tick " + str(frame))
    w(CSI + "?25h" + CSI + "?1049l")
    w("dashboard finished: " + str(len(TASKS)) + " tasks, " +
      str(FRAMES) + " frames\n")


main()

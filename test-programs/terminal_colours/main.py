#!/usr/bin/env python3
"""terminal_colours — a program that writes coloured lines to its terminal.

The Terminal Output pane draws what a recorded program wrote, in the colours
and weights it wrote it in, on the desktop, the terminal and the GPUI window
from one shared model. A test of that needs a recording whose output carries
ANSI SGR attributes of every kind the model decodes, a line written by more
than one write, a write that ends more than one line, a tab and an empty
line — and more lines than any pane shows, so a scrollbar scrubber over the
WHOLE output can be told apart from one over the lines on screen.

Deterministic: no clock, no randomness, no environment.
"""

import sys

ESC = "\x1b["
ROWS = 120


def paint(text, *codes):
    return ESC + ";".join(str(c) for c in codes) + "m" + text + ESC + "0m"


def banner():
    print(paint("red", 31) + " plain " + paint("bold green", 1, 32))
    sys.stdout.write("two writes, ")
    sys.stdout.write(paint("blue ground", 44) + "\n")
    print(paint("italic", 3) + " " + paint("underline", 4) + " " +
          paint("reverse", 7) + " " + paint("bright magenta", 95))
    print(paint("256-colour orange", 38, 5, 208) + " " +
          paint("truecolor teal", 38, 2, 0, 128, 128) + " " +
          paint("on yellow", 30, 43))
    print("col\tumns\tby\ttab")
    print("")
    sys.stdout.write("one write\nends two lines\n")


def row(i):
    colour = 31 + (i % 7)
    return "row " + str(i).rjust(3) + " " + paint("#" * (1 + i % 20), colour)


def main():
    banner()
    for i in range(ROWS):
        print(row(i))
    print(paint("done", 1, 92))


main()

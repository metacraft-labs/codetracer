#!/usr/bin/env python3
"""deep_calls: PLAT-70 Part I's fit-or-scroll fixture.

Horizontal-Overflow.md section 5.5.5: the Call Trace's
rows are cut with an ellipsis while every row's indent
and callee name fit the pane, and the pane scrolls
sideways only when a call is nested so deep that its
indent and name do not. This program nests one call
40 levels deep; the deepest is named
reached_the_bottom, so a reader of the scrolled pane
can find its whole name. Every argument is short.
"""


def descend(level):
    if level == 0:
        return reached_the_bottom(level)
    return descend(level - 1) + 1


def reached_the_bottom(level):
    return level


def main():
    return descend(40)


if __name__ == "__main__":
    print(main())

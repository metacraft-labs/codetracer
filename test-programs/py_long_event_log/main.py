#!/usr/bin/env python3
"""py_long_event_log: an Event Log longer than any pane shows at once.

Writes EVENT_COUNT numbered lines to stdout, one write event each, so the
Event Log holds more rows than its viewport and has to be scrolled to reach
the end. The first and last lines are marked so a test can tell it reached
both ends of the log: "event 001 [FIRST]" and "event 080 [LAST]".
"""

EVENT_COUNT = 80


def label(n):
    if n == 1:
        return " [FIRST]"
    if n == EVENT_COUNT:
        return " [LAST]"
    return ""


def main():
    for n in range(1, EVENT_COUNT + 1):
        print(f"event {n:03d}{label(n)}", flush=True)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Queries over `build_error_nav_probe.mjs`'s report.

Kept out of the shell gate because the interesting questions are comparisons
between two structures -- "is the caret where the pane says the error is" --
and expressing those in bash produces the kind of quoting that fails open.
Every predicate here prints `True` or `False` and nothing else, so a
mistyped query cannot look like a pass.
"""

import json
import re
import sys


def load(path):
    with open(path) as handle:
        return json.load(handle)


def parse_location(text):
    """`"6:41"` -> `(6, 41)`. `(-1, -1)` when it is not a location at all."""
    if not text:
        return (-1, -1)
    match = re.match(r"^\s*(\d+)\s*:\s*(\d+)\s*$", text)
    if not match:
        return (-1, -1)
    return (int(match.group(1)), int(match.group(2)))


def error_rows(report):
    return [r for r in report.get("problemRows", []) if r.get("severityError")]


def warning_rows(report):
    return [r for r in report.get("problemRows", []) if not r.get("severityError")]


def first_error(report):
    rows = error_rows(report)
    return rows[0] if rows else None


def caret(report, key):
    value = report.get(key)
    return value if isinstance(value, dict) else None


def main():
    path = sys.argv[1]
    query = sys.argv[2]
    args = sys.argv[3:]
    report = load(path)

    if query == "count":
        print(len(report.get(args[0], [])))
        return
    if query == "count-errors":
        print(len(error_rows(report)))
        return
    if query == "count-warnings":
        print(len(warning_rows(report)))
        return

    if query == "first-error-location":
        row = first_error(report)
        if not row:
            print("(no error row)")
            return
        print("%s %s" % (row.get("path", ""), row.get("location", "")))
        return

    if query == "first-error-has-position":
        # A path, a positive line AND a positive column. The corrupted-row
        # failure this area has already produced looks like a match with
        # `col = -1` and a path that never resolves, so all three are required
        # rather than "the row exists".
        row = first_error(report)
        if not row:
            print("False")
            return
        line, col = parse_location(row.get("location", ""))
        print(str(bool(row.get("path")) and line > 0 and col > 0))
        return

    if query in ("caret-before", "caret-after", "caret-uri"):
        key = "caretBefore" if query == "caret-before" else "caretAfterNext"
        pos = caret(report, key)
        if not pos:
            print("(no caret)")
            return
        if query == "caret-uri":
            print(pos.get("uri", ""))
        else:
            print("%s:%s" % (pos.get("line"), pos.get("col")))
        return

    if query == "caret-moved":
        before = caret(report, "caretBefore")
        after = caret(report, "caretAfterNext")
        if not before or not after:
            print("False")
            return
        print(str(
            (before.get("line"), before.get("col"), before.get("uri")) !=
            (after.get("line"), after.get("col"), after.get("uri"))))
        return

    if query == "caret-matches-diagnostic":
        row = first_error(report)
        after = caret(report, "caretAfterNext")
        if not row or not after:
            print("False")
            return
        line, col = parse_location(row.get("location", ""))
        if line <= 0 or col <= 0:
            # An unparseable location must not be able to "match" a caret.
            print("False")
            return
        print(str(after.get("line") == line and after.get("col") == col))
        return

    if query == "opened-right-file":
        # Monaco's model URI is an opaque id (`/4`), not the source path, so
        # the file is established by the tab the jump opened rather than by
        # string-matching a path that is not there. The claim is therefore the
        # weaker, true one: navigating opened an editor that was not the one
        # the caret started in.
        before = caret(report, "caretBefore")
        after = caret(report, "caretAfterNext")
        if not before or not after:
            print("False")
            return
        print(str(
            after.get("uri") != before.get("uri") and
            after.get("editorCount", 0) > before.get("editorCount", 0)))
        return

    if query == "caret-before-was-editor":
        before = caret(report, "caretBefore")
        print(str(bool(before) and bool(before.get("hasFocus"))))
        return

    if query == "wrap-announced":
        seen = [report.get("statusAfterNext", ""), report.get("statusAfterWrap", "")]
        print(str(any("wrapped" in (s or "") for s in seen)))
        return

    if query == "selection-is-visible":
        # The selected row must be VISUALLY distinct from the unselected ones.
        #
        # Compared against the other painted rows rather than against a
        # hardcoded colour: naming the expected background would be a check
        # that requires the current theme and could never catch it changing
        # wrongly, and the product ships more than one theme.
        rows = report.get("problemRows", [])
        selected = [r for r in rows if r.get("selected")]
        others = [r for r in rows if not r.get("selected")]
        if len(selected) != 1 or not others:
            # Exactly one selected row, and something to compare it with.
            print("Vacuous")
            return
        mine = (selected[0].get("background"), selected[0].get("boxShadow"))
        print(str(any(
            (o.get("background"), o.get("boxShadow")) != mine for o in others)))
        return

    if query == "selected-row-count":
        print(len([r for r in report.get("problemRows", []) if r.get("selected")]))
        return

    if query == "first-row-is-warning":
        rows = report.get("problemRows", [])
        print(str(bool(rows) and not rows[0].get("severityError")))
        return

    if query == "skipped-the-warnings":
        # EMT-D22.1: navigation ranges over ERRORS ONLY.
        #
        # A separate claim from "the caret matches the error", and it needs to
        # be: in this fixture the first painted row is a warning, so a
        # navigator that ignored severity would land somewhere plausible on a
        # real file at a real line, and only this check would notice. The
        # caret must NOT be on any warning row.
        after = caret(report, "caretAfterNext")
        warnings = warning_rows(report)
        if not warnings:
            # Distinguished from False on purpose: "there were no warnings to
            # skip" is a statement about the fixture, and reporting it as "the
            # caret landed on a warning" would attribute an instrument failure
            # to the product.
            print("Vacuous")
            return
        if not after:
            print("False")
            return
        for row in warnings:
            line, col = parse_location(row.get("location", ""))
            if line > 0 and after.get("line") == line and after.get("col") == col:
                print("False")
                return
        print("True")
        return

    if query == "menu-item-shortcut":
        for item in report.get("menuItems", []):
            if item.get("label") == args[0]:
                print(item.get("shortcut", ""))
                return
        print("(no such menu item)")
        return

    if query == "menu-item-geometry":
        # Real on-screen geometry: a positive box, inside the viewport, not
        # hidden. This is what catches the failure mode this gate exists for --
        # an element parked at x = -9999, or `display: none` -- and it is a
        # different question from whether something is drawn ON TOP of it.
        for item in report.get("menuItems", []):
            if item.get("label") == args[0]:
                print(str(
                    item.get("width", 0) > 0 and
                    item.get("x", -1) >= 0 and
                    item.get("y", -1) >= 0))
                return
        print("False")
        return

    if query == "menu-occlusion-matches-control":
        # WHETHER THIS ROW IS OCCLUDED, COMPARED WITH A ROW THAT PREDATES THIS
        # FEATURE.
        #
        # The in-page menu on the web arm renders underneath both
        # `#auto-hide-backdrop` and the filesystem tree, so every menu row
        # loses a hit test -- `Rebuild/Re-record file` exactly as much as the
        # two rows added here. That is a real z-order defect and it is not this
        # feature's; asserting a bare hit test would fail for someone else's
        # reason, and dropping the check would lose the ability to see a row
        # that really was invisible.
        #
        # So the claim is comparative: these rows are as visible as the control
        # row. It cannot pass vacuously -- the control must be present, and is
        # asserted separately.
        control = None
        target = None
        for item in report.get("menuItems", []):
            if item.get("label") == args[0]:
                target = item
            if item.get("label") == args[1]:
                control = item
        if control is None or target is None:
            print("False")
            return
        print(str(bool(target.get("painted")) == bool(control.get("painted"))))
        return

    if query == "menu-has-control":
        print(str(any(i.get("label") == args[0] for i in report.get("menuItems", []))))
        return

    if query == "menu-item-painted":
        for item in report.get("menuItems", []):
            if item.get("label") == args[0]:
                print(str(bool(item.get("painted"))))
                return
        print("False")
        return

    if query == "dump-rows":
        for row in report.get("problemRows", []):
            print("        %-8s %-28s %-8s %s" % (
                "error" if row.get("severityError") else "warning",
                row.get("path", ""), row.get("location", ""),
                (row.get("message", "") or "")[:60]))
        return

    if query == "dump-rejected":
        for row in report.get("problemRowsRejected", []):
            print("        " + str(row).replace("\n", " / ")[:140])
        return

    if query == "dump-menu":
        print("        root labels: %s" % report.get("menuRootLabels"))
        for item in report.get("menuItems", []):
            print("        %-28s %-14s painted=%s" % (
                item.get("label"), item.get("shortcut"), item.get("painted")))
        return

    if query == "dump-page-errors":
        for err in report.get("pageErrors", []):
            print("        " + str(err)[:180])
        return

    # A bare field.
    value = report.get(query, "")
    print(value if not isinstance(value, (dict, list)) else json.dumps(value))


if __name__ == "__main__":
    main()

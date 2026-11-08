## test_design_font_metrics.nim — how wide the GPUI views budget a string
## (`gpui/design_font_metrics.nim`), for the characters outside its ASCII
## table.
##
## The Agent Harbor views take a flex basis from these widths, and a browser
## measures the same text by the character. Until 2026-11-08 a character
## outside the table was budgeted once per UTF-8 BYTE: "…" as three capital
## Ms, "×" and "·" as two, which gave an initiative tab holding "2…" and
## "3×" recording buttons about 12 px more of a full bar than the web.
## Tabular figures (`tabular = true`, the views' `font-variant-numeric:
## tabular-nums`) are the face's `tnum` digits, all 620 units wide; a
## budget at the proportional advances made "1" 2.5 px narrower at 12 px
## than the browser draws it. No mocks: the function is pure.

import std/unittest

import ../design_font_metrics

suite "design_font_metrics: one budget per character":

  test "a character outside the table is one capital M, however many bytes":
    let m = groteskTextWidth("M", 12.0)
    check groteskTextWidth("\xE2\x80\xA6", 12.0) == m # "…", 3 bytes
    check groteskTextWidth("\xC3\x97", 12.0) == m     # "×", 2 bytes
    check groteskTextWidth("2\xE2\x80\xA6", 12.0) ==
      groteskTextWidth("2", 12.0) + m

  test "ASCII is unchanged":
    # BUILD at 14 px with the desktop's letter spacing: 38 px, the figure
    # the module's table was checked against.
    check groteskTextPx("BUILD", 14.0, LabelLetterSpacing) == 38

  test "letter spacing is added once per character":
    let plain = groteskTextWidth("a\xC2\xB7b", 14.0)          # "a·b"
    let spaced = groteskTextWidth("a\xC2\xB7b", 14.0, -0.5)
    check abs((plain - spaced) - 1.5) < 1e-9

suite "design_font_metrics: tabular figures":

  test "every digit is the tnum advance, and only digits change":
    for d in "0123456789":
      check abs(groteskTextWidth($d, 12.0, tabular = true) - 7.44) < 1e-9
    # Proportional by default: "1" (416) and "0" (641) differ.
    check abs(groteskTextWidth("1", 12.0) - 4.992) < 1e-9
    check abs(groteskTextWidth("0", 12.0) - 7.692) < 1e-9
    check groteskTextWidth("n/m x", 12.0, tabular = true) ==
      groteskTextWidth("n/m x", 12.0)
    check abs(groteskTextWidth("1/4", 12.0, tabular = true) -
              (groteskTextWidth("/", 12.0) + 2 * 7.44)) < 1e-9
    check groteskTextPx("11", 12.0, tabular = true) == 15
    check groteskTextPx("11", 12.0) == 10

suite "design_font_metrics: kerning":

  test "kerned widths are the shaped widths, and only on request":
    # GPUI's shaper (cosmic-text, the same face, tnum on) set these at
    # 12 px on 2026-11-08: 73.140, 75.108, 57.636.
    check abs(groteskTextWidth("1 completed", 12.0, tabular = true, kerned = true) - 73.140) < 1e-3
    check abs(groteskTextWidth("1 in progress", 12.0, tabular = true, kerned = true) - 75.108) < 1e-3
    check abs(groteskTextWidth("2 planned", 12.0, tabular = true, kerned = true) - 57.636) < 1e-3
    check abs(groteskTextWidth("1 completed", 12.0, tabular = true) - 73.596) < 1e-3
    # A pair the face kerns ("To", -101 units), and none across a tabular
    # digit (`"4` is -42 units with the proportional four).
    check groteskTextWidth("To", 16.0, kerned = true) < groteskTextWidth("To", 16.0)
    check groteskTextWidth("\"4", 12.0, tabular = true, kerned = true) ==
      groteskTextWidth("\"4", 12.0, tabular = true)
    check groteskTextWidth("\"4", 12.0, kerned = true) < groteskTextWidth("\"4", 12.0)

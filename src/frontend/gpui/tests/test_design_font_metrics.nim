## test_design_font_metrics.nim — how wide the GPUI views budget a string
## (`gpui/design_font_metrics.nim`), for the characters outside its ASCII
## table.
##
## The Agent Harbor views take a flex basis from these widths, and a browser
## measures the same text by the character. Until 2026-11-08 a character
## outside the table was budgeted once per UTF-8 BYTE: "…" as three capital
## Ms, "×" and "·" as two, which gave an initiative tab holding "2…" and
## "3×" recording buttons about 12 px more of a full bar than the web.
## No mocks: the function is pure.

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

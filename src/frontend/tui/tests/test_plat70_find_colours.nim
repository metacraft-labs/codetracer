## test_plat70_find_colours.nim — the find highlights' colours are the design
## system's, on all three front-ends (Find-And-Incremental-Search.md OQ-F6,
## decided by the user on 2026-11-20: dedicated find tokens).
##
## The chain under test, link by link:
##
##   codetracer-design-system `colors/editor/surface/find-match(-highlight)`
##     → the Monaco theme documents' `codetracer` block (`findMatch`,
##       `findMatchHighlight`), resolved by `scripts/tokens-to-styl.sh`
##     → `editor-theme/findMatch(Highlight)` (`styles/generated`)
##     → the terminal's `srSurfaceFindMatch` / `srSurfaceFindMatchCurrent`,
##       GPUI's `FindMatchColour` / `FindMatchCurrentColour`, and the desktop's
##       Monaco `editor.findMatchHighlightBackground` /
##       `editor.findMatchBackground` (`lib/monaco_appearance`).
##
## The painted grounds themselves are read off real screens elsewhere: the
## terminal's in `real_terminal/test_plat70c_find_pty.nim` (its expected hexes
## are `RoleSpecs`' — the roles asserted here); GPUI's constants, and the
## bands its plan draws, in `gpui/tests/test_plat70c_gpui_plan.nim` (GPUI's
## leaves load the shim, which this lane does not).
##
## No mocks: the shipped role table, the generated token
## module and the theme documents exactly as Monaco is given them.

import std/[json, os, strutils, unittest]

import ../app/theme/roles
import ../../lib/monaco_appearance
import ../../styles/generated/design_tokens

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 19

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())

const ThemeDir = "src/public/third_party/monaco-themes/themes/customThemes/json"

suite "OQ-F6: one pair of find tokens, three front-ends":
  test "the editor theme's find tokens are the design system's, in both modes":
    for mode in DesignMode:
      ck DesignTokenHex[dtEditorThemeFindMatch][mode] ==
           DesignTokenHex[dtColorsEditorSurfaceFindMatch][mode]
      ck DesignTokenHex[dtEditorThemeFindMatchHighlight][mode] ==
           DesignTokenHex[dtColorsEditorSurfaceFindMatchHighlight][mode]
    # Two distinct grounds: the current match is told apart from the rest.
    ck DesignTokenHex[dtEditorThemeFindMatch][dmDark] !=
         DesignTokenHex[dtEditorThemeFindMatchHighlight][dmDark]

  test "the theme documents name the tokens, not hexes":
    for name in ["codetracerDark.json", "codetracerWhite.json"]:
      let doc = parseJson(readFile(repo / ThemeDir / name))
      ck doc["codetracer"]["findMatch"].getStr ==
           "{colors.editor.surface.find-match}"
      ck doc["codetracer"]["findMatchHighlight"].getStr ==
           "{colors.editor.surface.find-match-highlight}"
      # The old keys were not Monaco colour ids, so Monaco ignored them.
      ck not doc["colors"].hasKey("findMatch")

  test "the terminal paints the find roles from them":
    ck RoleSpecs[srSurfaceFindMatch].bg == dtEditorThemeFindMatchHighlight
    ck RoleSpecs[srSurfaceFindMatchCurrent].bg == dtEditorThemeFindMatch

  test "Monaco is given them under its own colour ids, per mode":
    for (def, mode) in [(darkThemeDef, dmDark), (whiteThemeDef, dmLight)]:
      let colors = parseJson(def)["colors"]
      ck colors["editor.findMatchBackground"].getStr ==
           DesignTokenHex[dtEditorThemeFindMatch][mode]
      ck colors["editor.findMatchHighlightBackground"].getStr ==
           DesignTokenHex[dtEditorThemeFindMatchHighlight][mode]
      # Nothing else of the document is changed on the way.
      ck parseJson(def)["codetracer"]["ground"].getStr.startsWith("{colors.")

suite "OQ-F6: the tally":
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions

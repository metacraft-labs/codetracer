## test_capture_terminal_persona.nim — the persona capture tool reads a
## terminal's reply stream the way the committed personas record it
## (CodeTracer-TUI-Terminal-Adaptation.md §13.1).
##
## `tools/capture-terminal-persona` runs inside each real terminal (the
## `tui-real-emulators` lane); what it SAVES is decided by two pure
## functions, `tokens` (the reply stream split into escape sequences) and
## `keyOf` (the question a reply answers). Over every committed persona: the
## stream its terminal wrote, re-split, gives back the same tokens; each
## token is filed under the same question; and the answers, re-derived the
## way the tool derives them, equal the answers committed. No stand-in: the
## inputs are bytes real terminals wrote.

import std/[json, strutils, unittest]

import "../../../../tools/capture-terminal-persona/capture_terminal_persona"
import ../app/tests/personas/personas

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 36
  ## Six committed personas, six checks each.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

suite "the persona capture tool":

  test "every committed persona: its replies re-split and re-filed as committed":
    for c in capturedPersonas():
      checkpoint(c.provenance)
      ck tokens(c.replies.join("")) == c.replies
      var cpr = newJArray()
      var decrqm = newJObject()
      var late = newJArray()
      var answers = newJObject()
      var fenced = false
      for t in c.replies:
        let key = keyOf(t)
        if fenced or key == "":
          late.add %t
        elif key == "cpr":
          cpr.add %t
        elif key == "da1":
          answers["da1"] = %t
          fenced = true
        elif key.startsWith("decrqm."):
          decrqm[key["decrqm.".len .. ^1]] = %t
        else:
          answers[key] = %t
      answers["decrqm"] = decrqm
      answers["cpr"] = cpr
      answers["late"] = late
      ck fenced
      ck c.answers == answers
      ck c.cprCount == 6
      ck c.answerFor("da1").startsWith("\x1b[?")
      ck keyOf(c.answerFor("da1")) == "da1"

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions

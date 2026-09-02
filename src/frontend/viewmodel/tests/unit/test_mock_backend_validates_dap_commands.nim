## Proof that `MockBackendService`'s DAP-command validation can actually reject.
##
## LANE: `vm-unit` AND `vm-unit-js`, both by the directory glob.
##
## Compile and run:
##   nim c  -r src/frontend/viewmodel/tests/unit/test_mock_backend_validates_dap_commands.nim
##   nim js -r src/frontend/viewmodel/tests/unit/test_mock_backend_validates_dap_commands.nim
##
## ## What this suite is built against
##
## `backend/dap_dialect.md` §7 lists nine commands the ViewModels send that
## exist in no mapping table — not `VALID_DAP_COMMANDS`, not
## `EVENT_KIND_TO_DAP_MAPPING`, neither Rust dispatch table in `dap_server.rs`,
## and not `authority.nim`'s `DriverOnlyDebugCommands`. No engine implements any
## of them. Every one of the nine had tests, and every test passed, because
## `MockBackendService.send` did no validation at all: a test asserting "the
## command was dispatched" passes for a command nothing implements.
##
## `send` now validates. This suite exists because **a validator that has never
## rejected anything is indistinguishable from one that cannot**. Every claim
## below is about the validator's own behaviour, demonstrated, not assumed:
##
##   * it rejects a string that is deliberately not a command (if this case ever
##     goes green-by-passing, the validation has been switched off somewhere);
##   * it does *not* reject a listed command — a validator that refuses
##     everything is equally useless, and equally green if nobody checks;
##   * the rejection is **synchronous**. This is the load-bearing property.
##     Almost every send site reads `discard vm.store.backend.send(...)`, and a
##     *failed future* handed to `discard` is dropped without a word — which
##     would reproduce, inside the validator, the exact silence it exists to
##     break. The cases here call through a bare `discard` on purpose;
##   * all nine of §7's commands are rejected, and **the count is asserted**.
##     That last part is what stops the quiet regression this whole area is
##     about: adding one of the nine to `VALID_DAP_COMMANDS` to turn some other
##     red test green would drop `rejected` to 8 and redden this case by name.
##
## Every assertion is `counted` and the count itself is asserted by the last
## case, so a guard that returned early — or a loop over a list that turned out
## empty — stops being a silent pass. Universal quantification over an empty set
## passes vacuously; that is the failure mode this idiom exists to remove.

import std/[json, strutils, unittest]

import ../../backend/backend_service
import ../../backend/mock_backend
import ../../backend/dap_commands

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 26
  ## Asserted by the last case. Update it deliberately, in the same commit as
  ## the checks that moved it.

const DialectSection7Commands = [
  ## The nine from `backend/dap_dialect.md` §7, in the order that table lists
  ## them. This is a *pinned copy*: the doc, the allow-list and this array
  ## disagreeing is precisely the drift the suite is here to catch.
  "ct/jump-location",
  "ct/load-step-lines",
  "ct/line-step-jump",
  "ct/asm-instruction-jump",
  "ct/build-cancel",
  "ct/load-recent-trace",
  "ct/load-recent-folder",
  "ct/launch-config",
  "ct/new-record",
]

suite "MockBackendService validates the command it is handed":

  test "a deliberately invalid command is rejected, and the message names it":
    # The case that proves the validator can fail at all. If this ever passes
    # by NOT raising, validation has been disabled and every other suite's
    # green is worthless again.
    let mock = newMockBackendService(autoRespond = true)
    let backend = mock.toBackendService()

    var raised = false
    var message = ""
    try:
      # A bare `discard`, deliberately: this is the shape every ViewModel send
      # site uses, and the shape a failed future would be swallowed by.
      discard backend.send("ct/deliberately-not-a-real-command", %*{})
    except InvalidDapCommandDefect as err:
      raised = true
      message = err.msg

    counted raised
    counted message.contains("ct/deliberately-not-a-real-command")
    counted message.contains("dap_commands.nim")
    counted message.contains("dap_dialect.md")

    # And the attempt is still on the log, so a triage can name the offender
    # from the recording as well as from the message.
    counted mock.receivedCommands.len == 1
    counted mock.receivedCommands[0].command ==
      "ct/deliberately-not-a-real-command"

  test "a command that IS in the allow-list is not rejected":
    # The complement. A validator that refuses everything rejects the invalid
    # command too, and would pass the case above while breaking the product.
    let mock = newMockBackendService(autoRespond = true)
    let backend = mock.toBackendService()

    var refused = false
    try:
      discard backend.send("ct/load-locals", %*{})
    except InvalidDapCommandDefect:
      refused = true

    counted not refused
    counted "ct/load-locals".isValidDapCommand
    counted mock.receivedCommands.len == 1

  test "every command in dap_dialect.md §7 is rejected, and there are nine":
    # The nine at once — which is the whole argument for validating here rather
    # than at nine call sites. `rejected` is counted and its total asserted, so
    # quietly adding one of these to VALID_DAP_COMMANDS to turn another test
    # green reddens THIS case, by name, instead of passing unnoticed.
    var rejected = 0
    for command in DialectSection7Commands:
      let mock = newMockBackendService(autoRespond = true)
      let backend = mock.toBackendService()
      try:
        discard backend.send(command, %*{})
      except InvalidDapCommandDefect:
        inc rejected
      # Each one is absent from the allow-list, which is the reason it is
      # rejected — asserted separately so a failure says which fact broke.
      counted not command.isValidDapCommand

    counted rejected == 9
    counted DialectSection7Commands.len == 9

  test "validateCommands = false restores the old silence, and only then":
    # The documented transport-level escape hatch. It is asserted here so that
    # its effect is a stated property rather than a discovery, and so that the
    # difference between "validated" and "not validated" is visible in one
    # place.
    let lax = newMockBackendService(autoRespond = true, validateCommands = false)
    let laxBackend = lax.toBackendService()

    var refused = false
    try:
      discard laxBackend.send("ct/deliberately-not-a-real-command", %*{})
    except InvalidDapCommandDefect:
      refused = true

    counted not refused
    counted lax.receivedCommands.len == 1
    counted not lax.validateCommands

    # ... and the default really is the strict one, so a mock built the usual
    # way gets validation without asking for it.
    let strictByDefault = newMockBackendService(autoRespond = true)
    counted strictByDefault.validateCommands

  test "validation runs before the response path, whatever that path is":
    # An invalid command must be refused identically whether the mock would
    # have answered from an expectation, auto-responded, or deferred. Three
    # arms, because "it validates" that only holds on the default path is a
    # validator with three holes in it.
    var refusals = 0

    let withExpectation = newMockBackendService()
    withExpectation.expect("ct/build-cancel", %*{"ok": true})
    try:
      discard withExpectation.toBackendService().send("ct/build-cancel", %*{})
    except InvalidDapCommandDefect:
      inc refusals

    let autoResponding = newMockBackendService(autoRespond = true)
    try:
      discard autoResponding.toBackendService().send("ct/build-cancel", %*{})
    except InvalidDapCommandDefect:
      inc refusals

    let deferring = newMockBackendService(autoRespond = true)
    deferring.deferResponses = true
    try:
      discard deferring.toBackendService().send("ct/build-cancel", %*{})
    except InvalidDapCommandDefect:
      inc refusals

    counted refusals == 3
    # The deferred arm must not have handed out a future it will never settle:
    # validation refused before the deferral was created.
    counted deferring.pendingDeferredCount == 0

  test "mock_backend_validation_assertion_count_is_measured":
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions

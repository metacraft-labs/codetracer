import std / jsffi
import .. / common / ct_event
import types
import communication, dap
import utils

proc ctSourceLineJump*(dap: DapApi, line: int, path: cstring, behaviour: JumpBehaviour) {.exportc.} =
    let target = SourceLineJumpTarget(
    path: path,
    line: line,
    behaviour: behaviour,
    )
    dap.sendCtRequest(CtSourceLineJump, target.toJs)

proc ctAddToScratchpad*(viewsApi: MediatorWithSubscribers, expression: cstring) {.exportc.} =
    viewsApi.emit(InternalAddToScratchpadFromExpression, expression)

proc historyJump*(viewsApi: MediatorWithSubscribers, location: types.Location) =
  viewsApi.emit(InternalNewOperation, NewOperation(name: HISTORY_JUMP_VALUE, stableBusy: true))
  viewsApi.emit(CtHistoryJump, location)

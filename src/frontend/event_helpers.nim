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

proc ctAddToScratchpad*(api: MediatorWithSubscribers, expression: cstring) {.exportc.} =
  api.emit(InternalAddToScratchpadFromExpression, expression)

proc historyJump*(api: MediatorWithSubscribers, location: types.Location) =
  api.emit(InternalNewOperation, NewOperation(name: HISTORY_JUMP_VALUE, stableBusy: true))
  api.emit(CtHistoryJump, location)

proc installCt() =
  when not defined(ctInExtension):
    data.ipc.send "CODETRACER::install-ct", js{}

proc showNotification*(api: MediatorWithSubscribers, notification: Notification) =
  api.emit(CtNotification, notification)

proc infoMessage*(api: MediatorWithSubscribers, text: cstring) =
  let notification =
    makeNotification(NotificationKind.NotificationInfo, text)
  api.showNotification(notification)

proc installMessage*(api: MediatorWithSubscribers) =
  let notification = newNotification(
    NotificationKind.NotificationInfo,
    "CodeTracer isn't installed. Do you want to install it?",
    actions = @[newNotificationButtonAction("Install", proc = installCt())]
  )
  api.showNotification(notification)

proc warnMessage*(api: MediatorWithSubscribers, text: cstring) =
  let notification =
    makeNotification(NotificationKind.NotificationWarning, text)
  api.showNotification(notification)

proc errorMessage*(api: MediatorWithSubscribers, text: cstring) =
  let notification =
    makeNotification(NotificationKind.NotificationError, text)
  api.showNotification(notification)

proc successMessage*(api: MediatorWithSubscribers, text: cstring) =
  let notification =
    makeNotification(NotificationKind.NotificationSuccess, text)
  api.showNotification(notification)

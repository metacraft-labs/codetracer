type
  NotificationKind* = enum
    NotificationInfo,
    NotificationWarning,
    NotificationError,
    NotificationSuccess


  Notification* = ref object
    kind*: NotificationKind
    time*: int64
    text*: langstring
    active*: bool
    seen*: bool
    timeoutId*: int
    hasTimeout*: bool
    isOperationStatus*: bool
    # Defines side-effect-ful "actions" that will be performed when the
    # notification is sent
    actions*: seq[NotificationAction]

  NotificationActionKind* = enum
    ButtonAction

  NotificationAction* = object
    case kind*: NotificationActionKind:
      of ButtonAction:
        name*: langstring
        handler*: proc: void

proc newNotification*(kind: NotificationKind, text: string, isOperationStatus: bool = false, actions: seq[NotificationAction] = @[]): Notification =
  Notification(
    kind: kind,
    text: text,
    time: getTime().toUnix,
    active: true,
    isOperationStatus: isOperationStatus,
    actions: actions
  )

proc newNotificationButtonAction*(name: langstring, handler: proc: void): NotificationAction =
  NotificationAction(
    name: name,
    handler: handler,
    kind: NotificationActionKind.ButtonAction
  )
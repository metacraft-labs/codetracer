import ui_imports, strutils
import ../communication, ../../common/ct_event
from ../rr_gdb import RRGDBStopSignal
import ../event_helpers

const NO_CODE = -1
const NO_PATH = ""

proc getAsmCode(self: NoSourceComponent, location: types.Location) {.async.} =
  self.instructions = await data.services.editor.asmLoad(location)
  self.data.redraw()

proc historyJump*(self: NoSourceComponent, location: types.Location) =
  self.api.historyJump(location)

method render*(self: NoSourceComponent): VNode =
  let height = document.getElementById("ROOT").clientHeight - 20
  let metaInfo = data.services.debugger.location
  let history = self.data.services.debugger.jumpHistory
  let hasHistory = self.data.services.debugger.jumpHistory.len >= 2
  var location: types.Location
  var action: cstring

  if hasHistory:
    location = history[^2].location
    action = history[^1].lastOperation

  if self.instructions == Instructions():
    discard self.getAsmCode(history[^1].location)

  clog "no info: $  render unknown location component"

  if self.state.isNil:
    var hasInstructions = false

    result = buildHtml(
      tdiv(
        class = "unknown-location",
        style=style(StyleAttr.height, &"{height}px")
      )
    ):
      tdiv(class = "unknown-location-header"):
        text "Whoops!"
      tdiv(class = "unknown-location-content"):
        tdiv(class = "unknown-border"):
          if self.message.len > 0:
            p(class = "unknown-location-message"):
              text self.message
        tdiv(class = "unknown-border"):
          p(): text fmt"- Function: '{metaInfo.highLevelFunctionName}'"
          if metaInfo.highLevelPath != NO_PATH:
            p(): text  fmt"- Path: '{metaInfo.highLevelPath}'"
          if metaInfo.highLevelLine != NO_CODE:
            p(): text  fmt"- Line: '{metaInfo.highLevelLine}'"
        if hasHistory and action != "":
          tdiv(class = "unknown-border"):
            p(): text fmt"We were in '{location.path}' and ended up here because of an operation: '{action}'"
          tdiv(class = "unknown-border"):
            tdiv(class = "unknown-location-buttons"):
              p(): text "You can still use all of the actions or you can go back"
              button(
                class = "jump-back-button",
                onclick = proc =
                  if hasHistory:
                    self.data.services.debugger.currentOperation = HISTORY_JUMP_VALUE
                    self.historyJump(location)
                    discard self.data.services.debugger.jumpHistory.pop()
              ): text "Jump back"
      p(): text fmt"Originating address: 0x{toHex(self.instructions.address)}"
      tdiv(class = "unknown-location-asm"):
        let instructions = self.instructions

        for instruction in instructions.instructions:
          var highlight = ""
          var style = style()
          var prefix = ""
          hasInstructions = true

          if data.services.debugger.frameInfo.offset == instruction. offset:
            highlight = "asm-highlight"
            style = style(StyleAttr.color, "red")
            prefix = "->"

          let offset = &"{prefix}<+{instruction.offset}>"

          p(class = fmt"asm-code {highlight}", style = style):
            text fmt"{offset:>8}: {$instruction.name:<6} | {instruction.args}"
      if self.data.services.debugger.stopSignal notin {NoStopSignal, OtherStopSignal}:
        p(): text fmt"Signal received: {self.data.services.debugger.stopSignal}"
    if hasInstructions:
      self.state = result
  else:
    return self.state

import
  std/strutils,
  ../ui_helpers,
  ui_imports, value

method onDebugOutput(self: ReplComponent, response: DebugOutput) {.async.} =
  self.history[^1].output = response
  self.data.redraw()

method run(self: ReplComponent, input: cstring) {.async.} =
  if not self.service.stableBusy:
    self.history.add(
      DebugInteraction(
        input: input,
        output: DebugOutput(kind: DebugLoading, output: cstring"")
      )
    )
    debugRepl(self.history[^1].input)

method render*(self: ReplComponent): VNode =
  result = buildHtml(tdiv(class = componentContainerClass())):
    if self.data.trace.lang.isDbBased():
      tdiv(class = "repl-msg-wrapper"):
          tdiv(class = "repl-disabled-msg"):
            text(fmt"The Repl Component is not supported for Db based traces '{self.data.trace.lang.toName()}'")
    elif self.data.config.repl:
      tdiv(id = "repl"):
        form(onsubmit = proc(ev: Event, v: VNode) =
            ev.stopPropagation()
            ev.preventDefault()
            discard self.run(jq("#repl-input").toJs.value.to(cstring))):

          input(id = "repl-input", `type` = "text", placeholder = "Enter command...")

        tdiv(id = "repl-history"):
          for i in (self.history.len - 1).countdown(self.history.len - 10):
            if i >= 0:
              let interaction = self.history[i]
              let preClass =
                "repl-output-" & ($interaction.output.kind)
                  .replace("Debug")
                  .toLowerAscii()

              tdiv(class = "repl-input-history"):
                text ">" & $interaction.input
              tdiv(class = "repl-output-history"):
                pre(class = preClass):
                  text interaction.output.output
    else:
      tdiv(class = "repl-msg-wrapper"):
        tdiv(class = "repl-disabled-msg"):
          text("The Repl Component is disabled with the current configuration.\n*If you want to enable it please:\n1. Edit the 'repl' flag in CodeTracer/config/default_config.yaml\n2. Run rm -rf ~/.config/codetracer to get the updated config")

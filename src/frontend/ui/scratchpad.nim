import ui_imports, ../types

proc removeValue*(self: ScratchpadComponent, i: int) =
  self.programValues.delete(i, i)
  self.values.delete(i, i)
  self.data.redraw()

proc scratchpadValueView(self: ScratchpadComponent, i: int, value: ValueComponent): VNode =
  value.isScratchpadValue = true
  proc renderFunction(value: ValueComponent): VNode =
    result = buildHtml(tdiv(class = "scratchpad-value-view")):
      button(
        class = "scratchpad-value-close",
        onclick = proc =
          self.removeValue(i)
      )
      render(value)

  renderFunction(value)

method render*(self: ScratchpadComponent): VNode =

  buildHtml(
    tdiv(id = "values", class = componentContainerClass("active-state"))):
      tdiv(class = "value-components-container"):
        if self.values.len() > 0:
          for i, value in self.values:
            scratchpadValueView(self, i, value)
        else:
          tdiv(class = "empty-overlay"):
            text "You can add values from other components by right clicking on them and then click on 'Add value to scratchpad'."

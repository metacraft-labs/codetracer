import ui_imports

const
  DEFAULT_BYTES_PER_ROW = 16
  DEFAULT_ROW_COUNT = 8

proc placeholderRowView(self: MemoryViewComponent, rowIndex: int): VNode =
  let address = self.rangeStart + rowIndex * self.bytesPerRow
  buildHtml(
    tdiv(class = "memory-view-row")
  ):
    span(class = "memory-view-address"):
      text cstring(fmt"0x{address}")
    tdiv(class = "memory-view-bytes"):
      for _ in 0..<self.bytesPerRow:
        span(class = "memory-view-byte"):
          text ".."

method register*(self: MemoryViewComponent, api: MediatorWithSubscribers) =
  self.api = api

method render*(self: MemoryViewComponent): VNode =
  let rows = if self.rowCount > 0: self.rowCount else: DEFAULT_ROW_COUNT
  let bytesPerRow = if self.bytesPerRow > 0: self.bytesPerRow else: DEFAULT_BYTES_PER_ROW
  self.bytesPerRow = bytesPerRow
  self.rowCount = rows

  buildHtml(
    tdiv(class = "memory-view")
  ):
    tdiv(class = "memory-view-header"):
      span(class = "memory-view-title"):
        text "Memory View"
      span(class = "memory-view-range"):
        text cstring(fmt"range {self.rangeStart}..{self.rangeEnd}")
    tdiv(class = "memory-view-controls"):
      span(class = "memory-view-control"):
        text cstring(fmt"bytes/row: {bytesPerRow}")
      span(class = "memory-view-control"):
        text cstring(fmt"rows: {rows}")
    tdiv(class = "memory-view-grid"):
      for rowIndex in 0..<rows:
        placeholderRowView(self, rowIndex)

proc registerMemoryViewComponent*(component: MemoryViewComponent, api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)

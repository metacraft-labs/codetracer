import ui_imports, base64
import ../communication
import ../../common/ct_event

const
  DEFAULT_BYTES_PER_ROW = 16
  DEFAULT_ROW_COUNT = 8

proc decodeBytes(base64Value: cstring): seq[int] =
  if base64Value.len == 0:
    return @[]
  let decoded = decode($base64Value)
  result = newSeq[int](decoded.len)
  for i, ch in decoded:
    result[i] = ord(ch)

proc requestRange(self: MemoryViewComponent) =
  if self.loading or self.api.isNil:
    return
  let length = self.bytesPerRow * self.rowCount
  if length <= 0:
    return
  self.rangeEnd = self.rangeStart + length
  self.loading = true
  self.api.emit(CtLoadMemoryRange, CtLoadMemoryRangeArguments(
    address: self.rangeStart,
    length: length
  ))

proc highlightRange*(self: MemoryViewComponent, startAddress: int, length: int) =
  self.highlightStart = startAddress
  self.highlightLength = length
  self.redraw()

proc placeholderRowView(self: MemoryViewComponent, rowIndex: int): VNode =
  let address = self.rangeStart + rowIndex * self.bytesPerRow
  let addressHex = toHex(address, 8)
  buildHtml(
    tdiv(class = "memory-view-row")
  ):
    span(class = "memory-view-address"):
      text cstring(fmt"0x{addressHex}")
    tdiv(class = "memory-view-bytes"):
      for colIndex in 0..<self.bytesPerRow:
        let byteIndex = rowIndex * self.bytesPerRow + colIndex
        let byteAddress = address + colIndex
        let highlightEnd = self.highlightStart + self.highlightLength
        let highlightActive =
          self.highlightLength > 0 and
          byteAddress >= self.highlightStart and
          byteAddress < highlightEnd
        let byteValue =
          if byteIndex < self.bytes.len:
            cstring(toHex(self.bytes[byteIndex], 2))
          else:
            cstring("00")
        let highlightClass = if highlightActive: " memory-view-byte-highlight" else: ""
        span(class = cstring("memory-view-byte" & highlightClass)):
          text byteValue

method register*(self: MemoryViewComponent, api: MediatorWithSubscribers) =
  self.api = api
  api.subscribe(CtLoadMemoryRangeResponse, proc(kind: CtEventKind, response: CtLoadMemoryRangeResponseBody, sub: Subscriber) =
    self.rangeStart = response.startAddress
    self.rangeEnd = response.startAddress + response.length
    self.bytes = decodeBytes(response.bytesBase64)
    self.state = response.state
    self.error = response.error
    self.loading = false
    self.redraw()
  )
  if self.rowCount <= 0:
    self.rowCount = DEFAULT_ROW_COUNT
  if self.bytesPerRow <= 0:
    self.bytesPerRow = DEFAULT_BYTES_PER_ROW
  self.requestRange()

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
      if self.loading:
        span(class = "memory-view-status"):
          text "loading"
    tdiv(class = "memory-view-controls"):
      span(class = "memory-view-control"):
        text cstring(fmt"bytes/row: {bytesPerRow}")
      span(class = "memory-view-control"):
        text cstring(fmt"rows: {rows}")
      if self.error.len > 0:
        span(class = "memory-view-error"):
          text self.error
    tdiv(class = "memory-view-grid"):
      for rowIndex in 0..<rows:
        placeholderRowView(self, rowIndex)

proc registerMemoryViewComponent*(component: MemoryViewComponent, api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)

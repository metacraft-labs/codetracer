import ui_imports, base64
import ../communication
import ../../common/ct_event

const
  DEFAULT_BYTES_PER_ROW = 16
  DEFAULT_ROW_COUNT = 8
  ROW_HEIGHT_PX = 24
  OVERSCAN_ROWS = 4
  CACHE_MAX_ENTRIES = 32

proc decodeBytes(base64Value: cstring): seq[int] =
  if base64Value.len == 0:
    return @[]
  let decoded = decode($base64Value)
  result = newSeq[int](decoded.len)
  for i, ch in decoded:
    result[i] = ord(ch)

proc requestRange(self: MemoryViewComponent) =
  if self.api.isNil:
    return
  let length = self.bytesPerRow * self.rowCount
  if length <= 0:
    return
  if self.cache.hasKey(self.rangeStart):
    self.bytes = self.cache[self.rangeStart]
    return
  if self.loading and self.lastRequestedStart == self.rangeStart:
    return
  self.rangeEnd = self.rangeStart + length
  self.loading = true
  self.lastRequestedStart = self.rangeStart
  self.api.emit(CtLoadMemoryRange, CtLoadMemoryRangeArguments(
    address: self.rangeStart,
    length: length
  ))

proc updateRangeFromScroll(self: MemoryViewComponent) =
  let scrollNode = document.getElementById(cstring(fmt"memory-view-scroll-{self.id}"))
  if scrollNode.isNil:
    return
  let scrollTop = cast[int](scrollNode.toJs.scrollTop)
  let firstRow = if scrollTop > 0: scrollTop div ROW_HEIGHT_PX else: 0
  let startRow = if firstRow > OVERSCAN_ROWS: firstRow - OVERSCAN_ROWS else: 0
  let newStart = startRow * self.bytesPerRow
  if newStart != self.rangeStart:
    self.rangeStart = newStart
    self.requestRange()

proc parseSearchAddress(value: cstring): int =
  let raw = ($value).strip
  if raw.len == 0:
    return NO_ADDRESS
  try:
    var token = raw
    if token.len > 2 and (token.startsWith("0x") or token.startsWith("0X")):
      token = token[2..^1]
    if token.len == 0:
      return NO_ADDRESS
    return parseHexInt(token)
  except:
    return NO_ADDRESS

proc applySearch(self: MemoryViewComponent) =
  let addr = parseSearchAddress(self.searchValue)
  if addr == NO_ADDRESS:
    self.error = cstring"Invalid address"
    self.redraw()
    return
  self.error = cstring""
  self.rangeStart = addr
  self.requestRange()
  self.redraw()

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
    let bytes = decodeBytes(response.bytesBase64)
    self.bytes = bytes
    if not self.cache.hasKey(response.startAddress):
      self.cacheOrder.add(response.startAddress)
    self.cache[response.startAddress] = bytes
    if self.cacheOrder.len > CACHE_MAX_ENTRIES:
      let evictKey = self.cacheOrder[0]
      self.cacheOrder.delete(0, 0)
      self.cache.del(evictKey)
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
      tdiv(class = "memory-view-search"):
        input(
          `type`="text",
          value = self.searchValue,
          placeholder = "0x0000",
          oninput = proc(ev: Event, tg: VNode) =
            self.searchValue = ev.target.toJs.value.to(cstring)
        )
        button(
          class = "memory-view-search-button",
          onmousedown = proc(ev: Event, tg: VNode) =
            if cast[MouseEvent](ev).button == 0:
              self.applySearch()
        ):
          text "Go"
      if self.error.len > 0:
        span(class = "memory-view-error"):
          text self.error
    tdiv(
      id = cstring(fmt"memory-view-scroll-{self.id}"),
      class = "memory-view-scroll",
      onscroll = proc(ev: Event, tg: VNode) =
        self.updateRangeFromScroll()
    ):
      tdiv(class = "memory-view-grid"):
        for rowIndex in 0..<rows:
          placeholderRowView(self, rowIndex)

proc registerMemoryViewComponent*(component: MemoryViewComponent, api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)

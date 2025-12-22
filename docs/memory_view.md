# MemoryView design doc

## Purpose
MemoryView is a new UI component that visualizes heap memory as a grid of
addressed cells. It allows a user to scroll large heap regions without loading
all bytes at once by virtualizing memory ranges and requesting only the visible
window plus a small buffer.

## Goals
- Show a clear, legible grid of memory locations and values.
- Make scrolling smooth by virtualizing heap ranges and caching results.
- Support quick navigation to a specific address and to known heap regions.
- Handle large heaps safely with predictable memory usage.

## Non-goals
- Editing memory bytes in place.
- Stack or code segment visualization (heap only for v1).
- Full disassembly or pointer graph exploration.

## UX layout
MemoryView borrows the familiar hex-editor layout
(https://en.wikipedia.org/wiki/Hex_editor) but groups bytes into boxes to
improve scanning.

```
+-------------------------------------------------------------+
| MemoryView | Heap | Range: 0x00007f90_1000 - 0x00007f90_5fff |
| Search: [0x00007f90_2a10]  [Go]  [Bytes: 16]  [Group: 4]     |
|-------------------------------------------------------------|
| Address          | 00 01 02 03 | 04 05 06 07 | 08 09 0A 0B   |
| 0x7f90_1000      | 7f 45 4c 46 | 02 01 01 00 | 00 00 00 00  |
| 0x7f90_1010      | 03 00 3e 00 | 01 00 00 00 | 80 00 00 00  |
| 0x7f90_1020      | .. .. .. .. | .. .. .. .. | .. .. .. ..  |
| ...                                                     ... |
|-------------------------------------------------------------|
| Status: loaded 64 KB, cached 256 KB, requests in flight: 1  |
+-------------------------------------------------------------+
```

Notes:
- Each row shows one base address and a fixed number of bytes.
- Bytes are grouped (default 4) into light boxes for quick reading.
- Empty or unmapped data uses a placeholder token `..`.

## Data model
The UI works with two core concepts:

- HeapSegment: a known address interval describing the heap layout.
  - start_addr (u64)
  - end_addr (u64)
  - label (string, optional, e.g. "young gen")
- MemoryRange: a contiguous byte range plus the byte payload.
  - start_addr (u64)
  - length (u32)
  - bytes (Vec<u8>)
  - state (loaded | unmapped | error)

The UI maintains a cache keyed by aligned range start. It should never assume
contiguity beyond the range returned by the backend.

## Virtualization and loading ranges
MemoryView should virtualize rows based on viewport height. Only visible rows
plus a small overscan buffer are requested.

Recommended defaults:
- bytes_per_row: 16
- overscan_rows: 8
- range_align: 256 bytes
- range_request_size: 4 KB (16 rows) or 16 KB when the heap is large

Request algorithm:
1) Map viewport to a requested address interval.
2) Align the interval to `range_align`.
3) Split into chunks of `range_request_size`.
4) For each chunk not in cache and not in flight, issue a request.

Caching:
- LRU capped by a total byte size budget (e.g. 4-16 MB).
- Evict whole ranges, never partial rows.
- Keep the current viewport pinned.

Failure handling:
- If a request fails, store an error state for that range and render a visible
  inline error marker in the grid with a retry action.

## Interactions
- Scroll: drives virtualization; show a stable scrollbar based on the active
  heap segment.
- Jump to address: parse hex, scroll to the containing row, request the range.
- Range selector: list heap segments and allow quick switching.
- Visualize value: when a value is selected elsewhere (e.g. locals in the state
  panel), MemoryView receives its address and size, scrolls to the first byte if
  needed, and highlights the full range in the grid.
- Hover: show tooltip with address, byte value, and derived numeric formats.

## Accessibility
- Keep fixed-width numeric columns to maintain alignment.
- Support keyboard navigation with row and cell focus.
- Provide a screen-reader summary for the current range and focused address.

## Edge cases
- Unmapped addresses within a segment: display `..` and mark the row as sparse.
- Extremely large heaps: show a scale indicator and limit the jump list to the
  nearest segment to avoid long scroll jumps.
- Time-travel step changes: clear caches that are not safe across steps.
- Highlighted ranges that span unloaded bytes should trigger a range load and
  render a placeholder highlight until data arrives.

## Testing plan
- Unit tests for range alignment, chunking, and cache eviction.
- UI tests for smooth scroll with missing ranges.
- Error tests for partial/unmapped ranges and retry behavior.

## Open questions
- Should MemoryView support value decoding (u32/u64, float) in a side panel?
- How should it integrate with object inspection to jump to allocations?

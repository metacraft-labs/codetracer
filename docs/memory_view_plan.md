# MemoryView implementation plan

## Scope
Implement the MemoryView component described in `docs/memory_view.md` with heap
range virtualization, value highlighting from state panel locals, and basic
range navigation.

## Milestones
1) Data contract and backend integration
- Define a request/response shape for memory range loading (address, length,
  optional step id, optional heap segment id; response includes aligned start,
  length, payload bytes, and state).
- Add an RPC/IPC endpoint for fetching a range by address and length.
- Include error and unmapped signaling in the response.
- Decide on a transport encoding for bytes (base64 string vs. numeric array)
  and mirror it in both Rust and Nim conversions.
- Add MemoryView request/response types in the shared common types
  (`src/common/common_types/language_features/value.nim`) and ensure they are
  available to the frontend via `src/frontend/types.nim`.
- Add new `CtEventKind` entries in `src/common/ct_event.nim` (request and
  response kinds) and map them in `src/frontend/dap.nim`:
  - `EVENT_KIND_TO_DAP_MAPPING`
  - `toCtDapResponseEventKind`
  - `commandToCtResponseEventKind`
- Add custom Codetracer DAP requests for MemoryView and wire send/receive
  plumbing in `src/frontend/middleware.nim` (subscribe + emit).
- Add a new db-backend DAP server case for the memory query in
  `src/db-backend/src/dap_server.rs` (and in
  `src/db-backend/crates/db-backend-core/src/dap_server.rs` if that path is
  used), define its arguments in `src/db-backend/src/task.rs`, and implement a
  corresponding handler in `src/db-backend/src/handler.rs` to load memory
  ranges.
- Extend the replay abstraction to support memory reads (e.g. add
  `load_memory_range` to `src/db-backend/src/replay.rs`) and implement it in
  `src/db-backend/src/db.rs` and `src/db-backend/src/rr_dispatcher.rs`
  (returning a clear error for unsupported backends if needed).

2) UI component skeleton
- Create the MemoryView container with header, range selector, and grid (e.g.
  `src/frontend/ui/memory_view.nim`).
- Implement the UI-facing `render`/frontend methods in
  `src/frontend/ui/memory_view.nim` to integrate with the existing component
  lifecycle.
- Add a new `Content.MemoryView` entry in
  `src/common/common_types/codetracer_features/frontend.nim`, then register the
  component in `src/frontend/utils.nim` (`makeComponent` + component mapping).
- Add a panel entry (menu or command palette) so users can open MemoryView,
  following the existing patterns in `src/frontend/ui_js.nim`.
- Implement fixed-width address column and grouped byte boxes.
- Add placeholder rows for unloaded data.

3) Virtualization and cache
- Implement row virtualization based on viewport height.
- Add aligned range requests and an LRU cache with a byte budget.
- Ensure overscan range loads and in-flight de-duplication.

4) Interactions
- Implement jump-to-address parsing and scroll-to-row.
- Wire “visualize value” from state panel locals to highlight the memory range:
  add a UI action in `src/frontend/ui/value.nim` (or the state panel row
  renderer) that emits the MemoryView highlight request using the local’s
  `address` and a byte length. If size is not available, default to a single
  byte or pointer-size highlight and document the fallback.
- Add hover tooltip for address and byte value decoding.
- Emit MemoryView request events from the view and subscribe to response/update
  events to refresh the grid.

5) Error handling and resilience
- Render error markers for failed range requests with a retry action.
- Handle step changes by clearing unsafe caches.
- Guard against invalid addresses and zero-length ranges.

6) Testing
- Unit tests for alignment, chunking, and cache eviction.
- UI tests for scrolling, highlighting, and error states.

## Dependencies
- State panel locals already expose a stable `address`, but a byte length is not
  currently part of the shared `Variable` type; decide whether to infer size
  from type metadata or add an explicit size field for highlights.
- Backend must provide memory range access for the active trace step.

## Risks and mitigations
- Large heap performance: mitigate with strict cache limits and range alignment.
- Unmapped address density: render sparse rows and avoid repeated requests.

## Deliverables
- MemoryView UI component and styling.
- Range loading service with cache and request scheduling.
- Tests covering virtualized loading and value highlighting.

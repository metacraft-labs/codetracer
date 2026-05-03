type
  BootstrapPayload* = object
    ## Serialized IPC payload (already JSON.stringify-ed) that
    ## should be replayed to a reconnecting socket.
    ##
    ## ``id`` is the IPC channel name (e.g. ``CODETRACER::trace-loaded``).
    ## ``key`` distinguishes multiple payloads on the same channel — for
    ## ``CODETRACER::dap-receive-event`` it carries the inner DAP event
    ## name (e.g. ``ct/complete-move``) so we can cache the latest of
    ## several distinct DAP events without one overwriting the other.
    ## For other channels ``key`` is left empty and only ``id`` is used
    ## as the upsert/dedup discriminator.
    id*: cstring
    key*: cstring
    payload*: cstring

const
  bootstrapPriority* = @[
    cstring"CODETRACER::started",
    cstring"CODETRACER::init",
    cstring"CODETRACER::start-shell-ui",
    cstring"CODETRACER::start-deepreview",
    cstring"CODETRACER::no-trace",
    cstring"CODETRACER::welcome-screen"
  ]

  bootstrapEvents* = bootstrapPriority & @[
    cstring"CODETRACER::trace-loaded",
    cstring"CODETRACER::filenames-loaded",
    cstring"CODETRACER::filesystem-loaded",
    cstring"CODETRACER::symbols-loaded",
    cstring"CODETRACER::dap-replay-selected",
    cstring"CODETRACER::complete-move"
  ]

  ## DAP events (delivered via ``CODETRACER::dap-receive-event``) that
  ## carry critical bootstrap state.  After a browser reload the Backend
  ## Manager sits at the same trace position but does not spontaneously
  ## re-emit these one-shot events, so the host must cache the latest
  ## payload per kind and replay it to the reconnecting client.
  ##
  ## ``ct/complete-move`` is the canonical one — without it the editor
  ## tab never opens after a reload because
  ## ``editor_service.onCompleteMove`` is the only path that calls
  ## ``data.openTab``.
  bootstrapDapEvents* = @[
    cstring"ct/complete-move"
  ]

proc bootstrapDapEventKey*(eventName: cstring): cstring =
  ## Return the cache key for a DAP event that should be replayed during
  ## browser reconnect bootstrap, or an empty key for events that are
  ## rebuilt by renderer-side reload effects.
  for candidate in bootstrapDapEvents:
    if candidate == eventName:
      return eventName
  return cstring""

proc upsertBootstrap*(cache: var seq[BootstrapPayload], payload: BootstrapPayload) =
  ## Replace an existing payload for the same (id, key) tuple or append
  ## if unseen.  ``key`` is empty for legacy single-payload-per-id
  ## entries, so the behaviour for those is unchanged.
  for i, entry in cache.mpairs:
    if entry.id == payload.id and entry.key == payload.key:
      entry = payload
      return
  cache.add(payload)

proc orderedBootstrap*(cache: seq[BootstrapPayload]): seq[BootstrapPayload] =
  ## Return payloads ordered so the initial handshake/configuration
  ## replays before any heavier trace messages.
  result = @[]
  for id in bootstrapPriority:
    for payload in cache:
      if payload.id == id:
        result.add(payload)
  for payload in cache:
    if payload.id notin bootstrapPriority:
      result.add(payload)

proc replayBootstrap*(cache: seq[BootstrapPayload], emit: proc(id: cstring, payload: cstring)) =
  ## Emit cached messages to the attached socket in stable order.
  if emit.isNil:
    return
  for payload in cache.orderedBootstrap:
    emit(payload.id, payload.payload)

type
  BootstrapPayload* = object
    ## Serialized IPC payload (already JSON.stringify-ed) that
    ## should be replayed to a reconnecting socket.
    id*: cstring
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
    cstring"CODETRACER::symbols-loaded"
  ]

proc upsertBootstrap*(cache: var seq[BootstrapPayload], payload: BootstrapPayload) =
  ## Replace an existing payload for the same IPC id or append if unseen.
  for i, entry in cache.mpairs:
    if entry.id == payload.id:
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

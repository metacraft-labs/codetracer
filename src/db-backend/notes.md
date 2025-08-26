
-> dispatcher?

-> depending on setting/trace:
  start different process

  core_db? or specific?

  or some kind of more general handler? something like core_db which chooses?
  for now simplest just start custom core_db_ruby


  core_db_ruby: a rust binary

  same api: using a socket

  open socket

  load data:
    load
    index: at least lines
    maybe others?

  handle incoming
    -> send to handlers
    for now maybe three threads:
      incoming and handling and maybe sending?
    if outdated: cancel previous? but they in order
    for now: just do them in sequence;
      send results
      if we receive too many: maybe stop? for now do it in a simple way
      maybe dont send outdated(or dont start)

    // -> read in a loop; send to handle thread with channel; eventually register outdated;
    // -> receive from channel; check if outdated; if not handle; send to send thread;
    // -> receive from handle thread; send to client

    other option is to just act as a web server

    -> receive and send all tasks to new/separate async/threads
      just do them there and send directly result and quit thread

    +: simpler, a bit more like server maybe more parallel
    -: maybe harder to detect outdated, but probably still simpler

    +: like dispatcher, simple in a more common op sense
    -: too serialized, if we decide to parallelize tasks, hard

    ugh:
      send cant be just direct as we have one socket to client and we want to keep it one
      still we can have a sender thread
      and many task threads, not just one




TODO:
  `ct import-trace trace.json`
  => add in local db, print out info/id

  fix replay logic to start `ruby-db-backend` for RubyDbLang

  setup sockets in ruby-db-backend: input/output(separate thread) and sender to output thread
  receive/parse messages and send responses with sender+output thread
  start threads for received tasks and send events/res to output thread


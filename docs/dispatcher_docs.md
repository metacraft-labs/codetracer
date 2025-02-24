
-> dispatcher:
  loadProcessArgs() # processes args
  startIPC()        # start and setup loop for incoming messages(from client)
  ->
    createThread(thread, sendClientThread) # start a thread for sending messages/events to client
    readTaskLoop.loop(): # the loop
    -> # in core_common.nim
      # process incoming messages
      self.handleMessage(taskKind, taskId, eventualIntArg) # handle them
      -> # again in dispatcher.nim, calling its handleMessage
        # processing handler: some of:
        * configure(readArg[ConfigureArg](taskId)) # configure
        * fullResetOperation(taskId, resetOperationArg.resetLastLocation) # full cancel/reset
        * other cases or starting in thread(event load)
        elif for a task_process:
          run a before hook in dispatcher if such exists
          if we're jumping: dropping the task(probably ..wrong? if a new jump? otherwise ok)
          eventual cache check, but almost non used for now

          if for this task we can't interrupt: (usually a step-like move or loading info in stable):
            get the process and register the message for it
          else: (usually jump or additional info like flow/call-args):
            get an available worker
            find out if there is process for an outdated current task
            if there it is: cancel it
            register the message for the new task in the available worker
          (TODO) if there are problems with this or process cant be found:
            if it's a non-critical thing(info/non-critical action):
              log/report an error
            else: (e.g. moving):
              this shouldn't really happen normally as we should be able to
              start a new process in the worst case
              however file limits/more radical situations might lead to this:
                log/report a more critical error; eventual suggestion?


cancel:
  eventually: try to interrupt and do the replacing process
    only if it not working, but for now always replace
  if stable:
    equivalent to fullResetOperation
  else:
    stop existing worker

get an available worker:
  if stable:
    if interrupt:
      if free: stable; if not set cancelled wait for 100 ms: if free: stable;
      if not: StepBehindTracking worker if available
      otherwise: free/new
    else:
      just stable: assume it will queue either with registerMessage or socket
  elif worker, but to stable location:
    CloseTracking worker if available otherwise free/new
  else: # e.g. tracepoint
    a free/new non-tracking worker

fullResetOperation:
  eventually: try to interrupt and do the replacing process if not working
  now: always stop existing stable process
  and replace with StepBehindTracking if available, free/new otherwise
  eventually start a new StepBehindTracking process for reserve



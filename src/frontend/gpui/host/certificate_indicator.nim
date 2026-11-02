## The GPUI status bar's native certificate host.
##
## The facts reader is synchronous, and its ContentOracle closures are lazy:
## moving only the initial read to a worker would still let evaluation run git
## on the UI thread. The worker owns the complete read AND ViewModel evaluation.
## Only the resulting data-only model crosses a channel; no platform, closure,
## future or ViewModel is shared with the window.
import ../../viewmodel/viewmodels/[certificate_indicator_vm,
                                  certificate_indicator_source]
import ../../viewmodel/host/desktop_native

export certificate_indicator_vm

type
  Request = object
    generation: uint64
    directory: string
    stop: bool
  Reply = object
    generation: uint64
    model: CertificateIndicatorModel
  Mailbox = object
    requests: Channel[Request]
    replies: Channel[Reply]
  NativeCertificateIndicator* = ref object
    model*: CertificateIndicatorModel
    mailbox: ptr Mailbox
    worker: Thread[ptr Mailbox]
    directory: string
    generation: uint64
    busy: bool

proc failedModel(message: string): CertificateIndicatorModel =
  ## A failed computation is an honest complete answer, never a pending
  ## partial snapshot or a permanent "not looked yet".
  result = newCertificateIndicatorVm(nil).model
  result.state = cisUnverifiable
  result.label = UnverifiableLabel
  result.summary = "The certificate facts could not be read: " & message
  result.remedy = FixConfigurationRemedy

proc workerMain(mailbox: ptr Mailbox) {.thread.} =
  # The native facade's closure types are not annotated gcsafe. Every object
  # reachable here is constructed on this thread and stays here; channels
  # copy only request strings and the model's strings/sequences/enums.
  # awaitSync drains asyncdispatch's thread-local dispatcher, never the UI's.
  {.cast(gcsafe).}:
    while true:
      let request = mailbox.requests.recv()
      if request.stop:
        return
      var model: CertificateIndicatorModel
      try:
        let vm = newCertificateIndicatorVm(platformCertificateFactsReader(
          newDesktopNativePlatform(), request.directory,
          standardPlatformTriple(hostOS, hostCPU)))
        discard vm.refresh(citStartup)
        model = vm.model
      except CatchableError as err:
        model = failedModel(err.msg)
      mailbox.replies.send(Reply(generation: request.generation, model: model))

proc newNativeCertificateIndicator*(): NativeCertificateIndicator =
  ## Own one worker for this window, stopped by close after its loop ends.
  result = NativeCertificateIndicator(
    model: newCertificateIndicatorVm(nil).model)
  result.mailbox = cast[ptr Mailbox](allocShared0(sizeof(Mailbox)))
  result.mailbox.requests.open()
  result.mailbox.replies.open()
  try:
    createThread(result.worker, workerMain, result.mailbox)
  except CatchableError as err:
    result.mailbox.requests.close()
    result.mailbox.replies.close()
    deallocShared(result.mailbox)
    result.mailbox = nil
    result.model = failedModel(err.msg)

proc start(self: NativeCertificateIndicator) =
  self.busy = true
  self.mailbox.requests.send(Request(generation: self.generation,
                                     directory: self.directory))

proc request*(self: NativeCertificateIndicator; directory: string) =
  ## Called by the footer's draw: reusing a folder does no work. A changed
  ## folder supersedes the in-flight result. Keep at most one active read
  ## and one latest request, so navigation cannot create an unbounded queue.
  if self.isNil or self.mailbox.isNil or self.directory == directory or
     directory.len == 0:
    return
  self.directory = directory
  inc self.generation
  if not self.busy:
    self.start()

proc pending*(self: NativeCertificateIndicator): bool =
  not self.isNil and self.busy

proc poll*(self: NativeCertificateIndicator): bool =
  ## On the UI thread: apply a whole current answer and report completion
  ## so the window redraws. A stale folder's result is discarded before any
  ## model field changes, then the latest requested folder is read afresh.
  if self.isNil or self.mailbox.isNil or not self.busy:
    return false
  let (received, reply) = self.mailbox.replies.tryRecv()
  if not received:
    return false
  self.busy = false
  if reply.generation == self.generation:
    self.model = reply.model
    result = true
  else:
    self.start()

proc close*(self: NativeCertificateIndicator) =
  ## Once the window loop has ended, let the active read finish and join
  ## before freeing its channels. No worker can retain the window or redraw
  ## it after close, and closing twice is harmless.
  if self.isNil or self.mailbox.isNil:
    return
  self.mailbox.requests.send(Request(stop: true))
  joinThread(self.worker)
  self.mailbox.requests.close()
  self.mailbox.replies.close()
  deallocShared(self.mailbox)
  self.mailbox = nil
  self.busy = false

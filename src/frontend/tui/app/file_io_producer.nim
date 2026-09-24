## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## This module opens no file and starts no thread: it describes a file job,
## and decides what an ANSWER means for a buffer that may have moved while the
## job ran. The reading and writing are the host's (`host/file_worker.nim`).
##
## app/file_io_producer.nim — PLAT-29: FILE READS AND WRITES AS ASYNCHRONOUS
## PRODUCERS, RECONCILED.
##
## Editor-ViewModel.md §11 names file I/O among the producers that *"sit
## outside, compute against a version, and are reconciled or discarded when
## stale"*, and `reconcile.ProducerRules` already says what each means:
##
##   * a READ (`:e!`, reload from disk) is `srTextDerived`. Its bytes are the
##     file as it was; installing them over a range the user has typed into
##     since the read began would clobber the typing — the one outcome a load
##     must never have. So a reload whose buffer was edited while it was in
##     flight is DROPPED, and said so; one whose buffer did not move is
##     installed through the editing core (undoable, journaled, every mark
##     mapped); and one that only saw typing at the very edge of the buffer is
##     re-expressed past it by `rebase`, keeping the typing.
##   * a WRITE's acknowledgement (`:w`) is `srAnchorLive`: it names the bytes
##     that are now on disk. The buffer's saved text becomes EXACTLY those
##     bytes — not the buffer's current text, which may have moved on while
##     the write ran — so a buffer typed into during a save stays dirty, as it
##     must.
##
## Every answer is counted in the buffer's `fileReport`.

import codetracer_embed

type
  FileJobKind* = enum
    fjRead = "read"
    fjWrite = "write"

  FileJob* = object
    kind*: FileJobKind
    path*: string
      ## Project-relative, as the buffer names it.
    bufferSerial*: int
      ## Which opening of the file — see `HighlightRequest.bufferSerial`.
    version*: DocumentVersion
      ## The buffer's version when the job was made.
    docLen*: int
      ## The buffer's length at `version`.
    text*: string
      ## A write's bytes — the buffer's text at `version`.

  FileJobResult* = object
    job*: FileJob
    ok*: bool
    text*: string
      ## A read's bytes.
    message*: string
      ## Why it failed, in one line naming the path.

  FileAnswer* = object
    ## What the runtime should do with an answer, decided here.
    install*: bool
      ## A read to install: `change` against the CURRENT document.
    change*: ChangeSet
    savedText*: string
      ## The bytes now on disk, for `loadedText`; meaningful when `saved`.
    saved*: bool
    outcome*: ReconcileOutcome
    note*: string
      ## The status line.

proc fileJobFor*(kind: FileJobKind; d: EditingDocument; path: string;
                 bufferSerial: int): FileJob =
  FileJob(kind: kind, path: path, bufferSerial: bufferSerial,
          version: d.version, docLen: d.text.len,
          text: (if kind == fjWrite: d.text else: ""))

proc answerFor*(d: EditingDocument; res: FileJobResult;
                rep: var StalenessReport): FileAnswer =
  ## Reconcile one answer against the buffer it was made for.
  if not res.ok:
    return FileAnswer(note: res.message, outcome: roDropped)
  if not d.timeline.knows(res.job.version):
    rep.record(if res.job.kind == fjRead: pkFileRead else: pkFileWrite,
               roDropped, drVersionForgotten)
    return FileAnswer(
      saved: res.job.kind == fjWrite, savedText: res.job.text,
      outcome: roDropped,
      note: (if res.job.kind == fjRead:
               "reload of " & res.job.path & " discarded: the buffer moved " &
               "too far while it was read"
             else: "wrote " & res.job.path))
  case res.job.kind
  of fjRead:
    let pr = producerChange(pkFileRead, res.job.version,
                            changeSet(res.job.docLen, 0, res.job.docLen,
                                      res.text),
                            0, res.job.docLen)
    let r = reconcile(d.timeline, pr, rep)
    case r.outcome
    of roApplied, roMapped:
      FileAnswer(install: true, change: r.value.change, saved: true,
                 savedText: res.text, outcome: r.outcome,
                 note: "reloaded " & res.job.path &
                       (if r.outcome == roMapped: " (keeping what was typed " &
                                                  "at its edge while it was read)"
                        else: ""))
    of roDropped:
      FileAnswer(outcome: roDropped,
                 note: "reload of " & res.job.path & " discarded: the buffer " &
                       "was edited while it was being read, and installing " &
                       "the disk's bytes would overwrite that")
  of fjWrite:
    let pr = producerResult(pkFileWrite, res.job.version, res.job.docLen,
                            0, res.job.docLen)
    let r = reconcile(d.timeline, pr, rep)
    FileAnswer(saved: true, savedText: res.job.text, outcome: r.outcome,
               note: "wrote " & res.job.path &
                     (if r.outcome == roApplied: ""
                      else: " (the buffer has changed since)"))

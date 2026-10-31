## viewmodel/host/native_shell_host.nim — the Shell pane's process side on the
## terminal and in the GPUI window.
##
## Spec: `codetracer-pm` `spec/Planned-Features/CodeTracer-Shell.md` §7.2.
##
## The model (`viewmodels/shell_vm.nim`) decides when the shell starts, what
## each key sends and what the session's messages mean. This host gives it a
## process: the session (`common/shell_session.nim`) run IN this process — the
## same code `ct shell-session` runs behind the desktop's main process — and a
## pump the front-end's idle tick calls, which hands the model every message
## in the session's order.
##
## What the shell is:
##   * `CODETRACER_SHELL_COMMAND`, split on whitespace, when set (a test's
##     `bash --norc --noprofile -i`, a user's `zsh -l`); else `$SHELL -i`;
##   * started in the front-end's working directory;
##   * with this CodeTracer's `ct` first on its `PATH`: the `bin` of
##     `CODETRACER_PREFIX` when it holds a `ct`, else the front-end's own
##     directory when it does.

import std/[json, os, strutils]

import ../../../common/shell_session
import ../viewmodels/shell_vm

export shell_vm

type
  NativeShell* = ref object
    vm*: ShellVM
    session*: ShellSession

proc ctBinDir*(): string =
  ## The directory of the `ct` this front-end belongs to, or "" (then the
  ## shell's own `PATH` decides).
  let prefix = getEnv("CODETRACER_PREFIX")
  if prefix.len > 0 and fileExists(prefix / "bin" / "ct"):
    return prefix / "bin"
  if fileExists(getAppDir() / "ct"):
    return getAppDir()
  ""

proc shellOptionsFromEnv*(cols, rows: int): ShellSessionOptions =
  result = ShellSessionOptions(cols: cols, rows: rows, ctBinDir: ctBinDir(),
                               cwd: getCurrentDir())
  result.shellCommandFromEnv()

proc wireNativeShell*(vm: ShellVM;
                      openFolder: proc(path: string): string): NativeShell =
  ## Give `vm` its process side. `openFolder` is the front-end's "open this
  ## recording in a new session tab"; the model's press on a recorded command
  ## reaches it with the recording's folder.
  let n = NativeShell(vm: vm)
  vm.host.start = proc(cols, rows: int): string =
    try:
      n.session = startShellSession(shellOptionsFromEnv(cols, rows))
      ""
    except CatchableError as e:
      "could not start the shell: " & e.msg
  vm.host.input = proc(data: string) =
    if not n.session.isNil: n.session.sendInput(data)
  vm.host.resize = proc(cols, rows: int) =
    if not n.session.isNil: n.session.resize(cols, rows)
  vm.host.stop = proc() =
    if not n.session.isNil: n.session.close()
  vm.openRecording = proc(a: ShellAction): string =
    if a.traceFolder.len == 0:
      return "the recording reported no folder"
    if not dirExists(a.traceFolder):
      return "the recording's folder is gone: " & a.traceFolder
    if openFolder.isNil:
      return "this front-end cannot open " & a.traceFolder
    openFolder(a.traceFolder)
  n

proc pumpShell*(n: NativeShell; timeoutMs = 0): bool =
  ## Hand the model what the session wrote since the last pump; whether
  ## anything arrived (the pane needs repainting).
  if n.isNil or n.session.isNil or n.session.finished:
    return false
  for msg in n.session.poll(timeoutMs):
    n.vm.receiveUpdate(msg)
    result = true

proc closeNativeShell*(n: NativeShell) =
  ## The front-end is closing the pane's session (its tab, the window).
  if not n.isNil and not n.session.isNil:
    n.session.close()

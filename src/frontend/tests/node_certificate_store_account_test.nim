## node_certificate_store_account_test.nim
##
## THE NODE HOSTS KNOW WHOSE PARTITION OF THE SYSTEM ROOT IS THEIRS.
##
## Transport §2.1 partitions the local certificate store's system root by
## account: `<root>/<uid>` on POSIX systems, `%ProgramData%\test-certificates\
## <SID>` on Windows. The Electron renderer and the container endpoint resolve
## the roots through `node_certificate_host.nodeCertificateStoreRoots`. node
## has `process.getuid()` on POSIX and nothing on Windows, so until this suite's
## subject existed a Windows Electron window left the system root unresolved —
## and since an unresolved root makes every lookup incomplete, its indicator
## read *Unverifiable* whenever nothing in the user root covered the working
## tree. The SID now comes from `whoami /user /fo csv /nh`, the token user's
## SID, the account the native host reads with `GetTokenInformation`.
##
## ## The claims
##
##   1. `windowsSidFromWhoami` takes exactly one CSV line and its last field,
##      and refuses anything else — never a guessed account.
##   2. On Windows, `storeAccountFor` runs `%SystemRoot%\System32\whoami.exe
##      /user /fo csv /nh` (not a `whoami` found on `PATH`), and the system
##      root becomes `%ProgramData%\test-certificates\<SID>`.
##   3. When the command cannot run, fails or prints something else, the
##      system root stays unresolved and the roots carry the reason.
##   4. On POSIX the uid is used and no command is run.
##   5. This host's own node process resolves its system root with its own
##      account (the uid here; the SID when this suite runs on Windows, where
##      the real `whoami` answers).
##
## ## The one stand-in, and why
##
## Claims 2 and 3 replace the command runner (`AccountCommandRunner`) with a
## closure that records the argv and answers a canned `whoami` reply. They
## have to: this lane runs on Linux, which has no `whoami.exe` and no SID, and
## what is under test is what the host DOES with the answer — the path it
## runs, the parse, the refusal of a bad answer, the root it builds — not
## whether Windows' `whoami` works. Claim 5 runs the real command path on
## whatever host this is, so the shipped runner is exercised too; on a
## Windows host it is the real `whoami.exe`.
##
## Lane: `main-process` — `nim js -d:nodejs -d:ctIndex -d:server`, run under
## node.

import std/[jsffi, strutils]

import ../../ct_test/certificate_store_roots
import ../viewmodel/host/node_certificate_host

var checks = 0
var failedChecks = 0

proc ck(cond: bool; name: string) =
  inc checks
  if cond: echo "  [OK] ", name
  else:
    inc failedChecks
    echo "  [FAILED] ", name

proc exitProcess(code: int) {.importjs: "process.exit(#)".}
proc nodePlatform(): cstring {.importjs: "(process.platform)@".}
proc nodeUid(): cstring
  {.importjs: "((typeof process.getuid === 'function') ? String(process.getuid()) : '')@".}

const
  Sid = "S-1-5-21-3623811015-3361044348-30300820-1013"
  WhoamiLine = "\"desktop-x\\zahary\",\"" & Sid & "\""

proc windowsEnv(name: string): string =
  case name
  of "SystemRoot": "C:\\Windows"
  of "ProgramData": "C:\\ProgramData"
  of "LOCALAPPDATA": "C:\\Users\\zahary\\AppData\\Local"
  else: ""

type Recorder = ref object
  calls: seq[seq[string]]

proc answering(recorder: Recorder; reply: GitReply): AccountCommandRunner =
  result = proc(argv: seq[string]): GitReply {.closure.} =
    recorder.calls.add argv
    reply

echo "[Suite] windowsSidFromWhoami"

block:
  let parsed = windowsSidFromWhoami(WhoamiLine & "\r\n")
  ck(parsed.problem.len == 0 and parsed.sid == Sid,
     "one CSV line (CRLF-terminated) yields its SID")
  let comma = windowsSidFromWhoami("\"corp\\smith, john\",\"" & Sid & "\"\n\n")
  ck(comma.sid == Sid, "a comma inside the quoted user name is not a separator")
  for (label, output) in [
      ("empty output", ""),
      ("two lines", WhoamiLine & "\n" & WhoamiLine & "\n"),
      ("a header line too", "\"User Name\",\"SID\"\n" & WhoamiLine & "\n"),
      ("a table, not CSV", "desktop-x\\zahary " & Sid & "\n"),
      ("an unquoted last field", "\"desktop-x\\zahary\"," & Sid & "\n"),
      ("not a SID", "\"desktop-x\\zahary\",\"S-1-\"\n"),
      ("a path for a SID", "\"desktop-x\\zahary\",\"..\\..\\x\"\n")]:
    let refused = windowsSidFromWhoami(output)
    ck(refused.sid.len == 0 and refused.problem.len > 0,
       "refused, with a reason: " & label)

echo "[Suite] storeAccountFor on Windows"

block:
  let recorder = Recorder()
  let account = storeAccountFor(srpWindows, "", windowsEnv,
    recorder.answering(GitReply(exitCode: 0, stdout: WhoamiLine & "\r\n",
                                complete: true)))
  ck(account.problem.len == 0 and account.account == Sid,
     "the SID whoami prints is the account")
  ck(recorder.calls.len == 1 and recorder.calls[0] ==
       @["C:\\Windows\\System32\\whoami.exe", "/user", "/fo", "csv", "/nh"],
     "whoami.exe is run from %SystemRoot%\\System32, not looked up on PATH")
  let roots = rootsForAccount(srpWindows, windowsEnv, storeAccountFor(srpWindows, "", windowsEnv,
    recorder.answering(GitReply(exitCode: 0, stdout: WhoamiLine,
                                complete: true))))
  ck(roots.system == "C:\\ProgramData\\test-certificates\\" & Sid,
     "the system root is %ProgramData%\\test-certificates\\<SID>: " &
     roots.system)
  ck(roots.user.len > 0, "the user root is resolved as before: " & roots.user)
  ck(roots.problems.len == 0, "and nothing is reported: " & $roots.problems)

block:
  # %SystemRoot% unset: %windir% is the documented fallback.
  let recorder = Recorder()
  let account = storeAccountFor(srpWindows, "",
    proc(name: string): string =
      if name == "windir": "D:\\Win\\" else: "",
    recorder.answering(GitReply(exitCode: 0, stdout: WhoamiLine,
                                complete: true)))
  ck(account.account == Sid and recorder.calls.len == 1 and
       recorder.calls[0][0] == "D:\\Win\\System32\\whoami.exe",
     "%windir% is used when %SystemRoot% is unset, without a doubled separator")

block:
  for (label, reply) in [
      ("whoami cannot be launched",
       GitReply(exitCode: -1, stderr: "spawn ENOENT", complete: true)),
      ("whoami fails", GitReply(exitCode: 1, stderr: "ERROR: denied",
                                complete: true)),
      ("whoami prints no SID", GitReply(exitCode: 0, stdout: "nonsense\n",
                                        complete: true)),
      ("whoami's output was cut", GitReply(exitCode: 0, stdout: WhoamiLine,
                                           complete: false))]:
    let recorder = Recorder()
    let roots = rootsForAccount(srpWindows, windowsEnv, storeAccountFor(srpWindows, "",
      windowsEnv, recorder.answering(reply)))
    ck(roots.system.len == 0, label & ": the system root stays unresolved")
    var named = false
    for problem in roots.problems:
      if "SID could not be read" in problem:
        named = true
    ck(named, label & ": the roots say why: " & $roots.problems)
    ck(roots.user.len > 0, label & ": the user root is still resolved")

block:
  let recorder = Recorder()
  let onlyData = proc(name: string): string =
    if name == "ProgramData": "C:\\ProgramData" else: ""
  let roots = rootsForAccount(srpWindows, onlyData, storeAccountFor(srpWindows,
    "", onlyData, recorder.answering(GitReply(exitCode: 0, stdout: WhoamiLine,
                                    complete: true))))
  ck(recorder.calls.len == 0 and roots.system.len == 0,
     "no %SystemRoot% and no %windir%: nothing is run and the root stays " &
     "unresolved")

echo "[Suite] storeAccountFor on POSIX"

block:
  for platform in [srpUnix, srpMacos]:
    let recorder = Recorder()
    let account = storeAccountFor(platform, "1013",
      proc(name: string): string = "",
      recorder.answering(GitReply(exitCode: 0, stdout: WhoamiLine,
                                  complete: true)))
    ck(account.account == "1013" and recorder.calls.len == 0,
       $platform & ": the uid is the account and no command is run")

echo "[Suite] this host's node process"

block:
  let roots = nodeCertificateStoreRoots()
  if $nodePlatform() == "win32":
    ck(roots.system.len > 0 and "\\test-certificates\\S-1-" in roots.system,
       "Windows: the system root is partitioned by this account's SID: " &
       roots.system & " " & $roots.problems)
    let again = nodeCertificateStoreRoots()
    ck(again.system == roots.system, "and the same SID is answered again")
  else:
    let uid = $nodeUid()
    ck(uid.len > 0 and roots.system.endsWith("/" & uid),
       "POSIX: the system root is partitioned by this process's uid: " &
       roots.system)

echo checks, " checks, ", failedChecks, " failed"
if failedChecks > 0:
  exitProcess(1)

import std / [ os, osproc, streams, strutils ]
import results

proc getGitTopLevel*(dir: string): Result[string, string] =
  try:
    let gitExe = findExe("git")
    let cmd = startProcess(
      gitExe,
      args = @["rev-parse", "--show-toplevel"],
      workingDir = dir,
      options = {poStdErrToStdOut}
    )
    let output = cmd.outputStream.readAll().strip()
    let exitCode = waitForExit(cmd)
    if exitCode == 0 and output.len > 0:
      return ok(output)
  except:
    return err(getCurrentExceptionMsg())

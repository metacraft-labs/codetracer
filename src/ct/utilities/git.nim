import std / [ os, osproc, streams, strutils ]

proc getGitTopLevel*(dir: string): string =
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
      return output
  except:
    return ""
import std / [ os, osproc, streams, strutils ]

proc getGitTopLevel*(dir: string): string =
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
      return output
  except:
    return ""
import std / [ os, osproc, streams, strutils ]

proc getGitTopLevel*(dir: string): string =
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
      return output
  except:
    return ""
import std / [ os, osproc, streams, strutils ]

proc getGitTopLevel*(dir: string): string =
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
      return output
  except:
    return ""
import std / [ os, osproc, streams, strutils ]

proc getGitTopLevel*(dir: string): string =
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
      return output
  except:
    return ""
import std / [ os, osproc, streams, strutils ]

proc getGitTopLevel*(dir: string): string =
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
      return output
  except:
    return ""
import std / [ os, osproc, streams, strutils ]

proc getGitTopLevel*(dir: string): string =
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
      return output
  except:
    return ""

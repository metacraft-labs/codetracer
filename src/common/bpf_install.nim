## BPF installation and capability setup for CodeTracer.
##
## This module handles two complementary BPF setup tasks:
##
## 1. **Native backend (preferred)**: Set BPF capabilities
##    on the ``ct`` binary and install ``monitor.bpf.o`` so
##    the native libbpf backend can load BPF programs directly.
##
## 2. **bpftrace fallback**: Create a capabilities-aware copy
##    of bpftrace under ``/usr/local/lib/codetracer/``.
##
## On NixOS, capabilities are managed via ``security.wrappers``
## and the NixOS module. When that path exists, local setup is
## skipped.
##
## Kernel >= 5.8 is required for ``CAP_BPF``. Older kernels
## receive a warning and BPF setup is skipped gracefully.

import
  std/[os, osproc, strutils, strformat],
  results,
  paths,
  strings

const
  BpfInstallDir* = "/usr/local/lib/codetracer"
    ## Directory for capabilities-aware binaries and BPF objects.

  BpfBpftracePath* = BpfInstallDir / "bpftrace"
    ## Full path to the local bpftrace copy with capabilities set.

  BpfObjectInstallPath* = BpfInstallDir / "monitor.bpf.o"
    ## Full path for the compiled BPF object (native backend).

  BpfGroupName* = "codetracer-bpf"
    ## Unix group for capabilities-aware binaries.

  NixBpfWrapperPath* = "/run/wrappers/bin/codetracer-bpftrace"
    ## NixOS security.wrappers bpftrace path.

  BpfCaps = "cap_bpf,cap_perfmon,cap_dac_read_search+ep"
    ## Linux file capabilities for BPF process monitoring.
    ## - cap_bpf: load/attach BPF programs (kernel >= 5.8)
    ## - cap_perfmon: attach to tracepoints/perf events
    ## - cap_dac_read_search: read /proc for monitored PIDs

  ## Minimum kernel for CAP_BPF support.
  ## See: https://lwn.net/Articles/820560/
  MinKernelMajor = 5
  MinKernelMinor = 8

# -------------------------------------------------------------------
# Query helpers
# -------------------------------------------------------------------

proc isNixManagedBpf*(): bool =
  ## True if bpftrace is managed by NixOS security.wrappers.
  fileExists(NixBpfWrapperPath)

proc isLocalBpfInstalled*(): bool =
  ## True if /usr/local/lib/codetracer/bpftrace exists.
  fileExists(BpfBpftracePath)

proc isNativeBpfInstalled*(): bool =
  ## True if the compiled BPF object is installed.
  fileExists(BpfObjectInstallPath)

proc findSystemBpftrace*(): string =
  ## Locate bpftrace on the system. Returns "" if not found.
  result = findExe("bpftrace")
  if result.len > 0:
    return

  const commonPaths = [
    "/usr/bin/bpftrace",
    "/usr/sbin/bpftrace",
    "/usr/local/bin/bpftrace",
    "/snap/bin/bpftrace",
  ]
  for path in commonPaths:
    if fileExists(path):
      return path

  return ""

proc getBpftracePath*(): string =
  ## Returns the best available bpftrace path:
  ## 1. NixOS wrapper
  ## 2. Local capabilities-aware copy
  ## 3. System bpftrace from PATH
  if isNixManagedBpf():
    return NixBpfWrapperPath
  if isLocalBpfInstalled():
    return BpfBpftracePath
  return findSystemBpftrace()

proc needsSudo*(): bool =
  ## True if BPF setup requires sudo (not nix-managed).
  not isNixManagedBpf()

# -------------------------------------------------------------------
# Kernel version check
# -------------------------------------------------------------------

proc parseKernelVersion(): tuple[major: int, minor: int] =
  ## Parses the running kernel version from ``uname -r``.
  ## Returns (0, 0) on any parsing failure.
  try:
    let output = execProcess(
      "uname", args = ["-r"],
      options = {poUsePath}).strip()
    let parts = output.split({'.', '-'})
    if parts.len >= 2:
      return (parseInt(parts[0]), parseInt(parts[1]))
  except CatchableError:
    discard
  return (0, 0)

proc isKernelCapBpfCapable*(): bool =
  ## True if kernel >= 5.8 (CAP_BPF support).
  ## See: https://lwn.net/Articles/820560/
  let (major, minor) = parseKernelVersion()
  if major == 0:
    return true  # Unknown kernel — assume capable.
  return major > MinKernelMajor or
    (major == MinKernelMajor and minor >= MinKernelMinor)

# -------------------------------------------------------------------
# Package manager detection
# -------------------------------------------------------------------

proc suggestBpftraceInstall(): string =
  if findExe("apt").len > 0:
    return "sudo apt install bpftrace"
  elif findExe("dnf").len > 0:
    return "sudo dnf install bpftrace"
  elif findExe("yum").len > 0:
    return "sudo yum install bpftrace"
  elif findExe("pacman").len > 0:
    return "sudo pacman -S bpftrace"
  elif findExe("zypper").len > 0:
    return "sudo zypper install bpftrace"
  elif findExe("emerge").len > 0:
    return "sudo emerge dev-debug/bpftrace"
  elif findExe("snap").len > 0:
    return "sudo snap install bpftrace"
  else:
    return "Install bpftrace via your package manager"

# -------------------------------------------------------------------
# BPF object file discovery
# -------------------------------------------------------------------

proc findBpfObject*(): string =
  ## Locates ``monitor.bpf.o`` for the native backend.
  ## Checks env vars, prefix, exe-relative, install dir.
  result = getEnv("CODETRACER_BPF_OBJECT")
  if result.len > 0 and fileExists(result):
    return result

  let prefix = getEnv("CODETRACER_PREFIX")
  if prefix.len > 0:
    result = prefix / "share" / "monitor.bpf.o"
    if fileExists(result):
      return result

  # Relative to the running binary.
  let exeDir = getAppDir()
  result = exeDir.parentDir / "share" / "monitor.bpf.o"
  if fileExists(result):
    return result

  if fileExists(BpfObjectInstallPath):
    return BpfObjectInstallPath

  return ""

# -------------------------------------------------------------------
# Installation
# -------------------------------------------------------------------

proc isShellSafe(s: string): bool =
  ## Only allow POSIX-safe path/username characters.
  for c in s:
    if c notin {
      'a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.', '/',
    }:
      return false
  return s.len > 0

proc installNativeBpf*(
    sudoCommand: string = "sudo",
): Result[void, string] =
  ## Sets capabilities on the ``ct`` binary itself and
  ## installs ``monitor.bpf.o`` to the install directory.
  ##
  ## Must be ``ctAppFilename()``, not ``getAppFilename()``: inside the AppImage
  ## the process is started through the bundled dynamic loader, so
  ## /proc/self/exe names the loader, and setcap'ing a dynamic loader would
  ## grant capabilities to anything it is asked to run.
  let ctBinary = ctAppFilename()
  if ctBinary.len == 0:
    return err("Cannot determine ct binary path")
  if not isShellSafe(ctBinary):
    return err(
      "ct binary path contains unsafe chars: " &
      ctBinary)

  let currentUser = getEnv("USER", "")
  if currentUser.len == 0:
    return err(
      "Cannot determine current user " &
      "(USER env var is empty)")
  if not isShellSafe(currentUser):
    return err(
      "USER contains unsafe characters: " &
      currentUser)
  if not isShellSafe(sudoCommand):
    return err(
      "sudo command contains unsafe chars: " &
      sudoCommand)

  let bpfObject = findBpfObject()

  var parts: seq[string] = @[]
  parts.add(fmt2"mkdir -p {BpfInstallDir}")

  let groupCmd =
    fmt2"(getent group {BpfGroupName} " &
    fmt2">/dev/null 2>&1 || groupadd {BpfGroupName})"
  parts.add(groupCmd)
  parts.add(
    fmt2"usermod -aG {BpfGroupName} {currentUser}")
  parts.add(
    fmt2"setcap '{BpfCaps}' {ctBinary}")

  if bpfObject.len > 0 and isShellSafe(bpfObject):
    parts.add(
      fmt2"cp {bpfObject} {BpfObjectInstallPath}")
    parts.add(
      fmt2"chmod 644 {BpfObjectInstallPath}")

  let script = parts.join(" && ")

  echo "Setting up native BPF monitoring..."
  echo "  ct binary: " & ctBinary
  if bpfObject.len > 0:
    echo "  BPF object: " & bpfObject

  try:
    let exitCode = execCmd(
      sudoCommand & " sh -c '" & script & "'")
    if exitCode != 0:
      return err(
        "Native BPF setup failed (exit " &
        fmt2"{exitCode})")
  except OSError as e:
    return err(
      "Failed to execute native BPF setup: " &
      e.msg)

  echo "Native BPF monitoring set up."
  if bpfObject.len == 0:
    echo "  monitor.bpf.o not found." &
      " Run `just build-bpf-programs`."
  echo "  Log out and back in for group" &
    " membership to take effect."
  return ok()

proc installBpftraceFallback*(
    sudoCommand: string = "sudo",
): Result[void, string] =
  ## Sets up the bpftrace fallback backend.
  let systemBpftrace = findSystemBpftrace()
  if systemBpftrace.len == 0:
    let suggestion = suggestBpftraceInstall()
    return err(
      "bpftrace not found. " & suggestion)

  if isLocalBpfInstalled():
    echo "bpftrace fallback already set up."
    return ok()

  if not isShellSafe(systemBpftrace):
    return err(
      "bpftrace path unsafe: " & systemBpftrace)

  let currentUser = getEnv("USER", "")
  if currentUser.len == 0:
    return err(
      "Cannot determine current user " &
      "(USER env var is empty)")
  if not isShellSafe(currentUser):
    return err(
      "USER contains unsafe characters: " &
      currentUser)
  if not isShellSafe(sudoCommand):
    return err(
      "sudo command contains unsafe chars: " &
      sudoCommand)

  let script =
    fmt2"mkdir -p {BpfInstallDir}" &
    fmt2" && cp {systemBpftrace} {BpfBpftracePath}" &
    " && (getent group " &
    fmt2"{BpfGroupName} >/dev/null 2>&1" &
    fmt2" || groupadd {BpfGroupName})" &
    fmt2" && usermod -aG {BpfGroupName} {currentUser}" &
    fmt2" && chown root:{BpfGroupName} {BpfBpftracePath}" &
    fmt2" && chmod 750 {BpfBpftracePath}" &
    fmt2" && setcap '{BpfCaps}' {BpfBpftracePath}"

  echo "Setting up bpftrace fallback..."

  try:
    let exitCode = execCmd(
      sudoCommand & " sh -c '" & script & "'")
    if exitCode != 0:
      return err(
        "bpftrace setup failed (exit " &
        fmt2"{exitCode})")
  except OSError as e:
    return err(
      "Failed to execute bpftrace setup: " &
      e.msg)

  echo "bpftrace fallback set up."
  return ok()

proc installBpf*(
    sudoCommand: string = "sudo",
): Result[void, string] =
  ## Sets up BPF monitoring. Tries native backend first,
  ## then bpftrace fallback. Returns ok() if at least one
  ## backend succeeds.

  if isNixManagedBpf():
    echo "BPF is managed by Nix. Skipping."
    return ok()

  if not isKernelCapBpfCapable():
    let (major, minor) = parseKernelVersion()
    return err(
      fmt2"Kernel {major}.{minor} too old for " &
      fmt2"CAP_BPF (need >= {MinKernelMajor}." &
      fmt2"{MinKernelMinor})")

  let nativeResult = installNativeBpf(sudoCommand)
  if nativeResult.isErr:
    echo "Warning: native BPF setup failed: " &
      nativeResult.error

  let bpftraceResult =
    installBpftraceFallback(sudoCommand)
  if bpftraceResult.isErr:
    if nativeResult.isOk:
      echo "Note: bpftrace fallback unavailable."
      echo "  Native backend will be used."
    else:
      return err(
        "Both BPF backends failed.\n" &
        "  Native: " & nativeResult.error & "\n" &
        "  bpftrace: " & bpftraceResult.error)

  return ok()

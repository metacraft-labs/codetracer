Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Gate for the wall-clock bounds on bootstrap downloads and on the native
# commands the MSYS2 leg shells out to.
#
# This test exists because the Windows lane was not being kept red by any
# failure. It was being kept red by a HANG: jobs went silent inside the
# toolchain bootstrap and were killed hours later by the workflow timeout,
# having produced no error at all. A step that fails is a step you can read;
# a step that stalls is a step that burns a scarce Windows runner slot and
# tells you nothing.
#
# So the checks here are deliberately NEGATIVE checks. A timeout that has only
# ever been exercised on the happy path is not tested -- the interesting
# question is whether it fires, and how fast, when the operation really does
# stall. Every bound below is driven against a server or a child process that
# genuinely never finishes.
#
# The first group is the one that justifies the implementation existing at
# all: it pins the behaviour of `Invoke-WebRequest -OutFile`, WITH and WITHOUT
# `-TimeoutSec`, against a mid-body stall. Both hang. `-TimeoutSec` bounds the
# request up to the response headers and does not bound the body read, so the
# obvious one-line fix would not have fixed anything. If a future PowerShell
# changes that, this group starts failing and the hand-rolled streaming
# downloader can be reconsidered -- which is the point of asserting it rather
# than writing it in a comment.
#
# NO MOCKS. Per the workspace policy on mock objects, this file uses none. The
# stall is produced by a real TCP server that really does send response
# headers and then really does stop sending; the downloader under test is the
# real one from toolchain-utils.ps1, doing real socket reads into a real file
# on disk. The bounded-native-command checks drive a real child process. The
# only thing that is synthetic is the far end of the socket, which is the
# test's own subject matter -- there is no other way to observe a stall on
# demand.
#
# Runs on Linux/macOS pwsh as well as Windows: nothing here needs a Windows
# API.

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$utilsPath = Join-Path $repoRoot "non-nix-build/windows/toolchain-utils.ps1"

if (-not (Test-Path -LiteralPath $utilsPath -PathType Leaf)) {
  throw "toolchain-utils.ps1 not found at '$utilsPath'."
}
. $utilsPath

$script:Failures = 0
$script:Checks = 0

function Assert-True {
  param([bool]$Condition, [string]$Message)
  $script:Checks++
  if (-not $Condition) {
    $script:Failures++
    Write-Host "  FAIL: $Message"
  } else {
    Write-Host "  ok:   $Message"
  }
}

function Assert-Equal {
  param($Expected, $Actual, [string]$Message)
  Assert-True -Condition ($Expected -eq $Actual) -Message "$Message (expected '$Expected', got '$Actual')"
}

function Get-FreeTcpPort {
  $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $probe.Start()
  $port = $probe.LocalEndpoint.Port
  $probe.Stop()
  return $port
}

function Get-PwshPath {
  $path = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
  if ([string]::IsNullOrWhiteSpace($path)) {
    throw "Could not determine the running pwsh path."
  }
  return $path
}

# A one-shot HTTP server with three behaviours, run in a background job so the
# test process can be the client.
#
#   full   - send headers and the whole body, then close GRACEFULLY.
#   stall  - send headers and a first chunk, then stop sending and hold the
#            connection open. This is the shape that hung CI.
#   trickle- send headers and then one byte every 200ms, forever. This never
#            trips an inactivity bound; only a total budget catches it.
#
# TWO PROPERTIES BELOW ARE LOAD-BEARING, AND BOTH WERE LEARNED THE EXPENSIVE
# WAY -- each cost a run on a two-slot Windows lane, and in BOTH cases the
# defect was in this server, not in the downloader it is pointed at. A harness
# that is less reliable than the thing it measures cannot measure it.
#
# 1. THE RESPONSE IS BUILT BEFORE READINESS IS SIGNALLED, NEVER WHILE A CLIENT
#    IS WAITING ON IT.
#
#    The body used to be generated one byte at a time, in a PowerShell `for`
#    loop, AFTER the response headers had already gone out. The client's
#    inactivity clock starts at the headers, so every one of those 262,144
#    interpreted loop iterations was spent inside the very bound the test was
#    about to assert. That loop costs ~2s on a developer machine and an order
#    of magnitude more on a loaded CI guest, and when it crossed the 20s
#    inactivity window the download failed with `no data for 20s (received
#    0 B)` -- a real stall, correctly detected, caused entirely by the test
#    server sitting on its hands.
#
#    So the body is now filled by tiling a 26-byte pattern with
#    `Buffer.BlockCopy` (~30x cheaper, and identical bytes), and -- the part
#    that actually makes it deterministic rather than merely faster -- it is
#    built BEFORE the ready file appears. The parent cannot connect until the
#    bytes are already in memory, so no amount of host slowness can put CPU
#    time inside the measured window. The constant got better; the invariant
#    is what removes the race.
#
# 2. THE `full` CONNECTION IS CLOSED GRACEFULLY, NOT BY LETTING THE JOB EXIT.
#
#    `NetworkStream.Write` returns when the kernel has ACCEPTED the bytes, not
#    when the peer has received them. The server used to write the body and
#    then simply run off the end of the scriptblock, so the background job's
#    process exited with up to a full socket send buffer still queued. Linux
#    hides this: loopback send buffers are megabytes, so nothing is ever in
#    flight, and the kernel drains what is. Windows does not -- a process
#    exiting with queued data resets the connection, and the queued bytes are
#    discarded. That is how a run saw exactly `128.0 KiB of 256.0 KiB (50%)`
#    -- one read buffer -- and then "An existing connection was forcibly
#    closed by the remote host": a truncated body from a server that had
#    already returned from `Write` and believed it was done.
#
#    The fix is the standard graceful-close handshake: shut down the sending
#    half, then read until the peer's FIN. The client only closes after it has
#    consumed all `Content-Length` bytes, so that FIN is a positive
#    acknowledgement that the whole body landed. The server cannot exit before
#    it, and there is nothing left queued when it does.
#
#    This is deliberately NOT applied to `stall` or `trickle`. Holding those
#    connections open, indefinitely and rudely, is their entire purpose.
$serverScript = {
  param($Port, $Mode, $BodySize, $ReadyFile)

  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
  $listener.Start()

  # Build the whole response first -- see note 1 above. Nothing between the
  # ready signal and the write may cost measurable time.
  $declared = if ($Mode -eq "trickle") { 1073741824 } else { $BodySize }
  $header = "HTTP/1.1 200 OK`r`nContent-Length: $declared`r`nContent-Type: application/octet-stream`r`nConnection: close`r`n`r`n"
  $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)

  $body = $null
  if ($Mode -eq "full") {
    # Byte i is 'A' + (i mod 26), exactly as the assertion in Part 4 expects;
    # tiling the pattern produces the same bytes as the per-byte loop did.
    $body = [byte[]]::new($BodySize)
    $pattern = [byte[]](65..90)
    for ($offset = 0; $offset -lt $BodySize; $offset += $pattern.Length) {
      [System.Buffer]::BlockCopy(
        $pattern, 0, $body, $offset, [Math]::Min($pattern.Length, $BodySize - $offset))
    }
  }

  # Signal readiness out of band. The obvious handshake -- have the parent
  # connect to check the port is open -- cannot be used here, because this
  # listener is one-shot: the probe connection would BE the accepted
  # connection, and the download under test would then get ECONNREFUSED and
  # "pass" the stall assertions for entirely the wrong reason.
  New-Item -ItemType File -Path $ReadyFile -Force | Out-Null
  try {
    $client = $listener.AcceptTcpClient()
    $stream = $client.GetStream()

    $request = [byte[]]::new(65536)
    $stream.Read($request, 0, $request.Length) | Out-Null

    $stream.Write($headerBytes, 0, $headerBytes.Length)
    $stream.Flush()

    switch ($Mode) {
      "full" {
        $stream.Write($body, 0, $body.Length)
        $stream.Flush()

        # Graceful close -- see note 2 above. Half-close, then read until the
        # client's FIN, which it can only send once it has read every declared
        # byte. The receive timeout is a liveness backstop so a client that
        # dies without closing cannot strand this job; it is not part of the
        # handshake and must never be reached on the happy path.
        $client.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Send)
        $client.Client.ReceiveTimeout = 60000
        $drain = [byte[]]::new(4096)
        try {
          while ($stream.Read($drain, 0, $drain.Length) -gt 0) { }
        } catch [System.IO.IOException] {
          # Receive timeout, or the client aborted. Either way the send half
          # is already shut down, so nothing of ours is left unsent.
        }
        $client.Close()
      }
      "stall" {
        $chunk = [byte[]]::new(4096)
        $stream.Write($chunk, 0, $chunk.Length)
        $stream.Flush()
        Start-Sleep -Seconds 900
      }
      "trickle" {
        $one = [byte[]]::new(1)
        while ($true) {
          $stream.Write($one, 0, 1)
          $stream.Flush()
          Start-Sleep -Milliseconds 200
        }
      }
    }
  } finally {
    $listener.Stop()
  }
}

function Start-StallServer {
  param([string]$Mode, [int]$BodySize = 65536)

  $port = Get-FreeTcpPort
  $readyFile = Join-Path ([System.IO.Path]::GetTempPath()) ("ct-stall-ready-" + [Guid]::NewGuid().ToString("N"))
  $job = Start-Job -ScriptBlock $serverScript -ArgumentList $port, $Mode, $BodySize, $readyFile

  # Wait for the listener to be up, rather than sleeping a guessed interval
  # and racing it.
  $deadline = (Get-Date).AddSeconds(60)
  while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $readyFile -PathType Leaf)) {
    Start-Sleep -Milliseconds 100
  }
  if (-not (Test-Path -LiteralPath $readyFile -PathType Leaf)) {
    throw "The '$Mode' stall server never signalled readiness on port $port."
  }

  return [pscustomobject]@{
    Port      = $port
    Job       = $job
    ReadyFile = $readyFile
    Url       = "http://127.0.0.1:$port/artifact.bin"
  }
}

function Stop-StallServer {
  param($Server)
  if ($null -eq $Server) { return }
  Stop-Job -Job $Server.Job -ErrorAction SilentlyContinue
  Remove-Job -Job $Server.Job -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $Server.ReadyFile -Force -ErrorAction SilentlyContinue
}

$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ct-stall-test-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $scratchRoot | Out-Null

try {

  # -------------------------------------------------------------------------
  # Part 1 - the premise: Invoke-WebRequest cannot express this bound.
  # -------------------------------------------------------------------------

  Write-Host "== Invoke-WebRequest -OutFile does not bound a mid-body stall"

  foreach ($variant in @(
      @{ Name = "without -TimeoutSec"; Timeout = 0 },
      @{ Name = "with -TimeoutSec 5";  Timeout = 5 }
    )) {

    # A fresh stall server per variant: the server is one-shot.
    $server = $null
    try {
      $server = Start-StallServer -Mode "stall"
      $out = Join-Path $scratchRoot ("iwr-" + [Guid]::NewGuid().ToString("N") + ".bin")

      # Run the download in a child job so the test can outlive the hang it is
      # provoking. If the job is still running well past any timeout that was
      # asked for, the timeout did not cover the body read.
      $probe = Start-Job -ScriptBlock {
        param($Url, $Out, $TimeoutSec)
        if ($TimeoutSec -gt 0) {
          Invoke-WebRequest -Uri $Url -OutFile $Out -UseBasicParsing -TimeoutSec $TimeoutSec
        } else {
          Invoke-WebRequest -Uri $Url -OutFile $Out -UseBasicParsing
        }
      } -ArgumentList $server.Url, $out, $variant.Timeout

      $finished = $null -ne (Wait-Job -Job $probe -Timeout 25)
      Stop-Job -Job $probe -ErrorAction SilentlyContinue
      Remove-Job -Job $probe -Force -ErrorAction SilentlyContinue

      Assert-True -Condition (-not $finished) `
        -Message "Invoke-WebRequest $($variant.Name) is STILL RUNNING 25s into a mid-body stall (this is the hang the bound replaces)"
    } finally {
      Stop-StallServer -Server $server
    }
  }

  # -------------------------------------------------------------------------
  # Part 2 - the bound fires, quickly, with a message that names the cause.
  # -------------------------------------------------------------------------

  Write-Host "== Invoke-BoundedDownload fails fast on a stalled transfer"

  $server = $null
  try {
    $server = Start-StallServer -Mode "stall"
    $out = Join-Path $scratchRoot "stalled.bin"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $threw = $false
    $message = ""
    try {
      Invoke-BoundedDownload -Url $server.Url -OutFile $out -StallSeconds 5 -TotalSeconds 120 -ProgressSeconds 1 | Out-Null
    } catch {
      $threw = $true
      $message = [string]$_.Exception.Message
    }
    $sw.Stop()

    Assert-True -Condition $threw `
      -Message "a mid-body stall THROWS instead of blocking"
    Assert-True -Condition ($sw.Elapsed.TotalSeconds -lt 25) `
      -Message "and it throws promptly, at the bound rather than at the job timeout (took $([int]$sw.Elapsed.TotalSeconds)s, bound was 5s)"
    Assert-True -Condition ($sw.Elapsed.TotalSeconds -ge 4) `
      -Message "and not before the bound it was given (took $([int]$sw.Elapsed.TotalSeconds)s)"
    Assert-True -Condition ($message -match "stalled") `
      -Message "the error says the transfer stalled: '$message'"
    Assert-True -Condition ($message -match [regex]::Escape($server.Url)) `
      -Message "the error names the URL that stalled, so the log identifies the component"
    Assert-True -Condition (-not (Test-Path -LiteralPath $out -PathType Leaf)) `
      -Message "the truncated output file is removed, so a later run cannot mistake it for a cached artefact"
  } finally {
    Stop-StallServer -Server $server
  }

  # -------------------------------------------------------------------------
  # Part 3 - a transfer that never stalls but never finishes is still bounded.
  # -------------------------------------------------------------------------

  Write-Host "== Invoke-BoundedDownload enforces a total budget on a trickling transfer"

  $server = $null
  try {
    $server = Start-StallServer -Mode "trickle"
    $out = Join-Path $scratchRoot "trickle.bin"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $threw = $false
    $message = ""
    try {
      # The inactivity bound is generous relative to the 200ms trickle, so it
      # can never fire. Only the total budget can end this.
      Invoke-BoundedDownload -Url $server.Url -OutFile $out -StallSeconds 30 -TotalSeconds 6 -ProgressSeconds 2 | Out-Null
    } catch {
      $threw = $true
      $message = [string]$_.Exception.Message
    }
    $sw.Stop()

    Assert-True -Condition $threw `
      -Message "a transfer that trickles forever THROWS rather than running to the job timeout"
    Assert-True -Condition ($message -match "total budget") `
      -Message "and the error distinguishes the total budget from a stall: '$message'"
    Assert-True -Condition ($sw.Elapsed.TotalSeconds -lt 30) `
      -Message "the total budget is honoured promptly (took $([int]$sw.Elapsed.TotalSeconds)s, budget was 6s)"
  } finally {
    Stop-StallServer -Server $server
  }

  # -------------------------------------------------------------------------
  # Part 4 - the happy path still downloads bytes correctly.
  # -------------------------------------------------------------------------

  Write-Host "== Invoke-BoundedDownload still transfers a healthy response"

  $server = $null
  try {
    $bodySize = 262144
    $server = Start-StallServer -Mode "full" -BodySize $bodySize
    $out = Join-Path $scratchRoot "full.bin"

    $written = Invoke-BoundedDownload -Url $server.Url -OutFile $out -StallSeconds 20 -TotalSeconds 60 -ProgressSeconds 1

    Assert-Equal -Expected $bodySize -Actual $written `
      -Message "the downloader reports the number of bytes it wrote"
    Assert-True -Condition (Test-Path -LiteralPath $out -PathType Leaf) `
      -Message "the output file exists"
    $actual = [System.IO.File]::ReadAllBytes($out)
    Assert-Equal -Expected $bodySize -Actual $actual.Length `
      -Message "the output file is the full declared length"

    $corrupt = $false
    for ($i = 0; $i -lt $actual.Length; $i++) {
      if ($actual[$i] -ne [byte](65 + ($i % 26))) { $corrupt = $true; break }
    }
    Assert-True -Condition (-not $corrupt) `
      -Message "the bytes on disk are the bytes the server sent, in order"
  } finally {
    Stop-StallServer -Server $server
  }

  # -------------------------------------------------------------------------
  # Part 5 - the same guarantee for the native commands the MSYS2 leg runs.
  # -------------------------------------------------------------------------

  Write-Host "== Invoke-BoundedNativeCommand bounds a child that never exits"

  $pwshPath = Get-PwshPath

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $threw = $false
  $message = ""
  try {
    Invoke-BoundedNativeCommand `
      -FilePath $pwshPath `
      -ArgumentList @("-NoProfile", "-Command", "Start-Sleep -Seconds 900") `
      -Activity "a child that never exits" `
      -TimeoutSeconds 5 | Out-Null
  } catch {
    $threw = $true
    $message = [string]$_.Exception.Message
  }
  $sw.Stop()

  Assert-True -Condition $threw `
    -Message "a child that never exits is killed and THROWS"
  Assert-True -Condition ($sw.Elapsed.TotalSeconds -lt 25) `
    -Message "the kill happens at the bound (took $([int]$sw.Elapsed.TotalSeconds)s, bound was 5s)"
  Assert-True -Condition ($message -match "did not finish within") `
    -Message "the error says the command overran its bound: '$message'"
  Assert-True -Condition ($message -match "a child that never exits") `
    -Message "the error names the activity, not just a process id"

  Write-Host "== Invoke-BoundedNativeCommand gives the child an empty stdin"

  # A prompt in CI is indistinguishable from a hang unless stdin is closed.
  # With an empty stdin the read returns EOF immediately, so a child that
  # would otherwise wait forever exits on its own.
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $exit = -1
  $threw = $false
  try {
    $exit = Invoke-BoundedNativeCommand `
      -FilePath $pwshPath `
      -ArgumentList @("-NoProfile", "-Command", "`$null = [Console]::In.ReadToEnd(); exit 7") `
      -Activity "a child that reads stdin" `
      -TimeoutSeconds 20
  } catch {
    $threw = $true
  }
  $sw.Stop()

  Assert-True -Condition (-not $threw) `
    -Message "a child that reads stdin does NOT block: it sees EOF and exits"
  Assert-Equal -Expected 7 -Actual $exit `
    -Message "and its real exit code is returned to the caller"
  Assert-True -Condition ($sw.Elapsed.TotalSeconds -lt 20) `
    -Message "it exits well inside the bound (took $([int]$sw.Elapsed.TotalSeconds)s)"

  $exit = Invoke-BoundedNativeCommand `
    -FilePath $pwshPath `
    -ArgumentList @("-NoProfile", "-Command", "exit 0") `
    -Activity "a child that succeeds" `
    -TimeoutSeconds 60
  Assert-Equal -Expected 0 -Actual $exit `
    -Message "a successful child still reports exit 0"

  # -------------------------------------------------------------------------
  # Part 5b - the child receives the ARGUMENTS IT WAS GIVEN.
  #
  # THIS GROUP EXISTS BECAUSE ITS ABSENCE SHIPPED A BUG.
  #
  # Part 5 above drives the timeout and the stdin contracts hard, and passed
  # throughout. It never once passed an argument containing a space, and every
  # argument in the MSYS2 leg that matters is one long, space-filled shell
  # command. So the suite was green while the one production call that carried
  # such an argument was silently destroying it: `Start-Process -ArgumentList`
  # concatenates its array with spaces and quotes nothing, so
  #
  #     bash -lc "set -euo pipefail; pacman -Sy --noconfirm --needed <pkgs>"
  #
  # reached bash as `-lc` followed by `set`, and bash dutifully ran the
  # BUILTIN `set` -- which exits 0. Nothing was installed, the caller's
  # `exit -ne 0` guard could not fire, and the run failed several checks later
  # on a missing gcc.
  #
  # The assertion is therefore on the RECEIVED argv, not on any string this
  # process builds. A check that inspected our own command-line construction
  # would be asserting the bug's own assumptions back at itself. Here a real
  # child process is launched, and it reports what the operating system
  # actually handed it; the round trip through `CreateProcess`/`execve` is the
  # thing under test, and it is the only place the defect was visible.
  #
  # The child reads `[Environment]::GetCommandLineArgs()` rather than
  # PowerShell's `$args`, deliberately: that is the raw process argv, before
  # any PowerShell parameter binding, so nothing between the kernel and the
  # assertion can paper over a mangled argument.
  # -------------------------------------------------------------------------

  Write-Host "== Invoke-BoundedNativeCommand delivers arguments to the child intact"

  # Everything after the sentinel is reported back, separated by U+001F (unit
  # separator) -- a character that cannot occur in a Windows command line, so
  # the separator can never be confused with argument content.
  $echoArgvScript = Join-Path $scratchRoot "echo-argv.ps1"
  Set-Content -LiteralPath $echoArgvScript -Encoding UTF8 -Value @'
$all = [Environment]::GetCommandLineArgs()
$begin = [Array]::IndexOf($all, "--ct-argv-begin")
if ($begin -lt 0) { exit 3 }
$dest = $all[$begin + 1]
$rest = @($all | Select-Object -Skip ($begin + 2))
[System.IO.File]::WriteAllText($dest, ($rest -join ([string][char]31)))
exit 0
'@

  # Named cases, each one an argument shape that a bootstrap step really does
  # pass. The first is the exact shape that broke.
  $argvCases = [ordered]@{
    "a shell command with spaces (the MSYS2 pacman shape)" =
      "set -euo pipefail; pacman -Sy --noconfirm --needed mingw-w64-x86_64-gcc make pkgconf"
    "a Windows path containing a space" =
      'C:\Program Files\Some Dir\tool.exe'
    "a path with a space AND a trailing backslash (the classic quoting trap)" =
      'C:\Program Files\Some Dir\'
    "an argument containing double quotes" =
      'say "hello world" twice'
    "an argument with several consecutive spaces" = "a  b   c"
  }
  $expectedArgs = @($argvCases.Values)

  $argvOut = Join-Path $scratchRoot "received-argv.txt"
  $argvExit = Invoke-BoundedNativeCommand `
    -FilePath $pwshPath `
    -ArgumentList (@("-NoProfile", "-File", $echoArgvScript, "--ct-argv-begin", $argvOut) + $expectedArgs) `
    -Activity "a child that reports the arguments it received" `
    -TimeoutSeconds 120

  Assert-Equal -Expected 0 -Actual $argvExit `
    -Message "the argv-reporting child ran to completion"

  $receivedArgs = @()
  if (Test-Path -LiteralPath $argvOut -PathType Leaf) {
    $receivedArgs = @([System.IO.File]::ReadAllText($argvOut) -split ([string][char]31))
  }

  # The count is the load-bearing check and the one that would have caught the
  # regression on its own: the pacman argument alone went from 1 argument to 8.
  Assert-Equal -Expected $expectedArgs.Count -Actual $receivedArgs.Count `
    -Message "the child receives exactly as many arguments as it was given (a split argument shows up here first)"

  $index = 0
  foreach ($case in $argvCases.GetEnumerator()) {
    $actual = if ($index -lt $receivedArgs.Count) { $receivedArgs[$index] } else { "<missing>" }
    # -ceq: case-sensitive and exact. A quoting bug that only changes case is
    # not a thing, but a comparison that silently coerces is.
    Assert-True -Condition ($actual -ceq $case.Value) `
      -Message ("$($case.Key) survives intact: expected [$($case.Value)], got [$actual]")
    $index++
  }

  # And the same guarantee stated the way the caller needs it: the MSYS2 leg
  # passes TWO arguments to bash, and the second is one whole shell program.
  # This is a separate check from the loop above because it is the invariant
  # the production call depends on, and it should fail by name.
  $bashShapeOut = Join-Path $scratchRoot "received-bash-shape.txt"
  $shellCommand = "set -euo pipefail; pacman -Sy --noconfirm --needed make pkgconf"
  Invoke-BoundedNativeCommand `
    -FilePath $pwshPath `
    -ArgumentList @("-NoProfile", "-File", $echoArgvScript, "--ct-argv-begin", $bashShapeOut, "-lc", $shellCommand) `
    -Activity "a child standing in for bash -lc" `
    -TimeoutSeconds 120 | Out-Null

  $bashShape = @([System.IO.File]::ReadAllText($bashShapeOut) -split ([string][char]31))
  Assert-Equal -Expected 2 -Actual $bashShape.Count `
    -Message 'bash -lc <command> arrives as exactly two arguments, not as the command word count'
  Assert-True -Condition ($bashShape.Count -eq 2 -and $bashShape[1] -ceq $shellCommand) `
    -Message "and the second argument is the WHOLE shell program, not its first word"

  # The empty argument gets its own invocation, LAST, and the placement is
  # deliberate rather than cosmetic. Passing "" also exercises the parameter
  # BINDER (a mandatory [string[]] rejects an empty element unless the
  # parameter allows it), so a build in which that attribute is missing fails
  # here on binding, before the child is ever started. Folded into the group
  # above, that early abort would pre-empt the checks that actually describe a
  # split argument -- the failure would be real but would name the wrong
  # thing.
  $emptyArgOut = Join-Path $scratchRoot "received-empty-arg.txt"
  $emptyArgCase = @("before", "", "after")
  $emptyArgBound = $true
  try {
    Invoke-BoundedNativeCommand `
      -FilePath $pwshPath `
      -ArgumentList (@("-NoProfile", "-File", $echoArgvScript, "--ct-argv-begin", $emptyArgOut) + $emptyArgCase) `
      -Activity "a child given an empty argument" `
      -TimeoutSeconds 120 | Out-Null
  } catch {
    $emptyArgBound = $false
    Write-Host "  (empty-argument call failed: $([string]$_.Exception.Message))"
  }
  Assert-True -Condition $emptyArgBound `
    -Message "an empty argument is accepted rather than rejected by the parameter binder"
  if ($emptyArgBound) {
    $emptyArgReceived = @([System.IO.File]::ReadAllText($emptyArgOut) -split ([string][char]31))
    Assert-Equal -Expected 3 -Actual $emptyArgReceived.Count `
      -Message "an empty argument still occupies a position rather than vanishing"
    Assert-True -Condition (
      $emptyArgReceived.Count -eq 3 -and
      $emptyArgReceived[0] -ceq "before" -and
      $emptyArgReceived[1] -ceq "" -and
      $emptyArgReceived[2] -ceq "after") `
      -Message "and the arguments around it keep their positions"
  }

  # -------------------------------------------------------------------------
  # Part 6 - the bounds are configurable, and reject nonsense loudly.
  # -------------------------------------------------------------------------

  Write-Host "== the bounds are configurable"

  Assert-Equal -Expected 42 -Actual (Get-PositiveIntSetting -Name "CT_TEST_UNSET_BOUND" -Default 42) `
    -Message "an unset override falls back to the default"

  [Environment]::SetEnvironmentVariable("CT_TEST_BOUND", "17")
  try {
    Assert-Equal -Expected 17 -Actual (Get-PositiveIntSetting -Name "CT_TEST_BOUND" -Default 42) `
      -Message "a set override wins over the default"
  } finally {
    [Environment]::SetEnvironmentVariable("CT_TEST_BOUND", $null)
  }

  foreach ($bad in @("0", "-5", "soon")) {
    [Environment]::SetEnvironmentVariable("CT_TEST_BOUND", $bad)
    try {
      $rejected = $false
      try {
        Get-PositiveIntSetting -Name "CT_TEST_BOUND" -Default 42 | Out-Null
      } catch {
        $rejected = $true
      }
      Assert-True -Condition $rejected `
        -Message "an override of '$bad' is rejected rather than silently ignored"
    } finally {
      [Environment]::SetEnvironmentVariable("CT_TEST_BOUND", $null)
    }
  }

  # -------------------------------------------------------------------------
  # Part 6b - the pre-existing operator knob keeps working, including its
  # documented "0" escape, which must NOT be allowed to restore an unbounded
  # download. 0 opts out of the TOTAL budget only; the inactivity clock still
  # has to terminate the transfer, because that is the bound the lane needed.
  # -------------------------------------------------------------------------

  Write-Host "== WINDOWS_DIY_DOWNLOAD_TIMEOUT_SECONDS keeps its meaning"

  [Environment]::SetEnvironmentVariable("WINDOWS_DIY_DOWNLOAD_TIMEOUT_SECONDS", "900")
  try {
    Assert-Equal -Expected 900 -Actual (Get-DownloadTimeoutSeconds) `
      -Message "an explicit total budget is passed through"
  } finally {
    [Environment]::SetEnvironmentVariable("WINDOWS_DIY_DOWNLOAD_TIMEOUT_SECONDS", $null)
  }

  Assert-Equal -Expected 0 -Actual (Get-DownloadTimeoutSeconds) `
    -Message "unset defers to the bound's own default rather than imposing one here"

  [Environment]::SetEnvironmentVariable("WINDOWS_DIY_DOWNLOAD_TIMEOUT_SECONDS", "-1")
  try {
    $rejected = $false
    try { Get-DownloadTimeoutSeconds | Out-Null } catch { $rejected = $true }
    Assert-True -Condition $rejected -Message "a negative total budget is rejected"
  } finally {
    [Environment]::SetEnvironmentVariable("WINDOWS_DIY_DOWNLOAD_TIMEOUT_SECONDS", $null)
  }

  # The load-bearing one: "0" used to mean "wait forever". It must now mean
  # "no total budget", with the stall clock still ending a dead transfer.
  [Environment]::SetEnvironmentVariable("WINDOWS_DIY_DOWNLOAD_TIMEOUT_SECONDS", "0")
  $server = $null
  try {
    Assert-True -Condition ((Get-DownloadTimeoutSeconds) -gt 86400) `
      -Message "0 still opts out of any practical total budget"

    $server = Start-StallServer -Mode "stall"
    $out = Join-Path $scratchRoot "optout.bin"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $threw = $false
    $message = ""
    try {
      Invoke-BoundedDownload -Url $server.Url -OutFile $out `
        -StallSeconds 5 -TotalSeconds (Get-DownloadTimeoutSeconds) -ProgressSeconds 1 | Out-Null
    } catch {
      $threw = $true
      $message = [string]$_.Exception.Message
    }
    $sw.Stop()

    Assert-True -Condition $threw `
      -Message "but a stalled transfer STILL fails, even with the total budget opted out"
    Assert-True -Condition ($sw.Elapsed.TotalSeconds -lt 25) `
      -Message "and it still fails at the inactivity bound (took $([int]$sw.Elapsed.TotalSeconds)s)"
    Assert-True -Condition ($message -match "stalled") `
      -Message "reported as a stall, not as a budget overrun: '$message'"
  } finally {
    Stop-StallServer -Server $server
    [Environment]::SetEnvironmentVariable("WINDOWS_DIY_DOWNLOAD_TIMEOUT_SECONDS", $null)
  }

  # -------------------------------------------------------------------------
  # Part 6c - the total budget is shared across RETRIES.
  #
  # This is the check that nearly did not exist, and it matters more than it
  # looks. Bounding a single attempt is not the same as bounding the operation:
  # Invoke-WithRetry makes 4 attempts, so a per-attempt budget would give a
  # worst case of 4 x the budget plus backoff. With the shipped defaults that is
  # ~120 minutes for one component -- longer than the job cap the Windows jobs
  # carry, which means the job would be killed with no error at all. That is the
  # exact failure mode the rest of this file exists to eliminate, reintroduced
  # by the retry wrapper.
  # -------------------------------------------------------------------------

  Write-Host "== the total budget is shared across retries, not per attempt"

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  Assert-Equal -Expected 0 -Actual (Get-DownloadDeadlineSeconds -Elapsed $sw -Budget 0 -Url "http://x") `
    -Message "a deferred budget (0) stays deferred rather than becoming a deadline"

  $remaining = Get-DownloadDeadlineSeconds -Elapsed $sw -Budget 100 -Url "http://x"
  Assert-True -Condition ($remaining -gt 90 -and $remaining -le 100) `
    -Message "the first attempt gets essentially the whole budget (got ${remaining}s of 100s)"

  # A stopwatch that has already run past the budget stands in for "three
  # attempts have already been made"; the fourth must be refused outright
  # rather than handed another full budget.
  $spent = [System.Diagnostics.Stopwatch]::StartNew()
  Start-Sleep -Milliseconds 1200
  $refused = $false
  $message = ""
  try {
    Get-DownloadDeadlineSeconds -Elapsed $spent -Budget 1 -Url "http://example.invalid/a.bin" | Out-Null
  } catch {
    $refused = $true
    $message = [string]$_.Exception.Message
  }
  Assert-True -Condition $refused `
    -Message "once the shared budget is spent, a further attempt is REFUSED rather than given a fresh one"
  Assert-True -Condition ($message -match "across retries") `
    -Message "and the error says the budget was exhausted across retries: '$message'"

  # End to end: a permanently stalled server must not be able to consume
  # attempts x budget. With a 4s shared budget and a 2s stall bound, all four
  # attempts together have to finish inside the budget plus backoff, NOT inside
  # 4 x budget.
  $server = $null
  try {
    $server = Start-StallServer -Mode "trickle"
    $out = Join-Path $scratchRoot "sharedbudget.bin"
    [Environment]::SetEnvironmentVariable("WINDOWS_DIY_DOWNLOAD_TIMEOUT_SECONDS", "4")

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $threw = $false
    try { Download-File -Url $server.Url -OutFile $out } catch { $threw = $true }
    $sw.Stop()

    Assert-True -Condition $threw -Message "a trickling server still fails Download-File"
    Assert-True -Condition ($sw.Elapsed.TotalSeconds -lt 20) `
      -Message "and all retries together stay near the SHARED budget, not 4x it (took $([int]$sw.Elapsed.TotalSeconds)s, budget 4s)"
  } finally {
    [Environment]::SetEnvironmentVariable("WINDOWS_DIY_DOWNLOAD_TIMEOUT_SECONDS", $null)
    Stop-StallServer -Server $server
  }

  # -------------------------------------------------------------------------
  # Part 7 - the debugger cannot strand a job.
  # -------------------------------------------------------------------------

  Write-Host "== the interactive-debugger guard"

  $savedPreference = $ErrorActionPreference
  try {
    $global:ErrorActionPreference = "Break"
    $applied = @(Assert-NonInteractiveDebugger)
    Assert-Equal -Expected "Stop" -Actual $global:ErrorActionPreference `
      -Message "an inherited ErrorActionPreference of 'Break' is forced back to 'Stop'"
    Assert-True -Condition (@($applied | Where-Object { $_ -match "Break" }).Count -eq 1) `
      -Message "and the guard REPORTS that it had to intervene, rather than fixing it silently"
  } finally {
    $global:ErrorActionPreference = $savedPreference
  }

  $applied = @(Assert-NonInteractiveDebugger)
  Assert-Equal -Expected 0 -Actual $applied.Count `
    -Message "on a clean host the guard reports nothing"

} finally {
  Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
  Get-Job -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "download-stall-bound: $($script:Checks - $script:Failures)/$($script:Checks) checks passed"
if ($script:Failures -gt 0) {
  throw "download-stall-bound: $($script:Failures) check(s) failed."
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# HOW LONG A SINGLE TOOLCHAIN DOWNLOAD MAY BLOCK BEFORE IT IS A FAILURE.
#
# Every toolchain in this file is fetched through `Download-File` /
# `Download-String`, and before these bounds existed a single stalled socket
# parked the ENTIRE Windows dev-env bootstrap. `Invoke-WithRetry` did not help:
# it bounds the number of attempts (4), never the duration of one, so 4 x
# infinite is still infinite.
#
# CORRECTION, and it is the whole reason this file no longer uses
# `Invoke-WebRequest` for downloads. An earlier revision of this comment stated
# that under `pwsh` (HttpClient) `-TimeoutSec` "covers the whole transfer, body
# included -- not just the response headers". THAT IS FALSE, and the fix built
# on it did not work. `Invoke-WebRequest -OutFile` reads the response with
# `HttpCompletionOption.ResponseHeadersRead` and then streams to disk, so the
# HttpClient timeout `-TimeoutSec` sets expires only up to the response
# HEADERS; once the body has started arriving nothing bounds the read. Measured
# on pwsh 7 against a server that sends headers, sends a few bytes, and then
# stops: `-TimeoutSec 5` was still running 90 seconds later. A mid-body stall
# -- which is the shape actually observed on this lane -- is therefore NOT
# bounded by `-TimeoutSec` at any value.
#
# `ci/test/download-stall-bound.ps1` asserts this against a real loopback
# server rather than restating it, so the day a future PowerShell changes it,
# the test says so instead of a comment continuing to be believed.
#
# This function survives as the operator knob it always was; it now resolves
# the TOTAL budget for `Invoke-BoundedDownload`, which additionally enforces an
# inactivity bound that no `Invoke-WebRequest` option can express.
#
# The value has to clear the largest asset this bootstrap pulls: the WinDbg
# msixbundle in ensure-ttd.ps1 is ~767 MB, so a total-transfer budget of a few
# minutes would convert a slow link into a spurious red. 30 minutes is ~0.4 MB/s
# sustained for that asset -- far below any healthy runner, far above a socket
# that has stopped moving. Override for a genuinely slow network with
# WINDOWS_DIY_DOWNLOAD_TIMEOUT_SECONDS.
#
# 0 keeps its documented meaning of "no TOTAL budget", so an operator who set
# it does not silently get a new cap. It no longer means "no bound at all":
# the inactivity clock still applies and still guarantees termination, which is
# the property the lane actually needed.
function Get-DownloadTimeoutSeconds {
  $raw = [Environment]::GetEnvironmentVariable("WINDOWS_DIY_DOWNLOAD_TIMEOUT_SECONDS")
  if ([string]::IsNullOrWhiteSpace($raw)) {
    # Fall through to the bound's own default/override resolution.
    return 0
  }

  $parsed = 0
  if (-not [int]::TryParse($raw.Trim(), [ref]$parsed) -or $parsed -lt 0) {
    throw "WINDOWS_DIY_DOWNLOAD_TIMEOUT_SECONDS must be a non-negative integer (got '$raw')."
  }
  if ($parsed -eq 0) { return [int]::MaxValue }
  return $parsed
}

function Assert-NonInteractiveDebugger {
  <#
    .SYNOPSIS
      Make the PowerShell debugger unreachable, and report whether it was.

    .DESCRIPTION
      A CI job has no terminal, so a debugger prompt is not a debugging aid --
      it is a block that nothing will ever answer. One bootstrap job did reach
      it:

          Entering debug mode. Use h or ? for help.
          At ...\Microsoft.PowerShell.Archive.psm1:418 char:79
          [DBG]: PS C:\actions-runner\_work\codetracer\codetracer>>

      Be precise about what that job proves, because the tempting reading is
      wrong. It is NOT an instance of the multi-hour bootstrap hang, and this
      guard is not the fix for that. The break landed 0.6s BEFORE the runner's
      "The operation was canceled", in `Expand-Archive`'s partial-expansion
      cleanup path -- i.e. the host broke into the debugger while unwinding in
      response to the cancellation, rather than the debugger causing it. The
      job then ran its post-steps and completed normally. Nothing waited on the
      prompt.

      So this is a latent hazard rather than an observed outage: on a host that
      DID arrive with the debugger reachable, the same break on a real error
      would block instead of unwinding. Nothing in this repository sets
      `$ErrorActionPreference = 'Break'` or
      calls `Set-PSBreakpoint`, and the workflow's `shell: pwsh` expands to
      `pwsh -command ". '{0}'"` with neither `-NonInteractive` nor
      `-NoProfile`. So the debugger is reachable through host state this repo
      does not own -- a machine or user profile on the runner image being the
      obvious candidate -- and the durable fix is to refuse to inherit it
      rather than to hope it is absent.

      Returns the guards it actually had to apply, so a caller can log that
      the runner arrived in this state instead of silently papering over it.
  #>

  $applied = @()

  if ($ErrorActionPreference -eq "Break") {
    $script:ErrorActionPreference = "Stop"
    $global:ErrorActionPreference = "Stop"
    $applied += "ErrorActionPreference was 'Break'; forced to 'Stop'"
  }

  $breakpoints = @(Get-PSBreakpoint -ErrorAction SilentlyContinue)
  if ($breakpoints.Count -gt 0) {
    $breakpoints | Remove-PSBreakpoint -ErrorAction SilentlyContinue
    $applied += "removed $($breakpoints.Count) inherited breakpoint(s)"
  }

  Set-PSDebug -Off

  return $applied
}

function Invoke-WithRetry {
  param(
    [Parameter(Mandatory = $true)]
    [scriptblock]$Script,
    [int]$Attempts = 4,
    [int]$DelaySeconds = 2
  )

  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    try {
      return & $Script
    } catch {
      if ($attempt -ge $Attempts) {
        throw
      }
      Start-Sleep -Seconds ($DelaySeconds * $attempt)
    }
  }
}

function Get-WindowsArch {
  $overrideRaw = [Environment]::GetEnvironmentVariable("WINDOWS_DIY_ARCH_OVERRIDE")
  if (-not [string]::IsNullOrWhiteSpace($overrideRaw)) {
    $override = $overrideRaw.Trim().ToLowerInvariant()
    switch ($override) {
      "x64" {
        Write-Warning "WINDOWS_DIY_ARCH_OVERRIDE=x64 is forcing architecture detection."
        return "x64"
      }
      "arm64" {
        Write-Warning "WINDOWS_DIY_ARCH_OVERRIDE=arm64 is forcing architecture detection."
        return "arm64"
      }
      default {
        throw "Unsupported WINDOWS_DIY_ARCH_OVERRIDE value '$overrideRaw'. Supported values: x64, arm64."
      }
    }
  }

  $systemType = (Get-CimInstance Win32_ComputerSystem).SystemType.ToLowerInvariant()
  if ($systemType.Contains("arm64")) { return "arm64" }
  if ($systemType.Contains("x64") -or $systemType.Contains("x86_64")) { return "x64" }
  throw "Unsupported Windows architecture '$systemType'."
}

function Get-ExpectedSha256 {
  param(
    [Parameter(Mandatory = $true)][string]$ShaSource,
    [Parameter(Mandatory = $true)][string]$AssetName
  )

  foreach ($line in ($ShaSource -split "`n")) {
    $trimmed = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
      continue
    }

    if ($trimmed -match "^(?<hash>[A-Fa-f0-9]{64})\s+\*?(?<name>.+)$") {
      if ($Matches.name.Trim() -eq $AssetName) {
        return $Matches.hash.ToLowerInvariant()
      }
    } elseif ($trimmed -match "^[A-Fa-f0-9]{64}$") {
      return $trimmed.ToLowerInvariant()
    }
  }

  throw "Did not find SHA256 entry for '$AssetName'."
}

function Assert-FileSha256 {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Expected
  )

  $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $Expected.ToLowerInvariant()) {
    throw "Checksum mismatch for '$Path'. Expected '$Expected', got '$actual'."
  }
}

# Bootstrap downloads are bounded in wall-clock time, and the bound is on
# INACTIVITY rather than only on the total.
#
# `Invoke-WebRequest -OutFile` cannot express this. Its `-TimeoutSec` covers
# the request up to the response headers; once the body has started arriving
# it does not bound the read at all, so a connection that delivers headers and
# then stops sending bytes blocks forever. That is measured, not assumed --
# `ci/test/download-stall-bound.ps1` asserts it against a server that stalls
# mid-body, with and without `-TimeoutSec`, and both hang. Retrying does not
# help either: `Invoke-WithRetry` only re-runs on a throw, and a stalled
# stream never throws.
#
# So the download is streamed by hand with two clocks:
#
#   * a STALL clock, reset on every chunk that actually arrives, which is what
#     catches the mid-body stall; and
#   * a TOTAL clock, which catches a transfer that trickles just fast enough
#     to keep resetting the stall clock but will never finish.
#
# Progress is printed on an interval as well, so a slow-but-live download is
# distinguishable from a dead one in the log rather than looking identical to
# it. Both are recoverable positions; six hours of silence is not.
$script:DownloadStallSecondsDefault = 120
$script:DownloadTotalSecondsDefault = 1800
$script:DownloadProgressSecondsDefault = 30

function Get-PositiveIntSetting {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][int]$Default
  )

  $raw = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return $Default
  }

  $parsed = 0
  if (-not [int]::TryParse($raw.Trim(), [ref]$parsed) -or $parsed -le 0) {
    throw "Invalid $Name value '$raw'. Expected a positive whole number of seconds."
  }

  return $parsed
}

function Format-DownloadBytes {
  param([Parameter(Mandatory = $true)][long]$Bytes)

  if ($Bytes -ge 1048576) {
    return ("{0:N1} MiB" -f ($Bytes / 1048576))
  }
  if ($Bytes -ge 1024) {
    return ("{0:N1} KiB" -f ($Bytes / 1024))
  }
  return "$Bytes B"
}

function Invoke-BoundedDownload {
  <#
    .SYNOPSIS
      Stream $Url to $OutFile, failing loudly if the transfer stalls or
      overruns its total budget.

    .DESCRIPTION
      Throws on a stall, so the caller's Invoke-WithRetry can retry a
      genuinely transient stall, and so the FINAL failure is a real error
      with a real message instead of a job that is killed hours later by the
      workflow timeout with no indication of where it stopped.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [int]$StallSeconds = 0,
    [int]$TotalSeconds = 0,
    [int]$ProgressSeconds = 0
  )

  if ($StallSeconds -le 0) {
    $StallSeconds = Get-PositiveIntSetting -Name "CODETRACER_DOWNLOAD_STALL_SECONDS" -Default $script:DownloadStallSecondsDefault
  }
  if ($TotalSeconds -le 0) {
    $TotalSeconds = Get-PositiveIntSetting -Name "CODETRACER_DOWNLOAD_TIMEOUT_SECONDS" -Default $script:DownloadTotalSecondsDefault
  }
  if ($ProgressSeconds -le 0) {
    $ProgressSeconds = Get-PositiveIntSetting -Name "CODETRACER_DOWNLOAD_PROGRESS_SECONDS" -Default $script:DownloadProgressSecondsDefault
  }

  $parent = Split-Path -Parent $OutFile
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }

  $client = $null
  $response = $null
  $source = $null
  $target = $null
  $cts = $null
  $total = [long]0
  $completed = $false
  $overall = [System.Diagnostics.Stopwatch]::StartNew()

  try {
    $cts = [System.Threading.CancellationTokenSource]::new()
    $client = [System.Net.Http.HttpClient]::new()
    # The HttpClient-level timeout is deliberately infinite: the two clocks
    # below are the bound, and an HttpClient timeout would abort a large but
    # perfectly healthy download.
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan

    $cts.CancelAfter([TimeSpan]::FromSeconds([Math]::Min($StallSeconds, $TotalSeconds)))

    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
    $response = $client.SendAsync(
      $request,
      [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead,
      $cts.Token).GetAwaiter().GetResult()
    $response.EnsureSuccessStatusCode() | Out-Null

    $expected = [long]0
    if ($null -ne $response.Content.Headers.ContentLength) {
      $expected = [long]$response.Content.Headers.ContentLength
    }

    $source = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $target = [System.IO.FileStream]::new(
      $OutFile,
      [System.IO.FileMode]::Create,
      [System.IO.FileAccess]::Write,
      [System.IO.FileShare]::None)

    $buffer = [byte[]]::new(131072)
    $lastReport = [double]0

    while ($true) {
      $remaining = $TotalSeconds - $overall.Elapsed.TotalSeconds
      if ($remaining -le 0) {
        throw "Download of '$Url' exceeded its total budget of ${TotalSeconds}s after $(Format-DownloadBytes -Bytes $total). Raise CODETRACER_DOWNLOAD_TIMEOUT_SECONDS if this mirror is legitimately this slow."
      }

      # Re-arm the inactivity clock before each read, never letting it run
      # past the total budget.
      $window = [Math]::Min([double]$StallSeconds, $remaining)
      $cts.CancelAfter([TimeSpan]::FromSeconds($window))

      $read = $source.ReadAsync($buffer, 0, $buffer.Length, $cts.Token).GetAwaiter().GetResult()
      if ($read -le 0) { break }

      $target.Write($buffer, 0, $read)
      $total += $read

      if (($overall.Elapsed.TotalSeconds - $lastReport) -ge $ProgressSeconds) {
        $lastReport = $overall.Elapsed.TotalSeconds
        $sofar = Format-DownloadBytes -Bytes $total
        if ($expected -gt 0) {
          $pct = [Math]::Round(($total * 100.0) / $expected, 1)
          Write-Host "  ... $sofar of $(Format-DownloadBytes -Bytes $expected) ($pct%) after $([int]$overall.Elapsed.TotalSeconds)s"
        } else {
          Write-Host "  ... $sofar after $([int]$overall.Elapsed.TotalSeconds)s"
        }
      }
    }

    $target.Flush()
    if ($expected -gt 0 -and $total -ne $expected) {
      throw "Download of '$Url' ended early: got $(Format-DownloadBytes -Bytes $total) of $(Format-DownloadBytes -Bytes $expected)."
    }

    $completed = $true
    return $total
  } catch [System.OperationCanceledException] {
    # Both clocks cancel the same token, so the token alone does not say which
    # one fired. Ask the elapsed time instead: a transfer that trickled just
    # fast enough to keep resetting the inactivity clock, and then ran out its
    # total budget mid-read, must not be reported as a stall -- the two have
    # different remedies, and mislabelling them sends the reader after the
    # wrong one.
    if ($overall.Elapsed.TotalSeconds -ge $TotalSeconds) {
      throw "Download of '$Url' exceeded its total budget of ${TotalSeconds}s after $(Format-DownloadBytes -Bytes $total). Raise CODETRACER_DOWNLOAD_TIMEOUT_SECONDS if this mirror is legitimately this slow."
    }
    throw "Download of '$Url' stalled: no data for ${StallSeconds}s (received $(Format-DownloadBytes -Bytes $total)). Bounds are CODETRACER_DOWNLOAD_STALL_SECONDS / CODETRACER_DOWNLOAD_TIMEOUT_SECONDS."
  } finally {
    if ($null -ne $target) { $target.Dispose() }
    if ($null -ne $source) { $source.Dispose() }
    if ($null -ne $response) { $response.Dispose() }
    if ($null -ne $client) { $client.Dispose() }
    if ($null -ne $cts) { $cts.Dispose() }
    # Never leave a half-written file where a later run could mistake it for
    # a cached artefact. The SHA gate would catch it, but the error it
    # produces would name a checksum rather than the truncated transfer.
    if (-not $completed -and (Test-Path -LiteralPath $OutFile -PathType Leaf)) {
      Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
    }
  }
}

# THE TOTAL BUDGET IS SHARED ACROSS RETRIES, AND THAT IS NOT A DETAIL.
#
# `Invoke-WithRetry` makes 4 attempts. If each attempt were given the FULL
# total budget, the worst case would be 4 x 1800s plus backoff = ~120 minutes
# for a single component -- longer than the `timeout-minutes` the eph-win-x64
# jobs now carry. The job cap would fire first, killing the job with no error
# and no indication of which download was responsible, which is precisely the
# failure this whole change exists to remove. Bounding one attempt is not the
# same as bounding the operation.
#
# So the deadline is computed ONCE, outside the retry loop, and each attempt is
# given only the time that remains. The retries still buy what they are for --
# a connection reset or a 5xx fails fast and is worth re-trying -- without the
# multiplier turning a bounded download back into an unbounded one.
#
# The stall clock is deliberately NOT shared: it is a per-attempt inactivity
# bound, and re-arming it on a fresh connection is the correct behaviour.
function Get-DownloadDeadlineSeconds {
  param(
    [Parameter(Mandatory = $true)][System.Diagnostics.Stopwatch]$Elapsed,
    [Parameter(Mandatory = $true)][int]$Budget,
    [Parameter(Mandatory = $true)][string]$Url
  )

  # 0 means "defer to Invoke-BoundedDownload's own default/override"; there is
  # no shared deadline to enforce in that case beyond what it applies itself.
  if ($Budget -le 0) { return 0 }

  $remaining = [int][Math]::Floor($Budget - $Elapsed.Elapsed.TotalSeconds)
  if ($remaining -le 0) {
    throw "Download of '$Url' exhausted its total budget of ${Budget}s across retries."
  }
  return $remaining
}

function Download-File {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$OutFile
  )

  $timeoutSeconds = Get-DownloadTimeoutSeconds
  $elapsed = [System.Diagnostics.Stopwatch]::StartNew()
  Invoke-WithRetry -Script {
    $remaining = Get-DownloadDeadlineSeconds -Elapsed $elapsed -Budget $timeoutSeconds -Url $Url
    Invoke-BoundedDownload -Url $Url -OutFile $OutFile -TotalSeconds $remaining
  } | Out-Null
}

function Download-String {
  param([Parameter(Mandatory = $true)][string]$Url)

  $timeoutSeconds = Get-DownloadTimeoutSeconds
  $elapsed = [System.Diagnostics.Stopwatch]::StartNew()
  $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("ct-download-" + [Guid]::NewGuid().ToString("N"))
  try {
    Invoke-WithRetry -Script {
      # Shared across retries -- see the note above Download-File.
      $remaining = Get-DownloadDeadlineSeconds -Elapsed $elapsed -Budget $timeoutSeconds -Url $Url
      Invoke-BoundedDownload -Url $Url -OutFile $scratch -TotalSeconds $remaining
    } | Out-Null
    $content = [System.IO.File]::ReadAllBytes($scratch)
  } finally {
    if (Test-Path -LiteralPath $scratch -PathType Leaf) {
      Remove-Item -LiteralPath $scratch -Force -ErrorAction SilentlyContinue
    }
  }

  if ($content -is [byte[]]) {
    return [System.Text.Encoding]::UTF8.GetString($content)
  }
  if (
    $content -is [object[]] -and
    $content.Length -gt 0 -and
    $content[0] -is [byte]
  ) {
    return [System.Text.Encoding]::UTF8.GetString([byte[]]$content)
  }

  return [string]$content
}

$script:NativeCommandTimeoutSecondsDefault = 1800

function Invoke-BoundedNativeCommand {
  <#
    .SYNOPSIS
      Run a native command with a wall-clock bound and a closed stdin.

    .DESCRIPTION
      Three hazards. Stdin is the one that is easy to miss, and argument
      quoting is the one that is easy to get wrong.

      A bootstrap step that shells out to a package manager or an archiver
      inherits the runner's stdin. If the child ever decides to prompt, it
      blocks on a read that nothing will ever answer, and the job dies at the
      workflow timeout with the prompt buried in a log nobody watches. Giving
      the child an immediately-closed stdin turns that into an instant EOF, so
      a prompt becomes a fast failure instead of a silent one.

      The timeout covers the second: a child that is not prompting but is
      simply stuck -- a package mirror that accepted the connection and then
      stopped sending, say -- and would otherwise run out the clock.

      ARGUMENT QUOTING IS THE THIRD, AND IT IS WHY THIS USES
      `ProcessStartInfo.ArgumentList` RATHER THAN THE OBVIOUS SPELLINGS.

      An argument that contains a space is one argument. Preserving that
      across a process boundary is the whole problem, because Windows does not
      have an argv: `CreateProcess` takes ONE string, and the child splits it
      again with its own rules. Three ways to launch a child from PowerShell,
      and only one of them gets this right:

        Start-Process -ArgumentList @(...)
            JOINS THE ARRAY WITH SPACES AND QUOTES NOTHING. Every element is
            concatenated into `StartInfo.Arguments` verbatim, so an argument
            that contains a space arrives as several arguments and one that
            contains a quote arrives mangled. This is not a Windows-only
            hazard -- it corrupts the argument on Linux and macOS pwsh too.
            This function used to do exactly this, and the cost was a run in
            which `bash -lc "<pacman command>"` reached bash as the two
            arguments `-lc` and `set`: bash ran the builtin `set`, exited 0,
            and the exit-code guard below could not fire. Nothing was
            installed and nothing said so.

        & $exe @args
            Correct on pwsh 7 (`$PSNativeCommandArgumentPassing` defaults to
            `Standard`, which builds an argv rather than a string), and it is
            the right tool for a call that needs no bound. It is the wrong
            tool HERE, because it gives no handle on the child: no way to wait
            with a deadline, no way to kill the process tree when the deadline
            passes, and no way to hand it a closed stdin. Reaching for it
            would restore the quoting by discarding the two properties this
            function exists to provide.

        ProcessStartInfo.ArgumentList  <- what this does
            A real per-argument collection. On Unix it is passed straight to
            `execve`, so there is no quoting step to get wrong. On Windows the
            runtime escapes each element with the exact inverse of
            `CommandLineToArgvW` -- the same algorithm the child uses to split
            -- so an argument round-trips whatever it contains. And because it
            is a plain `Process`, the deadline, the tree-kill and the closed
            stdin all stay exactly as they were.

      Hand-rolling the Windows escaping into a single `-ArgumentList` string
      was the other candidate and was rejected: it is the one part of this
      that the runtime already implements correctly, and a subtly wrong
      backslash-before-quote rule would fail in precisely the silent way this
      change exists to eliminate.

      stdout and stderr are deliberately NOT redirected. They stay inherited,
      so native output goes straight to the job log and can never be captured
      into the PowerShell pipeline, where it would corrupt the return value of
      whatever function is calling this.

    .PARAMETER Activity
      Human-readable description used in the timeout message, so the failure
      names the step rather than just a process id.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    # `AllowEmptyString` applies to the ELEMENTS: without it a mandatory
    # `[string[]]` rejects the whole call if any single argument is "", which
    # is a legitimate argument (`-D` with an empty value, say) and one that
    # .NET's per-argument quoting round-trips correctly as `""`.
    [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$ArgumentList,
    [Parameter(Mandatory = $true)][string]$Activity,
    [int]$TimeoutSeconds = 0
  )

  if ($TimeoutSeconds -le 0) {
    $TimeoutSeconds = Get-PositiveIntSetting -Name "CODETRACER_NATIVE_COMMAND_TIMEOUT_SECONDS" -Default $script:NativeCommandTimeoutSecondsDefault
  }

  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $FilePath
  foreach ($argument in $ArgumentList) {
    if ($null -eq $argument) {
      throw "$Activity was given a null argument. Every element of -ArgumentList must be a string."
    }
    $startInfo.ArgumentList.Add($argument)
  }
  # Required for ArgumentList to be honoured at all, and for the console
  # handles to be inherited rather than a new window being created -- the same
  # thing `Start-Process -NoNewWindow` was asking for.
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $false
  # Closed immediately after start; see the EOF note above.
  $startInfo.RedirectStandardInput = $true

  $process = [System.Diagnostics.Process]::new()
  try {
    $process.StartInfo = $startInfo
    [void]$process.Start()
    # The child's stdin is a pipe whose write end we close before it can read.
    # A read on it returns EOF at once, which is what an empty stdin bought and
    # costs no temp file to arrange.
    #
    # Swallowing a failure here is safe rather than lazy: the only consequence
    # of not closing is that the child could block on a read, and the deadline
    # below already covers that. Rethrowing would turn a child that exited
    # before we got to the close into a spurious failure of the step.
    try { $process.StandardInput.Close() } catch { }

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      try { $process.Kill($true) } catch { try { $process.Kill() } catch { } }
      throw "$Activity did not finish within ${TimeoutSeconds}s and was killed. Raise CODETRACER_NATIVE_COMMAND_TIMEOUT_SECONDS if this step is legitimately this slow."
    }

    return $process.ExitCode
  } finally {
    $process.Dispose()
  }
}

# ---------------------------------------------------------------------------
# The content-addressed store root, and why a delete must never reach it.
#
# Under the chosen provisioning arm the toolchain store is GUEST-LOCAL: one
# copy per job, refilled over HTTP from a binary cache, and discarded with the
# ephemeral guest. That removes the shared-store hazard where one job's
# `Remove-Item -Recurse` took a toolchain out from under seven others -- a
# private tree has no other readers to harm.
#
# What it does NOT remove is the cost. A store entry that a clean-up step
# deletes has to be refilled over the network the next time something wants
# it, so a delete under the store root is a cache-miss generator even when it
# is not a correctness bug. `Ensure-CleanDirectory` is a private-scratch
# primitive; the store is not private scratch, and the two are only
# distinguishable by path.
#
# The roots are the ones `reprobuild-specs/Local-Content-Addressed-Store.md`
# specifies under "Store Root": the per-user Windows root
# `${LOCALAPPDATA}\repro\store\` and the shared cross-user root
# `${PROGRAMDATA}\repro\store\`. `REPRO_STORE_ROOT` is the store's own
# override (`repro_local_store/store.nim`'s `StoreRootEnvVar`) and is honoured
# so a relocated store is still fenced; `CODETRACER_WINDOWS_STORE_ROOT` exists
# for the same reason on this side of the boundary and is what the tests
# drive, so the guard can be exercised without depending on a machine having
# a store installed.
# ---------------------------------------------------------------------------

function Get-WindowsStoreRoots {
  <#
    .SYNOPSIS
      Every directory a materialised store entry may live under on this host.

    .DESCRIPTION
      Returned as absolute paths with no trailing separator. Roots whose
      defining environment variable is unset are omitted rather than guessed
      at, so this returns an empty array on a host with no store and on
      non-Windows PowerShell -- which is the correct answer in both cases,
      not a degraded one.
  #>

  $roots = New-Object System.Collections.Generic.List[string]

  foreach ($candidate in @(
      [Environment]::GetEnvironmentVariable("CODETRACER_WINDOWS_STORE_ROOT"),
      [Environment]::GetEnvironmentVariable("REPRO_STORE_ROOT"))) {
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
      $roots.Add($candidate.Trim())
    }
  }

  foreach ($base in @(
      [Environment]::GetEnvironmentVariable("LOCALAPPDATA"),
      [Environment]::GetEnvironmentVariable("ProgramData"))) {
    if (-not [string]::IsNullOrWhiteSpace($base)) {
      $roots.Add((Join-Path $base.Trim() "repro/store"))
    }
  }

  $normalized = New-Object System.Collections.Generic.List[string]
  foreach ($root in $roots) {
    $full = ""
    try {
      $full = [System.IO.Path]::GetFullPath($root)
    } catch {
      # An unusable value in the environment must not take the bootstrap
      # down; it simply does not name a root worth fencing.
      continue
    }
    $full = $full.TrimEnd([System.IO.Path]::DirectorySeparatorChar,
                          [System.IO.Path]::AltDirectorySeparatorChar)
    if ([string]::IsNullOrWhiteSpace($full)) { continue }
    if (-not ($normalized -contains $full)) {
      $normalized.Add($full)
    }
  }

  return @($normalized)
}

function Get-ContainingStoreRoot {
  <#
    .SYNOPSIS
      The store root that contains $Path, or "" when none does.

    .DESCRIPTION
      A path that IS a store root counts as contained: deleting the root
      itself is the largest version of the mistake this guard exists to
      refuse, not an exemption from it.

      Comparison is on the normalised absolute path with a separator
      appended, so `<root>store-scratch` is not mistaken for a child of
      `<root>store`. Case-insensitive, because NTFS is.
  #>
  param([Parameter(Mandatory = $true)][string]$Path)

  $full = ""
  try {
    $full = [System.IO.Path]::GetFullPath($Path)
  } catch {
    return ""
  }
  $full = $full.TrimEnd([System.IO.Path]::DirectorySeparatorChar,
                        [System.IO.Path]::AltDirectorySeparatorChar)

  foreach ($root in (Get-WindowsStoreRoots)) {
    if ($full.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $root
    }
    $rootPrefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $root
    }
  }

  return ""
}

function Ensure-CleanDirectory {
  <#
    .SYNOPSIS
      Replace $Path with an empty directory. PRIVATE SCRATCH ONLY.

    .DESCRIPTION
      Refuses any path at or under a content-addressed store root, naming
      both the offending path and the root that fenced it. See the block
      comment above `Get-WindowsStoreRoots` for why.
  #>
  param([Parameter(Mandatory = $true)][string]$Path)

  $storeRoot = Get-ContainingStoreRoot -Path $Path
  if (-not [string]::IsNullOrWhiteSpace($storeRoot)) {
    throw ("Ensure-CleanDirectory refuses to delete '$Path': it is inside the " +
      "content-addressed store root '$storeRoot'. Store entries are immutable and " +
      "are refilled from the binary cache, so deleting one is a cache-miss " +
      "generator rather than a clean-up. Use a private scratch path, or release " +
      "the store root that holds the entry and let the store's own GC reclaim it.")
  }

  if (Test-Path $Path) {
    Remove-Item -LiteralPath $Path -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Test-BootstrapAllowlistActive {
  <#
    .SYNOPSIS
      True when WINDOWS_DIY_ONLY restricts this run to a named subset.

    .DESCRIPTION
      A caller that sets WINDOWS_DIY_ONLY is asking for a SUBSET of
      codetracer's dev env -- typically a satellite repo that needs one
      pinned tool. Everything in `env.ps1` that exists to make CODETRACER
      ITSELF buildable (its node-packages tooling, its tree-sitter Nim
      parser, its runtime env, the hard requirement on MSVC's cl.exe) is
      then out of scope, and asserting it would fail a run that got exactly
      what it asked for.

      This is deliberately a single predicate rather than a set of opt-outs
      the caller has to remember: a satellite repo that had to name each
      extra separately would silently start failing the day a new one is
      added, which is the same defect that makes a subtractive component
      list unusable.
  #>
  return -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("WINDOWS_DIY_ONLY"))
}

function Get-BootstrapStepSkipReason {
  <#
    .SYNOPSIS
      Why this component will not run, or $null if it will.

    .DESCRIPTION
      THE single decision point for whether a gated component is wanted.
      Two gates feed it and they answer different questions:

        WINDOWS_DIY_ONLY          positive allowlist -- "just these".
        WINDOWS_DIY_SKIP_<STEP>   subtractive        -- "all but this".

      They compose, and neither silently overrides the other: a component
      must be listed by the allowlist (when one is given) AND not be
      individually skipped.

      It matters that this is ONE function. `env.ps1` consults the same
      question twice per component -- once to dispatch it, and once again
      afterwards to decide whether to ASSERT the tool is present (see the
      `WINDOWS_DIY_ENSURE_TTD` / `WINDOWS_DIY_ENSURE_DOTNET` defaults). If
      the two consultations can disagree, a component is skipped and then
      demanded, and the run fails on the absence of something it was told
      not to install.
  #>
  param([Parameter(Mandatory = $true)][string]$Step)

  $onlyRaw = [Environment]::GetEnvironmentVariable("WINDOWS_DIY_ONLY")
  if (-not [string]::IsNullOrWhiteSpace($onlyRaw)) {
    $only = @($onlyRaw -split "[,;\s]+" |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { $_.Trim().ToUpperInvariant() })
    if ($only -notcontains $Step.ToUpperInvariant()) {
      return "not listed in WINDOWS_DIY_ONLY"
    }
  }

  $envName = "WINDOWS_DIY_SKIP_$Step"
  $rawValue = [Environment]::GetEnvironmentVariable($envName)
  if (-not [string]::IsNullOrWhiteSpace($rawValue)) {
    $value = $rawValue.Trim().ToLowerInvariant()
    if ($value -in @("1", "true", "yes", "on")) {
      return "$envName=$rawValue is set"
    }
  }

  return $null
}

function Test-BootstrapStepEnabled {
  param([Parameter(Mandatory = $true)][string]$Step)

  $reason = Get-BootstrapStepSkipReason -Step $Step
  if ($null -ne $reason) {
    Write-Warning "Skipping bootstrap step '$Step': $reason."
    return $false
  }

  return $true
}

# ---------------------------------------------------------------------------
# Bootstrap step accounting
#
# Every gated component in `env.ps1`'s dispatch block runs through
# `Invoke-BootstrapStep`, which times it, records whether it ran or was
# skipped, and notes which install-root directories it created. At the end of
# a bootstrap `Write-BootstrapStepReport` turns that into a machine-readable
# per-component table: name, declared relocatability class, wall clock,
# on-disk size, and the directories the size came from.
#
# WHY THE DISPATCH BLOCK PRODUCES THE TABLE, rather than a separate list of
# components maintained alongside it: a separate list rots silently. A
# component added to the dispatch later would simply be absent from the
# decomposition, and the absence would look exactly like a component that
# installs nothing. Because the table is emitted BY the dispatch, a new
# component appears in it automatically, and the AST gate in
# `ci/test/bootstrap-decomposition.ps1` refuses a dispatch line that does not
# go through this wrapper.
#
# SIZES ARE MEASURED ONCE, AT THE END, not per step. Walking a multi-gigabyte
# install root 22 times would cost more than several of the installs being
# measured. What each step records live is the cheap part -- wall clock, and a
# top-level directory listing before and after -- and the expensive recursive
# sizing happens a single time in `Write-BootstrapStepReport`, attributed back
# to whichever step created each directory.
# ---------------------------------------------------------------------------

# Valid relocatability classes. This is the property a caller needs in order
# to decide whether a component can live in a shared immutable store at all.
#
# These describe the install MECHANISM, which is a static property of the
# Ensure-* script and can be read off it. They deliberately do NOT claim the
# installed bits are position-independent: proving that requires moving a
# store entry and re-running it, which is a separate measurement, not a
# declaration made here.
#   relocatable - installed by extracting an archive or building in place
#                 under the install root; nothing was written outside it.
#                 A store CANDIDATE.
#   junction    - install materialises junctions/symlinks inside the install
#                 root. Movable only if the links are rebuilt.
#   installer   - a vendor installer (.exe/.msi/winget/AppX) ran and may have
#                 written outside the install root, e.g. into Program Files
#                 or the registry. NOT a store candidate without repackaging.
$script:BootstrapRelocatabilityClasses = @("relocatable", "junction", "installer")

$script:BootstrapStepRecords = [System.Collections.Generic.List[object]]::new()

# Where the running decomposition is flushed after every component, or $null
# when nobody asked for progress reporting. See Write-BootstrapStepProgress for
# why this exists at all.
$script:BootstrapProgressDir = $null

function Get-BootstrapStepRecords {
  return $script:BootstrapStepRecords.ToArray()
}

function Reset-BootstrapStepRecords {
  $script:BootstrapStepRecords.Clear()
  $script:BootstrapProgressDir = $null
}

# The decomposition file's name. One constant, because the partial writer and
# the final writer MUST target the same path: the whole point of the partial is
# that the pipeline which collects the final report needs no special case to
# collect it instead.
$script:BootstrapDecompositionFileName = "windows-env-decomposition.json"

function Resolve-BootstrapReportDir {
  <#
    .SYNOPSIS
      The directory the decomposition is written to.

    .DESCRIPTION
      `WINDOWS_DIY_REPORT_DIR` when set, else `<RepoRoot>/.tmp/windows-diy`.

      This is a function rather than an expression repeated at each call site
      because it is now consulted TWICE per bootstrap -- once up front to arm
      progress reporting, and once at the end to write the final report -- and
      the two must not be able to disagree. A satellite repo that sets
      WINDOWS_DIY_REPORT_DIR and got the partial in one place and the final in
      another would be worse off than with no partial at all.
  #>
  param([Parameter(Mandatory = $true)][string]$RepoRoot)

  $dir = [Environment]::GetEnvironmentVariable("WINDOWS_DIY_REPORT_DIR")
  if ([string]::IsNullOrWhiteSpace($dir)) {
    $dir = Join-Path $RepoRoot ".tmp/windows-diy"
  }
  return $dir
}

function Initialize-BootstrapProgress {
  <#
    .SYNOPSIS
      Arm per-component flushing of the decomposition to $OutputDir.

    .DESCRIPTION
      Call before the dispatch block. Until this is called, Invoke-BootstrapStep
      accumulates records in memory only, which is the behaviour every existing
      caller and test relies on.
  #>
  param([Parameter(Mandatory = $true)][string]$OutputDir)

  $script:BootstrapProgressDir = $OutputDir
}

function Write-BootstrapStepProgress {
  <#
    .SYNOPSIS
      Flush the components recorded SO FAR to the decomposition path.

    .DESCRIPTION
      WHY THIS EXISTS, and it is not redundant with the `finally` that calls
      Write-BootstrapStepReport.

      That `finally` publishes a partial table when a component THROWS. It does
      nothing at all when the process is KILLED -- and on CI the dominant way
      this bootstrap ends is neither success nor an exception but a job or step
      timeout, which terminates pwsh outright. A PowerShell `finally` is not a
      process-death handler: no unwinding happens, so the report is never
      written and the run yields no timings whatsoever. That is not
      hypothetical; it is the observed outcome of the provisioning probe, whose
      workflow's own comment claimed a partial table would survive.

      Flushing after each component converts "killed at the cap => zero data"
      into "killed at the cap => exact timings for everything that finished,
      and the name of the component it died in". For a bootstrap whose whole
      measurement problem is that it rarely reaches the end, that is the
      difference between a run costing a scarce runner slot for nothing and a
      run that advances the measurement.

      SIZES ARE DELIBERATELY ABSENT from the partial. Recursive sizing of a
      multi-gigabyte install root is the expensive half of the report and doing
      it 22 times would cost more than several of the installs being measured
      -- the same reason Write-BootstrapStepReport measures once, at the end.
      The partial therefore carries `phase = "partial"` and a NULL
      `install_root_bytes`, so a consumer cannot mistake "not measured yet" for
      "measured as zero". The final report overwrites this file in place.

      Best-effort by construction: this runs between components, and a failure
      to write a progress file must never abort a provision that is otherwise
      succeeding.
  #>
  if ([string]::IsNullOrWhiteSpace($script:BootstrapProgressDir)) { return }

  try {
    $records = Get-BootstrapStepRecords
    $rows = @()
    foreach ($record in $records) {
      $rows += [pscustomobject]@{
        step = $record.step
        status = $record.status
        relocatability = $record.relocatability
        relocatability_warning = $null
        seconds = $record.seconds
        # Null rather than 0: this component's bytes are UNMEASURED at this
        # point, and a zero here would be read as "installed nothing".
        bytes = $null
        files = $null
        reparse_points = $null
        install_dirs = @($record.created_dirs)
        skip_variable = $record.skip_variable
        skip_reason = $record.skip_reason
        error = $record.error
      }
    }

    $report = [pscustomobject]@{
      schema = "codetracer.windows-env-decomposition.v1"
      phase = "partial"
      generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      os = "windows"
      install_root_bytes = $null
      install_root_files = $null
      install_root_reparse_points = $null
      total_seconds = [math]::Round((($rows | Measure-Object -Property seconds -Sum).Sum), 3)
      # A partial is never complete by definition -- there are components it
      # has not reached yet.
      complete = $false
      skipped_steps = @($rows | Where-Object { $_.status -eq "skipped" } | ForEach-Object { $_.step })
      failed_steps = @($rows | Where-Object { $_.status -eq "failed" } | ForEach-Object { $_.step })
      components = $rows
    }

    New-Item -ItemType Directory -Force -Path $script:BootstrapProgressDir | Out-Null
    $jsonPath = Join-Path $script:BootstrapProgressDir $script:BootstrapDecompositionFileName
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
  } catch {
    Write-Warning "Failed to flush the partial env.ps1 decomposition: $($_.Exception.Message)"
  }
}

function Get-InstallRootTopLevelNames {
  param([Parameter(Mandatory = $true)][string]$Root)

  if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    return @()
  }
  return @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue |
    ForEach-Object { $_.Name })
}

function Invoke-BootstrapStep {
  <#
    .SYNOPSIS
      Run one gated bootstrap component, honouring WINDOWS_DIY_SKIP_<Step>,
      and record what it cost.

    .PARAMETER Step
      The gate name, e.g. "CAPNP". `WINDOWS_DIY_SKIP_<Step>` disables it.

    .PARAMETER Relocatability
      How this component installs; one of $BootstrapRelocatabilityClasses.
      Declared at the call site because it is a static property of the
      Ensure-* script, not something that can be inferred from the result.
      `Write-BootstrapStepReport` cross-checks the "relocatable" claim
      against the reparse points it actually finds, so a wrong declaration
      is caught rather than trusted.

    .PARAMETER Root
      The install root, used to attribute created directories.

    .PARAMETER Action
      The Ensure-* invocation.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Step,
    [Parameter(Mandatory = $true)][ValidateSet("relocatable", "junction", "installer")][string]$Relocatability,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][scriptblock]$Action
  )

  # Two gates, and they answer different questions.
  #
  # WINDOWS_DIY_SKIP_<STEP> is subtractive: "codetracer's dev env, minus this
  # component". WINDOWS_DIY_ONLY is a positive allowlist: "just these
  # components". A satellite repo wants the second -- `codetracer-trace-format`
  # needs Cap'n Proto and nothing else, and expressing that as twenty-one
  # skip variables would be both unreadable and silently wrong the moment a
  # twenty-third component is added, because the new one would default to ON.
  #
  # The allowlist is also the shape a per-project overlay needs: it NAMES the
  # pinned components that project wants, rather than subtracting from a
  # whole-repo default.
  #
  # BOTH gates live in Get-BootstrapStepSkipReason rather than here, because
  # `env.ps1` asks the same question a second time -- after the dispatch, to
  # decide whether to ASSERT a tool is present. Evaluating the allowlist only
  # at this call site made the two answers disagree: a component was skipped
  # here and then demanded there, and the run failed on the absence of
  # something it had been told not to install.
  $skipReason = Get-BootstrapStepSkipReason -Step $Step

  if ($null -ne $skipReason) {
    $script:BootstrapStepRecords.Add([pscustomobject]@{
      step = $Step
      relocatability = $Relocatability
      status = "skipped"
      skip_variable = "WINDOWS_DIY_SKIP_$Step"
      skip_reason = $skipReason
      seconds = 0.0
      created_dirs = @()
      error = $null
    })
    Write-BootstrapStepProgress
    return
  }

  $before = Get-InstallRootTopLevelNames -Root $Root
  $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  $status = "ok"
  $errorText = $null
  try {
    & $Action
  } catch {
    # Record the cost of the failure before rethrowing. A component that
    # dies 40 minutes in is a fact the decomposition needs. Timing this
    # bootstrap from runs that never completed is how a provisioning cost
    # gets mis-stated, and an unrecorded failure is how that happens.
    $status = "failed"
    $errorText = $_.Exception.Message
    throw
  } finally {
    $stopwatch.Stop()
    $after = Get-InstallRootTopLevelNames -Root $Root
    $created = @($after | Where-Object { $before -notcontains $_ })
    $script:BootstrapStepRecords.Add([pscustomobject]@{
      step = $Step
      relocatability = $Relocatability
      status = $status
      skip_variable = "WINDOWS_DIY_SKIP_$Step"
      skip_reason = $null
      seconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
      created_dirs = $created
      error = $errorText
    })
    # Flush before control leaves this component. If the job cap kills the
    # process during the NEXT component, everything up to here survives.
    Write-BootstrapStepProgress
  }
}

function Measure-DirectorySize {
  <#
    .SYNOPSIS
      Recursive on-disk size in bytes, plus a reparse-point count.

    .DESCRIPTION
      Reparse points are counted but NOT followed, and their targets are not
      added to the byte total. Following them would double-count a junction
      into a directory that is itself inside the install root -- which is
      exactly the shape `Ensure-NodeModulesJunction` creates -- and would
      make the install-root total too large by an amount that varies with
      how many junctions happen to exist.
  #>
  param([Parameter(Mandatory = $true)][string]$Path)

  $bytes = [long]0
  $files = [long]0
  $reparsePoints = [long]0

  if (-not (Test-Path -LiteralPath $Path)) {
    return [pscustomobject]@{ bytes = $bytes; files = $files; reparse_points = $reparsePoints }
  }

  $stack = [System.Collections.Generic.Stack[string]]::new()
  $stack.Push($Path)
  while ($stack.Count -gt 0) {
    $current = $stack.Pop()
    $entries = @()
    try {
      $entries = @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)
    } catch {
      continue
    }
    foreach ($entry in $entries) {
      $isReparse = (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
      if ($isReparse) {
        $reparsePoints++
        continue
      }
      if ($entry.PSIsContainer) {
        $stack.Push($entry.FullName)
      } else {
        $bytes += [long]$entry.Length
        $files++
      }
    }
  }

  return [pscustomobject]@{ bytes = $bytes; files = $files; reparse_points = $reparsePoints }
}

function Write-BootstrapStepReport {
  <#
    .SYNOPSIS
      Emit the per-component decomposition and the install-root total.

    .DESCRIPTION
      Writes `<OutputDir>/windows-env-decomposition.json` (machine-readable,
      the artifact to commit) and a short human-readable summary to the
      host. Anything that sizes this bootstrap derives from it, so it records
      the denominator too: whether the run completed, and which components
      were skipped. A "green" run with components skipped is a different fact
      from a green run without, and the file says which it was.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$OutputDir
  )

  $records = Get-BootstrapStepRecords
  $rows = @()
  $attributed = @{}

  foreach ($record in $records) {
    $bytes = [long]0
    $files = [long]0
    $reparse = [long]0
    foreach ($dir in $record.created_dirs) {
      $full = Join-Path $Root $dir
      $measured = Measure-DirectorySize -Path $full
      $bytes += $measured.bytes
      $files += $measured.files
      $reparse += $measured.reparse_points
      $attributed[$dir] = $record.step
    }

    # Cross-check the declared class against what is on disk. A component
    # declared "relocatable" that produced reparse points is mis-declared,
    # and a later store-safety assumption would inherit the error.
    #
    # PROMOTED FROM WARNING TO VIOLATION. The warning form caught GCC and RUST
    # on the first complete decomposition run without having been designed as
    # a relocatability gate -- which is the argument for keeping it and the
    # argument against leaving it a warning. Under publish-and-refill a
    # mis-declared component is not a note in a log, it is a cache entry that
    # every later job inherits, so a claim the filesystem contradicts has to
    # stop the run. `Assert-BootstrapRelocatability` is what does the stopping;
    # this function only RECORDS, because it runs inside a `finally` whose
    # whole purpose is to survive a failed provision and must not mask the
    # failure that got it there.
    #
    # The count alone is not the test, and NEITHER IS WHERE THE TARGET
    # RESOLVES. `Get-ReparsePointFindings` judges the STORED target: an
    # absolute one is a violation even when it currently points inside the
    # install root, because a junction records a location and locations do
    # not travel with the tree. Only a RELATIVE target that stays inside the
    # root is cleared. Read that function's block comment before changing
    # anything here -- "it resolves inside the root" is the test that would
    # have cleared the gcc junction this promotion exists to catch.
    # The walk is skipped entirely when the count is zero, so the common
    # case costs nothing.
    #
    # WHAT THIS WILL TRIP FIRST, AND IT HAS NOT BEEN MEASURED. On the last
    # complete decomposition run the install root carried 14 reparse points:
    # GCC's 1 (now converted away) and RUST's 13, under `rustup\` /
    # `cargo\`, which `Ensure-Rust` reports but deliberately does not
    # convert. RUST is still declared `relocatable`, so if those 13 store
    # ABSOLUTE targets this assertion will stop the first real Windows
    # provisioning run after this change. That is the gate doing its job
    # rather than a bug in it -- a component that cannot be relocated must
    # not go on claiming it can -- but the kind of those 13 targets is
    # UNKNOWN: it can only be established by a Windows run, and the
    # increment that armed this was directed not to dispatch one. Whoever
    # sees that failure should either convert the rustup layout or change
    # its declaration, not lower this back to a warning.
    $relocatabilityWarning = $null
    $stepViolations = @()
    if ($record.relocatability -eq "relocatable" -and $reparse -gt 0) {
      foreach ($dir in $record.created_dirs) {
        $full = Join-Path $Root $dir
        foreach ($finding in (Get-ReparsePointFindings -Root $Root -Path $full)) {
          if (Test-RelocatabilityViolation -Finding $finding) {
            $stepViolations += [pscustomobject]@{
              step = $record.step
              kind = $finding.kind
              path = $finding.path
              detail =
                if ($finding.kind -eq "reparse-absolute-target") {
                  "reparse point stores the ABSOLUTE target '$($finding.target)', which names the current root and will not follow the tree to another one"
                } else {
                  "reparse point targets '$($finding.target)', which resolves outside the install root"
                }
            }
          }
        }
      }
      $relocatabilityWarning =
        "declared relocatable but $reparse reparse point(s) found under its install directories"
      if ($stepViolations.Count -gt 0) {
        Write-Warning "Bootstrap step '$($record.step)': $relocatabilityWarning; $($stepViolations.Count) of them will not survive relocation (absolute target, or a relative one that escapes the root)"
      } else {
        # Worth saying rather than staying silent: the count is non-zero and
        # the component is still relocatable, which is a different fact from
        # a zero count and would otherwise be indistinguishable from one.
        Write-Host "Bootstrap step '$($record.step)': $reparse reparse point(s), all with relative targets inside the install root."
      }
    }

    $rows += [pscustomobject]@{
      step = $record.step
      status = $record.status
      relocatability = $record.relocatability
      relocatability_warning = $relocatabilityWarning
      relocatability_violations = @($stepViolations)
      seconds = $record.seconds
      bytes = $bytes
      files = $files
      reparse_points = $reparse
      install_dirs = @($record.created_dirs)
      skip_variable = $record.skip_variable
      skip_reason = $record.skip_reason
      error = $record.error
    }
  }

  $rootMeasured = Measure-DirectorySize -Path $Root
  $unattributed = @(Get-InstallRootTopLevelNames -Root $Root |
    Where-Object { -not $attributed.ContainsKey($_) })

  $skipped = @($rows | Where-Object { $_.status -eq "skipped" } | ForEach-Object { $_.step })
  $failed = @($rows | Where-Object { $_.status -eq "failed" } | ForEach-Object { $_.step })
  $relocatabilityViolations = @($rows | ForEach-Object { $_.relocatability_violations } |
    Where-Object { $null -ne $_ })

  # Architecture is a label on the measurement, not part of it. Get-WindowsArch
  # goes through CIM, which is Windows-only and can fail on a loaded box; a
  # report that cannot say which architecture it came from is far more useful
  # than no report at all, and this function is called from a `finally` whose
  # whole purpose is to survive a failed provision.
  $arch = "unknown"
  try { $arch = Get-WindowsArch } catch { $arch = "unknown" }

  $report = [pscustomobject]@{
    schema = "codetracer.windows-env-decomposition.v1"
    # "final" distinguishes this from the per-component flush
    # Write-BootstrapStepProgress leaves at the same path when a run is killed
    # mid-bootstrap. Only a "final" report has sizes, and only a "final" report
    # can be quoted as the cost of a complete provision.
    phase = "final"
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    os = "windows"
    arch = $arch
    install_root = $Root
    # The install-root total. Reported as the whole-root
    # measurement rather than the sum of the per-step rows, because a step
    # that writes into a directory an earlier step created contributes to
    # the root total but is not attributed to a directory of its own.
    install_root_bytes = $rootMeasured.bytes
    install_root_files = $rootMeasured.files
    install_root_reparse_points = $rootMeasured.reparse_points
    total_seconds = [math]::Round((($rows | Measure-Object -Property seconds -Sum).Sum), 3)
    # A run with skips is not the same fact as a run without. Recorded here
    # so a consumer of this file cannot mistake one for the other.
    complete = ($skipped.Count -eq 0 -and $failed.Count -eq 0)
    skipped_steps = $skipped
    failed_steps = $failed
    # Components whose declared relocatability the filesystem contradicts.
    # Empty is the only acceptable steady state; `Assert-BootstrapRelocatability`
    # is what enforces that, from outside the `finally` this runs in.
    relocatability_violations = @($relocatabilityViolations)
    unattributed_install_dirs = $unattributed
    components = $rows
  }

  New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
  $jsonPath = Join-Path $OutputDir "windows-env-decomposition.json"
  $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

  Write-Host ""
  Write-Host "env.ps1 per-component decomposition ($($rows.Count) components):"
  foreach ($row in ($rows | Sort-Object -Property seconds -Descending)) {
    $mb = [math]::Round($row.bytes / 1MB, 1)
    Write-Host ("  {0,-12} {1,-11} {2,10:N1}s {3,10} MB  {4}" -f `
      $row.step, $row.status, $row.seconds, $mb, $row.relocatability)
  }
  Write-Host ("  TOTAL install root: {0:N1} MB in {1:N0} files ({2} reparse points)" -f `
    ($rootMeasured.bytes / 1MB), $rootMeasured.files, $rootMeasured.reparse_points)
  if (-not $report.complete) {
    Write-Host ("  NOTE: incomplete run - skipped [{0}] failed [{1}]" -f `
      ($skipped -join ","), ($failed -join ","))
  }
  if ($relocatabilityViolations.Count -gt 0) {
    Write-Host ("  RELOCATABILITY: {0} violation(s) - see relocatability_violations" -f `
      $relocatabilityViolations.Count)
  }
  Write-Host "Wrote $jsonPath"

  return $jsonPath
}

function Assert-BootstrapRelocatability {
  <#
    .SYNOPSIS
      Fail the run when a component's declared relocatability is contradicted
      by what it put on disk.

    .DESCRIPTION
      This is the FAIL half of the check `Write-BootstrapStepReport` records.
      It is a separate function, called from OUTSIDE the report's `finally`,
      for one reason: the report exists to survive a failed provision, and a
      relocatability throw raised from inside it would replace the error that
      actually stopped the bootstrap with a downstream one. So the report
      always writes, and this only ever runs on a bootstrap that otherwise
      succeeded.

      Why this is a failure and not a warning: under publish-and-refill the
      publisher and the consumer are different machines, so a component that
      bakes a path into a store entry produces a tree that works for the
      machine that built it and silently misresolves for every machine that
      later pulls it. A warning nobody must act on is how the next
      mis-declaration gets in.

    .PARAMETER ReportPath
      The `windows-env-decomposition.json` written by
      `Write-BootstrapStepReport`. A missing or unreadable report is NOT
      treated as a pass -- it is the absence of evidence, and this throws
      rather than shrugging.
  #>
  param([Parameter(Mandatory = $true)][string]$ReportPath)

  if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
    throw ("Cannot check relocatability: no decomposition report at '$ReportPath'. " +
      "A missing report is an unchecked claim, not a passing one.")
  }

  $report = $null
  try {
    $report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
  } catch {
    throw "Cannot check relocatability: '$ReportPath' is not readable JSON: $($_.Exception.Message)"
  }

  $violations = @()
  if ($report.PSObject.Properties.Name -contains "relocatability_violations") {
    $violations = @($report.relocatability_violations | Where-Object { $null -ne $_ })
  }

  if ($violations.Count -eq 0) {
    Write-Host "Relocatability check passed: every component declared relocatable resolves inside the install root."
    return
  }

  $lines = foreach ($violation in $violations) {
    "  $($violation.step): $($violation.kind) at '$($violation.path)' - $($violation.detail)"
  }
  throw ("Relocatability check FAILED for $($violations.Count) item(s). A component " +
    "declared relocatable put something in the install root that will not survive " +
    "being materialised at a different root, which under publish-and-refill poisons " +
    "the cache entry for every later job:`n" + ($lines -join "`n"))
}

function ConvertTo-InstallRelativePath {
  param(
    [Parameter(Mandatory = $true)][string]$AbsolutePath,
    [Parameter(Mandatory = $true)][string]$Root
  )

  $absoluteRoot = [System.IO.Path]::GetFullPath($Root)
  $absoluteTarget = [System.IO.Path]::GetFullPath($AbsolutePath)
  # The separator must be the PLATFORM's, not a literal backslash. The test
  # for "already ends in a separator" one line down always used
  # `DirectorySeparatorChar` while the append used `"\"`, so on a host whose
  # separator is `/` this function rejected every path that was in fact under
  # the root. That never showed on Windows -- where the two are the same
  # character -- and it is why the pointer discipline could not be exercised
  # on Linux pwsh, which is where its tests run.
  $separator = [System.IO.Path]::DirectorySeparatorChar
  $rootPrefix =
    if ($absoluteRoot.EndsWith($separator)) { $absoluteRoot }
    else { $absoluteRoot + $separator }

  if (-not $absoluteTarget.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Expected path '$absoluteTarget' to be under install root '$absoluteRoot'."
  }

  return $absoluteTarget.Substring($rootPrefix.Length).Replace("\", "/")
}

# ---------------------------------------------------------------------------
# The pointer-file discipline, and the audit that decides whether a component
# actually earns the word "relocatable".
#
# `<component>.install.relative-path` holds a forward-slash-normalised
# ROOT-RELATIVE path. It is the one mechanism that lets a component tree be
# archived on the machine that built it and materialised somewhere else at a
# different root -- which, under publish-and-refill, is the NORMAL case and not
# a hypothetical: the publisher and the consumer are different machines.
#
# A baked absolute path under that arm is not merely awkward. It is a poisoned
# cache entry: the tree looks correct, resolves against the publisher's paths,
# and every later job that pulls it inherits the same wrong answer silently.
#
# Two checks are needed and neither subsumes the other:
#
#   * REPARSE POINTS -- a junction to a target outside the tree does not travel
#     with the tree. Cheap to check (directory metadata only) and it is what
#     caught GCC and RUST on the decomposition run's first complete pass.
#   * CONTENT -- an absolute path baked into a text file has no reparse point
#     to find. `rustup`'s `settings.toml` is exactly this shape, and it would
#     have gone unnoticed had rustup not ALSO created junctions. A zero
#     reparse-point count is a floor, not a clearance.
# ---------------------------------------------------------------------------

function Resolve-InstallDirFromRelativePathFile {
  <#
    .SYNOPSIS
      Rehydrate an absolute install directory from a root-relative pointer file.

    .DESCRIPTION
      The read side of `Write-InstallPointer`. Joining a ROOT-RELATIVE path
      onto whatever root the caller is standing at is the entire relocation
      mechanism: the same pointer file resolves to the publisher's path on the
      publisher and to the consumer's path on the consumer, with nothing to
      rewrite in between.

      `$FallbackDir` exists for components that do not yet write a pointer, so
      a caller can adopt the discipline without a flag day. It returns "" when
      there is neither a pointer nor a fallback, which callers must treat as
      "not installed" rather than as a path.

      MOVED HERE from `env.ps1` when the `Ensure-*` scripts became callers:
      the reader and the writer belong in the module both sides dot-source.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$InstallRoot,
    [Parameter(Mandatory = $true)][string]$RelativePathFile,
    [string]$FallbackDir = ""
  )

  if (Test-Path -LiteralPath $RelativePathFile -PathType Leaf) {
    $relative = (Get-Content -LiteralPath $RelativePathFile -Raw).Trim()
    if (-not [string]::IsNullOrWhiteSpace($relative)) {
      $parts = $relative -split '[\\/]'
      return (Join-Path $InstallRoot ([System.IO.Path]::Combine($parts)))
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($FallbackDir)) {
    return $FallbackDir
  }

  return ""
}

function Write-InstallPointer {
  <#
    .SYNOPSIS
      Record where a component's install tree sits, ROOT-RELATIVELY.

    .DESCRIPTION
      Writes `<VersionRoot>/<Component>.install.relative-path` (and, when
      metadata is supplied, `<Component>.install.meta`) so
      `Resolve-InstallDirFromRelativePathFile` can rehydrate the absolute path
      against whatever root the tree is materialised at.

      `ConvertTo-InstallRelativePath` refuses a target outside the root, so a
      component that cannot express its install directory relatively fails
      HERE, at the point the claim is made, rather than at the point a later
      job discovers the tree does not work.

    .PARAMETER Component
      The pointer-file stem, e.g. "gcc". Conventionally the lowercase tool
      name, matching what `env.ps1` reads back.

    .PARAMETER VersionRoot
      The directory the pointer files live in -- normally
      `<Root>/<tool>/<version>`.

    .PARAMETER InstallDir
      The absolute path of the directory the tool is actually installed in.

    .PARAMETER Metadata
      Extra key/value pairs for `<Component>.install.meta`. `install_relative_path`
      is added automatically. Pass `$null` to skip the meta file entirely.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Component,
    [Parameter(Mandatory = $true)][string]$VersionRoot,
    [Parameter(Mandatory = $true)][string]$InstallDir,
    [hashtable]$Metadata = $null
  )

  $relative = ConvertTo-InstallRelativePath -AbsolutePath $InstallDir -Root $Root

  New-Item -ItemType Directory -Force -Path $VersionRoot | Out-Null
  $pointerPath = Join-Path $VersionRoot "$Component.install.relative-path"
  Set-Content -LiteralPath $pointerPath -Value $relative -Encoding ASCII

  if ($null -ne $Metadata) {
    $values = @{}
    foreach ($key in $Metadata.Keys) {
      $values[[string]$key] = [string]$Metadata[$key]
    }
    $values["install_relative_path"] = $relative
    Write-KeyValueFile -Path (Join-Path $VersionRoot "$Component.install.meta") -Values $values
  }

  return $relative
}

function Get-ReparsePointFindings {
  <#
    .SYNOPSIS
      Every reparse point under $Path, with a verdict on whether its target
      escapes $Root.

    .DESCRIPTION
      Walks directories and files, never FOLLOWING a reparse point -- following
      one would recurse into whatever it names, which on an escaping junction
      means walking outside the tree under audit.

      THE TEST IS ON THE STORED TARGET, NOT ON WHERE IT CURRENTLY RESOLVES,
      and the difference is the whole point. An NTFS junction stores an
      ABSOLUTE path. `New-Item -ItemType Junction -Path <root>\gcc\15.2.0
      -Target <root>\gcc\winlibs-15.2.0\mingw64` therefore produces a link
      whose target is inside the install root TODAY and which still names the
      OLD root after the tree is materialised somewhere else -- so it survives
      a "does the target resolve inside the root?" check and does not survive
      relocation. That is precisely the failure this audit exists to catch,
      and a resolution-based check would have passed it.

      So the three verdicts are:

        * `reparse-absolute-target` -- a violation unconditionally. The stored
          path names a location, not a relationship, and locations do not move
          with the tree.
        * `reparse-escapes-root` -- a relative target that still climbs out of
          the root. A violation for the ordinary reason.
        * `reparse-inside-root` -- a relative target resolving within the root.
          This one travels, and is reported rather than dropped so that "no
          reparse points at all" stays distinguishable from "reparse points
          that are all fine".

      Portable: `LinkTarget` is a PowerShell 7 property present on Linux and
      macOS too, where symlinks stand in for junctions. That is what lets this
      be exercised off Windows.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Path
  )

  $findings = [System.Collections.Generic.List[object]]::new()
  if (-not (Test-Path -LiteralPath $Path)) {
    return @($findings)
  }

  $absoluteRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar)
  $rootPrefix = $absoluteRoot + [System.IO.Path]::DirectorySeparatorChar

  $pending = New-Object System.Collections.Generic.Queue[string]
  $pending.Enqueue($Path)

  while ($pending.Count -gt 0) {
    $current = $pending.Dequeue()
    $entries = @()
    try {
      $entries = @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)
    } catch {
      continue
    }

    foreach ($entry in $entries) {
      $isReparse = $false
      try {
        $isReparse = $entry.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)
      } catch {
        $isReparse = $false
      }

      if ($isReparse) {
        $target = ""
        try { $target = [string]$entry.LinkTarget } catch { $target = "" }

        # A relative link target is resolved against the link's own
        # directory, which is how a link that travels with the tree is
        # normally written.
        $resolved = ""
        if (-not [string]::IsNullOrWhiteSpace($target)) {
          try {
            $resolved = [System.IO.Path]::GetFullPath(
              [System.IO.Path]::Combine((Split-Path -Parent $entry.FullName), $target))
          } catch {
            $resolved = ""
          }
        }
        $resolved = $resolved.TrimEnd([System.IO.Path]::DirectorySeparatorChar,
                                      [System.IO.Path]::AltDirectorySeparatorChar)

        # An unreadable target is treated as absolute rather than as fine: a
        # link this audit cannot describe is not a link it may clear.
        $isAbsolute = $true
        if (-not [string]::IsNullOrWhiteSpace($target)) {
          try {
            $isAbsolute = [System.IO.Path]::IsPathRooted($target)
          } catch {
            $isAbsolute = $true
          }
        }

        $escapes = $true
        if (-not [string]::IsNullOrWhiteSpace($resolved)) {
          $escapes = -not (
            $resolved.Equals($absoluteRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
            $resolved.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase))
        }

        $kind =
          if ($isAbsolute) { "reparse-absolute-target" }
          elseif ($escapes) { "reparse-escapes-root" }
          else { "reparse-inside-root" }

        $findings.Add([pscustomobject]@{
          kind = $kind
          path = $entry.FullName
          target = $target
          resolved_target = $resolved
          target_is_absolute = $isAbsolute
        })
        # Do NOT descend through it.
        continue
      }

      if ($entry.PSIsContainer) {
        $pending.Enqueue($entry.FullName)
      }
    }
  }

  return @($findings)
}

function Get-BakedAbsolutePathFindings {
  <#
    .SYNOPSIS
      Files under $Path whose CONTENT contains the absolute path of $Root.

    .DESCRIPTION
      The check the reparse-point counter cannot make. A component can be
      non-relocatable with zero reparse points -- rustup's `settings.toml`
      records absolute `RUSTUP_HOME`/toolchain paths as plain text -- and such
      a tree is exactly the silent failure publish-and-refill produces: it
      resolves fine on the machine that wrote it.

      Bytes are searched, not lines, and in BOTH UTF-8 and UTF-16LE, because
      Windows tools write both and a UTF-16 `settings.toml` would be invisible
      to a UTF-8-only scan. All three spellings of the root a Windows tool may
      emit are searched: the native `\` form, the forward-slash form many
      cross-platform tools normalise to, and the `\\`-escaped form that appears
      inside JSON and TOML string literals.

      Reparse points are not followed, and files larger than $MaxFileBytes are
      reported as unscanned rather than silently skipped -- an unscanned file
      is an unknown, and an unknown recorded as a pass is how this check would
      become decoration.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Path,
    [long]$MaxFileBytes = 33554432
  )

  $findings = [System.Collections.Generic.List[object]]::new()
  if (-not (Test-Path -LiteralPath $Path)) {
    return @($findings)
  }

  $absoluteRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar)

  $spellings = @($absoluteRoot)
  $forward = $absoluteRoot.Replace("\", "/")
  if ($forward -ne $absoluteRoot) { $spellings += $forward }
  $escaped = $absoluteRoot.Replace("\", "\\")
  if ($escaped -ne $absoluteRoot) { $spellings += $escaped }

  $needles = [System.Collections.Generic.List[object]]::new()
  foreach ($spelling in $spellings) {
    $needles.Add([pscustomobject]@{
      spelling = $spelling
      encoding = "utf-8"
      bytes = [System.Text.Encoding]::UTF8.GetBytes($spelling)
    })
    $needles.Add([pscustomobject]@{
      spelling = $spelling
      encoding = "utf-16le"
      bytes = [System.Text.Encoding]::Unicode.GetBytes($spelling)
    })
  }

  $pending = New-Object System.Collections.Generic.Queue[string]
  $pending.Enqueue($Path)

  while ($pending.Count -gt 0) {
    $current = $pending.Dequeue()
    $entries = @()
    try {
      $entries = @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)
    } catch {
      continue
    }

    foreach ($entry in $entries) {
      $isReparse = $false
      try {
        $isReparse = $entry.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)
      } catch {
        $isReparse = $false
      }
      if ($isReparse) { continue }

      if ($entry.PSIsContainer) {
        $pending.Enqueue($entry.FullName)
        continue
      }

      if ($entry.Length -gt $MaxFileBytes) {
        $findings.Add([pscustomobject]@{
          kind = "unscanned-oversized-file"
          path = $entry.FullName
          spelling = ""
          encoding = ""
          detail = "file is $($entry.Length) bytes, over the $MaxFileBytes-byte scan limit"
        })
        continue
      }

      $bytes = $null
      try {
        $bytes = [System.IO.File]::ReadAllBytes($entry.FullName)
      } catch {
        $findings.Add([pscustomobject]@{
          kind = "unscanned-unreadable-file"
          path = $entry.FullName
          spelling = ""
          encoding = ""
          detail = "could not be read"
        })
        continue
      }

      foreach ($needle in $needles) {
        if (Test-ByteSequenceContains -Haystack $bytes -Needle $needle.bytes) {
          $findings.Add([pscustomobject]@{
            kind = "baked-absolute-path"
            path = $entry.FullName
            spelling = $needle.spelling
            encoding = $needle.encoding
            detail = "contains the install root as $($needle.encoding) text"
          })
          break
        }
      }
    }
  }

  return @($findings)
}

function Test-ByteSequenceContains {
  <#
    .SYNOPSIS
      True when $Needle occurs anywhere in $Haystack.

    .DESCRIPTION
      A plain byte search rather than a string search, so it is unaffected by
      how the file's own encoding would decode -- a UTF-16LE path inside an
      otherwise-binary file is still found.
  #>
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Haystack,
    [Parameter(Mandatory = $true)][byte[]]$Needle
  )

  if ($Needle.Length -eq 0) { return $false }
  if ($Haystack.Length -lt $Needle.Length) { return $false }

  $last = $Haystack.Length - $Needle.Length
  $first = $Needle[0]
  for ($i = 0; $i -le $last; $i++) {
    if ($Haystack[$i] -ne $first) { continue }
    $matched = $true
    for ($j = 1; $j -lt $Needle.Length; $j++) {
      if ($Haystack[$i + $j] -ne $Needle[$j]) { $matched = $false; break }
    }
    if ($matched) { return $true }
  }
  return $false
}

function Get-InstallTreeRelocatabilityFindings {
  <#
    .SYNOPSIS
      Everything that would stop $Path from working after being materialised
      at a different root.

    .DESCRIPTION
      The union of the reparse-point audit and the content audit, with only
      the escaping reparse points and the baked absolute paths counted as
      violations. `-SkipContentScan` runs the cheap half alone, which is what
      the provisioning report does by default: the content scan reads every
      byte of the install root, and that is a deliberate cost to opt into
      rather than one to impose on every provision.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$SkipContentScan
  )

  $findings = [System.Collections.Generic.List[object]]::new()
  foreach ($finding in (Get-ReparsePointFindings -Root $Root -Path $Path)) {
    $findings.Add($finding)
  }
  if (-not $SkipContentScan) {
    foreach ($finding in (Get-BakedAbsolutePathFindings -Root $Root -Path $Path)) {
      $findings.Add($finding)
    }
  }
  return @($findings)
}

function Repair-RustupSettingsRelocatability {
  <#
    .SYNOPSIS
      Strip the absolute directory paths rustup bakes into `settings.toml`.

    .DESCRIPTION
      rustup's `settings.toml` carries an `[overrides]` table whose KEYS are
      absolute directory paths -- one per `rustup override set` -- recording
      which toolchain to use under which directory. Nothing else in the file
      is a path: `version` and `default_toolchain` are opaque identifiers, and
      `profile` is an enum.

      This is the failure mode a reparse-point count cannot see. A rustup tree
      can have zero reparse points and still be non-relocatable, because the
      paths are plain text in a config file, and the entry will look correct
      on the machine that wrote it and resolve against a stranger's
      directories anywhere else.

      Overrides are DROPPED rather than rewritten because there is nothing to
      rewrite them to: an override is a statement about a directory on the
      publishing machine, and that directory does not exist on the consumer.
      Dropping them restores the documented default behaviour (use
      `default_toolchain`), which is what a freshly provisioned tree wants
      anyway -- `Ensure-Rust` never sets an override.

      PARSING NOTE, stated because it bounds what this may be pointed at: this
      is a line-oriented transform over the file RUSTUP GENERATES, not a TOML
      parser. It relies on rustup writing table headers at the start of a line
      and on `[overrides]` running to the next header or to EOF. Do not reuse
      it on hand-edited or arbitrary TOML.

    .OUTPUTS
      An object with `path`, `changed`, and `removed_lines`. A missing file is
      reported as `changed = $false` rather than as an error: a rustup home
      with no settings yet is a normal state, not a defect.
  #>
  param([Parameter(Mandatory = $true)][string]$RustupHome)

  $settingsPath = Join-Path $RustupHome "settings.toml"
  $result = [pscustomobject]@{
    path = $settingsPath
    changed = $false
    removed_lines = @()
  }

  if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    return $result
  }

  $lines = @(Get-Content -LiteralPath $settingsPath)
  $kept = New-Object System.Collections.Generic.List[string]
  $removed = New-Object System.Collections.Generic.List[string]
  $inOverrides = $false

  foreach ($line in $lines) {
    $trimmed = $line.TrimStart()
    if ($trimmed.StartsWith("[")) {
      # A new table header always ends the overrides table, including
      # `[overrides]` itself when it appears twice.
      $inOverrides = ($trimmed -match '^\[\s*overrides\s*\]')
      if ($inOverrides) {
        $removed.Add($line)
        continue
      }
    }

    if ($inOverrides) {
      $removed.Add($line)
      continue
    }

    $kept.Add($line)
  }

  if ($removed.Count -eq 0) {
    return $result
  }

  Set-Content -LiteralPath $settingsPath -Value $kept -Encoding UTF8
  $result.changed = $true
  $result.removed_lines = @($removed)
  return $result
}

function Test-RelocatabilityViolation {
  <#
    .SYNOPSIS
      True when a finding is a reason to refuse the "relocatable" claim.

    .DESCRIPTION
      `reparse-inside-root` is not: a RELATIVE link that resolves within the
      tree travels with it. `reparse-absolute-target` is, even when the target
      happens to sit inside the root today -- see `Get-ReparsePointFindings`
      for why that case is the one that gets missed.

      The `unscanned-*` kinds are not violations either -- they are gaps in
      the evidence, reported so a reader can see the check did not cover
      everything, and deliberately NOT promoted to failures, because "we could
      not read it" is a different claim from "it is broken".
  #>
  param([Parameter(Mandatory = $true)]$Finding)

  return ($Finding.kind -eq "reparse-absolute-target" -or
          $Finding.kind -eq "reparse-escapes-root" -or
          $Finding.kind -eq "baked-absolute-path")
}

function Get-Sha256HexForString {
  param([Parameter(Mandatory = $true)][string]$Value)

  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
  $hashBytes = [System.Security.Cryptography.SHA256]::HashData($bytes)
  return [System.Convert]::ToHexString($hashBytes).ToLowerInvariant()
}

function Read-KeyValueFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  $result = @{}
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $result
  }

  foreach ($line in (Get-Content -LiteralPath $Path)) {
    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }
    $trimmed = $line.Trim()
    if ($trimmed.StartsWith("#")) {
      continue
    }
    $separatorIndex = $trimmed.IndexOf("=")
    if ($separatorIndex -lt 1) {
      continue
    }
    $key = $trimmed.Substring(0, $separatorIndex).Trim()
    $value = $trimmed.Substring($separatorIndex + 1).Trim()
    if (-not [string]::IsNullOrWhiteSpace($key)) {
      $result[$key] = $value
    }
  }

  return $result
}

function Write-KeyValueFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][hashtable]$Values
  )

  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($key in ($Values.Keys | Sort-Object)) {
    $lines.Add("$key=$($Values[$key])")
  }

  $targetDirectory = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($targetDirectory)) {
    New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
  }

  Set-Content -LiteralPath $Path -Value $lines -Encoding ASCII
}

function Test-KeyValueFileMatches {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Expected,
    [Parameter(Mandatory = $true)][hashtable]$Actual
  )

  foreach ($key in $Expected.Keys) {
    if (-not $Actual.ContainsKey($key)) {
      return $false
    }
    if ([string]$Actual[$key] -ne [string]$Expected[$key]) {
      return $false
    }
  }
  return $true
}

function Get-WindowsTarExe {
  $systemTar = Join-Path $env:SystemRoot "System32/tar.exe"
  if (Test-Path $systemTar) {
    return $systemTar
  }

  $tarCommand = Get-Command tar -ErrorAction SilentlyContinue
  if ($null -ne $tarCommand -and -not [string]::IsNullOrWhiteSpace($tarCommand.Source)) {
    return $tarCommand.Source
  }

  throw "Unable to find tar.exe. Required to extract ct-remote archives."
}

function Find-SystemSevenZipExe {
  $commands = @("7z", "7za", "7zr")
  foreach ($commandName in $commands) {
    $command = Get-Command $commandName -ErrorAction SilentlyContinue
    if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
      return $command.Source
    }
  }

  $candidateRoots = @(
    ${env:ProgramFiles},
    ${env:ProgramFiles(x86)}
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

  foreach ($root in $candidateRoots) {
    $candidate = Join-Path $root "7-Zip/7z.exe"
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return $candidate
    }
  }

  return $null
}

function Get-SevenZipExe {
  param(
    [string]$Root,
    [hashtable]$Toolchain
  )

  # Prefer any 7-Zip already present (fast path for dev machines that have it
  # installed), but the GHA/self-hosted DIY runners do NOT ship 7-Zip, so fall
  # back to provisioning the pinned standalone 7zr.exe into the DIY cache. This
  # mirrors the Ensure-Gcc WinLibs direct-download fallback and keeps toolchain
  # provisioning in-repo rather than relying on ad-hoc runner state.
  $existing = Find-SystemSevenZipExe
  if ($null -ne $existing) {
    return $existing
  }

  if ([string]::IsNullOrWhiteSpace($Root) -or $null -eq $Toolchain) {
    throw "Unable to find 7-Zip (7z.exe/7za/7zr). Required to extract .7z toolchain archives."
  }

  $version = $Toolchain["SEVENZIP_VERSION"]
  if ([string]::IsNullOrWhiteSpace($version)) {
    throw "Missing SEVENZIP_VERSION in toolchain-versions.env; cannot provision 7zr.exe."
  }
  $expectedSha = $Toolchain["SEVENZIP_WIN_X64_SHA256"]
  if ([string]::IsNullOrWhiteSpace($expectedSha) -or $expectedSha -notmatch '^[A-Fa-f0-9]{64}$') {
    throw "Missing or invalid SEVENZIP_WIN_X64_SHA256 in toolchain-versions.env."
  }

  $sevenZipDir = Join-Path $Root "7zip/$version"
  $sevenZipExe = Join-Path $sevenZipDir "7zr.exe"

  if (Test-Path -LiteralPath $sevenZipExe -PathType Leaf) {
    try {
      Assert-FileSha256 -Path $sevenZipExe -Expected $expectedSha
      return $sevenZipExe
    } catch {
      Remove-Item -LiteralPath $sevenZipExe -Force -ErrorAction SilentlyContinue
    }
  }

  New-Item -ItemType Directory -Force -Path $sevenZipDir | Out-Null
  $downloadUrl = "https://github.com/ip7z/7zip/releases/download/$version/7zr.exe"
  Write-Host "Downloading 7-Zip standalone (7zr.exe $version) from $downloadUrl ..."
  Download-File -Url $downloadUrl -OutFile $sevenZipExe
  Assert-FileSha256 -Path $sevenZipExe -Expected $expectedSha

  if (-not (Test-Path -LiteralPath $sevenZipExe -PathType Leaf)) {
    throw "7-Zip provisioning did not produce '$sevenZipExe'."
  }

  Write-Host "Provisioned 7-Zip $version (7zr.exe) at $sevenZipExe"
  return $sevenZipExe
}

function Get-BashExe {
  $bashCommand = Get-Command bash -ErrorAction SilentlyContinue
  if ($null -eq $bashCommand -or [string]::IsNullOrWhiteSpace($bashCommand.Source)) {
    throw "bash is required for Tup source bootstrap but was not found on PATH. Install Git Bash/MSYS2 and retry."
  }
  return $bashCommand.Source
}

function ConvertTo-BashPath {
  param([Parameter(Mandatory = $true)][string]$WindowsPath)

  $normalized = [System.IO.Path]::GetFullPath($WindowsPath).Replace("\", "/")
  if ($normalized -match '^(?<drive>[A-Za-z]):(?<rest>/.*)$') {
    return "/$($Matches.drive.ToLowerInvariant())$($Matches.rest)"
  }
  return $normalized
}

function Resolve-GitRefToRevision {
  param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$RefName
  )

  if ($RefName -match '^[A-Fa-f0-9]{40}$') {
    return $RefName.ToLowerInvariant()
  }

  $gitCommand = Get-Command git -ErrorAction SilentlyContinue
  if ($null -eq $gitCommand -or [string]::IsNullOrWhiteSpace($gitCommand.Source)) {
    throw "git is required for source bootstrap but was not found on PATH."
  }

  $revisionOutput = & $gitCommand.Source ls-remote --refs $Repository $RefName 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to resolve git ref '$RefName' for '$Repository'."
  }

  $firstLine = ($revisionOutput | Select-Object -First 1)
  $firstLine = ([string]$firstLine).Trim()
  if ([string]::IsNullOrWhiteSpace($firstLine)) {
    throw "Ref '$RefName' did not resolve to a revision for '$Repository'."
  }

  $parts = $firstLine -split '\s+'
  if ($parts.Length -lt 1 -or $parts[0] -notmatch '^[A-Fa-f0-9]{40}$') {
    throw "Unexpected ls-remote output while resolving '$RefName' for '$Repository': $firstLine"
  }

  return $parts[0].ToLowerInvariant()
}

function Get-FlakeLockedGithubNode {
  param(
    [Parameter(Mandatory = $true)][string]$FlakeLockPath,
    [Parameter(Mandatory = $true)][string]$NodeName
  )

  if (-not (Test-Path -LiteralPath $FlakeLockPath -PathType Leaf)) {
    throw "Expected flake lock file at '$FlakeLockPath'."
  }

  $flakeLock = Get-Content -LiteralPath $FlakeLockPath -Raw | ConvertFrom-Json
  if ($null -eq $flakeLock -or $null -eq $flakeLock.nodes) {
    throw "flake.lock at '$FlakeLockPath' does not contain a nodes table."
  }

  $node = $flakeLock.nodes.$NodeName
  if ($null -eq $node -or $null -eq $node.locked) {
    throw "flake.lock is missing node '$NodeName' or its locked entry."
  }

  $type = [string]$node.locked.type
  if ($type -ne "github" -and $type -ne "git") {
    throw "flake.lock node '$NodeName' must be github or git locked. Found type '$type'."
  }

  $owner = ""
  $repo = ""
  $rev = [string]$node.locked.rev
  $url = ""

  if ($type -eq "github") {
    $owner = [string]$node.locked.owner
    $repo = [string]$node.locked.repo
    $url = "https://github.com/$owner/$repo.git"
  } else {
    $url = [string]$node.locked.url
    if ($url -match "github\.com/([^/]+)/([^/.]+?)(?:\.git)?$") {
      $owner = $Matches[1]
      $repo = $Matches[2]
    } else {
      throw "flake.lock node '$NodeName' has type 'git' but URL '$url' is not a GitHub URL."
    }
  }

  if (
    [string]::IsNullOrWhiteSpace($owner) -or
    [string]::IsNullOrWhiteSpace($repo) -or
    [string]::IsNullOrWhiteSpace($rev)
  ) {
    throw "flake.lock node '$NodeName' must include locked owner/repo/rev."
  }

  return @{
    owner = $owner
    repo = $repo
    rev = $rev
    url = $url
  }
}

function Resolve-AbsolutePathWithBase {
  param(
    [Parameter(Mandatory = $true)][string]$PathValue,
    [Parameter(Mandatory = $true)][string]$BasePath
  )

  $expanded = [Environment]::ExpandEnvironmentVariables($PathValue)
  if ([System.IO.Path]::IsPathRooted($expanded)) {
    return [System.IO.Path]::GetFullPath($expanded)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $BasePath $expanded))
}

function Get-TupMsys2PackageList {
  param([Parameter(Mandatory = $true)][hashtable]$Toolchain)

  $packagesRaw = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_MSYS2_PACKAGES")
  if ([string]::IsNullOrWhiteSpace($packagesRaw)) {
    $packagesRaw = $Toolchain["TUP_MSYS2_PACKAGES"]
  }
  $packages = @($packagesRaw.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries))
  if ($packages.Count -eq 0) {
    throw "TUP Windows MSYS2 package list is empty. Set TUP_WINDOWS_MSYS2_PACKAGES or add TUP_MSYS2_PACKAGES to toolchain-versions.env."
  }
  return $packages
}

function Ensure-TupMsys2BuildPrereqs {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $versionRaw = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_MSYS2_BASE_VERSION")
  if ([string]::IsNullOrWhiteSpace($versionRaw)) {
    $versionRaw = $Toolchain["TUP_MSYS2_BASE_VERSION"]
  }
  $version = $versionRaw.Trim()
  if ($version -notmatch '^[0-9]{8}$') {
    throw "Invalid TUP_WINDOWS_MSYS2_BASE_VERSION '$versionRaw'. Expected YYYYMMDD."
  }

  $expectedShaRaw = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_MSYS2_BASE_X64_SHA256")
  if ([string]::IsNullOrWhiteSpace($expectedShaRaw)) {
    $expectedShaRaw = $Toolchain["TUP_MSYS2_BASE_X64_SHA256"]
  }
  $expectedSha = $expectedShaRaw.Trim().ToLowerInvariant()
  if ($expectedSha -notmatch '^[A-Fa-f0-9]{64}$') {
    throw "Invalid TUP_WINDOWS_MSYS2_BASE_X64_SHA256 value '$expectedShaRaw'."
  }

  $msys2Root = Join-Path $Root "tup/msys2/$version"
  $msysInstallRoot = Join-Path $msys2Root "msys64"
  $msysBashExe = Join-Path $msysInstallRoot "usr/bin/bash.exe"
  $archiveName = "msys2-base-x86_64-$version.tar.xz"
  $baseUrl = "https://github.com/msys2/msys2-installer/releases/download/$($version.Substring(0,4))-$($version.Substring(4,2))-$($version.Substring(6,2))"
  $assetUrl = "$baseUrl/$archiveName"
  $shaUrl = "$assetUrl.sha256"
  $archivePath = Join-Path $env:TEMP $archiveName
  $installMetaFile = Join-Path $msys2Root "msys2.install.meta"
  $packages = Get-TupMsys2PackageList -Toolchain $Toolchain
  $packageList = ($packages -join " ")

  $expectedMetadata = @{
    tup_msys2_version = $version
    tup_msys2_archive_sha256 = $expectedSha
    tup_msys2_packages = $packageList
  }

  if ((Test-Path -LiteralPath $msysBashExe -PathType Leaf) -and (Test-Path -LiteralPath $installMetaFile -PathType Leaf)) {
    $installedMetadata = Read-KeyValueFile -Path $installMetaFile
    if (Test-KeyValueFileMatches -Expected $expectedMetadata -Actual $installedMetadata) {
      return @{
        root = $msysInstallRoot
        bashExe = $msysBashExe
        metadata = $expectedMetadata
      }
    }
  }

  # Announce it. Every other bootstrap download says what it is fetching
  # before it fetches it; this one did not, which is why a stall here
  # produced a log whose last line was the PREVIOUS component finishing and
  # gave no hint that MSYS2 was even involved.
  Write-Host "Downloading MSYS2 base $version from $assetUrl ..."
  Download-File -Url $assetUrl -OutFile $archivePath
  try {
    Assert-FileSha256 -Path $archivePath -Expected $expectedSha
  } catch {
    $shaText = Download-String -Url $shaUrl
    $shaFromSidecar = Get-ExpectedSha256 -ShaSource $shaText -AssetName $archiveName
    if ($shaFromSidecar -ne $expectedSha) {
      throw "Pinned TUP MSYS2 SHA mismatch for '$archiveName'. toolchain pin: $expectedSha, sidecar: $shaFromSidecar"
    }
    throw
  }

  Ensure-CleanDirectory -Path $msys2Root
  New-Item -ItemType Directory -Force -Path $msys2Root | Out-Null
  $tarExe = Get-WindowsTarExe
  # Bounded, and with a closed stdin: native output still reaches the console
  # (so it cannot become function pipeline output and corrupt the hashtable
  # return value), but neither leg can now block the job indefinitely.
  Write-Host "Extracting MSYS2 base archive to $msys2Root ..."
  $tarExit = Invoke-BoundedNativeCommand `
    -FilePath $tarExe `
    -ArgumentList @("-xJf", $archivePath, "-C", $msys2Root) `
    -Activity "MSYS2 Tup prerequisite archive extraction"
  if ($tarExit -ne 0) {
    throw "Failed to extract MSYS2 Tup prerequisite archive '$archivePath' (exit $tarExit)."
  }
  if (-not (Test-Path -LiteralPath $msysBashExe -PathType Leaf)) {
    throw "MSYS2 Tup prerequisite bootstrap did not produce '$msysBashExe'."
  }

  $packageArgs = ($packages | ForEach-Object { $_.Trim() }) -join " "
  # `--noconfirm` was already here, so pacman is not waiting on a [Y/n]. What
  # it can still do is wait on a mirror that has gone quiet mid-transfer, and
  # `-lc` means a prompt from anything pacman itself invokes would inherit the
  # runner's stdin. The bound and the closed stdin close both.
  #
  # THE COMPLETION MARKER IS NOT BELT-AND-BRACES; IT IS THE GUARD THAT WORKS.
  #
  # `$pacmanExit -ne 0` asks "did the shell fail?", which is only a proxy for
  # "did the install happen?", and the two came apart badly once: the command
  # string was split on its spaces before it reached bash, bash ran the
  # builtin `set` instead, and `set` exits 0. A zero from a command that never
  # ran is indistinguishable from a zero from a command that succeeded, so the
  # guard could not fire and the run went on to fail three checks later on a
  # missing gcc -- naming a symptom of the real fault and giving no route back
  # to it.
  #
  # A marker written by the LAST statement of the command string cannot be
  # faked by a truncated or misdelivered command: its existence proves the
  # whole string arrived AND that every statement before it succeeded (`set
  # -e`). It goes in `/tmp`, which for MSYS2 is the installation root's own
  # `tmp` directory -- bash.exe lives at `<msys64>/usr/bin`, so `/` is
  # `<msys64>` -- and that lets this side check for it with no Windows-to-MSYS
  # path conversion.
  $markerName = "ct-msys2-pacman-" + [Guid]::NewGuid().ToString("N") + ".done"
  $msysTmpDir = Join-Path $msysInstallRoot "tmp"
  New-Item -ItemType Directory -Force -Path $msysTmpDir | Out-Null
  $markerPath = Join-Path $msysTmpDir $markerName
  $packageInstallCommand =
    "set -euo pipefail; pacman -Sy --noconfirm --needed $packageArgs; printf 'ok' > '/tmp/$markerName'"
  Write-Host "Installing MSYS2 packages: $packageArgs"
  $ranToCompletion = $false
  try {
    $pacmanExit = Invoke-BoundedNativeCommand `
      -FilePath $msysBashExe `
      -ArgumentList @("-lc", $packageInstallCommand) `
      -Activity "MSYS2 pacman install of Tup prerequisites"
    if ($pacmanExit -ne 0) {
      throw "Failed to install Tup MSYS2 prerequisite packages ($packageArgs) (exit $pacmanExit)."
    }
    $ranToCompletion = Test-Path -LiteralPath $markerPath -PathType Leaf
  } finally {
    Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
  }

  # THE MARKER DIAGNOSES; THE TOOLS DECIDE.
  #
  # Deliberately in this order, and deliberately not "no marker => throw".
  # The archive was extracted into a directory this function had just emptied,
  # so these three binaries exist only if THIS pacman run produced them --
  # which makes their presence proof of the install that is independent of
  # both the exit code and the marker. Letting the marker veto that proof
  # would put a fresh way to fail a working provision in place of the old way
  # to pass a broken one, and the marker is the newer, less-proven of the two
  # signals. So the tools decide the outcome, and the marker decides what the
  # failure is CALLED -- which is the part that was missing, because the
  # symptom ("no gcc") and the cause ("the install never ran") had become
  # indistinguishable from here.
  $mingwGccExe = Join-Path $msysInstallRoot "mingw64/bin/gcc.exe"
  $mingwPkgConfigExe = Join-Path $msysInstallRoot "mingw64/bin/pkg-config.exe"
  $msysMakeExe = Join-Path $msysInstallRoot "usr/bin/make.exe"

  $missing = @()
  if (-not (Test-Path -LiteralPath $mingwGccExe -PathType Leaf)) { $missing += "MinGW compiler at '$mingwGccExe'" }
  if (-not (Test-Path -LiteralPath $mingwPkgConfigExe -PathType Leaf)) { $missing += "MinGW pkg-config at '$mingwPkgConfigExe'" }
  if (-not (Test-Path -LiteralPath $msysMakeExe -PathType Leaf)) { $missing += "make at '$msysMakeExe'" }

  if ($missing.Count -gt 0) {
    if (-not $ranToCompletion) {
      # The observed failure, now named at its cause instead of three checks
      # downstream.
      throw (
        "The MSYS2 pacman install DID NOT RUN. '$msysBashExe' exited 0 without reaching " +
        "the end of the install command, so nothing was installed and the exit code " +
        "means nothing -- a shell handed a truncated command succeeds at running the " +
        "wrong thing. Requested packages: $packageArgs. Missing afterwards: " +
        ($missing -join "; ") + ". Check that the command string reached bash intact " +
        "(the arguments a child receives are gated by ci/test/download-stall-bound.ps1)."
      )
    }
    throw (
      "The MSYS2 pacman install of ($packageArgs) ran to completion and reported success, " +
      "but produced no " + ($missing -join "; and no ") + ". Suspect a renamed package or " +
      "an incomplete mirror rather than the invocation."
    )
  }

  if (-not $ranToCompletion) {
    # Everything asked for is present, so the install unambiguously happened
    # and this run is sound. Say so anyway: the marker is what makes the
    # failure above diagnosable, and a marker that has quietly stopped working
    # must not be discovered during the next incident.
    Write-Host "::warning::MSYS2 pacman completion marker was not found at '$markerPath', but every requested tool is present. The install succeeded; the marker check itself needs attention."
  }

  Write-KeyValueFile -Path $installMetaFile -Values $expectedMetadata
  return @{
    root = $msysInstallRoot
    bashExe = $msysBashExe
    metadata = $expectedMetadata
  }
}

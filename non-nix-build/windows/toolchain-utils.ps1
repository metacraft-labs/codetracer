Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# HOW LONG A SINGLE TOOLCHAIN DOWNLOAD MAY BLOCK BEFORE IT IS A FAILURE.
#
# `Invoke-WebRequest` has NO default timeout: `-TimeoutSec` unset means
# infinite, and under `pwsh` (HttpClient) the value covers the whole transfer,
# body included -- not just the response headers. Every toolchain in this file
# is fetched through `Download-File` / `Download-String`, so before this
# constant existed a single stalled socket parked the ENTIRE Windows dev-env
# bootstrap forever. `Invoke-WithRetry` did not help: it bounds the number of
# attempts (4), never the duration of one, so 4 x infinite is still infinite.
#
# This is not theoretical. On 2026-09-04 run 33880354195, `windows-rust-components`
# sat in `Setup dev env` from 14:37:32 to 20:05:35 and `origin-DAP (materialized
# Python, Windows)` sat in `Setup db-backend siblings` from 14:20:59 to
# 20:05:50 -- both released only by GitHub's DEFAULT 360-minute job timeout,
# because neither job sets `timeout-minutes` either. For those six hours they
# held the `Codetracer CI-dev` concurrency group `in_progress`, which is what
# starved every other verdict on the branch.
#
# The value has to clear the largest asset this bootstrap pulls: the WinDbg
# msixbundle in ensure-ttd.ps1 is ~767 MB, so a total-transfer budget of a few
# minutes would convert a slow link into a spurious red. 30 minutes is ~0.4 MB/s
# sustained for that asset -- far below any healthy runner, far above a socket
# that has stopped moving. Override for a genuinely slow network with
# WINDOWS_DIY_DOWNLOAD_TIMEOUT_SECONDS; 0 restores the old infinite behaviour
# and is deliberately spelled as an opt-in rather than left as the default.
function Get-DownloadTimeoutSeconds {
  $raw = [Environment]::GetEnvironmentVariable("WINDOWS_DIY_DOWNLOAD_TIMEOUT_SECONDS")
  if ([string]::IsNullOrWhiteSpace($raw)) { return 1800 }

  $parsed = 0
  if (-not [int]::TryParse($raw.Trim(), [ref]$parsed) -or $parsed -lt 0) {
    throw "WINDOWS_DIY_DOWNLOAD_TIMEOUT_SECONDS must be a non-negative integer (got '$raw')."
  }
  return $parsed
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

function Download-File {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$OutFile
  )

  $timeoutSeconds = Get-DownloadTimeoutSeconds
  Invoke-WithRetry -Script {
    # A zero timeout is git's/PowerShell's "wait forever"; only pass the
    # parameter when the operator has NOT asked for that, so the opt-out is a
    # real opt-out rather than `-TimeoutSec 0` meaning something subtly else.
    if ($timeoutSeconds -gt 0) {
      Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec $timeoutSeconds
    } else {
      Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    }
  } | Out-Null
}

function Download-String {
  param([Parameter(Mandatory = $true)][string]$Url)

  $timeoutSeconds = Get-DownloadTimeoutSeconds
  $content = Invoke-WithRetry -Script {
    if ($timeoutSeconds -gt 0) {
      (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $timeoutSeconds).Content
    } else {
      (Invoke-WebRequest -Uri $Url -UseBasicParsing).Content
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

function Ensure-CleanDirectory {
  param([Parameter(Mandatory = $true)][string]$Path)

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

function Get-BootstrapStepRecords {
  return $script:BootstrapStepRecords.ToArray()
}

function Reset-BootstrapStepRecords {
  $script:BootstrapStepRecords.Clear()
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
    $relocatabilityWarning = $null
    if ($record.relocatability -eq "relocatable" -and $reparse -gt 0) {
      $relocatabilityWarning =
        "declared relocatable but $reparse reparse point(s) found under its install directories"
      Write-Warning "Bootstrap step '$($record.step)': $relocatabilityWarning"
    }

    $rows += [pscustomobject]@{
      step = $record.step
      status = $record.status
      relocatability = $record.relocatability
      relocatability_warning = $relocatabilityWarning
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

  # Architecture is a label on the measurement, not part of it. Get-WindowsArch
  # goes through CIM, which is Windows-only and can fail on a loaded box; a
  # report that cannot say which architecture it came from is far more useful
  # than no report at all, and this function is called from a `finally` whose
  # whole purpose is to survive a failed provision.
  $arch = "unknown"
  try { $arch = Get-WindowsArch } catch { $arch = "unknown" }

  $report = [pscustomobject]@{
    schema = "codetracer.windows-env-decomposition.v1"
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
  Write-Host "Wrote $jsonPath"

  return $jsonPath
}

function ConvertTo-InstallRelativePath {
  param(
    [Parameter(Mandatory = $true)][string]$AbsolutePath,
    [Parameter(Mandatory = $true)][string]$Root
  )

  $absoluteRoot = [System.IO.Path]::GetFullPath($Root)
  $absoluteTarget = [System.IO.Path]::GetFullPath($AbsolutePath)
  $rootPrefix = if ($absoluteRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar)) { $absoluteRoot } else { "$absoluteRoot\" }

  if (-not $absoluteTarget.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Expected path '$absoluteTarget' to be under install root '$absoluteRoot'."
  }

  return $absoluteTarget.Substring($rootPrefix.Length).Replace("\", "/")
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
  # Keep native command output visible in the console while preventing it from
  # becoming function pipeline output (which would corrupt the hashtable return value).
  & $tarExe -xJf $archivePath -C $msys2Root | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to extract MSYS2 Tup prerequisite archive '$archivePath'."
  }
  if (-not (Test-Path -LiteralPath $msysBashExe -PathType Leaf)) {
    throw "MSYS2 Tup prerequisite bootstrap did not produce '$msysBashExe'."
  }

  $packageArgs = ($packages | ForEach-Object { $_.Trim() }) -join " "
  $packageInstallCommand = "set -euo pipefail; pacman -Sy --noconfirm --needed $packageArgs"
  & $msysBashExe -lc $packageInstallCommand | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to install Tup MSYS2 prerequisite packages ($packageArgs)."
  }

  $mingwGccExe = Join-Path $msysInstallRoot "mingw64/bin/gcc.exe"
  $mingwPkgConfigExe = Join-Path $msysInstallRoot "mingw64/bin/pkg-config.exe"
  $msysMakeExe = Join-Path $msysInstallRoot "usr/bin/make.exe"
  if (-not (Test-Path -LiteralPath $mingwGccExe -PathType Leaf)) {
    throw "MSYS2 Tup prerequisite install is incomplete. Missing MinGW compiler at '$mingwGccExe'."
  }
  if (-not (Test-Path -LiteralPath $mingwPkgConfigExe -PathType Leaf)) {
    throw "MSYS2 Tup prerequisite install is incomplete. Missing MinGW pkg-config at '$mingwPkgConfigExe'."
  }
  if (-not (Test-Path -LiteralPath $msysMakeExe -PathType Leaf)) {
    throw "MSYS2 Tup prerequisite install is incomplete. Missing make at '$msysMakeExe'."
  }

  Write-KeyValueFile -Path $installMetaFile -Values $expectedMetadata
  return @{
    root = $msysInstallRoot
    bashExe = $msysBashExe
    metadata = $expectedMetadata
  }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Gate for the env.ps1 per-component decomposition: a machine-readable
# per-component table that must cover every gated component in env.ps1's
# dispatch block, checked mechanically against that dispatch list rather than
# by eye, so a component added or removed later cannot silently fall out of
# the decomposition.
#
# The mechanical check has two halves, because either alone can pass while
# the decomposition is wrong:
#
#   1. STATIC (AST): every Ensure-* call in env.ps1's gated dispatch block
#      goes through Invoke-BootstrapStep. This is what stops a newly added
#      component from being invisible to the report -- a bare `Ensure-Foo`
#      would install a tool that the decomposition never mentions, and the
#      omission would be indistinguishable from a component that costs
#      nothing.
#
#   2. BEHAVIOURAL: Invoke-BootstrapStep and Write-BootstrapStepReport
#      actually record what they claim, against a real filesystem -- skips,
#      failures, sizes, and the reparse-point exclusion that keeps the
#      install-root total from double-counting junctions.
#
# NO MOCKS. Per the workspace policy on mock objects, this file uses none:
# the AST half parses the real env.ps1, and the behavioural half runs the
# real functions from the real toolchain-utils.ps1 against real directories
# under a temporary root. The only substitution is that the scriptblocks
# passed to Invoke-BootstrapStep create directories directly instead of
# downloading a toolchain -- that is the test's own subject matter (what the
# wrapper does with an arbitrary action), not a stand-in for a collaborator.
#
# Runs on Linux/macOS pwsh as well as Windows: nothing here needs a Windows
# API. The reparse-point case is skipped where the platform cannot create a
# symlink without elevation, and says so.

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$envPs1Path = Join-Path $repoRoot "env.ps1"
$utilsPath = Join-Path $repoRoot "non-nix-build/windows/toolchain-utils.ps1"

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

# ---------------------------------------------------------------------------
# Part 1 - static: the dispatch block routes every component through the
# accounting wrapper.
# ---------------------------------------------------------------------------

Write-Host "== dispatch-block coverage (AST of env.ps1)"

if (-not (Test-Path -LiteralPath $envPs1Path -PathType Leaf)) {
  throw "env.ps1 not found at '$envPs1Path'."
}

$parseErrors = $null
$envAst = [System.Management.Automation.Language.Parser]::ParseFile(
  $envPs1Path, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
  $parseErrors | ForEach-Object { Write-Host "  env.ps1: $($_.Message)" }
  throw "env.ps1 does not parse."
}

function Get-CommandAsts {
  param($Ast, [string]$NamePattern)
  return @($Ast.FindAll({
    param($node)
    ($node -is [System.Management.Automation.Language.CommandAst]) -and
    ($null -ne $node.GetCommandName()) -and
    ($node.GetCommandName() -like $NamePattern)
  }, $true))
}

# The gated dispatch block is the `if ($doSync) { ... }` whose body contains
# the Invoke-BootstrapStep calls. env.ps1 has more than one `if ($doSync)`
# -- the other guards Ensure-NodeTooling -- so it is identified by content
# rather than by position, which also keeps this gate working when the file
# is edited above it.
$dispatchBlocks = @($envAst.FindAll({
  param($node)
  ($node -is [System.Management.Automation.Language.IfStatementAst]) -and
  (@(Get-CommandAsts -Ast $node -NamePattern "Invoke-BootstrapStep").Count -gt 0)
}, $true))

# FindAll returns nested matches too (an outer `if` containing the real one).
# The dispatch block is the innermost such statement.
$dispatchBlock = $dispatchBlocks |
  Sort-Object -Property { $_.Extent.EndOffset - $_.Extent.StartOffset } |
  Select-Object -First 1

Assert-True -Condition ($null -ne $dispatchBlock) `
  -Message "env.ps1 contains an `$doSync dispatch block using Invoke-BootstrapStep"

if ($null -eq $dispatchBlock) {
  Write-Host "FAILED: cannot continue without the dispatch block."
  exit 1
}

$stepCalls = @(Get-CommandAsts -Ast $dispatchBlock -NamePattern "Invoke-BootstrapStep")
$ensureCalls = @(Get-CommandAsts -Ast $dispatchBlock -NamePattern "Ensure-*")

# Every Ensure-* call inside the block must sit inside the extent of some
# Invoke-BootstrapStep call -- i.e. inside its -Action scriptblock.
$uncovered = @()
foreach ($ensure in $ensureCalls) {
  $covered = $false
  foreach ($step in $stepCalls) {
    if ($ensure.Extent.StartOffset -ge $step.Extent.StartOffset -and
        $ensure.Extent.EndOffset -le $step.Extent.EndOffset) {
      $covered = $true
      break
    }
  }
  if (-not $covered) {
    $uncovered += "$($ensure.GetCommandName()) at line $($ensure.Extent.StartLineNumber)"
  }
}

Assert-True -Condition ($uncovered.Count -eq 0) `
  -Message ("every Ensure-* call in the dispatch block goes through Invoke-BootstrapStep" +
            $(if ($uncovered.Count -gt 0) { " (uncovered: $($uncovered -join '; '))" } else { "" }))

# A leftover bare `Test-BootstrapStepEnabled` gate in this block means a
# component is gated but unaccounted: it would run without being timed.
$rawGates = @(Get-CommandAsts -Ast $dispatchBlock -NamePattern "Test-BootstrapStepEnabled")
Assert-Equal -Expected 0 -Actual $rawGates.Count `
  -Message "no bare Test-BootstrapStepEnabled gate remains in the dispatch block"

# Extract the declared -Step and -Relocatability of each call.
$declared = @()
foreach ($step in $stepCalls) {
  $stepName = $null
  $class = $null
  for ($i = 0; $i -lt $step.CommandElements.Count; $i++) {
    $element = $step.CommandElements[$i]
    if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
      $next = if (($i + 1) -lt $step.CommandElements.Count) { $step.CommandElements[$i + 1] } else { $null }
      $value = $null
      if ($next -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        $value = $next.Value
      }
      switch ($element.ParameterName) {
        "Step" { $stepName = $value }
        "Relocatability" { $class = $value }
      }
    }
  }
  $declared += [pscustomobject]@{ step = $stepName; relocatability = $class; line = $step.Extent.StartLineNumber }
}

$validClasses = @("relocatable", "junction", "installer")
$badClass = @($declared | Where-Object { $validClasses -notcontains $_.relocatability })
Assert-True -Condition ($badClass.Count -eq 0) `
  -Message ("every dispatched component declares a valid relocatability class" +
            $(if ($badClass.Count -gt 0) { " (bad: $(($badClass | ForEach-Object { "$($_.step)=$($_.relocatability)" }) -join ', '))" } else { "" }))

$missingName = @($declared | Where-Object { [string]::IsNullOrWhiteSpace($_.step) })
Assert-Equal -Expected 0 -Actual $missingName.Count `
  -Message "every dispatched component declares a literal -Step name"

$names = @($declared | ForEach-Object { $_.step })
$duplicates = @($names | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
Assert-True -Condition ($duplicates.Count -eq 0) `
  -Message ("component names are unique" + $(if ($duplicates.Count -gt 0) { " (duplicated: $($duplicates -join ','))" } else { "" }))

# There are 22 gated components today. Assert the floor rather than equality:
# adding a component is legitimate and must not break this gate, whereas
# losing one silently is the failure mode the gate exists for.
Assert-True -Condition ($stepCalls.Count -ge 22) `
  -Message "the dispatch block covers at least the 22 known gated components (found $($stepCalls.Count))"

# ...and the NAMES, not just the count. A count floor alone is defeated by the
# most likely edit of all: one component dropped while another is added, which
# leaves the total at 22 and the decomposition quietly missing a tool. Pinning
# the names makes a removal an explicit, reviewable edit to this list rather
# than an invisible consequence of an unrelated change. Additions still need no
# edit here -- this is a required SUBSET, not an exact set.
$requiredComponents = @(
  "TTD", "NODE", "UV", "GCC", "GNAT", "GO", "LDC", "VLANG", "FPC", "ZSTD",
  "ZLIB", "LLVM", "CLINGO", "RUST", "JUST", "NEXTEST", "NIM", "CAPNP", "TUP",
  "NARGO", "DOTNET", "CT_REMOTE"
)
$missingComponents = @($requiredComponents | Where-Object { $names -notcontains $_ })
Assert-True -Condition ($missingComponents.Count -eq 0) `
  -Message ("every known gated component is still dispatched" +
            $(if ($missingComponents.Count -gt 0) { " (missing: $($missingComponents -join ','))" } else { "" }))

Write-Host "  components dispatched: $(($names | Sort-Object) -join ', ')"

# ---------------------------------------------------------------------------
# Part 2 - behavioural: the wrapper and the report record what they claim.
# ---------------------------------------------------------------------------

Write-Host "== Invoke-BootstrapStep / Write-BootstrapStepReport behaviour"

. $utilsPath

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("ct-decomp-" + [Guid]::NewGuid().ToString('N'))
$installRoot = Join-Path $testRoot "install"
$reportDir = Join-Path $testRoot "report"
New-Item -ItemType Directory -Force -Path $installRoot | Out-Null

try {
  Reset-BootstrapStepRecords

  # A component that installs something: 3 files of known size.
  Invoke-BootstrapStep -Step "ALPHA" -Relocatability relocatable -Root $installRoot -Action {
    $dir = Join-Path $installRoot "alpha/1.0"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($name in @("a.bin", "b.bin", "c.bin")) {
      [IO.File]::WriteAllBytes((Join-Path $dir $name), (New-Object byte[] 1000))
    }
  }

  # A component disabled by its skip variable.
  $env:WINDOWS_DIY_SKIP_BETA = "1"
  try {
    Invoke-BootstrapStep -Step "BETA" -Relocatability relocatable -Root $installRoot -Action {
      throw "BETA must not run while WINDOWS_DIY_SKIP_BETA is set."
    }
  } finally {
    Remove-Item Env:\WINDOWS_DIY_SKIP_BETA -ErrorAction SilentlyContinue
  }

  # A component installed by a vendor installer, declared as such.
  Invoke-BootstrapStep -Step "GAMMA" -Relocatability installer -Root $installRoot -Action {
    $dir = Join-Path $installRoot "gamma"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $dir "setup.log"), (New-Object byte[] 500))
  }

  # A component that fails. The wrapper must record the cost and RETHROW --
  # swallowing it would turn a broken provision into a silently partial one,
  # which is the exact defect this file guards against.
  $rethrown = $false
  try {
    Invoke-BootstrapStep -Step "DELTA" -Relocatability relocatable -Root $installRoot -Action {
      $dir = Join-Path $installRoot "delta"
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
      throw "simulated DELTA failure"
    }
  } catch {
    $rethrown = ($_.Exception.Message -eq "simulated DELTA failure")
  }
  Assert-True -Condition $rethrown -Message "a failing component rethrows rather than being swallowed"

  $records = Get-BootstrapStepRecords
  Assert-Equal -Expected 4 -Actual $records.Count -Message "one record per dispatched component"

  $alpha = $records | Where-Object { $_.step -eq "ALPHA" }
  $beta = $records | Where-Object { $_.step -eq "BETA" }
  $gamma = $records | Where-Object { $_.step -eq "GAMMA" }
  $delta = $records | Where-Object { $_.step -eq "DELTA" }

  Assert-Equal -Expected "ok" -Actual $alpha.status -Message "ALPHA recorded as ok"
  Assert-Equal -Expected "skipped" -Actual $beta.status -Message "BETA recorded as skipped"
  Assert-Equal -Expected "failed" -Actual $delta.status -Message "DELTA recorded as failed"
  Assert-Equal -Expected "WINDOWS_DIY_SKIP_BETA" -Actual $beta.skip_variable `
    -Message "the skip variable that disabled BETA is named in the record"
  Assert-True -Condition ($delta.error -eq "simulated DELTA failure") `
    -Message "the failure message is recorded"
  Assert-True -Condition ($alpha.created_dirs -contains "alpha") `
    -Message "ALPHA's install directory is attributed to it"
  Assert-True -Condition ($beta.created_dirs.Count -eq 0) `
    -Message "a skipped component is attributed no install directory"

  $reportPath = Write-BootstrapStepReport -Root $installRoot -OutputDir $reportDir
  Assert-True -Condition (Test-Path -LiteralPath $reportPath -PathType Leaf) `
    -Message "the decomposition file is written"

  $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
  Assert-Equal -Expected "codetracer.windows-env-decomposition.v1" -Actual $report.schema `
    -Message "the report declares its schema"
  Assert-Equal -Expected 4 -Actual $report.components.Count -Message "the report has a row per component"

  # A run with a skip or a failure is NOT a complete provision, and the
  # report must say so: a green run must not be green by omission.
  Assert-Equal -Expected $false -Actual $report.complete `
    -Message "a run with a skipped and a failed component is reported incomplete"
  Assert-True -Condition ($report.skipped_steps -contains "BETA") `
    -Message "the skipped component is named in skipped_steps"
  Assert-True -Condition ($report.failed_steps -contains "DELTA") `
    -Message "the failed component is named in failed_steps"

  $alphaRow = $report.components | Where-Object { $_.step -eq "ALPHA" }
  Assert-Equal -Expected 3000 -Actual $alphaRow.bytes -Message "ALPHA's install size is measured exactly"
  Assert-Equal -Expected 3 -Actual $alphaRow.files -Message "ALPHA's file count is measured exactly"
  $gammaRow = $report.components | Where-Object { $_.step -eq "GAMMA" }
  Assert-Equal -Expected "installer" -Actual $gammaRow.relocatability `
    -Message "the declared relocatability class survives into the report"

  # The whole-root total.
  Assert-Equal -Expected 3500 -Actual $report.install_root_bytes `
    -Message "the install-root total is the sum of everything under the root"

  # A directory nobody created must be reported as unattributed rather than
  # quietly dropped, or the per-component rows could sum to less than the
  # root total with no indication why.
  New-Item -ItemType Directory -Force -Path (Join-Path $installRoot "stray") | Out-Null
  [IO.File]::WriteAllBytes((Join-Path $installRoot "stray/x.bin"), (New-Object byte[] 250))
  $report2 = Get-Content -LiteralPath (Write-BootstrapStepReport -Root $installRoot -OutputDir $reportDir) -Raw | ConvertFrom-Json
  Assert-True -Condition ($report2.unattributed_install_dirs -contains "stray") `
    -Message "a directory no component created is reported as unattributed"

  # Reparse points must be counted but not followed. Following a junction
  # that points back inside the install root would double-count it and
  # inflate the install-root total by a variable amount.
  $linkPath = Join-Path $installRoot "linked"
  $linkCreated = $false
  try {
    New-Item -ItemType SymbolicLink -Path $linkPath -Target (Join-Path $installRoot "alpha") -ErrorAction Stop | Out-Null
    $linkCreated = $true
  } catch {
    Write-Host "  skip: cannot create a symlink on this platform/privilege level ($($_.Exception.Message))"
  }
  if ($linkCreated) {
    $measured = Measure-DirectorySize -Path $installRoot
    Assert-Equal -Expected 3750 -Actual $measured.bytes `
      -Message "a symlink back into the install root is not followed (no double-count)"
    Assert-True -Condition ($measured.reparse_points -ge 1) `
      -Message "the reparse point is counted"
  }

  # WINDOWS_DIY_ONLY: the positive allowlist a satellite repo uses to ask for
  # a subset of components (codetracer-trace-format wants CAPNP and nothing
  # else). Expressing that subtractively would silently break the moment a
  # new component is added, because the new one defaults to ON -- so the
  # allowlist must EXCLUDE by default, and that is what these two cases pin.
  Reset-BootstrapStepRecords
  $env:WINDOWS_DIY_ONLY = "CAPNP"
  try {
    Invoke-BootstrapStep -Step "CAPNP" -Relocatability relocatable -Root $installRoot -Action { }
    Invoke-BootstrapStep -Step "NARGO" -Relocatability relocatable -Root $installRoot -Action {
      throw "NARGO must not run when WINDOWS_DIY_ONLY does not list it."
    }
    $onlyRecords = Get-BootstrapStepRecords
    $capnpRecord = $onlyRecords | Where-Object { $_.step -eq "CAPNP" }
    $nargoRecord = $onlyRecords | Where-Object { $_.step -eq "NARGO" }
    Assert-Equal -Expected "ok" -Actual $capnpRecord.status `
      -Message "WINDOWS_DIY_ONLY=CAPNP runs the listed component"
    Assert-Equal -Expected "skipped" -Actual $nargoRecord.status `
      -Message "WINDOWS_DIY_ONLY=CAPNP skips an unlisted component"
    Assert-Equal -Expected "not listed in WINDOWS_DIY_ONLY" -Actual $nargoRecord.skip_reason `
      -Message "the allowlist exclusion records WHY it was skipped, not just that it was"
  } finally {
    Remove-Item Env:\WINDOWS_DIY_ONLY -ErrorAction SilentlyContinue
  }

  # The allowlist is case- and separator-insensitive, because it is written by
  # hand in workflow YAML.
  Reset-BootstrapStepRecords
  $env:WINDOWS_DIY_ONLY = "capnp, rust"
  try {
    Invoke-BootstrapStep -Step "RUST" -Relocatability relocatable -Root $installRoot -Action { }
    $rustRecord = Get-BootstrapStepRecords | Where-Object { $_.step -eq "RUST" }
    Assert-Equal -Expected "ok" -Actual $rustRecord.status `
      -Message "the allowlist accepts lowercase, comma-and-space separated names"
  } finally {
    Remove-Item Env:\WINDOWS_DIY_ONLY -ErrorAction SilentlyContinue
  }

  # A skip variable still wins inside an allowlist: the two gates compose,
  # and neither silently overrides the other.
  Reset-BootstrapStepRecords
  $env:WINDOWS_DIY_ONLY = "CAPNP"
  $env:WINDOWS_DIY_SKIP_CAPNP = "1"
  try {
    Invoke-BootstrapStep -Step "CAPNP" -Relocatability relocatable -Root $installRoot -Action {
      throw "CAPNP must not run while WINDOWS_DIY_SKIP_CAPNP is set."
    }
    $bothRecord = Get-BootstrapStepRecords | Where-Object { $_.step -eq "CAPNP" }
    Assert-Equal -Expected "skipped" -Actual $bothRecord.status `
      -Message "an explicit skip still applies to a component inside WINDOWS_DIY_ONLY"
  } finally {
    Remove-Item Env:\WINDOWS_DIY_ONLY -ErrorAction SilentlyContinue
    Remove-Item Env:\WINDOWS_DIY_SKIP_CAPNP -ErrorAction SilentlyContinue
  }

  # THE DISPATCH GATE AND THE ASSERTION GATE MUST AGREE.
  #
  # env.ps1 asks whether a component is wanted TWICE: once to dispatch it
  # (through Invoke-BootstrapStep) and once afterwards to decide whether to
  # ASSERT the tool is present -- `WINDOWS_DIY_ENSURE_TTD` and
  # `WINDOWS_DIY_ENSURE_DOTNET` both default to `Test-BootstrapStepEnabled`.
  # If only the first consultation honoured WINDOWS_DIY_ONLY, then
  # `WINDOWS_DIY_ONLY=CAPNP` would skip Ensure-Ttd and then throw
  # "Microsoft Time Travel Debugging is not available" a few hundred lines
  # later -- the run failing on the absence of something it was told not to
  # install. These cases pin the two gates to the same answer.
  Reset-BootstrapStepRecords
  $env:WINDOWS_DIY_ONLY = "CAPNP"
  try {
    Assert-True -Condition (Test-BootstrapAllowlistActive) `
      -Message "WINDOWS_DIY_ONLY is reported as an active allowlist"
    Assert-Equal -Expected $false -Actual (Test-BootstrapStepEnabled "TTD") `
      -Message "Test-BootstrapStepEnabled agrees the dispatch skipped TTD under WINDOWS_DIY_ONLY=CAPNP"
    Assert-Equal -Expected $false -Actual (Test-BootstrapStepEnabled "DOTNET") `
      -Message "Test-BootstrapStepEnabled agrees the dispatch skipped DOTNET under WINDOWS_DIY_ONLY=CAPNP"
    Assert-Equal -Expected $true -Actual (Test-BootstrapStepEnabled "CAPNP") `
      -Message "Test-BootstrapStepEnabled keeps the allowlisted component enabled"
  } finally {
    Remove-Item Env:\WINDOWS_DIY_ONLY -ErrorAction SilentlyContinue
  }
  Assert-Equal -Expected $false -Actual (Test-BootstrapAllowlistActive) `
    -Message "no allowlist is active when WINDOWS_DIY_ONLY is unset"
  Assert-Equal -Expected $true -Actual (Test-BootstrapStepEnabled "TTD") `
    -Message "with no allowlist set, every component is enabled as before"

  # env.ps1 defaults WINDOWS_DIY_SKIP_TTD_PROBE from this composition. The
  # probe is a Get-AppxPackage call, which is the least reliable thing the
  # bootstrap does on a CI guest, so it must not run for a caller that did not
  # ask for TTD -- and must still run for one that did.
  function Test-TtdProbeSkippedByDefault {
    return ((Test-BootstrapAllowlistActive) -and -not (Test-BootstrapStepEnabled "TTD"))
  }
  Assert-Equal -Expected $false -Actual (Test-TtdProbeSkippedByDefault) `
    -Message "with no allowlist, the TTD/AppX probe still runs by default"
  $env:WINDOWS_DIY_ONLY = "CAPNP"
  try {
    Assert-Equal -Expected $true -Actual (Test-TtdProbeSkippedByDefault) `
      -Message "under WINDOWS_DIY_ONLY=CAPNP the TTD/AppX probe is skipped by default"
    $env:WINDOWS_DIY_ONLY = "CAPNP,TTD"
    Assert-Equal -Expected $false -Actual (Test-TtdProbeSkippedByDefault) `
      -Message "but an allowlist that NAMES TTD still probes for it"
  } finally {
    Remove-Item Env:\WINDOWS_DIY_ONLY -ErrorAction SilentlyContinue
  }

  Reset-BootstrapStepRecords

  # An invalid relocatability class must be rejected at the call site.
  $rejected = $false
  try {
    Invoke-BootstrapStep -Step "EPSILON" -Relocatability "sometimes" -Root $installRoot -Action { }
  } catch {
    $rejected = $true
  }
  Assert-True -Condition $rejected -Message "an unknown relocatability class is rejected"

} finally {
  Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
  Reset-BootstrapStepRecords
}

# ---------------------------------------------------------------------------
# Part 2b - the partial decomposition survives a run that never reaches the end.
#
# The `finally` around env.ps1's dispatch publishes a table when a component
# THROWS. It publishes nothing when the process is KILLED, which is what a CI
# job timeout does -- and on this lane a timeout kill is the common ending, not
# the rare one. So the guarantee that matters is the one tested here: after
# every component, the table so far is already ON DISK, at the path the final
# report will later overwrite.
#
# The kill is simulated by simply NOT calling Write-BootstrapStepReport, which
# is exactly what a killed process does. Anything stronger (actually killing a
# child pwsh) would test the harness rather than the contract.
# ---------------------------------------------------------------------------

Write-Host "== partial decomposition survives a killed run"

$progressRoot = Join-Path ([IO.Path]::GetTempPath()) ("ct-progress-" + [Guid]::NewGuid().ToString('N'))
$progressInstall = Join-Path $progressRoot "install"
$progressReport = Join-Path $progressRoot "report"
New-Item -ItemType Directory -Force -Path $progressInstall | Out-Null

try {
  Reset-BootstrapStepRecords

  $decompositionPath = Join-Path $progressReport "windows-env-decomposition.json"

  # Before anything is armed, a component must NOT write a progress file.
  # Existing callers and satellite repos rely on the in-memory-only behaviour.
  Invoke-BootstrapStep -Step "ALPHA" -Relocatability relocatable -Root $progressInstall -Action { }
  Assert-True -Condition (-not (Test-Path -LiteralPath $decompositionPath)) `
    -Message "no progress file is written until Initialize-BootstrapProgress arms it"

  Reset-BootstrapStepRecords
  Initialize-BootstrapProgress -OutputDir $progressReport

  Invoke-BootstrapStep -Step "ALPHA" -Relocatability relocatable -Root $progressInstall -Action {
    $dir = Join-Path $progressInstall "alpha/1.0"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $dir "a.bin"), (New-Object byte[] 2048))
  }

  Assert-True -Condition (Test-Path -LiteralPath $decompositionPath -PathType Leaf) `
    -Message "the partial decomposition exists after the FIRST component, before any report call"

  $partial = Get-Content -LiteralPath $decompositionPath -Raw | ConvertFrom-Json
  Assert-Equal -Expected "partial" -Actual $partial.phase `
    -Message "the partial declares itself partial"
  Assert-Equal -Expected 1 -Actual @($partial.components).Count `
    -Message "the partial carries the one component that has run"
  Assert-Equal -Expected "ALPHA" -Actual @($partial.components)[0].step `
    -Message "and names it"
  Assert-True -Condition (@($partial.components)[0].seconds -ge 0) `
    -Message "the partial carries a real wall-clock figure for it"
  Assert-True -Condition ($null -eq $partial.install_root_bytes) `
    -Message "the partial reports install_root_bytes as NULL, never as zero"
  Assert-True -Condition ($null -eq @($partial.components)[0].bytes) `
    -Message "a partial component's size is NULL, so it cannot be read as 'installed nothing'"
  Assert-True -Condition (-not $partial.complete) `
    -Message "a partial is never complete"

  # A second component must extend the partial in place, at the same path.
  Invoke-BootstrapStep -Step "GAMMA" -Relocatability installer -Root $progressInstall -Action {
    $dir = Join-Path $progressInstall "gamma"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $partial2 = Get-Content -LiteralPath $decompositionPath -Raw | ConvertFrom-Json
  Assert-Equal -Expected 2 -Actual @($partial2.components).Count `
    -Message "each further component extends the partial in place"

  # THE CASE THAT MOTIVATES ALL OF THIS: a component that dies mid-flight.
  # Everything before it must already be on disk, and the run is then abandoned
  # WITHOUT calling Write-BootstrapStepReport -- the killed-process shape.
  try {
    Invoke-BootstrapStep -Step "DELTA" -Relocatability relocatable -Root $progressInstall -Action {
      throw "simulated DELTA failure"
    }
  } catch { }

  $partial3 = Get-Content -LiteralPath $decompositionPath -Raw | ConvertFrom-Json
  Assert-Equal -Expected 3 -Actual @($partial3.components).Count `
    -Message "the component that died is itself recorded in the partial"
  Assert-True -Condition (@($partial3.failed_steps) -contains "DELTA") `
    -Message "and is named in failed_steps, so the blocking component is identifiable"
  Assert-True -Condition (@($partial3.components | Where-Object { $_.step -eq "ALPHA" }).Count -eq 1) `
    -Message "timings for the components that DID finish survive the abandoned run"

  # Finally: the real report must overwrite the partial at the same path, and
  # be distinguishable from it. If it landed elsewhere, the pipeline that
  # collects the artifact would publish the partial and silently drop the real
  # one -- worse than having no partial at all.
  $finalPath = Write-BootstrapStepReport -Root $progressInstall -OutputDir $progressReport
  Assert-Equal -Expected $decompositionPath -Actual $finalPath `
    -Message "the final report overwrites the partial at the SAME path"
  $final = Get-Content -LiteralPath $finalPath -Raw | ConvertFrom-Json
  Assert-Equal -Expected "final" -Actual $final.phase `
    -Message "the final report declares itself final"
  Assert-True -Condition ($final.install_root_bytes -gt 0) `
    -Message "and unlike the partial it carries the measured install-root size"

  # WINDOWS_DIY_REPORT_DIR must steer the partial and the final to the SAME
  # directory. Two resolvers that could disagree is the defect this shares one
  # function to prevent.
  $override = Join-Path $progressRoot "override"
  $env:WINDOWS_DIY_REPORT_DIR = $override
  try {
    Assert-Equal -Expected $override -Actual (Resolve-BootstrapReportDir -RepoRoot $progressRoot) `
      -Message "WINDOWS_DIY_REPORT_DIR steers the report directory"
  } finally {
    Remove-Item Env:\WINDOWS_DIY_REPORT_DIR -ErrorAction SilentlyContinue
  }
  Assert-Equal -Expected (Join-Path $progressRoot ".tmp/windows-diy") `
    -Actual (Resolve-BootstrapReportDir -RepoRoot $progressRoot) `
    -Message "and without it the default is <repo>/.tmp/windows-diy"

} finally {
  Remove-Item -LiteralPath $progressRoot -Recurse -Force -ErrorAction SilentlyContinue
  Reset-BootstrapStepRecords
}

# ---------------------------------------------------------------------------
# Part 3 - the nargo linker verification.
#
# `ensure-nargo.ps1` refuses to hand cargo a `link.exe` it cannot show to be
# MSVC's. The predicate that decides this is pure and filesystem-only, so it is
# testable off Windows against real directories -- which matters, because the
# lane it protects has never reached Phase 5 and no run has exercised it.
#
# The classified failure it exists for is a GNU coreutils `link` answering
# rustc's `link.exe` invocation: "link: extra operand ... Try 'link --help'".
# ---------------------------------------------------------------------------

Write-Host "== nargo MSVC linker verification (ensure-nargo.ps1)"

. (Join-Path $repoRoot "non-nix-build/windows/ensure-nargo.ps1")

$linkerRoot = Join-Path ([IO.Path]::GetTempPath()) ("ct-linker-" + [Guid]::NewGuid().ToString('N'))
try {
  # A real MSVC-shaped directory: link.exe with cl.exe beside it.
  $msvcDir = Join-Path $linkerRoot "VC/Tools/MSVC/14.44/bin/Hostx64/x64"
  New-Item -ItemType Directory -Force -Path $msvcDir | Out-Null
  foreach ($exe in @("link.exe", "cl.exe")) {
    [IO.File]::WriteAllBytes((Join-Path $msvcDir $exe), (New-Object byte[] 4))
  }

  # A coreutils-shaped directory: link.exe alone, no cl.exe.
  $msysDir = Join-Path $linkerRoot "msys64/usr/bin"
  New-Item -ItemType Directory -Force -Path $msysDir | Out-Null
  [IO.File]::WriteAllBytes((Join-Path $msysDir "link.exe"), (New-Object byte[] 4))

  $msvcLink = Join-Path $msvcDir "link.exe"
  $msysLink = Join-Path $msysDir "link.exe"

  # Path 1: MSVC_PATH_ADDITIONS names the directory.
  $v = Test-MsvcLinkerPath -LinkExePath $msvcLink -MsvcPathAdditions "$msvcDir;C:\Windows\System32"
  Assert-Equal -Expected $true -Actual $v.isMsvc `
    -Message "a link.exe inside an MSVC_PATH_ADDITIONS directory is accepted"

  # Path 2 -- THE ONE THAT MATTERS. export-msvc-env.ps1 exits silently when
  # Build Tools are absent, so MSVC_PATH_ADDITIONS is empty on exactly the
  # runs this check is for. The cl.exe-sibling test must still decide.
  $v = Test-MsvcLinkerPath -LinkExePath $msvcLink -MsvcPathAdditions ""
  Assert-Equal -Expected $true -Actual $v.isMsvc `
    -Message "with no MSVC_PATH_ADDITIONS, a link.exe beside cl.exe is still accepted"
  Assert-True -Condition ($v.reason -like "*cl.exe*") `
    -Message "and the acceptance says it was decided by the cl.exe sibling"

  # The coreutils link.exe must be rejected under BOTH configurations --
  # including when MSVC_PATH_ADDITIONS is absent, which is where the previous
  # revision of this check warned and continued.
  $v = Test-MsvcLinkerPath -LinkExePath $msysLink -MsvcPathAdditions ""
  Assert-Equal -Expected $false -Actual $v.isMsvc `
    -Message "a coreutils link.exe is REJECTED even when MSVC_PATH_ADDITIONS is empty"
  $v = Test-MsvcLinkerPath -LinkExePath $msysLink -MsvcPathAdditions $msvcDir
  Assert-Equal -Expected $false -Actual $v.isMsvc `
    -Message "a coreutils link.exe is rejected when MSVC additions name a different directory"

  # A trailing separator on the published additions must not make a match fail;
  # export-msvc-env.ps1 emits vcvarsall's PATH verbatim and those entries vary.
  $v = Test-MsvcLinkerPath -LinkExePath $msvcLink -MsvcPathAdditions "$msvcDir\"
  Assert-Equal -Expected $true -Actual $v.isMsvc `
    -Message "a trailing separator on an MSVC_PATH_ADDITIONS entry still matches"
} finally {
  Remove-Item -LiteralPath $linkerRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "bootstrap-decomposition: $($script:Checks - $script:Failures)/$($script:Checks) checks passed"
if ($script:Failures -gt 0) {
  throw "bootstrap-decomposition: $($script:Failures) check(s) failed."
}

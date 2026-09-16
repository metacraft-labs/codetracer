[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$EnvScriptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($EnvScriptPath)) {
  $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  $EnvScriptPath = Join-Path $repoRoot "env.ps1"
}

if (-not (Test-Path -LiteralPath $EnvScriptPath -PathType Leaf)) {
  throw "Missing required file: $EnvScriptPath"
}

$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
  $EnvScriptPath,
  [ref]$null,
  [ref]$parseErrors
)

if ($parseErrors.Count -gt 0) {
  $parseErrors | ForEach-Object { Write-Error "${EnvScriptPath}: $($_.Message)" }
  throw "PowerShell parser reported one or more errors."
}

# `Prepend-PathEntries` is exercised in ISOLATION -- the function bodies are
# lifted out of env.ps1 and run on their own, so this validator never activates
# a dev shell or touches a toolchain. Every function the lifted body CALLS must
# therefore be lifted with it, or the probe below fails with a
# CommandNotFoundException that looks like a test bug rather than a missing
# dependency. Keep this list in step with what Prepend-PathEntries calls.
$requiredFunctions = @("Get-PathEntryComparisonKey", "Prepend-PathEntries")

$functionSources = @()
foreach ($functionName in $requiredFunctions) {
  $found = $ast.Find(
    {
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq $functionName
    }.GetNewClosure(),
    $true
  )

  if ($null -eq $found) {
    throw "env.ps1 does not define $functionName."
  }

  $functionSources += $found.Extent.Text
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("codetracer-path-entry-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

$savedPath = [Environment]::GetEnvironmentVariable("PATH")
try {
  $probe = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Environment]::SetEnvironmentVariable("PATH", "codetracer-original-path", "Process")
Prepend-PathEntries -Entries @()
Prepend-PathEntries -Entries $null
if ([Environment]::GetEnvironmentVariable("PATH") -ne "codetracer-original-path") {
  throw "Prepend-PathEntries changed PATH when only empty entries were supplied."
}
Prepend-PathEntries -Entries @("", $null, "   ", $tempDir)
$updatedPath = [Environment]::GetEnvironmentVariable("PATH")
$expectedPath = "$tempDir;codetracer-original-path"
if ($updatedPath -ne $expectedPath) {
  throw "Prepend-PathEntries produced unexpected PATH '$updatedPath' (expected '$expectedPath')."
}

# --- PATH must not accumulate across repeated activations --------------------
# `. .\env.ps1` is run once per shell, but shells get re-activated: a second
# dot-source in the same session, a nested script that activates again, a
# long-lived agent session that re-enters the dev shell. Every one of those
# used to prepend the SAME directories again, without bound. That matters
# because anything resolving through cmd.exe truncates PATH at 8191
# characters, and the overflow does not announce itself as an overflow -- it
# surfaces as a missing tool ("'tailwindcss' is not recognized") or as a
# link/DLL error, i.e. as a plausible but entirely fictitious product defect.
# Two separate such phantom diagnoses have already been written up on this
# host. The invariant is therefore: prepending is IDEMPOTENT.

# (1) Repeat activation must be a no-op, not a doubling.
[Environment]::SetEnvironmentVariable("PATH", "codetracer-original-path", "Process")
Prepend-PathEntries -Entries @($tempDir)
$afterFirst = [Environment]::GetEnvironmentVariable("PATH")
Prepend-PathEntries -Entries @($tempDir)
$afterSecond = [Environment]::GetEnvironmentVariable("PATH")
if ($afterSecond -ne $afterFirst) {
  throw "Prepend-PathEntries is not idempotent: one activation gave '$afterFirst', two gave '$afterSecond'."
}

# (2) An entry already present further down PATH is MOVED to the front, not
#     duplicated -- the caller's intent is precedence, and precedence is
#     achieved by moving, never by adding a second copy.
[Environment]::SetEnvironmentVariable("PATH", "codetracer-original-path;$tempDir", "Process")
Prepend-PathEntries -Entries @($tempDir)
$moved = [Environment]::GetEnvironmentVariable("PATH")
if ($moved -ne "$tempDir;codetracer-original-path") {
  throw "Prepend-PathEntries duplicated an entry already on PATH: '$moved'."
}

# (3) The same directory named twice in ONE call is added once.
[Environment]::SetEnvironmentVariable("PATH", "codetracer-original-path", "Process")
Prepend-PathEntries -Entries @($tempDir, $tempDir)
$twiceInOneCall = [Environment]::GetEnvironmentVariable("PATH")
if ($twiceInOneCall -ne "$tempDir;codetracer-original-path") {
  throw "Prepend-PathEntries duplicated a repeated entry within one call: '$twiceInOneCall'."
}

# (4) Windows path comparison is case-insensitive and ignores a trailing
#     separator, so these spellings are the SAME directory and must not
#     produce three entries.
[Environment]::SetEnvironmentVariable("PATH", "codetracer-original-path", "Process")
Prepend-PathEntries -Entries @($tempDir)
Prepend-PathEntries -Entries @($tempDir.ToUpperInvariant())
Prepend-PathEntries -Entries @("$tempDir\")
$spellings = [Environment]::GetEnvironmentVariable("PATH")
if (($spellings -split ';').Count -ne 2) {
  throw "Prepend-PathEntries treated case/trailing-separator variants as distinct: '$spellings'."
}

# (5) Segments that do NOT match a prepended entry are preserved verbatim,
#     empty segments included -- dedup must not quietly rewrite the rest of
#     PATH while it is in there.
[Environment]::SetEnvironmentVariable("PATH", "alpha;;beta", "Process")
Prepend-PathEntries -Entries @($tempDir)
$preserved = [Environment]::GetEnvironmentVariable("PATH")
if ($preserved -ne "$tempDir;alpha;;beta") {
  throw "Prepend-PathEntries did not preserve unrelated PATH segments verbatim: '$preserved'."
}
'@

  $scriptBlock = [scriptblock]::Create(($functionSources -join "`n") + "`n" + $probe)
  & $scriptBlock
} finally {
  [Environment]::SetEnvironmentVariable("PATH", $savedPath, "Process")
  if (Test-Path -LiteralPath $tempDir) {
    Remove-Item -LiteralPath $tempDir -Recurse -Force
  }
}

Write-Host "Prepend-PathEntries validation passed for '$EnvScriptPath'."

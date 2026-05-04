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

$functionAst = $ast.Find(
  {
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -eq "Prepend-PathEntries"
  },
  $true
)

if ($null -eq $functionAst) {
  throw "env.ps1 does not define Prepend-PathEntries."
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
'@

  $scriptBlock = [scriptblock]::Create($functionAst.Extent.Text + "`n" + $probe)
  & $scriptBlock
} finally {
  [Environment]::SetEnvironmentVariable("PATH", $savedPath, "Process")
  if (Test-Path -LiteralPath $tempDir) {
    Remove-Item -LiteralPath $tempDir -Recurse -Force
  }
}

Write-Host "Prepend-PathEntries validation passed for '$EnvScriptPath'."

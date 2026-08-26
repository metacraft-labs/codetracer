# Behavioural gate on env.ps1's Windows DIY install-root resolution.
#
# THE FIELD FAILURE THIS EXISTS TO PREVENT
#
# Every ephemeral `eph-win-x64` job died in `Ensure-Ttd` with
#
#     New-Item : Access to the path 'D:\metacraft-dev-deps\ttd' is denied.
#
# because `Get-DefaultInstallRoot` treated "D:\ exists" as "D:\ is a writable
# dev drive". On those guests `D:` is the cloudbase-init config drive: a
# read-only CDFS volume (`Win32_LogicalDisk` DriveType 5, VolumeName
# `config-2`). It exists, so the probe said yes; it is read-only, so every
# `Ensure-*` step underneath it failed. TTD is merely the first of them.
#
# WHAT IS PROVABLE HERE
#
# The two functions are extracted from env.ps1 by AST and executed in
# isolation -- the same technique validate-env-path-entries.ps1 uses -- so
# this runs on any Windows host without needing a read-only D:. The
# unwritable case is synthesised from a deny ACE rather than assumed, and the
# synthesis is itself checked before anything is concluded from it.
#
# Deliberately NOT proved here: that a real CDFS mount behaves this way. Only
# a booted guest can say that, and it was confirmed on a CoW clone of
# `golden-win11-cloudbase.qcow2` on 2026-08-23.
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
  $EnvScriptPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
  $parseErrors | ForEach-Object {
    Write-Error "${EnvScriptPath}: $($_.Message)"
  }
  throw "PowerShell parser reported one or more errors."
}

function Get-FunctionText {
  param([string]$Name)
  $fn = $ast.Find({
      param($node)
      $node -is
        [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq $Name
    }, $true)
  if ($null -eq $fn) { throw "env.ps1 does not define $Name." }
  return $fn.Extent.Text
}

$writableFn = Get-FunctionText -Name "Test-DirectoryWritable"
$rootFn = Get-FunctionText -Name "Get-DefaultInstallRoot"

# --- static gate: the existence-only probe must not come back --------------
# This is the mistake itself, not a proxy for it. `Get-DefaultInstallRoot`
# asking Test-Path about D:\ is exactly the shipped defect, so the gate names
# it. Anchored on the D: branch only: Test-Path is legitimate elsewhere.
$rootLines = @(
  $rootFn -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' })
$dLines = @($rootLines | Where-Object { $_ -match '"D:\\' })
if ($dLines.Count -eq 0) {
  throw ("Get-DefaultInstallRoot no longer mentions D:\ at all. If the " +
    "dev-drive preference was removed on purpose, update this gate; " +
    "otherwise this is a vacuous pass.")
}
$badProbe = @($dLines | Where-Object { $_ -match 'Test-Path' })
if ($badProbe.Count -gt 0) {
  throw ("Get-DefaultInstallRoot probes D:\ with Test-Path, which cannot " +
    "see a read-only mount. That is the eph-win-x64 failure. " +
    "Offending line(s): " + ($badProbe -join ' | '))
}
$goodProbe = @($dLines | Where-Object { $_ -match 'Test-DirectoryWritable' })
if ($goodProbe.Count -eq 0) {
  throw ("Get-DefaultInstallRoot's D:\ branch does not go through " +
    "Test-DirectoryWritable.")
}

# --- behavioural gate ------------------------------------------------------
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) (
  "codetracer-install-root-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

$saved = @{}
foreach ($n in @("WINDOWS_DIY_INSTALL_ROOT", "RUNNER_TEMP", "TEMP", "TMP")) {
  $saved[$n] = [Environment]::GetEnvironmentVariable($n)
}

try {
  $probe = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-Equal($actual, $expected, $what) {
  if ($actual -ne $expected) {
    throw "$what : got '$actual', expected '$expected'"
  }
}
function Assert-True($cond, $what) {
  if (-not $cond) { throw "$what : expected true" }
}
function Assert-False($cond, $what) {
  if ($cond) { throw "$what : expected false" }
}

# 1. A writable directory is writable, and the probe leaves nothing behind.
$before = @(Get-ChildItem -LiteralPath $tempRoot -Force).Count
Assert-True (Test-DirectoryWritable -Path $tempRoot) "writable temp dir"
$after = @(Get-ChildItem -LiteralPath $tempRoot -Force).Count
Assert-Equal $after $before "the probe left its directory behind"

# 2. A path that does not exist is not writable (the old probe's other half).
$missing = Join-Path $tempRoot "no-such-dir"
Assert-False (Test-DirectoryWritable -Path $missing) "missing dir"
Assert-False (Test-DirectoryWritable -Path "") "empty path"
Assert-False (Test-DirectoryWritable -Path $null) "null path"

# 3. A directory that EXISTS but refuses creation is not writable. This is
#    the eph-win-x64 D: case in miniature. A CDFS mount cannot be conjured
#    in a test, so a deny ACE stands in for it.
#
#    The setup is SELF-VALIDATING, deliberately. If the deny ACE silently
#    fails to bite -- wrong SID, an elevated context that overrides it, a
#    filesystem that ignores ACLs -- then Test-DirectoryWritable returning
#    $true is the CORRECT answer, and asserting $false would be asserting a
#    lie. So this first proves, with a direct New-Item, that the directory
#    really does refuse creation, and only then asks the probe to agree. A
#    setup that cannot be established is a hard failure, never a skip.
#
#    `$env:OS`, not `$IsWindows`: the goldens ship Windows PowerShell 5.1,
#    where `$IsWindows` does not exist and `Set-StrictMode -Version Latest`
#    turns reading it into a terminating error. `$env:OS` is `Windows_NT` on
#    both 5.1 and pwsh 7, and an absent environment variable is $null rather
#    than a throw under StrictMode.
if ($env:OS -ne 'Windows_NT') {
  throw ("This gate requires Windows: it needs real NTFS ACLs to build " +
    "the 'exists but refuses creation' case that the eph-win-x64 D: " +
    "drive represents.")
}
$denied = Join-Path $tempRoot "denied"
New-Item -ItemType Directory -Path $denied -Force | Out-Null
$acl = Get-Acl -LiteralPath $denied
$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$ace = New-Object Security.AccessControl.FileSystemAccessRule(
  $me,
  "CreateDirectories,CreateFiles,Write",
  "ContainerInherit,ObjectInherit",
  "None",
  "Deny")
$acl.AddAccessRule($ace)
Set-Acl -LiteralPath $denied -AclObject $acl
try {
  Assert-True (Test-Path -LiteralPath $denied -PathType Container) `
    "the deny-ACL dir still EXISTS (why Test-Path is not enough)"

  # Prove the setup before trusting the assertion that depends on it.
  $reallyRefuses = $false
  try {
    $control = Join-Path $denied "control"
    New-Item -ItemType Directory -Path $control -ErrorAction Stop | Out-Null
  } catch {
    $reallyRefuses = $true
  }
  Assert-True $reallyRefuses `
    "the deny ACE bites (else the next assertion is vacuous)"

  Assert-False (Test-DirectoryWritable -Path $denied) `
    "a deny-ACL dir must not read as writable"
} finally {
  $acl2 = Get-Acl -LiteralPath $denied
  $acl2.RemoveAccessRule($ace) | Out-Null
  Set-Acl -LiteralPath $denied -AclObject $acl2
}

# 4. An explicit WINDOWS_DIY_INSTALL_ROOT is honoured verbatim and NOT
#    second-guessed -- including when it points somewhere unwritable,
#    because silently relocating an operator's pinned root is worse than
#    failing.
[Environment]::SetEnvironmentVariable(
  "WINDOWS_DIY_INSTALL_ROOT", "  X:\pinned\root  ", "Process")
Assert-Equal (Get-DefaultInstallRoot) "X:\pinned\root" `
  "an explicit root wins and is trimmed"

# 5. With no explicit root and no writable D:, resolution must still produce
#    a usable root rather than throwing. D: is whatever this host has, so the
#    assertion is that we get a non-empty root back, and that when D: is
#    absent or read-only the answer is NOT under D:.
[Environment]::SetEnvironmentVariable(
  "WINDOWS_DIY_INSTALL_ROOT", $null, "Process")
$resolved = Get-DefaultInstallRoot
Assert-True ($resolved -is [string] -and $resolved.Length -gt 0) `
  "resolution returns a root"
if (-not (Test-DirectoryWritable -Path "D:\")) {
  if ($resolved -like "D:*") {
    throw "resolved to '$resolved' although D:\ is not writable"
  }
}

# 6. Whatever it resolved to must itself be creatable -- the property the
#    whole bootstrap depends on, and the one violated in the field.
New-Item -ItemType Directory -Force -Path $resolved -ErrorAction Stop |
  Out-Null
Assert-True (Test-DirectoryWritable -Path $resolved) `
  "the resolved root is writable"

Write-Host "resolved install root: $resolved"
'@

  $scriptBlock = [scriptblock]::Create(
    $writableFn + "`n" + $rootFn + "`n" + $probe)
  & $scriptBlock
} finally {
  foreach ($n in $saved.Keys) {
    [Environment]::SetEnvironmentVariable($n, $saved[$n], "Process")
  }
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force `
      -ErrorAction SilentlyContinue
  }
}

Write-Host "Install-root resolution validation passed for '$EnvScriptPath'."

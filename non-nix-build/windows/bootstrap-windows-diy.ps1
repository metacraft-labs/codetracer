[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$InstallRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-DefaultWindowsDiyInstallRoot {
  $envInstallRoot = [Environment]::GetEnvironmentVariable("WINDOWS_DIY_INSTALL_ROOT")
  if (-not [string]::IsNullOrWhiteSpace($envInstallRoot)) {
    return $envInstallRoot.Trim()
  }

  $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
  if ([string]::IsNullOrWhiteSpace($localAppData)) {
    throw "Could not resolve LocalApplicationData for default Windows DIY install root."
  }

  return (Join-Path (Join-Path $localAppData "codetracer") "windows-diy")
}

if ((-not $PSBoundParameters.ContainsKey("InstallRoot")) -or [string]::IsNullOrWhiteSpace($InstallRoot)) {
  $InstallRoot = Get-DefaultWindowsDiyInstallRoot
}

$toolchain = [ordered]@{
  rustupVersion   = "1.28.2"
  rustToolchain   = "1.92.0"
  nodeVersion     = "24.13.0"
  uvVersion       = "0.9.28"
  dotnetSdkVersion = "9.0.310"
  nimVersion      = "2.2.6"
  nimWinX64Sha256 = "557eed9a9193a3bc812245a997d678fd6dc2c2dec6cfa9ba664a16b310115584"
  nimSourceRepo   = "https://github.com/nim-lang/Nim.git"
  nimSourceRef    = "v2.2.6"
  nimCsourcesRepo = "https://github.com/nim-lang/csources_v3.git"
  nimCsourcesRef  = "master"
  ctRemoteVersion = "102d2c8"
  ctRemoteWinX64Sha256 = "9b9e4dd3f318e368b1653e4d52b0ea30f50211dc9ea9be65a7f112257bb91752"
  capnpVersion = "1.3.0"
  capnpWinX64Sha256 = "2c503361f8bf26fa9e7caccb6db04d6b271d5f0ad3da0616cf40e9a51335c89c"
  capnpSourceRepo = "https://github.com/capnproto/capnproto.git"
  capnpSourceRef = "v1.3.0"
  tupSourceRepo = "https://github.com/zah/tup.git"
  tupSourceRef = "variants-for-windows"
  tupSourceBuildCommand = "TUP_MINGW=1 TUP_MINGW32=0 ./bootstrap.sh"
  tupPrebuiltVersion = "latest"
  tupPrebuiltUrl = "https://gittup.org/tup/win32/tup-latest.zip"
  tupPrebuiltSha256 = "fc55fcff297050582c21454af54372f69057e3c2008dbc093c84eeee317e285e"
  tupMsys2BaseVersion = "20251213"
  tupMsys2BaseX64Sha256 = "999f63c2fc7525af5cd41b55e9ea704471a4f9d0278a257fff3b0d1183c441b9"
  tupMsys2Packages = "mingw-w64-x86_64-gcc mingw-w64-x86_64-pkgconf make"
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

function ConvertTo-RustTarget {
  param([string]$Arch)
  switch ($Arch) {
    "x64" { return "x86_64-pc-windows-msvc" }
    "arm64" { return "aarch64-pc-windows-msvc" }
    default { throw "Unsupported Rust target arch '$Arch'." }
  }
}

function ConvertTo-UvTarget {
  param([string]$Arch)
  switch ($Arch) {
    "x64" { return "x86_64-pc-windows-msvc" }
    "arm64" { return "aarch64-pc-windows-msvc" }
    default { throw "Unsupported uv target arch '$Arch'." }
  }
}

function ConvertTo-NodeFileArch {
  param([string]$Arch)
  switch ($Arch) {
    "x64" { return "x64" }
    "arm64" { return "arm64" }
    default { throw "Unsupported Node arch '$Arch'." }
  }
}

function ConvertTo-NimFileArch {
  param([string]$Arch)
  switch ($Arch) {
    "x64" { return "x64" }
    default { throw "Nim bootstrap currently supports Windows x64 only. No pinned official asset/hash is configured for '$Arch'." }
  }
}

function ConvertTo-CapnpPrebuiltFileArch {
  param([string]$Arch)
  switch ($Arch) {
    "x64" { return "win32" }
    default { throw "Cap'n Proto prebuilt mode currently supports Windows x64 only. No pinned official asset/hash is configured for '$Arch'." }
  }
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

  Invoke-WithRetry -Script {
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
  } | Out-Null
}

function Download-String {
  param([Parameter(Mandatory = $true)][string]$Url)

  $content = Invoke-WithRetry -Script {
    (Invoke-WebRequest -Uri $Url -UseBasicParsing).Content
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

function Test-BootstrapStepEnabled {
  param([Parameter(Mandatory = $true)][string]$Step)

  $envName = "WINDOWS_DIY_SKIP_$Step"
  $rawValue = [Environment]::GetEnvironmentVariable($envName)
  if ([string]::IsNullOrWhiteSpace($rawValue)) {
    return $true
  }

  $value = $rawValue.Trim().ToLowerInvariant()
  if ($value -in @("1", "true", "yes", "on")) {
    Write-Warning "Skipping bootstrap step '$Step' because $envName=$rawValue."
    return $false
  }

  return $true
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

function Get-TupMsys2PackageList {
  $packagesRaw = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_MSYS2_PACKAGES")
  if ([string]::IsNullOrWhiteSpace($packagesRaw)) {
    $packagesRaw = $toolchain.tupMsys2Packages
  }
  $packages = @($packagesRaw.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries))
  if ($packages.Count -eq 0) {
    throw "TUP Windows MSYS2 package list is empty. Set TUP_WINDOWS_MSYS2_PACKAGES or toolchain.tupMsys2Packages."
  }
  return $packages
}

function Ensure-TupMsys2BuildPrereqs {
  param([Parameter(Mandatory = $true)][string]$Root)

  $versionRaw = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_MSYS2_BASE_VERSION")
  if ([string]::IsNullOrWhiteSpace($versionRaw)) {
    $versionRaw = $toolchain.tupMsys2BaseVersion
  }
  $version = $versionRaw.Trim()
  if ($version -notmatch '^[0-9]{8}$') {
    throw "Invalid TUP_WINDOWS_MSYS2_BASE_VERSION '$versionRaw'. Expected YYYYMMDD."
  }

  $expectedShaRaw = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_MSYS2_BASE_X64_SHA256")
  if ([string]::IsNullOrWhiteSpace($expectedShaRaw)) {
    $expectedShaRaw = $toolchain.tupMsys2BaseX64Sha256
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
  $packages = Get-TupMsys2PackageList
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

function Resolve-AbsolutePathFromScriptRoot {
  param([Parameter(Mandatory = $true)][string]$PathValue)

  $expanded = [Environment]::ExpandEnvironmentVariables($PathValue)
  if ([System.IO.Path]::IsPathRooted($expanded)) {
    return [System.IO.Path]::GetFullPath($expanded)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot $expanded))
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

function Get-CtRemoteSourceRevision {
  param([Parameter(Mandatory = $true)][string]$RepoRoot)

  $gitCommand = Get-Command git -ErrorAction SilentlyContinue
  if ($null -eq $gitCommand -or [string]::IsNullOrWhiteSpace($gitCommand.Source)) {
    return "git-unavailable"
  }

  $revisionOutput = & $gitCommand.Source -C $RepoRoot rev-parse --short=12 HEAD 2>$null
  if ($LASTEXITCODE -ne 0) {
    return "unknown-revision"
  }

  $revision = ([string]$revisionOutput).Trim()
  if ([string]::IsNullOrWhiteSpace($revision)) {
    return "unknown-revision"
  }

  & $gitCommand.Source -C $RepoRoot diff --quiet --ignore-submodules HEAD -- 2>$null
  $isDirty = ($LASTEXITCODE -ne 0)
  if ($isDirty) {
    $statusOutput = (& $gitCommand.Source -C $RepoRoot status --porcelain --untracked-files=all 2>$null) -join "`n"
    $statusBytes = [System.Text.Encoding]::UTF8.GetBytes($statusOutput)
    $statusHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($statusBytes)).ToLowerInvariant()
    return "$revision-dirty-$statusHash"
  }

  return $revision
}

function Get-DefaultCtRemoteSourceRid {
  param([Parameter(Mandatory = $true)][string]$Arch)

  switch ($Arch) {
    "x64" { return "win-x64" }
    "arm64" { return "win-arm64" }
    default { throw "Unsupported architecture '$Arch' for ct-remote source RID selection." }
  }
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

function Get-NimSourceCompilerHint {
  $hints = New-Object System.Collections.Generic.List[string]
  $ccValue = [Environment]::GetEnvironmentVariable("CC")
  if (-not [string]::IsNullOrWhiteSpace($ccValue)) {
    $hints.Add("CC=$ccValue")
  }

  $clCommand = Get-Command cl.exe -ErrorAction SilentlyContinue
  if ($null -ne $clCommand -and -not [string]::IsNullOrWhiteSpace($clCommand.Source)) {
    $clOutput = & $clCommand.Source 2>&1
    $clVersion = ($clOutput | Select-String -Pattern "Version\s+[0-9.]+" | Select-Object -First 1).Line
    if (-not [string]::IsNullOrWhiteSpace($clVersion)) {
      $hints.Add("cl=$($clVersion.Trim())")
    } else {
      $hints.Add("cl=present")
    }
  } else {
    $hints.Add("cl=missing")
  }

  $gccCommand = Get-Command gcc -ErrorAction SilentlyContinue
  if ($null -ne $gccCommand -and -not [string]::IsNullOrWhiteSpace($gccCommand.Source)) {
    $gccVersion = (& $gccCommand.Source --version | Select-Object -First 1)
    if (-not [string]::IsNullOrWhiteSpace($gccVersion)) {
      $hints.Add("gcc=$($gccVersion.Trim())")
    } else {
      $hints.Add("gcc=present")
    }
  } else {
    $hints.Add("gcc=missing")
  }

  return ($hints -join ";")
}

function Ensure-NimSourceCompilerEnvironment {
  param(
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][string]$Root
  )

  $requestedCompilerRaw = [Environment]::GetEnvironmentVariable("NIM_WINDOWS_SOURCE_CC")
  $requestedCompiler = if ([string]::IsNullOrWhiteSpace($requestedCompilerRaw)) {
    "auto"
  } else {
    $requestedCompilerRaw.Trim().ToLowerInvariant()
  }
  if ($requestedCompiler -notin @("auto", "gcc", "vcc")) {
    throw "Unsupported NIM_WINDOWS_SOURCE_CC '$requestedCompilerRaw'. Supported values: auto, gcc, vcc."
  }

  $allowTupMsys2GccRaw = [Environment]::GetEnvironmentVariable("NIM_WINDOWS_SOURCE_BOOTSTRAP_GCC_FROM_TUP_MSYS2")
  $allowTupMsys2Gcc = if ([string]::IsNullOrWhiteSpace($allowTupMsys2GccRaw)) {
    $true
  } else {
    $allowTupMsys2GccRaw.Trim() -ne "0"
  }

  if ($requestedCompiler -ne "vcc") {
    $gccCommand = Get-Command gcc -ErrorAction SilentlyContinue
    if (($null -eq $gccCommand -or [string]::IsNullOrWhiteSpace($gccCommand.Source)) -and $allowTupMsys2Gcc) {
      $msys2 = Ensure-TupMsys2BuildPrereqs -Root $Root
      $msysMingwBinDir = Join-Path ([string]$msys2.root) "mingw64/bin"
      $msysUsrBinDir = Join-Path ([string]$msys2.root) "usr/bin"
      $currentPath = [Environment]::GetEnvironmentVariable("Path")
      $pathPrefix = @()
      if (Test-Path -LiteralPath $msysMingwBinDir -PathType Container) { $pathPrefix += $msysMingwBinDir }
      if (Test-Path -LiteralPath $msysUsrBinDir -PathType Container) { $pathPrefix += $msysUsrBinDir }
      if ($pathPrefix.Count -gt 0) {
        $prefixJoined = $pathPrefix -join ";"
        if ([string]::IsNullOrWhiteSpace($currentPath)) {
          Set-Item -Path "Env:Path" -Value $prefixJoined
        } else {
          Set-Item -Path "Env:Path" -Value "$prefixJoined;$currentPath"
        }
      }
      $gccCommand = Get-Command gcc -ErrorAction SilentlyContinue
    }

    if ($null -ne $gccCommand -and -not [string]::IsNullOrWhiteSpace($gccCommand.Source)) {
      $env:CC = "gcc"
      $env:NIM_WINDOWS_SOURCE_CC_EFFECTIVE = "gcc"
      Write-Host "Configured GCC compiler environment for Nim source bootstrap."
      return
    }

    if ($requestedCompiler -eq "gcc") {
      throw "NIM source bootstrap requested gcc via NIM_WINDOWS_SOURCE_CC=gcc, but gcc is unavailable on PATH."
    }
  }

  $clCommand = Get-Command cl.exe -ErrorAction SilentlyContinue
  if ($null -eq $clCommand -or [string]::IsNullOrWhiteSpace($clCommand.Source)) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio/Installer/vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
      throw "Nim source bootstrap requires a C compiler. Neither gcc nor cl.exe is available, and vswhere.exe was not found to locate Visual Studio Build Tools."
    }

    $installPath = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($installPath)) {
      $installPath = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null | Select-Object -First 1)
    }
    if ([string]::IsNullOrWhiteSpace($installPath)) {
      throw "Nim source bootstrap requires a C compiler. Could not find a Visual Studio Build Tools installation with VC toolchain components."
    }

    $vcvarsAll = Join-Path $installPath "VC/Auxiliary/Build/vcvarsall.bat"
    if (-not (Test-Path -LiteralPath $vcvarsAll -PathType Leaf)) {
      throw "Nim source bootstrap requires a C compiler. Expected vcvarsall.bat at '$vcvarsAll'."
    }

    $vcArch = if ($Arch -eq "arm64") { "x64" } else { "amd64" }
    $envOutput = & cmd.exe /d /s /c "`"$vcvarsAll`" $vcArch >nul && set"
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to initialize Visual Studio compiler environment via '$vcvarsAll $vcArch'."
    }
    foreach ($line in $envOutput) {
      $separator = $line.IndexOf("=")
      if ($separator -lt 1) {
        continue
      }
      $name = $line.Substring(0, $separator)
      $value = $line.Substring($separator + 1)
      if ($name -ieq "PATH") {
        Set-Item -Path "Env:Path" -Value $value
        continue
      }
      Set-Item -Path "Env:$name" -Value $value
    }

    $clCommand = Get-Command cl.exe -ErrorAction SilentlyContinue
    if ($null -eq $clCommand -or [string]::IsNullOrWhiteSpace($clCommand.Source)) {
      $hostCandidates = @("Hostx64", "Hostarm64", "Hostx86")
      foreach ($hostCandidate in $hostCandidates) {
        $candidateGlob = Join-Path $installPath "VC/Tools/MSVC/*/bin/$hostCandidate/$vcArch/cl.exe"
        $candidate = Get-ChildItem -Path $candidateGlob -File -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($null -eq $candidate) {
          continue
        }

        $candidateDir = Split-Path -Parent $candidate.FullName
        $vcToolsInstallDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $candidate.FullName)))
        $currentPath = [Environment]::GetEnvironmentVariable("Path")
        if ([string]::IsNullOrWhiteSpace($currentPath)) {
          Set-Item -Path "Env:Path" -Value $candidateDir
        } else {
          Set-Item -Path "Env:Path" -Value "$candidateDir;$currentPath"
        }
        Set-Item -Path "Env:NIM_WINDOWS_VC_BIN_DIR" -Value $candidateDir
        $vcIncludeDir = Join-Path $vcToolsInstallDir "include"
        if (Test-Path -LiteralPath $vcIncludeDir -PathType Container) {
          $currentInclude = [Environment]::GetEnvironmentVariable("INCLUDE")
          if ([string]::IsNullOrWhiteSpace($currentInclude)) {
            Set-Item -Path "Env:INCLUDE" -Value $vcIncludeDir
          } elseif ($currentInclude -notlike "$vcIncludeDir*") {
            Set-Item -Path "Env:INCLUDE" -Value "$vcIncludeDir;$currentInclude"
          }
        }

        $vcLibDir = Join-Path $vcToolsInstallDir "lib/$vcArch"
        if (Test-Path -LiteralPath $vcLibDir -PathType Container) {
          $currentLib = [Environment]::GetEnvironmentVariable("LIB")
          if ([string]::IsNullOrWhiteSpace($currentLib)) {
            Set-Item -Path "Env:LIB" -Value $vcLibDir
          } elseif ($currentLib -notlike "$vcLibDir*") {
            Set-Item -Path "Env:LIB" -Value "$vcLibDir;$currentLib"
          }
        }

        $clCommand = Get-Command cl.exe -ErrorAction SilentlyContinue
        if ($null -ne $clCommand -and -not [string]::IsNullOrWhiteSpace($clCommand.Source)) {
          break
        }
      }
    }
    if ($null -eq $clCommand -or [string]::IsNullOrWhiteSpace($clCommand.Source)) {
      throw "Visual Studio environment initialization completed, but cl.exe is still unavailable."
    }

    Write-Host "Configured MSVC compiler environment for Nim source bootstrap ($vcArch)."
  }

  $env:CC = "cl"
  $env:NIM_WINDOWS_SOURCE_CC_EFFECTIVE = "vcc"
}

function Get-CtRemotePublishedBinaryPath {
  param([Parameter(Mandatory = $true)][string]$Directory)

  $candidateNames = @(
    "DesktopClient.App",
    "DesktopClient.App.exe"
  )

  foreach ($candidateName in $candidateNames) {
    $candidatePath = Join-Path $Directory $candidateName
    if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
      return $candidatePath
    }
  }

  $dirListing = if (Test-Path -LiteralPath $Directory -PathType Container) {
    (Get-ChildItem -LiteralPath $Directory | Select-Object -ExpandProperty Name) -join ", "
  } else {
    "<missing directory>"
  }
  throw "Could not find DesktopClient.App publish output in '$Directory'. Checked DesktopClient.App and DesktopClient.App.exe. Directory contents: $dirListing"
}

function Ensure-Node {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch
  )

  $version = $toolchain.nodeVersion
  $nodeArch = ConvertTo-NodeFileArch -Arch $Arch
  $asset = "node-v$version-win-$nodeArch.zip"
  $nodeVersionRoot = Join-Path $Root "node/$version"
  $extractDir = Join-Path $nodeVersionRoot "node-v$version-win-$nodeArch"
  $nodeExe = Join-Path $extractDir "node.exe"

  if (Test-Path $nodeExe) {
    $installedVersion = (& $nodeExe --version).TrimStart("v")
    if ($installedVersion -eq $version) {
      Write-Host "Node.js $version already installed at $extractDir"
      return
    }
  }

  New-Item -ItemType Directory -Force -Path $nodeVersionRoot | Out-Null
  $downloadUrl = "https://nodejs.org/dist/v$version/$asset"
  $sumsUrl = "https://nodejs.org/dist/v$version/SHASUMS256.txt"

  $tempZip = Join-Path $env:TEMP "$asset"
  Download-File -Url $downloadUrl -OutFile $tempZip

  $sumsText = Download-String -Url $sumsUrl
  $expected = Get-ExpectedSha256 -ShaSource $sumsText -AssetName $asset
  Assert-FileSha256 -Path $tempZip -Expected $expected

  Ensure-CleanDirectory -Path $nodeVersionRoot
  Expand-Archive -Path $tempZip -DestinationPath $nodeVersionRoot -Force
  Remove-Item -LiteralPath $tempZip -Force

  if (-not (Test-Path $nodeExe)) {
    throw "Node.js extraction did not produce '$nodeExe'."
  }

  Write-Host "Installed Node.js $version to $extractDir"
}

function Ensure-Uv {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch
  )

  $version = $toolchain.uvVersion
  $target = ConvertTo-UvTarget -Arch $Arch
  $asset = "uv-$target.zip"
  $uvRoot = Join-Path $Root "uv/$version"
  $uvExe = Join-Path $uvRoot "uv.exe"

  if (Test-Path $uvExe) {
    $current = (& $uvExe --version).Split(" ")[1]
    if ($current -eq $version) {
      Write-Host "uv $version already installed at $uvRoot"
      return
    }
  }

  $baseUrl = "https://github.com/astral-sh/uv/releases/download/$version"
  $zipUrl = "$baseUrl/$asset"
  $shaUrl = "$baseUrl/$asset.sha256"
  $tempZip = Join-Path $env:TEMP "$asset"

  Download-File -Url $zipUrl -OutFile $tempZip
  $shaText = Download-String -Url $shaUrl
  $expected = Get-ExpectedSha256 -ShaSource $shaText -AssetName $asset
  Assert-FileSha256 -Path $tempZip -Expected $expected

  Ensure-CleanDirectory -Path $uvRoot
  Expand-Archive -Path $tempZip -DestinationPath $uvRoot -Force
  Remove-Item -LiteralPath $tempZip -Force

  if (-not (Test-Path $uvExe)) {
    throw "uv extraction did not produce '$uvExe'."
  }

  Write-Host "Installed uv $version to $uvRoot"
}

function Ensure-CtRemote {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch
  )

  $version = $toolchain.ctRemoteVersion
  $archiveSha256 = $toolchain.ctRemoteWinX64Sha256
  $asset = "DesktopClient.App-win-x64-$version.tar.gz"
  $baseUrl = "https://downloads.codetracer.com/DesktopClient.App"
  $archiveUrl = "$baseUrl/$asset"
  $sourceModeRaw = [Environment]::GetEnvironmentVariable("CT_REMOTE_WINDOWS_SOURCE_MODE")
  $sourceMode = if ([string]::IsNullOrWhiteSpace($sourceModeRaw)) { "auto" } else { $sourceModeRaw.Trim().ToLowerInvariant() }
  $localRepoRaw = [Environment]::GetEnvironmentVariable("CT_REMOTE_WINDOWS_SOURCE_REPO")
  if ([string]::IsNullOrWhiteSpace($localRepoRaw)) {
    $localRepoRaw = "../../../codetracer-ci"
  }
  $localRepoRoot = Resolve-AbsolutePathFromScriptRoot -PathValue $localRepoRaw
  $sourceRidRaw = [Environment]::GetEnvironmentVariable("CT_REMOTE_WINDOWS_SOURCE_RID")
  $sourceRid = if ([string]::IsNullOrWhiteSpace($sourceRidRaw)) { Get-DefaultCtRemoteSourceRid -Arch $Arch } else { $sourceRidRaw.Trim().ToLowerInvariant() }
  $sourceProjectRelativePath = "apps/DesktopClient/DesktopClient.App/DesktopClient.App.csproj"
  $sourceProjectPath = Join-Path $localRepoRoot $sourceProjectRelativePath
  $publishScriptRaw = [Environment]::GetEnvironmentVariable("CT_REMOTE_WINDOWS_PUBLISH_SCRIPT")
  if ([string]::IsNullOrWhiteSpace($publishScriptRaw)) {
    $publishScriptPath = Join-Path $localRepoRoot "non-nix-build/windows/publish-desktop-client.ps1"
  } else {
    $publishScriptPath = Resolve-AbsolutePathWithBase -PathValue $publishScriptRaw -BasePath $localRepoRoot
  }
  $publishScriptExists = Test-Path -LiteralPath $publishScriptPath -PathType Leaf
  $ctRemoteRoot = Join-Path $Root "ct-remote/$version"
  $ctRemoteBinary = Join-Path $ctRemoteRoot "ct-remote"
  $ctRemoteExe = Join-Path $ctRemoteRoot "ct-remote.exe"
  $versionFile = Join-Path $ctRemoteRoot "ct-remote.version"
  $shaFile = Join-Path $ctRemoteRoot "ct-remote.archive.sha256"
  $sourceFile = Join-Path $ctRemoteRoot "ct-remote.source"

  if ($sourceRid -notin @("win-x64", "win-arm64")) {
    throw "Unsupported CT_REMOTE_WINDOWS_SOURCE_RID '$sourceRid'. Supported values: win-x64, win-arm64."
  }

  $supportsPinnedDownload = ($Arch -eq "x64")
  $useLocalSource = $false
  switch ($sourceMode) {
    "auto" {
      $sourceProjectExists = Test-Path -LiteralPath $sourceProjectPath -PathType Leaf
      if (-not $sourceProjectExists) {
        if ($supportsPinnedDownload) {
          $useLocalSource = $false
        } else {
          throw "CT_REMOTE_WINDOWS_SOURCE_MODE=auto on '$Arch' requires local source project '$sourceProjectPath'. Pinned download is x64-only."
        }
      } else {
        $useLocalSource = $true
      }
    }
    "local" {
      if (-not (Test-Path -LiteralPath $sourceProjectPath -PathType Leaf)) {
        throw "CT_REMOTE_WINDOWS_SOURCE_MODE=local requires '$sourceProjectPath' to exist."
      }
      $useLocalSource = $true
    }
    "download" {
      if (-not $supportsPinnedDownload) {
        throw "CT_REMOTE_WINDOWS_SOURCE_MODE=download is only supported on Windows x64 because only '$asset' is pinned with '$($toolchain.ctRemoteWinX64Sha256)'."
      }
      $useLocalSource = $false
    }
    default {
      throw "Unsupported CT_REMOTE_WINDOWS_SOURCE_MODE '$sourceMode'. Supported values: auto, local, download."
    }
  }

  $dotnetCommand = $null
  if ($useLocalSource) {
    if (-not $publishScriptExists) {
      $dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
    }
    if (
      -not $publishScriptExists -and
      ($null -eq $dotnetCommand -or [string]::IsNullOrWhiteSpace($dotnetCommand.Source)) -and
      $sourceMode -eq "auto" -and
      $supportsPinnedDownload
    ) {
      Write-Warning "Skipping ct-remote local-source bootstrap because '$publishScriptPath' is not available and dotnet is not on PATH. Falling back to pinned download."
      $useLocalSource = $false
    }
  }

  $expectedSha = $archiveSha256.ToLowerInvariant()
  $expectedSource = ""
  if ($useLocalSource) {
    $sourceRevision = Get-CtRemoteSourceRevision -RepoRoot $localRepoRoot
    if ($publishScriptExists) {
      $expectedSource = "local|repo=$localRepoRoot|project=$sourceProjectRelativePath|publish_script=$publishScriptPath|rid=$sourceRid|revision=$sourceRevision"
    } else {
      $expectedSource = "local|repo=$localRepoRoot|project=$sourceProjectRelativePath|publish_script=dotnet-direct|rid=$sourceRid|revision=$sourceRevision"
    }
  } else {
    $expectedSource = "download|asset=$asset|sha256=$expectedSha"
  }

  if ((Test-Path $ctRemoteBinary) -and (Test-Path $ctRemoteExe) -and (Test-Path $versionFile) -and (Test-Path $sourceFile)) {
    $installedVersionLine = Get-Content -LiteralPath $versionFile -ErrorAction SilentlyContinue | Select-Object -First 1
    $installedSourceLine = Get-Content -LiteralPath $sourceFile -ErrorAction SilentlyContinue | Select-Object -First 1
    $installedVersion = ([string]$installedVersionLine).Trim()
    $installedSource = ([string]$installedSourceLine).Trim()

    if ($installedVersion -eq $version -and $installedSource -eq $expectedSource) {
      if ($useLocalSource) {
        Write-Host "ct-remote $version already installed from local source at $ctRemoteRoot"
        return
      }

      if (Test-Path -LiteralPath $shaFile -PathType Leaf) {
        $installedShaLine = Get-Content -LiteralPath $shaFile -ErrorAction SilentlyContinue | Select-Object -First 1
        $installedSha = ([string]$installedShaLine).Trim().ToLowerInvariant()
        if ($installedSha -eq $expectedSha) {
          Write-Host "ct-remote $version already installed from pinned download at $ctRemoteRoot"
          return
        }
      }
    }
  }

  Ensure-CleanDirectory -Path $ctRemoteRoot
  if ($useLocalSource) {
    Write-Host "Building ct-remote from local source repo '$localRepoRoot' (RID: $sourceRid)"
    if ($publishScriptExists) {
      Write-Host "Using ct-remote publish helper script '$publishScriptPath'"
      & $publishScriptPath -Rid $sourceRid -Configuration Release
      if (-not $?) {
        if ($supportsPinnedDownload) {
          throw "Publish helper '$publishScriptPath' failed for RID '$sourceRid'. Set CT_REMOTE_WINDOWS_SOURCE_MODE=download to force pinned artifact fallback."
        }
        throw "Publish helper '$publishScriptPath' failed for RID '$sourceRid'. On '$Arch', CT_REMOTE_WINDOWS_SOURCE_MODE=download is x64-only; retry local mode and adjust CT_REMOTE_WINDOWS_SOURCE_RID (for example, win-x64) if your local toolchain cannot publish win-arm64."
      }
    } else {
      if ($null -eq $dotnetCommand -or [string]::IsNullOrWhiteSpace($dotnetCommand.Source)) {
        throw "CT_REMOTE_WINDOWS_SOURCE_MODE=$sourceMode selected local source '$localRepoRoot', but '$publishScriptPath' is missing and dotnet was not found on PATH. On '$Arch', pinned ct-remote download fallback is available only on x64."
      }

      Write-Warning "Publish helper script '$publishScriptPath' was not found. Falling back to direct dotnet publish."
      & $dotnetCommand.Source publish $sourceProjectPath -c Release -r $sourceRid
      if ($LASTEXITCODE -ne 0) {
        if ($supportsPinnedDownload) {
          throw "dotnet publish failed for '$sourceProjectPath'. Set CT_REMOTE_WINDOWS_SOURCE_MODE=download to force pinned artifact fallback."
        }
        throw "dotnet publish failed for '$sourceProjectPath' (RID '$sourceRid'). On '$Arch', CT_REMOTE_WINDOWS_SOURCE_MODE=download is x64-only; retry local mode and adjust CT_REMOTE_WINDOWS_SOURCE_RID (for example, win-x64) if your local toolchain cannot publish win-arm64."
      }
    }

    $publishedDirectory = Join-Path $localRepoRoot "runtime/publish/DesktopClient.App"
    $publishedBinary = Get-CtRemotePublishedBinaryPath -Directory $publishedDirectory
    Copy-Item -LiteralPath $publishedBinary -Destination $ctRemoteBinary -Force
    Copy-Item -LiteralPath $publishedBinary -Destination $ctRemoteExe -Force
  } else {
    Write-Host "Installing ct-remote from pinned download '$archiveUrl'"
    $tempArchive = Join-Path $env:TEMP $asset
    Download-File -Url $archiveUrl -OutFile $tempArchive
    try {
      Assert-FileSha256 -Path $tempArchive -Expected $archiveSha256

      $tarExe = Get-WindowsTarExe
      & $tarExe -xzf $tempArchive -C $ctRemoteRoot

      $downloadedBinary = Get-CtRemotePublishedBinaryPath -Directory $ctRemoteRoot
      Copy-Item -LiteralPath $downloadedBinary -Destination $ctRemoteBinary -Force
      Copy-Item -LiteralPath $downloadedBinary -Destination $ctRemoteExe -Force
    } finally {
      Remove-Item -LiteralPath $tempArchive -Force -ErrorAction SilentlyContinue
    }

    $expectedSha | Out-File -LiteralPath $shaFile -Encoding ASCII -Force
  }

  $version | Out-File -LiteralPath $versionFile -Encoding ASCII -Force
  $expectedSource | Out-File -LiteralPath $sourceFile -Encoding ASCII -Force

  if (-not (Test-Path $ctRemoteBinary) -or -not (Test-Path $ctRemoteExe)) {
    throw "ct-remote bootstrap did not produce '$ctRemoteBinary' and '$ctRemoteExe'."
  }

  if ($useLocalSource) {
    Write-Host "Installed ct-remote $version from local source to $ctRemoteRoot"
  } else {
    Write-Host "Installed ct-remote $version from pinned download to $ctRemoteRoot"
  }
}

function Get-CapnpCompilerVersion {
  param([Parameter(Mandatory = $true)][string]$CapnpExe)

  $firstLine = (& $CapnpExe --version | Select-Object -First 1)
  if ($firstLine -match '([0-9]+(?:\.[0-9]+)*(?:[-+][0-9A-Za-z.-]+)?)') {
    return $Matches[1]
  }

  throw "Unable to parse Cap'n Proto version from '$CapnpExe': $firstLine"
}

function Get-CmakeVersionHint {
  $cmakeCommand = Get-Command cmake -ErrorAction SilentlyContinue
  if ($null -eq $cmakeCommand -or [string]::IsNullOrWhiteSpace($cmakeCommand.Source)) {
    return "cmake=missing"
  }

  $cmakeVersionLine = (& $cmakeCommand.Source --version | Select-Object -First 1)
  if ([string]::IsNullOrWhiteSpace($cmakeVersionLine)) {
    return "cmake=present"
  }

  return "cmake=$($cmakeVersionLine.Trim())"
}

function Ensure-CapnpPrebuilt {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch
  )

  $version = $toolchain.capnpVersion
  $archiveSha256 = $toolchain.capnpWinX64Sha256
  $capnpArch = ConvertTo-CapnpPrebuiltFileArch -Arch $Arch
  $asset = "capnproto-c++-$capnpArch-$version.zip"
  $capnpVersionRoot = Join-Path $Root "capnp/$version"
  $prebuiltRoot = Join-Path $capnpVersionRoot "prebuilt"
  $extractDir = Join-Path $prebuiltRoot "capnproto-tools-win32-$version"
  $capnpExe = Join-Path $extractDir "capnp.exe"
  $versionFile = Join-Path $prebuiltRoot "capnp.version"
  $shaFile = Join-Path $prebuiltRoot "capnp.archive.sha256"
  $sourceFile = Join-Path $prebuiltRoot "capnp.source"
  $expectedSource = "prebuilt|asset=$asset|sha256=$($archiveSha256.ToLowerInvariant())"

  if ((Test-Path $capnpExe) -and (Test-Path $versionFile) -and (Test-Path $shaFile) -and (Test-Path $sourceFile)) {
    $installedVersionLine = Get-Content -LiteralPath $versionFile -ErrorAction SilentlyContinue | Select-Object -First 1
    $installedShaLine = Get-Content -LiteralPath $shaFile -ErrorAction SilentlyContinue | Select-Object -First 1
    $installedSourceLine = Get-Content -LiteralPath $sourceFile -ErrorAction SilentlyContinue | Select-Object -First 1
    $installedVersion = ([string]$installedVersionLine).Trim()
    $installedSha = ([string]$installedShaLine).Trim().ToLowerInvariant()
    $installedSource = ([string]$installedSourceLine).Trim()
    $detectedVersion = Get-CapnpCompilerVersion -CapnpExe $capnpExe
    if (
      $installedVersion -eq $version -and
      $installedSha -eq $archiveSha256.ToLowerInvariant() -and
      $installedSource -eq $expectedSource -and
      $detectedVersion -eq $version
    ) {
      Write-Host "Cap'n Proto $version already installed at $extractDir"
      return @{
        mode = "prebuilt"
        installDir = $extractDir
        metadata = @{
          capnp_mode = "prebuilt"
          capnp_version = $version
          capnp_arch = $Arch
          capnp_asset = $asset
          capnp_archive_sha256 = $archiveSha256.ToLowerInvariant()
        }
      }
    }
  }

  New-Item -ItemType Directory -Force -Path $prebuiltRoot | Out-Null
  $zipUrl = "https://capnproto.org/$asset"
  $tempZip = Join-Path $env:TEMP $asset

  Download-File -Url $zipUrl -OutFile $tempZip
  try {
    Assert-FileSha256 -Path $tempZip -Expected $archiveSha256

    Ensure-CleanDirectory -Path $prebuiltRoot
    Expand-Archive -Path $tempZip -DestinationPath $prebuiltRoot -Force

    if (-not (Test-Path $capnpExe)) {
      throw "Cap'n Proto extraction did not produce '$capnpExe'."
    }

    $detectedVersion = Get-CapnpCompilerVersion -CapnpExe $capnpExe
    if ($detectedVersion -ne $version) {
      throw "Cap'n Proto bootstrap produced unexpected version '$detectedVersion' (expected '$version')."
    }

    $version | Out-File -LiteralPath $versionFile -Encoding ASCII -Force
    $archiveSha256.ToLowerInvariant() | Out-File -LiteralPath $shaFile -Encoding ASCII -Force
    $expectedSource | Out-File -LiteralPath $sourceFile -Encoding ASCII -Force
  } finally {
    Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
  }

  Write-Host "Installed Cap'n Proto $version to $extractDir"
  return @{
    mode = "prebuilt"
    installDir = $extractDir
    metadata = @{
      capnp_mode = "prebuilt"
      capnp_version = $version
      capnp_arch = $Arch
      capnp_asset = $asset
      capnp_archive_sha256 = $archiveSha256.ToLowerInvariant()
    }
  }
}

function Ensure-CapnpFromSource {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch
  )

  $version = $toolchain.capnpVersion
  $capnpVersionRoot = Join-Path $Root "capnp/$version"
  $sourceCacheRoot = Join-Path $capnpVersionRoot "cache/source"
  $capnpRepo = [Environment]::GetEnvironmentVariable("CAPNP_WINDOWS_SOURCE_REPO")
  if ([string]::IsNullOrWhiteSpace($capnpRepo)) {
    $capnpRepo = $toolchain.capnpSourceRepo
  }
  $capnpRef = [Environment]::GetEnvironmentVariable("CAPNP_WINDOWS_SOURCE_REF")
  if ([string]::IsNullOrWhiteSpace($capnpRef)) {
    $capnpRef = $toolchain.capnpSourceRef
  }
  $capnpRevisionOverride = [Environment]::GetEnvironmentVariable("CAPNP_WINDOWS_SOURCE_REVISION")
  $capnpRevision = if ([string]::IsNullOrWhiteSpace($capnpRevisionOverride)) {
    Resolve-GitRefToRevision -Repository $capnpRepo -RefName $capnpRef
  } else {
    $capnpRevisionOverride.Trim().ToLowerInvariant()
  }

  $gitCommand = Get-Command git -ErrorAction SilentlyContinue
  if ($null -eq $gitCommand -or [string]::IsNullOrWhiteSpace($gitCommand.Source)) {
    throw "git is required for Cap'n Proto source bootstrap but was not found on PATH."
  }
  $cmakeCommand = Get-Command cmake -ErrorAction SilentlyContinue
  if ($null -eq $cmakeCommand -or [string]::IsNullOrWhiteSpace($cmakeCommand.Source)) {
    throw "cmake is required for Cap'n Proto source bootstrap but was not found on PATH."
  }
  $ninjaCommand = Get-Command ninja -ErrorAction SilentlyContinue
  Ensure-NimSourceCompilerEnvironment -Arch $Arch -Root $Root
  $compilerHint = Get-NimSourceCompilerHint
  $cmakeHint = Get-CmakeVersionHint
  $generatorRaw = [Environment]::GetEnvironmentVariable("CAPNP_WINDOWS_CMAKE_GENERATOR")
  $generator = if ([string]::IsNullOrWhiteSpace($generatorRaw)) {
    if ($null -ne $ninjaCommand -and -not [string]::IsNullOrWhiteSpace($ninjaCommand.Source)) {
      "Ninja"
    } else {
      "Visual Studio 17 2022"
    }
  } else {
    $generatorRaw.Trim()
  }

  $cacheInputMetadata = @{
    capnp_mode = "source"
    capnp_version = $version
    capnp_arch = $Arch
    capnp_repo = $capnpRepo
    capnp_ref = $capnpRef
    capnp_revision = $capnpRevision
    capnp_cmake_generator = $generator
    compiler_hint = $compilerHint
    cmake_hint = $cmakeHint
  }
  $cacheInputString = (($cacheInputMetadata.Keys | Sort-Object | ForEach-Object { "$_=$($cacheInputMetadata[$_])" }) -join "`n")
  $cacheKey = Get-Sha256HexForString -Value $cacheInputString
  $cacheRoot = Join-Path $sourceCacheRoot $cacheKey
  $installDir = Join-Path $cacheRoot "install"
  $capnpExe = Join-Path $installDir "bin/capnp.exe"
  $sourceMetaFile = Join-Path $cacheRoot "capnp.source.meta"

  if ((Test-Path -LiteralPath $capnpExe -PathType Leaf) -and (Test-Path -LiteralPath $sourceMetaFile -PathType Leaf)) {
    $installedMetadata = Read-KeyValueFile -Path $sourceMetaFile
    $detectedVersion = Get-CapnpCompilerVersion -CapnpExe $capnpExe
    if ((Test-KeyValueFileMatches -Expected $cacheInputMetadata -Actual $installedMetadata) -and $detectedVersion -eq $version) {
      Write-Host "Cap'n Proto $version source cache hit at $installDir"
      return @{
        mode = "source"
        installDir = $installDir
        metadata = $cacheInputMetadata
      }
    }
  }

  $stagingRoot = Join-Path $env:TEMP "codetracer-capnp-source-$cacheKey"
  Ensure-CleanDirectory -Path $stagingRoot
  $sourceDir = Join-Path $stagingRoot "capnp-src"
  $buildDir = Join-Path $stagingRoot "build"
  $stagingInstallDir = Join-Path $stagingRoot "install"
  $stagedCapnpExe = Join-Path $stagingInstallDir "bin/capnp.exe"
  try {
    Write-Host "Building Cap'n Proto $version from source (cache key: $cacheKey)"
    & $gitCommand.Source clone $capnpRepo $sourceDir
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to clone Cap'n Proto repository '$capnpRepo'."
    }
    & $gitCommand.Source -C $sourceDir checkout --detach $capnpRevision
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to checkout Cap'n Proto revision '$capnpRevision'."
    }

    $configureArgs = @(
      "-S", $sourceDir,
      "-B", $buildDir,
      "-G", $generator,
      "-DCMAKE_INSTALL_PREFIX=$stagingInstallDir",
      "-DBUILD_TESTING=OFF",
      "-DBUILD_SHARED_LIBS=OFF",
      "-DCMAKE_BUILD_TYPE=Release"
    )
    if ($generator -like "Visual Studio*") {
      $vsArch = if ($Arch -eq "arm64") { "ARM64" } else { "x64" }
      $configureArgs += @("-A", $vsArch)
    }
    & $cmakeCommand.Source @configureArgs
    if ($LASTEXITCODE -ne 0) {
      throw "Cap'n Proto source bootstrap failed while running cmake configure."
    }

    $buildArgs = @("--build", $buildDir, "--config", "Release", "--target", "install")
    & $cmakeCommand.Source @buildArgs
    if ($LASTEXITCODE -ne 0) {
      throw "Cap'n Proto source bootstrap failed while running cmake build/install."
    }

    if (-not (Test-Path -LiteralPath $stagedCapnpExe -PathType Leaf)) {
      throw "Cap'n Proto source bootstrap did not produce '$stagedCapnpExe'."
    }

    $detectedVersion = Get-CapnpCompilerVersion -CapnpExe $stagedCapnpExe
    if ($detectedVersion -ne $version) {
      throw "Cap'n Proto source bootstrap produced unexpected version '$detectedVersion' (expected '$version')."
    }

    Ensure-CleanDirectory -Path $cacheRoot
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    foreach ($sourceEntry in (Get-ChildItem -LiteralPath $stagingInstallDir -Force)) {
      Copy-Item -LiteralPath $sourceEntry.FullName -Destination $installDir -Recurse -Force
    }
    Write-KeyValueFile -Path $sourceMetaFile -Values $cacheInputMetadata
  } finally {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
  }

  Write-Host "Installed Cap'n Proto $version from source to $installDir"
  return @{
    mode = "source"
    installDir = $installDir
    metadata = $cacheInputMetadata
  }
}

function Ensure-Capnp {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch
  )

  $requestedModeRaw = [Environment]::GetEnvironmentVariable("CAPNP_WINDOWS_SOURCE_MODE")
  $requestedMode = if ([string]::IsNullOrWhiteSpace($requestedModeRaw)) { "auto" } else { $requestedModeRaw.Trim().ToLowerInvariant() }
  $capnpVersionRoot = Join-Path $Root "capnp/$($toolchain.capnpVersion)"
  $installPathFile = Join-Path $capnpVersionRoot "capnp.install.relative-path"
  $installMetaFile = Join-Path $capnpVersionRoot "capnp.install.meta"

  $result = $null
  switch ($requestedMode) {
    "prebuilt" {
      if ($Arch -ne "x64") {
        throw "CAPNP_WINDOWS_SOURCE_MODE=prebuilt is supported on Windows x64 only. Detected architecture '$Arch'. Use CAPNP_WINDOWS_SOURCE_MODE=source to build from source."
      }
      $result = Ensure-CapnpPrebuilt -Root $Root -Arch $Arch
    }
    "source" {
      $result = Ensure-CapnpFromSource -Root $Root -Arch $Arch
    }
    "auto" {
      if ($Arch -eq "x64") {
        $result = Ensure-CapnpPrebuilt -Root $Root -Arch $Arch
      } else {
        $result = Ensure-CapnpFromSource -Root $Root -Arch $Arch
      }
    }
    default {
      throw "Unsupported CAPNP_WINDOWS_SOURCE_MODE '$requestedMode'. Supported values: auto, source, prebuilt."
    }
  }

  if ($result -is [array]) {
    $hashResult = $result | Where-Object { $_ -is [hashtable] -or $_ -is [System.Collections.IDictionary] } | Select-Object -Last 1
    if ($null -ne $hashResult) {
      $result = $hashResult
    }
  }

  if ($result -is [System.Collections.IDictionary] -and -not ($result -is [hashtable])) {
    $normalizedResult = @{}
    foreach ($entry in $result.GetEnumerator()) {
      $normalizedResult[[string]$entry.Key] = $entry.Value
    }
    $result = $normalizedResult
  }

  if ($null -eq $result -or -not $result.ContainsKey("installDir")) {
    throw "Cap'n Proto bootstrap did not return an install directory."
  }

  $installDir = [string]$result.installDir
  $relativeInstallDir = ConvertTo-InstallRelativePath -AbsolutePath $installDir -Root $Root
  $selectedMetadata = @{
    requested_mode = $requestedMode
    effective_mode = [string]$result.mode
    capnp_version = $toolchain.capnpVersion
    capnp_arch = $Arch
    install_relative_path = $relativeInstallDir
  }
  foreach ($key in $result.metadata.Keys) {
    $selectedMetadata[$key] = [string]$result.metadata[$key]
  }

  New-Item -ItemType Directory -Force -Path $capnpVersionRoot | Out-Null
  Set-Content -LiteralPath $installPathFile -Value $relativeInstallDir -Encoding ASCII
  Write-KeyValueFile -Path $installMetaFile -Values $selectedMetadata
}

function Get-TupVersionLine {
  param([Parameter(Mandatory = $true)][string]$TupExe)

  $versionOutput = & $TupExe --version 2>&1
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    $renderedOutput = (($versionOutput | ForEach-Object { [string]$_ }) -join " | ").Trim()
    if ([string]::IsNullOrWhiteSpace($renderedOutput)) {
      $renderedOutput = "<no output>"
    }
    throw "Failed to run '$TupExe --version' (exit code: $exitCode). Output: $renderedOutput"
  }
  $firstLine = ($versionOutput | Select-Object -First 1)
  if ([string]::IsNullOrWhiteSpace($firstLine)) {
    throw "Unable to detect Tup version from '$TupExe'."
  }
  return ([string]$firstLine).Trim()
}

function Ensure-TupPrebuilt {
  param([Parameter(Mandatory = $true)][string]$Root)

  $prebuiltUrl = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_PREBUILT_URL")
  $prebuiltSha = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_PREBUILT_SHA256")
  if ([string]::IsNullOrWhiteSpace($prebuiltUrl)) {
    $prebuiltUrl = $toolchain.tupPrebuiltUrl
  } else {
    $prebuiltUrl = $prebuiltUrl.Trim()
  }
  if ([string]::IsNullOrWhiteSpace($prebuiltSha)) {
    $prebuiltSha = $toolchain.tupPrebuiltSha256
  } else {
    $prebuiltSha = $prebuiltSha.Trim()
  }
  if ([string]::IsNullOrWhiteSpace($prebuiltUrl) -or [string]::IsNullOrWhiteSpace($prebuiltSha)) {
    throw "Tup prebuilt mode requires TUP_WINDOWS_PREBUILT_URL and TUP_WINDOWS_PREBUILT_SHA256 (or matching toolchain defaults)."
  }

  $normalizedSha = $prebuiltSha.Trim().ToLowerInvariant()
  if ($normalizedSha -notmatch '^[A-Fa-f0-9]{64}$') {
    throw "TUP_WINDOWS_PREBUILT_SHA256 must be a 64-character hexadecimal SHA256."
  }

  $tupRoot = Join-Path $Root "tup"
  $prebuiltRoot = Join-Path $tupRoot "prebuilt/$normalizedSha"
  $installDir = Join-Path $prebuiltRoot "install"
  $tupExe = Join-Path $installDir "tup.exe"
  $metaFile = Join-Path $prebuiltRoot "tup.prebuilt.meta"
  $requestedVersion = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_PREBUILT_VERSION")
  if ([string]::IsNullOrWhiteSpace($requestedVersion)) {
    $requestedVersion = $toolchain.tupPrebuiltVersion
  } else {
    $requestedVersion = $requestedVersion.Trim()
  }

  $expectedMetadata = @{
    tup_mode = "prebuilt"
    tup_prebuilt_url = $prebuiltUrl
    tup_prebuilt_sha256 = $normalizedSha
    tup_prebuilt_version = $requestedVersion
  }

  if ((Test-Path -LiteralPath $tupExe -PathType Leaf) -and (Test-Path -LiteralPath $metaFile -PathType Leaf)) {
    $installedMetadata = Read-KeyValueFile -Path $metaFile
    if (Test-KeyValueFileMatches -Expected $expectedMetadata -Actual $installedMetadata) {
      try {
        $null = Get-TupVersionLine -TupExe $tupExe
        Write-Host "Tup prebuilt cache hit at $installDir"
        return @{
          mode = "prebuilt"
          installDir = $installDir
          metadata = $expectedMetadata
        }
      } catch {
        Write-Warning "Cached Tup prebuilt install is invalid and will be reinstalled: $($_.Exception.Message)"
      }
    }
  }

  $uri = [System.Uri]$prebuiltUrl.Trim()
  $assetName = [System.IO.Path]::GetFileName($uri.LocalPath)
  if ([string]::IsNullOrWhiteSpace($assetName)) {
    throw "Could not derive Tup prebuilt asset name from URL '$prebuiltUrl'."
  }

  $tempAsset = Join-Path $env:TEMP "codetracer-tup-prebuilt-$normalizedSha-$assetName"
  Download-File -Url $prebuiltUrl -OutFile $tempAsset
  try {
    Assert-FileSha256 -Path $tempAsset -Expected $normalizedSha
    Ensure-CleanDirectory -Path $prebuiltRoot
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null

    $assetLower = $assetName.ToLowerInvariant()
    if ($assetLower.EndsWith(".zip")) {
      $expandedRoot = Join-Path $prebuiltRoot "expanded"
      Expand-Archive -Path $tempAsset -DestinationPath $expandedRoot -Force
      $candidate = Get-ChildItem -Path $expandedRoot -Filter "tup.exe" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($null -eq $candidate) {
        throw "Tup prebuilt ZIP did not contain tup.exe."
      }
      $candidateRoot = Split-Path -Parent $candidate.FullName
      foreach ($entry in (Get-ChildItem -LiteralPath $candidateRoot -File)) {
        Copy-Item -LiteralPath $entry.FullName -Destination (Join-Path $installDir $entry.Name) -Force
      }
      Copy-Item -LiteralPath $candidate.FullName -Destination $tupExe -Force
    } elseif ($assetLower.EndsWith(".exe")) {
      Copy-Item -LiteralPath $tempAsset -Destination $tupExe -Force
    } else {
      throw "Unsupported Tup prebuilt asset '$assetName'. Only .zip and .exe are supported."
    }

    $null = Get-TupVersionLine -TupExe $tupExe
    Write-KeyValueFile -Path $metaFile -Values $expectedMetadata
  } finally {
    Remove-Item -LiteralPath $tempAsset -Force -ErrorAction SilentlyContinue
  }

  Write-Host "Installed Tup from prebuilt asset to $installDir"
  return @{
    mode = "prebuilt"
    installDir = $installDir
    metadata = $expectedMetadata
  }
}

function New-TupWindowsBootstrapScript {
  param([Parameter(Mandatory = $true)][string]$SourceDir)

  $scriptPath = Join-Path $SourceDir "codetracer-bootstrap-windows.sh"
  $scriptContent = @'
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"

: "${CC:=x86_64-w64-mingw32-gcc}"
: "${AR:=x86_64-w64-mingw32-ar}"

COMMON_CFLAGS=(
  -Os
  -W
  -Wall
  -fno-common
  -D_FILE_OFFSET_BITS=64
  -I"$ROOT_DIR/src"
  -I"$BUILD_DIR"
  -include signal.h
  -include "$ROOT_DIR/src/compat/win32/mingw.h"
  -I"$ROOT_DIR/src/compat/win32"
  -D_GNU_SOURCE
  "-DS_ISLNK(a)=0"
  "-D__reserved="
  -DAT_REMOVEDIR=0x200
  -DUNICODE
  -D_UNICODE
)

LUA_CFLAGS=(
  -DLUA_COMPAT_ALL
  -DLUA_USE_MKSTEMP
  -w
)

WRAP_LDFLAGS=(
  -Wl,--wrap=open
  -Wl,--wrap=close
  -Wl,--wrap=tmpfile
  -Wl,--wrap=dup
  -Wl,--wrap=__mingw_vprintf
  -Wl,--wrap=__mingw_vfprintf
)

compile_object() {
  local src="$1"
  shift || true
  local rel="${src#$ROOT_DIR/}"
  local obj_name="${rel//\//_}"
  local obj_path="$BUILD_DIR/${obj_name%.c}.o"
  "$CC" "${COMMON_CFLAGS[@]}" "$@" -c "$src" -o "$obj_path"
}

mkdir -p "$BUILD_DIR"
rm -f "$BUILD_DIR"/*.o "$BUILD_DIR"/*.a "$BUILD_DIR"/lua "$BUILD_DIR"/tup.exe "$BUILD_DIR"/tup-dllinject.dll "$BUILD_DIR"/builtin.lua
rm -rf "$BUILD_DIR"/luabuiltin
mkdir -p "$BUILD_DIR/luabuiltin"

lua_objects=()
while IFS= read -r -d '' src; do
  compile_object "$src" "${LUA_CFLAGS[@]}"
  rel="${src#$ROOT_DIR/}"
  obj_name="${rel//\//_}"
  obj_path="$BUILD_DIR/${obj_name%.c}.o"
  lua_objects+=("$obj_path")
done < <(find "$ROOT_DIR/src/lua" -maxdepth 1 -type f -name '*.c' -print0 | sort -z)

lua_link_objects=()
tup_lua_objects=()
for obj in "${lua_objects[@]}"; do
  base="$(basename "$obj")"
  if [[ "$base" != "src_lua_lua.o" && "$base" != "src_lua_luac.o" ]]; then
    tup_lua_objects+=("$obj")
  fi
  if [[ "$base" != "src_lua_luac.o" ]]; then
    lua_link_objects+=("$obj")
  fi
done

"$CC" "${lua_link_objects[@]}" -o "$BUILD_DIR/lua" -lm
cp "$ROOT_DIR/src/luabuiltin/builtin.lua" "$BUILD_DIR/builtin.lua"
(
  cd "$BUILD_DIR"
  ./lua "$ROOT_DIR/src/luabuiltin/xxd.lua" builtin.lua luabuiltin/luabuiltin.h
)

dllinject_objects=()
while IFS= read -r -d '' src; do
  compile_object "$src" -Wno-missing-prototypes -DNDEBUG
  rel="${src#$ROOT_DIR/}"
  obj_name="${rel//\//_}"
  obj_path="$BUILD_DIR/${obj_name%.c}.o"
  dllinject_objects+=("$obj_path")
done < <(find "$ROOT_DIR/src/dllinject" -maxdepth 1 -type f -name '*.c' -print0 | sort -z)

"$CC" -shared -static-libgcc "${dllinject_objects[@]}" -lpsapi -o "$BUILD_DIR/tup-dllinject.dll"

tup_objects=()
add_tree_objects() {
  local dir="$1"
  local extra_args=("${@:2}")
  while IFS= read -r -d '' src; do
    compile_object "$src" "${extra_args[@]}"
    rel="${src#$ROOT_DIR/}"
    obj_name="${rel//\//_}"
    obj_path="$BUILD_DIR/${obj_name%.c}.o"
    tup_objects+=("$obj_path")
  done < <(find "$dir" -maxdepth 1 -type f -name '*.c' -print0 | sort -z)
}

add_tree_objects "$ROOT_DIR/src/tup"
compile_object "$ROOT_DIR/src/tup/monitor/null.c"
tup_objects+=("$BUILD_DIR/src_tup_monitor_null.o")
compile_object "$ROOT_DIR/src/tup/flock/lock_file.c"
tup_objects+=("$BUILD_DIR/src_tup_flock_lock_file.o")
compile_object "$ROOT_DIR/src/tup/server/windepfile.c"
tup_objects+=("$BUILD_DIR/src_tup_server_windepfile.o")
compile_object "$ROOT_DIR/src/tup/tup/main.c"
tup_objects+=("$BUILD_DIR/src_tup_tup_main.o")
add_tree_objects "$ROOT_DIR/src/inih" -Wno-cast-qual -DINI_ALLOW_MULTILINE=0
add_tree_objects "$ROOT_DIR/src/sqlite3" -w -DSQLITE_TEMP_STORE=2 -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION

for compat_src in \
  "$ROOT_DIR/src/compat/dir_mutex.c" \
  "$ROOT_DIR/src/compat/fstatat.c" \
  "$ROOT_DIR/src/compat/mkdirat.c" \
  "$ROOT_DIR/src/compat/openat.c" \
  "$ROOT_DIR/src/compat/renameat.c" \
  "$ROOT_DIR/src/compat/unlinkat.c"; do
  compile_object "$compat_src"
  rel="${compat_src#$ROOT_DIR/}"
  obj_name="${rel//\//_}"
  tup_objects+=("$BUILD_DIR/${obj_name%.c}.o")
done

add_tree_objects "$ROOT_DIR/src/compat/win32"

version="$(git -C "$ROOT_DIR" describe --always --dirty 2>/dev/null || echo codetracer-bootstrap)"
printf 'const char *tup_version(void) {return "%s";}\n' "$version" | "$CC" -x c -c - -o "$BUILD_DIR/tup-version.o"

"$CC" -static-libgcc \
  "${tup_lua_objects[@]}" \
  "${tup_objects[@]}" \
  "$BUILD_DIR/tup-dllinject.dll" \
  "$BUILD_DIR/tup-version.o" \
  "${WRAP_LDFLAGS[@]}" \
  -o "$BUILD_DIR/tup.exe" \
  -lm \
  -lpthread

self_host_update_raw="${TUP_WINDOWS_SELF_HOST_UPDATE:-0}"
self_host_update="$(echo "$self_host_update_raw" | tr '[:upper:]' '[:lower:]')"
if [[ "$self_host_update" == "1" || "$self_host_update" == "true" || "$self_host_update" == "yes" || "$self_host_update" == "on" ]]; then
  if [[ ! -d "$ROOT_DIR/.tup" ]]; then
    "$BUILD_DIR/tup.exe" init
  fi
  "$BUILD_DIR/tup.exe" upd
else
  echo "Skipping Tup self-host init/upd during bootstrap (set TUP_WINDOWS_SELF_HOST_UPDATE=1 to enable for debugging)."
fi
'@

  Set-Content -LiteralPath $scriptPath -Value $scriptContent -Encoding ASCII
  return $scriptPath
}

function Apply-TupWindowsSourcePatches {
  param([Parameter(Mandatory = $true)][string]$SourceDir)

  $fstatatPath = Join-Path $SourceDir "src/compat/fstatat.c"
  if (-not (Test-Path -LiteralPath $fstatatPath -PathType Leaf)) {
    throw "Expected Tup source file '$fstatatPath' for Windows compatibility patching."
  }

  $originalContent = Get-Content -LiteralPath $fstatatPath -Raw -Encoding UTF8
  $stat64Pattern = [regex]'_stat64\(pathname,\s*buf\)'
  $matchCount = $stat64Pattern.Matches($originalContent).Count
  if ($matchCount -eq 0) {
    Write-Host "Tup transient patch: no _stat64(pathname, buf) callsites found in src/compat/fstatat.c; assuming upstream already carries a compatible Windows fix."
  } else {
    $patchedContent = $stat64Pattern.Replace($originalContent, 'stat(pathname, buf)')
    if ([string]::Equals($originalContent, $patchedContent, [System.StringComparison]::Ordinal)) {
      throw "Failed to apply transient Windows patch for Tup src/compat/fstatat.c."
    }

    Set-Content -LiteralPath $fstatatPath -Value $patchedContent -Encoding UTF8
    Write-Host "Applied transient Tup Windows source patch in src/compat/fstatat.c: replaced $matchCount _stat64(pathname, buf) callsite(s) with stat(pathname, buf)."
  }

  $lstatPath = Join-Path $SourceDir "src/compat/win32/lstat.c"
  if (-not (Test-Path -LiteralPath $lstatPath -PathType Leaf)) {
    throw "Expected Tup source file '$lstatPath' for Windows compatibility patching."
  }

  $originalLstatContent = Get-Content -LiteralPath $lstatPath -Raw -Encoding UTF8
  $wstat64Pattern = [regex]'_wstat64\(wpathname,\s*buf\)'
  $wstatPattern = [regex]'_wstat\(wpathname,\s*buf\)'
  $wstat64MatchCount = $wstat64Pattern.Matches($originalLstatContent).Count
  $wstatMatchCount = $wstatPattern.Matches($originalLstatContent).Count
  $totalLstatMatchCount = $wstat64MatchCount + $wstatMatchCount
  if ($totalLstatMatchCount -eq 0) {
    Write-Host "Tup transient patch: no _wstat64(wpathname, buf) or _wstat(wpathname, buf) callsites found in src/compat/win32/lstat.c; assuming upstream already carries a compatible Windows fix."
  } else {
    $patchedLstatContent = $wstat64Pattern.Replace($originalLstatContent, 'stat(pathname, buf)')
    $patchedLstatContent = $wstatPattern.Replace($patchedLstatContent, 'stat(pathname, buf)')
    if ([string]::Equals($originalLstatContent, $patchedLstatContent, [System.StringComparison]::Ordinal)) {
      throw "Failed to apply transient Windows patch for Tup src/compat/win32/lstat.c."
    }

    Set-Content -LiteralPath $lstatPath -Value $patchedLstatContent -Encoding UTF8
    Write-Host "Applied transient Tup Windows source patch in src/compat/win32/lstat.c: replaced $wstat64MatchCount _wstat64(wpathname, buf) and $wstatMatchCount _wstat(wpathname, buf) callsite(s) with stat(pathname, buf)."
  }

  $win32TupPath = Join-Path $SourceDir "win32.tup"
  if (-not (Test-Path -LiteralPath $win32TupPath -PathType Leaf)) {
    $win32TupContent = @'
# Transient bootstrap compatibility stub for Windows source mode.
# This is synthesized only in codetracer's temporary Tup source checkout.
# Intentionally empty: Tuprules.tup includes win32.tup for platform overrides.
'@
    Set-Content -LiteralPath $win32TupPath -Value $win32TupContent -Encoding ASCII
    Write-Host "Applied transient Tup Windows source patch: created minimal win32.tup include stub."
  } else {
    Write-Host "Tup transient patch: win32.tup already exists; leaving source file unchanged."
  }

  $serverTupfilePath = Join-Path $SourceDir "src/tup/server/Tupfile"
  if (-not (Test-Path -LiteralPath $serverTupfilePath -PathType Leaf)) {
    throw "Expected Tup source file '$serverTupfilePath' for Windows compatibility patching."
  }

  $originalServerTupfile = Get-Content -LiteralPath $serverTupfilePath -Raw -Encoding UTF8
  $serverFuseRulePattern = [regex]'(?m)^: foreach fuse_server\.c fuse_fs\.c master_fork\.c \|> !cc \|>\s*\r?\n?'
  $serverFuseRuleMatches = $serverFuseRulePattern.Matches($originalServerTupfile).Count
  if ($serverFuseRuleMatches -eq 0) {
    Write-Host "Tup transient patch: no fused server !cc rule found in src/tup/server/Tupfile; assuming upstream already carries a compatible Windows fix."
  } else {
    $patchedServerTupfile = $serverFuseRulePattern.Replace($originalServerTupfile, '')
    if ([string]::Equals($originalServerTupfile, $patchedServerTupfile, [System.StringComparison]::Ordinal)) {
      throw "Failed to apply transient Windows patch for Tup src/tup/server/Tupfile."
    }

    Set-Content -LiteralPath $serverTupfilePath -Value $patchedServerTupfile -Encoding UTF8
    Write-Host "Applied transient Tup Windows source patch in src/tup/server/Tupfile: removed $serverFuseRuleMatches fused server !cc rule(s) (fuse_server.c/fuse_fs.c/master_fork.c) while keeping windepfile.c on !mingwcc."
  }

  $flockTupfilePath = Join-Path $SourceDir "src/tup/flock/Tupfile"
  if (-not (Test-Path -LiteralPath $flockTupfilePath -PathType Leaf)) {
    throw "Expected Tup source file '$flockTupfilePath' for Windows compatibility patching."
  }

  $originalFlockTupfile = Get-Content -LiteralPath $flockTupfilePath -Raw -Encoding UTF8
  $flockFcntlRulePattern = [regex]'(?m)^: foreach fcntl\.c \|> !cc \|>\s*\r?\n?'
  $flockFcntlRuleMatches = $flockFcntlRulePattern.Matches($originalFlockTupfile).Count
  if ($flockFcntlRuleMatches -eq 0) {
    Write-Host "Tup transient patch: no fcntl !cc rule found in src/tup/flock/Tupfile; assuming upstream already carries a compatible Windows fix."
  } else {
    $patchedFlockTupfile = $flockFcntlRulePattern.Replace($originalFlockTupfile, '')
    if ([string]::Equals($originalFlockTupfile, $patchedFlockTupfile, [System.StringComparison]::Ordinal)) {
      throw "Failed to apply transient Windows patch for Tup src/tup/flock/Tupfile."
    }

    Set-Content -LiteralPath $flockTupfilePath -Value $patchedFlockTupfile -Encoding UTF8
    Write-Host "Applied transient Tup Windows source patch in src/tup/flock/Tupfile: removed $flockFcntlRuleMatches fcntl !cc rule(s) while keeping lock_file.c !mingwcc."
  }

  $rootTupfilePath = Join-Path $SourceDir "Tupfile"
  if (-not (Test-Path -LiteralPath $rootTupfilePath -PathType Leaf)) {
    throw "Expected Tup source file '$rootTupfilePath' for Windows compatibility patching."
  }

  $originalRootTupfile = Get-Content -LiteralPath $rootTupfilePath -Raw -Encoding UTF8
  $rootFcntlClientObjPattern = [regex]'(?m)^client_objs \+= src/tup/flock/fcntl\.o\s*\r?\n?'
  $rootFcntlClientObjMatches = $rootFcntlClientObjPattern.Matches($originalRootTupfile).Count
  if ($rootFcntlClientObjMatches -eq 0) {
    Write-Host "Tup transient patch: no src/tup/flock/fcntl.o client_objs entry found in root Tupfile; assuming upstream already carries a compatible Windows fix."
  } else {
    $patchedRootTupfile = $rootFcntlClientObjPattern.Replace($originalRootTupfile, '')
    if ([string]::Equals($originalRootTupfile, $patchedRootTupfile, [System.StringComparison]::Ordinal)) {
      throw "Failed to apply transient Windows patch for Tup root Tupfile client_objs."
    }

    Set-Content -LiteralPath $rootTupfilePath -Value $patchedRootTupfile -Encoding UTF8
    Write-Host "Applied transient Tup Windows source patch in Tupfile: removed $rootFcntlClientObjMatches src/tup/flock/fcntl.o client_objs entry(ies)."
  }
}

function Ensure-TupFromSource {
  param([Parameter(Mandatory = $true)][string]$Root)

  $tupRepo = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_SOURCE_REPO")
  if ([string]::IsNullOrWhiteSpace($tupRepo)) {
    $tupRepo = $toolchain.tupSourceRepo
  } else {
    $tupRepo = $tupRepo.Trim()
  }
  $tupRef = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_SOURCE_REF")
  if ([string]::IsNullOrWhiteSpace($tupRef)) {
    $tupRef = $toolchain.tupSourceRef
  } else {
    $tupRef = $tupRef.Trim()
  }
  $tupRevisionOverride = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_SOURCE_REVISION")
  $buildCommand = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_SOURCE_BUILD_COMMAND")
  if ([string]::IsNullOrWhiteSpace($buildCommand)) {
    $buildCommand = $toolchain.tupSourceBuildCommand
  } else {
    $buildCommand = $buildCommand.Trim()
  }
  $useCodetracerBootstrapScript = [string]::Equals($buildCommand, $toolchain.tupSourceBuildCommand, [System.StringComparison]::Ordinal)
  $effectiveBuildCommandIdentity = if ($useCodetracerBootstrapScript) {
    "codetracer-bootstrap-windows.sh@v14"
  } else {
    "custom:$buildCommand"
  }

  $buildCommandBashEscaped = $buildCommand.Replace("'", "'\''")
  $tupRevision = if ([string]::IsNullOrWhiteSpace($tupRevisionOverride)) {
    Resolve-GitRefToRevision -Repository $tupRepo -RefName $tupRef
  } else {
    $tupRevisionOverride.Trim().ToLowerInvariant()
  }

  $gitCommand = Get-Command git -ErrorAction SilentlyContinue
  if ($null -eq $gitCommand -or [string]::IsNullOrWhiteSpace($gitCommand.Source)) {
    throw "git is required for Tup source bootstrap but was not found on PATH."
  }
  $msys2 = Ensure-TupMsys2BuildPrereqs -Root $Root
  $msysBashExe = [string]$msys2.bashExe
  $msysBinDir = Join-Path ([string]$msys2.root) "usr/bin"
  $msysMingwBinDir = Join-Path ([string]$msys2.root) "mingw64/bin"
  $msysMingw32BinDir = Join-Path ([string]$msys2.root) "mingw32/bin"
  $msysBinDirForBash = ConvertTo-BashPath -WindowsPath $msysBinDir
  $msysMingwBinDirForBash = ConvertTo-BashPath -WindowsPath $msysMingwBinDir
  $msysMingw32BinDirForBash = ConvertTo-BashPath -WindowsPath $msysMingw32BinDir

  $tupRoot = Join-Path $Root "tup"
  $sourceCacheRoot = Join-Path $tupRoot "cache/source"
  $cacheInputMetadata = @{
    tup_mode = "source"
    tup_source_repo = $tupRepo
    tup_source_ref = $tupRef
    tup_source_revision = $tupRevision
    tup_source_build_command = $buildCommand
    tup_source_effective_build_command = $effectiveBuildCommandIdentity
    tup_msys2_version = [string]$msys2.metadata.tup_msys2_version
    tup_msys2_packages = [string]$msys2.metadata.tup_msys2_packages
  }
  $cacheInputString = (($cacheInputMetadata.Keys | Sort-Object | ForEach-Object { "$_=$($cacheInputMetadata[$_])" }) -join "`n")
  $cacheKey = Get-Sha256HexForString -Value $cacheInputString
  $cacheRoot = Join-Path $sourceCacheRoot $cacheKey
  $installDir = Join-Path $cacheRoot "install"
  $tupExe = Join-Path $installDir "tup.exe"
  $sourceMetaFile = Join-Path $cacheRoot "tup.source.meta"

  if ((Test-Path -LiteralPath $tupExe -PathType Leaf) -and (Test-Path -LiteralPath $sourceMetaFile -PathType Leaf)) {
    $installedMetadata = Read-KeyValueFile -Path $sourceMetaFile
    if (Test-KeyValueFileMatches -Expected $cacheInputMetadata -Actual $installedMetadata) {
      $null = Get-TupVersionLine -TupExe $tupExe
      Write-Host "Tup source cache hit at $installDir"
      return @{
        mode = "source"
        installDir = $installDir
        metadata = $cacheInputMetadata
      }
    }
  }

  $stagingRoot = Join-Path $env:TEMP "codetracer-tup-source-$cacheKey"
  Ensure-CleanDirectory -Path $stagingRoot
  $sourceDir = Join-Path $stagingRoot "tup-src"
  try {
    Write-Host "Building Tup from source (cache key: $cacheKey)"
    & $gitCommand.Source clone $tupRepo $sourceDir
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to clone Tup repository '$tupRepo'."
    }
    & $gitCommand.Source -C $sourceDir checkout --detach $tupRevision
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to checkout Tup revision '$tupRevision'."
    }
    Apply-TupWindowsSourcePatches -SourceDir $sourceDir

    $sourceDirForBash = ConvertTo-BashPath -WindowsPath $sourceDir
    if ($useCodetracerBootstrapScript) {
      $generatedScriptPath = New-TupWindowsBootstrapScript -SourceDir $sourceDir
      $generatedScriptPathForBash = ConvertTo-BashPath -WindowsPath $generatedScriptPath
      $bootstrapScript = "set -euo pipefail; export PATH='${msysMingwBinDirForBash}:${msysMingw32BinDirForBash}:${msysBinDirForBash}:`$PATH'; export TUP_MINGW=1; export TUP_MINGW32=0; cd '$sourceDirForBash'; chmod +x '$generatedScriptPathForBash'; '$generatedScriptPathForBash'"
    } else {
      $bootstrapScript = "set -euo pipefail; export PATH='${msysMingwBinDirForBash}:${msysMingw32BinDirForBash}:${msysBinDirForBash}:`$PATH'; export TUP_MINGW=1; export TUP_MINGW32=0; cd '$sourceDirForBash'; $buildCommandBashEscaped"
    }
    & $msysBashExe -lc $bootstrapScript
    if ($LASTEXITCODE -ne 0) {
      throw "Tup source bootstrap command failed: $effectiveBuildCommandIdentity (requested: $buildCommand, MSYS2 shell '$msysBashExe')."
    }

    $candidatePaths = @(
      (Join-Path $sourceDir "tup.exe"),
      (Join-Path $sourceDir "tup"),
      (Join-Path $sourceDir "build/tup.exe"),
      (Join-Path $sourceDir "build/tup")
    )
    $builtTupPath = $candidatePaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($builtTupPath)) {
      throw "Tup source bootstrap did not produce a tup executable in expected locations."
    }

    Ensure-CleanDirectory -Path $cacheRoot
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    Copy-Item -LiteralPath $builtTupPath -Destination $tupExe -Force
    $builtTupDir = Split-Path -Path $builtTupPath -Parent
    $runtimeArtifacts = @("tup-dllinject.dll")
    foreach ($artifact in $runtimeArtifacts) {
      $artifactPath = Join-Path $builtTupDir $artifact
      if (Test-Path -LiteralPath $artifactPath -PathType Leaf) {
        Copy-Item -LiteralPath $artifactPath -Destination (Join-Path $installDir $artifact) -Force
      }
    }
    $null = Get-TupVersionLine -TupExe $tupExe
    Write-KeyValueFile -Path $sourceMetaFile -Values $cacheInputMetadata
  } finally {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
  }

  Write-Host "Installed Tup from source to $installDir"
  return @{
    mode = "source"
    installDir = $installDir
    metadata = $cacheInputMetadata
  }
}

function Ensure-Tup {
  param([Parameter(Mandatory = $true)][string]$Root)

  $requestedModeRaw = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_SOURCE_MODE")
  $requestedMode = if ([string]::IsNullOrWhiteSpace($requestedModeRaw)) { "prebuilt" } else { $requestedModeRaw.Trim().ToLowerInvariant() }
  $tupRoot = Join-Path $Root "tup"
  $installPathFile = Join-Path $tupRoot "tup.install.relative-path"
  $installMetaFile = Join-Path $tupRoot "tup.install.meta"

  $result = $null
  switch ($requestedMode) {
    "source" {
      $result = Ensure-TupFromSource -Root $Root
    }
    "prebuilt" {
      $result = Ensure-TupPrebuilt -Root $Root
    }
    "auto" {
      try {
        $result = Ensure-TupPrebuilt -Root $Root
      } catch {
        Write-Warning "Tup prebuilt bootstrap failed in auto mode. Falling back to source bootstrap. Error: $($_.Exception.Message)"
        $result = Ensure-TupFromSource -Root $Root
      }
    }
    default {
      throw "Unsupported TUP_WINDOWS_SOURCE_MODE '$requestedMode'. Supported values: auto, source, prebuilt."
    }
  }

  if ($result -is [array]) {
    $hashResult = $result | Where-Object { $_ -is [hashtable] -or $_ -is [System.Collections.IDictionary] } | Select-Object -Last 1
    if ($null -ne $hashResult) {
      $result = $hashResult
    }
  }
  if ($result -is [System.Collections.IDictionary] -and -not ($result -is [hashtable])) {
    $normalizedResult = @{}
    foreach ($entry in $result.GetEnumerator()) {
      $normalizedResult[[string]$entry.Key] = $entry.Value
    }
    $result = $normalizedResult
  }
  if ($null -eq $result -or -not $result.ContainsKey("installDir")) {
    throw "Tup bootstrap did not return an install directory."
  }

  $installDir = [string]$result.installDir
  $relativeInstallDir = ConvertTo-InstallRelativePath -AbsolutePath $installDir -Root $Root
  $selectedMetadata = @{
    requested_mode = $requestedMode
    effective_mode = [string]$result.mode
    install_relative_path = $relativeInstallDir
  }
  foreach ($key in $result.metadata.Keys) {
    $selectedMetadata[$key] = [string]$result.metadata[$key]
  }

  New-Item -ItemType Directory -Force -Path $tupRoot | Out-Null
  Set-Content -LiteralPath $installPathFile -Value $relativeInstallDir -Encoding ASCII
  Write-KeyValueFile -Path $installMetaFile -Values $selectedMetadata
}

function Get-NimCompilerVersion {
  param([Parameter(Mandatory = $true)][string]$NimExe)

  $firstLine = (& $NimExe --version | Select-Object -First 1)
  if ($firstLine -match 'Version\s+([0-9]+(?:\.[0-9]+)*(?:[-+][0-9A-Za-z.-]+)?)') {
    return $Matches[1]
  }

  throw "Unable to parse Nim version from '$NimExe': $firstLine"
}

function Ensure-NimPrebuilt {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch
  )

  $version = $toolchain.nimVersion
  $archiveSha256 = $toolchain.nimWinX64Sha256
  $nimArch = ConvertTo-NimFileArch -Arch $Arch
  $asset = "nim-$version`_$nimArch.zip"
  $shaAsset = "$asset.sha256"
  $nimVersionRoot = Join-Path $Root "nim/$version"
  $prebuiltRoot = Join-Path $nimVersionRoot "prebuilt"
  $extractDir = Join-Path $prebuiltRoot "nim-$version"
  $nimExe = Join-Path $extractDir "bin/nim.exe"
  $versionFile = Join-Path $prebuiltRoot "nim.version"
  $shaFile = Join-Path $prebuiltRoot "nim.archive.sha256"
  $sourceFile = Join-Path $prebuiltRoot "nim.source"

  if ((Test-Path $nimExe) -and (Test-Path $versionFile) -and (Test-Path $shaFile) -and (Test-Path $sourceFile)) {
    $installedVersionLine = Get-Content -LiteralPath $versionFile -ErrorAction SilentlyContinue | Select-Object -First 1
    $installedShaLine = Get-Content -LiteralPath $shaFile -ErrorAction SilentlyContinue | Select-Object -First 1
    $installedSourceLine = Get-Content -LiteralPath $sourceFile -ErrorAction SilentlyContinue | Select-Object -First 1
    $installedVersion = ([string]$installedVersionLine).Trim()
    $installedSha = ([string]$installedShaLine).Trim().ToLowerInvariant()
    $installedSource = ([string]$installedSourceLine).Trim()
    $detectedVersion = Get-NimCompilerVersion -NimExe $nimExe
    if (
      $installedVersion -eq $version -and
      $installedSha -eq $archiveSha256.ToLowerInvariant() -and
      $installedSource -eq "prebuilt|asset=$asset|sha256=$($archiveSha256.ToLowerInvariant())" -and
      $detectedVersion -eq $version
    ) {
      Write-Host "Nim $version already installed at $extractDir"
      return @{
        mode = "prebuilt"
        installDir = $extractDir
        metadata = @{
          nim_mode = "prebuilt"
          nim_version = $version
          nim_arch = $Arch
          nim_asset = $asset
          nim_archive_sha256 = $archiveSha256.ToLowerInvariant()
        }
      }
    }
  }

  New-Item -ItemType Directory -Force -Path $prebuiltRoot | Out-Null
  $baseUrl = "https://nim-lang.org/download"
  $zipUrl = "$baseUrl/$asset"
  $shaUrl = "$baseUrl/$shaAsset"
  $tempZip = Join-Path $env:TEMP $asset

  Download-File -Url $zipUrl -OutFile $tempZip
  try {
    $shaText = Download-String -Url $shaUrl
    $expectedFromSidecar = Get-ExpectedSha256 -ShaSource $shaText -AssetName $asset
    if ($expectedFromSidecar.ToLowerInvariant() -ne $archiveSha256.ToLowerInvariant()) {
      throw "Pinned Nim SHA256 '$archiveSha256' does not match upstream sidecar '$expectedFromSidecar' for '$asset'."
    }
    Assert-FileSha256 -Path $tempZip -Expected $archiveSha256

    Ensure-CleanDirectory -Path $prebuiltRoot
    Expand-Archive -Path $tempZip -DestinationPath $prebuiltRoot -Force

    if (-not (Test-Path $nimExe)) {
      throw "Nim extraction did not produce '$nimExe'."
    }

    $detectedVersion = Get-NimCompilerVersion -NimExe $nimExe
    if ($detectedVersion -ne $version) {
      throw "Nim bootstrap produced unexpected version '$detectedVersion' (expected '$version')."
    }

    $version | Out-File -LiteralPath $versionFile -Encoding ASCII -Force
    $archiveSha256.ToLowerInvariant() | Out-File -LiteralPath $shaFile -Encoding ASCII -Force
    "prebuilt|asset=$asset|sha256=$($archiveSha256.ToLowerInvariant())" | Out-File -LiteralPath $sourceFile -Encoding ASCII -Force
  } finally {
    Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
  }

  Write-Host "Installed Nim $version to $extractDir"
  return @{
    mode = "prebuilt"
    installDir = $extractDir
    metadata = @{
      nim_mode = "prebuilt"
      nim_version = $version
      nim_arch = $Arch
      nim_asset = $asset
      nim_archive_sha256 = $archiveSha256.ToLowerInvariant()
    }
  }
}

function Ensure-NimFromSource {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch
  )

  $version = $toolchain.nimVersion
  $nimVersionRoot = Join-Path $Root "nim/$version"
  $sourceCacheRoot = Join-Path $nimVersionRoot "cache/source"
  $nimRepo = [Environment]::GetEnvironmentVariable("NIM_WINDOWS_SOURCE_REPO")
  if ([string]::IsNullOrWhiteSpace($nimRepo)) {
    $nimRepo = $toolchain.nimSourceRepo
  }
  $nimRef = [Environment]::GetEnvironmentVariable("NIM_WINDOWS_SOURCE_REF")
  if ([string]::IsNullOrWhiteSpace($nimRef)) {
    $nimRef = $toolchain.nimSourceRef
  }
  $nimRevisionOverride = [Environment]::GetEnvironmentVariable("NIM_WINDOWS_SOURCE_REVISION")
  $csourcesRepo = [Environment]::GetEnvironmentVariable("NIM_WINDOWS_CSOURCES_REPO")
  if ([string]::IsNullOrWhiteSpace($csourcesRepo)) {
    $csourcesRepo = $toolchain.nimCsourcesRepo
  }
  $csourcesRef = [Environment]::GetEnvironmentVariable("NIM_WINDOWS_CSOURCES_REF")
  if ([string]::IsNullOrWhiteSpace($csourcesRef)) {
    $csourcesRef = $toolchain.nimCsourcesRef
  }
  $csourcesRevisionOverride = [Environment]::GetEnvironmentVariable("NIM_WINDOWS_CSOURCES_REVISION")

  $nimRevision = if ([string]::IsNullOrWhiteSpace($nimRevisionOverride)) {
    Resolve-GitRefToRevision -Repository $nimRepo -RefName $nimRef
  } else {
    $nimRevisionOverride.Trim().ToLowerInvariant()
  }
  $csourcesRevision = if ([string]::IsNullOrWhiteSpace($csourcesRevisionOverride)) {
    Resolve-GitRefToRevision -Repository $csourcesRepo -RefName $csourcesRef
  } else {
    $csourcesRevisionOverride.Trim().ToLowerInvariant()
  }
  Ensure-NimSourceCompilerEnvironment -Arch $Arch -Root $Root
  $compilerHint = Get-NimSourceCompilerHint
  $bootstrapCompilerMode = if ($Arch -eq "arm64") { "prebuilt-x64-fallback-if-needed" } else { "csources-bin-only" }
  $cacheInputMetadata = @{
    nim_mode = "source"
    nim_version = $version
    nim_arch = $Arch
    nim_repo = $nimRepo
    nim_ref = $nimRef
    nim_revision = $nimRevision
    csources_repo = $csourcesRepo
    csources_ref = $csourcesRef
    csources_revision = $csourcesRevision
    bootstrap_compiler_mode = $bootstrapCompilerMode
    compiler_hint = $compilerHint
  }
  $cacheInputString = (($cacheInputMetadata.Keys | Sort-Object | ForEach-Object { "$_=$($cacheInputMetadata[$_])" }) -join "`n")
  $cacheKey = Get-Sha256HexForString -Value $cacheInputString
  $cacheRoot = Join-Path $sourceCacheRoot $cacheKey
  $extractDir = Join-Path $cacheRoot "nim-$version"
  $nimExe = Join-Path $extractDir "bin/nim.exe"
  $sourceMetaFile = Join-Path $cacheRoot "nim.source.meta"

  if ((Test-Path -LiteralPath $nimExe -PathType Leaf) -and (Test-Path -LiteralPath $sourceMetaFile -PathType Leaf)) {
    $installedMetadata = Read-KeyValueFile -Path $sourceMetaFile
    $detectedVersion = Get-NimCompilerVersion -NimExe $nimExe
    if ((Test-KeyValueFileMatches -Expected $cacheInputMetadata -Actual $installedMetadata) -and $detectedVersion -eq $version) {
      Write-Host "Nim $version source cache hit at $extractDir"
      return @{
        mode = "source"
        installDir = $extractDir
        metadata = $cacheInputMetadata
      }
    }
  }

  $gitCommand = Get-Command git -ErrorAction SilentlyContinue
  if ($null -eq $gitCommand -or [string]::IsNullOrWhiteSpace($gitCommand.Source)) {
    throw "git is required for Nim source bootstrap but was not found on PATH."
  }

  $stagingRoot = Join-Path $env:TEMP "codetracer-nim-source-$cacheKey"
  Ensure-CleanDirectory -Path $stagingRoot
  $csourcesDir = Join-Path $stagingRoot "csources_v3"
  $nimSourceDir = Join-Path $stagingRoot "nim-src"

  try {
    Write-Host "Building Nim $version from source (cache key: $cacheKey)"
    & $gitCommand.Source clone $csourcesRepo $csourcesDir
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to clone Nim csources repository '$csourcesRepo'."
    }
    & $gitCommand.Source -C $csourcesDir checkout --detach $csourcesRevision
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to checkout csources revision '$csourcesRevision'."
    }

    & $gitCommand.Source clone $nimRepo $nimSourceDir
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to clone Nim repository '$nimRepo'."
    }
    & $gitCommand.Source -C $nimSourceDir checkout --detach $nimRevision
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to checkout Nim revision '$nimRevision'."
    }

    $bootstrapNim = Join-Path $csourcesDir "bin/nim.exe"
    if (-not (Test-Path -LiteralPath $bootstrapNim -PathType Leaf)) {
      if ($Arch -eq "arm64") {
        Write-Warning "Nim csources checkout did not provide '$bootstrapNim' for arm64; using pinned x64 Nim prebuilt compiler as bootstrap."
        $prebuiltBootstrap = Ensure-NimPrebuilt -Root $Root -Arch "x64"
        $bootstrapNim = Join-Path ([string]$prebuiltBootstrap.installDir) "bin/nim.exe"
      }
    }
    if (-not (Test-Path -LiteralPath $bootstrapNim -PathType Leaf)) {
      throw "Nim source bootstrap could not find a usable bootstrap compiler at '$bootstrapNim'."
    }

    $nimBinDir = Join-Path $nimSourceDir "bin"
    New-Item -ItemType Directory -Force -Path $nimBinDir | Out-Null
    Copy-Item -LiteralPath $bootstrapNim -Destination (Join-Path $nimBinDir "nim.exe") -Force
    $bootstrapVccExe = Join-Path (Split-Path -Parent $bootstrapNim) "vccexe.exe"
    if (Test-Path -LiteralPath $bootstrapVccExe -PathType Leaf) {
      Copy-Item -LiteralPath $bootstrapVccExe -Destination (Join-Path $nimBinDir "vccexe.exe") -Force
    }

    Push-Location $nimSourceDir
    try {
      $vcBinDir = [Environment]::GetEnvironmentVariable("NIM_WINDOWS_VC_BIN_DIR")
      if ([string]::IsNullOrWhiteSpace($vcBinDir)) {
        $env:Path = "$nimBinDir;$($env:Path)"
      } else {
        $env:Path = "$nimBinDir;$vcBinDir;$($env:Path)"
      }

      $effectiveCompiler = [Environment]::GetEnvironmentVariable("NIM_WINDOWS_SOURCE_CC_EFFECTIVE")
      $kochCompileArgs = @("c", "koch.nim")
      $kochBootArgs = @("boot", "-d:release")
      if ($effectiveCompiler -eq "vcc") {
        $kochCompileArgs = @("c", "--cc:vcc", "koch.nim")
        $kochBootArgs = @("boot", "-d:release", "--cc:vcc")
      } elseif ($effectiveCompiler -eq "gcc") {
        $kochCompileArgs = @("c", "--cc:gcc", "koch.nim")
        $kochBootArgs = @("boot", "-d:release", "--cc:gcc")
      }

      & $bootstrapNim @kochCompileArgs
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to compile Nim koch tool from source."
      }

      $kochExe = Join-Path $nimSourceDir "koch.exe"
      if (-not (Test-Path -LiteralPath $kochExe -PathType Leaf)) {
        throw "Nim source bootstrap did not produce '$kochExe'."
      }

      & $kochExe @kochBootArgs
      if ($LASTEXITCODE -ne 0) {
        throw "Nim source bootstrap failed while running 'koch boot -d:release'."
      }
    } finally {
      Pop-Location
    }

    $builtNimExe = Join-Path $nimSourceDir "bin/nim.exe"
    if (-not (Test-Path -LiteralPath $builtNimExe -PathType Leaf)) {
      throw "Nim source bootstrap did not produce '$builtNimExe'."
    }

    $detectedVersion = Get-NimCompilerVersion -NimExe $builtNimExe
    if ($detectedVersion -ne $version) {
      throw "Nim source bootstrap produced unexpected version '$detectedVersion' (expected '$version')."
    }

    Ensure-CleanDirectory -Path $cacheRoot
    New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
    foreach ($sourceEntry in (Get-ChildItem -LiteralPath $nimSourceDir -Force)) {
      Copy-Item -LiteralPath $sourceEntry.FullName -Destination $extractDir -Recurse -Force
    }
    Write-KeyValueFile -Path $sourceMetaFile -Values $cacheInputMetadata
  } finally {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
  }

  Write-Host "Installed Nim $version from source to $extractDir"
  return @{
    mode = "source"
    installDir = $extractDir
    metadata = $cacheInputMetadata
  }
}

function Ensure-Nim {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch
  )

  $requestedModeRaw = [Environment]::GetEnvironmentVariable("NIM_WINDOWS_SOURCE_MODE")
  $requestedMode = if ([string]::IsNullOrWhiteSpace($requestedModeRaw)) { "auto" } else { $requestedModeRaw.Trim().ToLowerInvariant() }
  $nimVersionRoot = Join-Path $Root "nim/$($toolchain.nimVersion)"
  $installPathFile = Join-Path $nimVersionRoot "nim.install.relative-path"
  $installMetaFile = Join-Path $nimVersionRoot "nim.install.meta"

  $result = $null
  switch ($requestedMode) {
    "prebuilt" {
      if ($Arch -ne "x64") {
        throw "NIM_WINDOWS_SOURCE_MODE=prebuilt is supported on Windows x64 only. Detected architecture '$Arch'. Use NIM_WINDOWS_SOURCE_MODE=source to attempt source bootstrap on this architecture."
      }
      $result = Ensure-NimPrebuilt -Root $Root -Arch $Arch
    }
    "source" {
      $result = Ensure-NimFromSource -Root $Root -Arch $Arch
    }
    "auto" {
      try {
        $result = Ensure-NimFromSource -Root $Root -Arch $Arch
      } catch {
        if ($Arch -ne "x64") {
          throw "NIM_WINDOWS_SOURCE_MODE=auto attempted Nim source bootstrap on '$Arch' and failed: $($_.Exception.Message) Prebuilt fallback is x64-only. Re-run with NIM_WINDOWS_SOURCE_MODE=source after fixing the source-bootstrap issue."
        }
        Write-Warning "Nim source bootstrap failed in auto mode. Falling back to pinned prebuilt asset. Error: $($_.Exception.Message)"
        $result = Ensure-NimPrebuilt -Root $Root -Arch $Arch
      }
    }
    default {
      throw "Unsupported NIM_WINDOWS_SOURCE_MODE '$requestedMode'. Supported values: auto, source, prebuilt."
    }
  }

  if ($result -is [array]) {
    $hashResult = $result | Where-Object { $_ -is [hashtable] -or $_ -is [System.Collections.IDictionary] } | Select-Object -Last 1
    if ($null -ne $hashResult) {
      $result = $hashResult
    }
  }

  if ($result -is [System.Collections.IDictionary] -and -not ($result -is [hashtable])) {
    $normalizedResult = @{}
    foreach ($entry in $result.GetEnumerator()) {
      $normalizedResult[[string]$entry.Key] = $entry.Value
    }
    $result = $normalizedResult
  }

  if ($null -eq $result -or -not $result.ContainsKey("installDir")) {
    throw "Nim bootstrap did not return an install directory."
  }

  $installDir = [string]$result.installDir
  $relativeInstallDir = ConvertTo-InstallRelativePath -AbsolutePath $installDir -Root $Root
  $selectedMetadata = @{
    requested_mode = $requestedMode
    effective_mode = [string]$result.mode
    nim_version = $toolchain.nimVersion
    nim_arch = $Arch
    install_relative_path = $relativeInstallDir
  }
  foreach ($key in $result.metadata.Keys) {
    $selectedMetadata[$key] = [string]$result.metadata[$key]
  }

  New-Item -ItemType Directory -Force -Path $nimVersionRoot | Out-Null
  Set-Content -LiteralPath $installPathFile -Value $relativeInstallDir -Encoding ASCII
  Write-KeyValueFile -Path $installMetaFile -Values $selectedMetadata
}

function Ensure-Rust {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch
  )

  $rustToolchain = $toolchain.rustToolchain
  $rustupVersion = $toolchain.rustupVersion
  $rustTarget = ConvertTo-RustTarget -Arch $Arch
  $rustupHome = Join-Path $Root "rustup"
  $cargoHome = Join-Path $Root "cargo"
  $rustcExe = Join-Path $cargoHome "bin/rustc.exe"
  $rustupExe = Join-Path $cargoHome "bin/rustup.exe"

  function Ensure-RustComponents {
    param(
      [Parameter(Mandatory = $true)][string]$RustupExe,
      [Parameter(Mandatory = $true)][string]$Toolchain
    )

    if (-not (Test-Path -LiteralPath $RustupExe -PathType Leaf)) {
      throw "Rustup executable missing at '$RustupExe'."
    }

    & $RustupExe component add clippy --toolchain $Toolchain | Out-Null
  }

  if (Test-Path $rustcExe) {
    $current = (& $rustcExe --version)
    if ($current.StartsWith("rustc $rustToolchain ")) {
      Write-Host "Rust $rustToolchain already installed at $cargoHome"
      $env:RUSTUP_HOME = $rustupHome
      $env:CARGO_HOME = $cargoHome
      Ensure-RustComponents -RustupExe $rustupExe -Toolchain $rustToolchain
      return
    }
  }

  New-Item -ItemType Directory -Force -Path $rustupHome | Out-Null
  New-Item -ItemType Directory -Force -Path $cargoHome | Out-Null

  $baseUrl = "https://static.rust-lang.org/rustup/archive/$rustupVersion/$rustTarget"
  $exeUrl = "$baseUrl/rustup-init.exe"
  $shaUrl = "$baseUrl/rustup-init.exe.sha256"
  $tempExe = Join-Path $env:TEMP "rustup-init-$rustupVersion-$rustTarget.exe"

  Download-File -Url $exeUrl -OutFile $tempExe
  $shaText = Download-String -Url $shaUrl
  $expected = Get-ExpectedSha256 -ShaSource $shaText -AssetName "rustup-init.exe"
  Assert-FileSha256 -Path $tempExe -Expected $expected

  $env:RUSTUP_HOME = $rustupHome
  $env:CARGO_HOME = $cargoHome

  & $tempExe -y --default-toolchain $rustToolchain --profile minimal --no-modify-path
  Remove-Item -LiteralPath $tempExe -Force

  if (-not (Test-Path $rustcExe)) {
    throw "Rust bootstrap did not produce '$rustcExe'."
  }

  $installed = (& $rustcExe --version)
  if (-not $installed.StartsWith("rustc $rustToolchain ")) {
    throw "Rust bootstrap produced unexpected version: $installed"
  }

  Ensure-RustComponents -RustupExe $rustupExe -Toolchain $rustToolchain
  Write-Host "Installed Rust toolchain $rustToolchain with rustup $rustupVersion"
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

  if ([string]$node.locked.type -ne "github") {
    throw "flake.lock node '$NodeName' must be github-locked. Found type '$($node.locked.type)'."
  }

  $owner = [string]$node.locked.owner
  $repo = [string]$node.locked.repo
  $rev = [string]$node.locked.rev
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
    url = "https://github.com/$owner/$repo.git"
  }
}

function Ensure-Nargo {
  param([Parameter(Mandatory = $true)][string]$Root)

  $cargoHome = Join-Path $Root "cargo"
  $rustupHome = Join-Path $Root "rustup"
  $cargoExe = Join-Path $cargoHome "bin/cargo.exe"
  if (-not (Test-Path -LiteralPath $cargoExe -PathType Leaf)) {
    throw "Nargo bootstrap requires '$cargoExe'. Run Rust bootstrap first."
  }

  $env:CARGO_HOME = $cargoHome
  $env:RUSTUP_HOME = $rustupHome

  $gitCommand = Get-Command git -ErrorAction SilentlyContinue
  if ($null -eq $gitCommand -or [string]::IsNullOrWhiteSpace($gitCommand.Source)) {
    throw "git is required for nargo source bootstrap but was not found on PATH."
  }
  $rustupExe = Join-Path $cargoHome "bin/rustup.exe"
  if (-not (Test-Path -LiteralPath $rustupExe -PathType Leaf)) {
    throw "Nargo bootstrap requires '$rustupExe'. Run Rust bootstrap first."
  }

  $repoRoot = Resolve-AbsolutePathFromScriptRoot -PathValue "../.."
  $flakeLockPath = Join-Path $repoRoot "flake.lock"
  $noir = Get-FlakeLockedGithubNode -FlakeLockPath $flakeLockPath -NodeName "noir"

  $nargoRoot = Join-Path $Root "nargo"
  $cacheRoot = Join-Path $nargoRoot "cache/source/$($noir.rev)"
  $sourceDir = Join-Path $cacheRoot "noir"
  $installDir = Join-Path $nargoRoot "cache/source/$($noir.rev)/install"
  $nargoExe = Join-Path $installDir "nargo.exe"
  $installPathFile = Join-Path $nargoRoot "nargo.install.relative-path"
  $installMetaFile = Join-Path $nargoRoot "nargo.install.meta"

  $expectedMetadata = @{
    source = "github"
    owner = $noir.owner
    repo = $noir.repo
    revision = $noir.rev
    repository = $noir.url
    rust_toolchain = "nightly"
  }

  if ((Test-Path -LiteralPath $nargoExe -PathType Leaf) -and (Test-Path -LiteralPath $installMetaFile -PathType Leaf)) {
    $existingMeta = Read-KeyValueFile -Path $installMetaFile
    if (Test-KeyValueFileMatches -Expected $expectedMetadata -Actual $existingMeta) {
      $relativeInstallDir = ConvertTo-InstallRelativePath -AbsolutePath $installDir -Root $Root
      Set-Content -LiteralPath $installPathFile -Value $relativeInstallDir -Encoding ASCII
      Write-Host "nargo source cache hit at $installDir"
      return
    }
  }

  Ensure-CleanDirectory -Path $cacheRoot
  New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
  New-Item -ItemType Directory -Force -Path $installDir | Out-Null

  & $gitCommand.Source -c core.longpaths=true clone $noir.url $sourceDir
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to clone Noir repository '$($noir.url)'."
  }

  & $gitCommand.Source -c core.longpaths=true -C $sourceDir checkout $noir.rev
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to checkout Noir revision '$($noir.rev)'."
  }

  $nargoCargoTomlPath = Join-Path $sourceDir "tooling/nargo_cli/Cargo.toml"
  if (-not (Test-Path -LiteralPath $nargoCargoTomlPath -PathType Leaf)) {
    throw "Expected nargo_cli Cargo.toml at '$nargoCargoTomlPath'."
  }
  $nargoCargoTomlContent = Get-Content -LiteralPath $nargoCargoTomlPath -Raw -Encoding UTF8
  if ($nargoCargoTomlContent -match '(?m)^termion\s*=\s*"3\.0\.0"\s*$') {
    $patchedNargoCargoTomlContent = [regex]::Replace(
      $nargoCargoTomlContent,
      '(?m)^termion\s*=\s*"3\.0\.0"\s*$',
      ''
    )
    Set-Content -LiteralPath $nargoCargoTomlPath -Value $patchedNargoCargoTomlContent -Encoding UTF8
  }

  $compileCmdPath = Join-Path $sourceDir "tooling/nargo_cli/src/cli/compile_cmd.rs"
  if (-not (Test-Path -LiteralPath $compileCmdPath -PathType Leaf)) {
    throw "Expected nargo_cli compile command source at '$compileCmdPath'."
  }
  $compileCmdContent = Get-Content -LiteralPath $compileCmdPath -Raw -Encoding UTF8
  $compileCmdPatched = $compileCmdContent.
    Replace('write!(screen, "{}", termion::cursor::Save).unwrap();', 'write!(screen, "\x1b[s").unwrap();').
    Replace('write!(screen, "{}{}", termion::cursor::Restore, termion::clear::AfterCursor).unwrap();', 'write!(screen, "{}{}", "\x1b[u", "\x1b[J").unwrap();')
  Set-Content -LiteralPath $compileCmdPath -Value $compileCmdPatched -Encoding UTF8

  $msys2 = Ensure-TupMsys2BuildPrereqs -Root $Root
  $msysBashExe = [string]$msys2.bashExe
  $msysMingwBinDir = Join-Path ([string]$msys2.root) "mingw64/bin"
  $clangExe = Join-Path $msysMingwBinDir "clang.exe"
  if (-not (Test-Path -LiteralPath $clangExe -PathType Leaf)) {
    & $msysBashExe -lc "set -euo pipefail; pacman -Sy --noconfirm --needed mingw-w64-x86_64-clang"
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to install MSYS2 clang prerequisite for nargo bootstrap."
    }
  }

  $msvcExportScript = Join-Path $PSScriptRoot "export-msvc-env.ps1"
  if (Test-Path -LiteralPath $msvcExportScript -PathType Leaf) {
    $msvcEnvLines = & pwsh -NoProfile -ExecutionPolicy Bypass -File $msvcExportScript
    foreach ($line in $msvcEnvLines) {
      if ([string]::IsNullOrWhiteSpace($line) -or ($line -notmatch "=")) {
        continue
      }
      $separatorIndex = $line.IndexOf("=")
      if ($separatorIndex -lt 1) {
        continue
      }
      $name = $line.Substring(0, $separatorIndex)
      $value = $line.Substring($separatorIndex + 1)
      Set-Item -Path "Env:$name" -Value $value
    }
  }
  $env:Path = "$msysMingwBinDir;$($env:Path)"

  Push-Location $sourceDir
  try {
    & $rustupExe toolchain install nightly --profile minimal
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to install nightly toolchain required for nargo bootstrap."
    }
    & $cargoExe +nightly build --release -p nargo_cli --bin nargo
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to build nargo from '$sourceDir'."
    }
  } finally {
    Pop-Location
  }

  $builtNargoCandidates = @(
    (Join-Path $sourceDir "target/release/nargo.exe"),
    (Join-Path $sourceDir "target/release/nargo")
  )
  $builtNargo = $builtNargoCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
  if ([string]::IsNullOrWhiteSpace($builtNargo)) {
    throw "Noir build did not produce a nargo executable in target/release."
  }

  Copy-Item -LiteralPath $builtNargo -Destination $nargoExe -Force

  $relativeInstallDir = ConvertTo-InstallRelativePath -AbsolutePath $installDir -Root $Root
  Write-KeyValueFile -Path $installMetaFile -Values $expectedMetadata
  Set-Content -LiteralPath $installPathFile -Value $relativeInstallDir -Encoding ASCII

  Write-Host "Installed nargo from flake.lock noir revision $($noir.rev) to $installDir"
}

$resolvedRoot = Resolve-Path -LiteralPath (New-Item -ItemType Directory -Force -Path $InstallRoot).FullName
$arch = Get-WindowsArch

Write-Host "Windows DIY bootstrap install root: $resolvedRoot"
Write-Host "Detected architecture: $arch"

if (Test-BootstrapStepEnabled -Step "RUST") { Ensure-Rust -Root $resolvedRoot -Arch $arch }
if (Test-BootstrapStepEnabled -Step "NARGO") { Ensure-Nargo -Root $resolvedRoot }
if (Test-BootstrapStepEnabled -Step "NODE") { Ensure-Node -Root $resolvedRoot -Arch $arch }
if (Test-BootstrapStepEnabled -Step "UV") { Ensure-Uv -Root $resolvedRoot -Arch $arch }
if (Test-BootstrapStepEnabled -Step "NIM") { Ensure-Nim -Root $resolvedRoot -Arch $arch }
if (Test-BootstrapStepEnabled -Step "CAPNP") { Ensure-Capnp -Root $resolvedRoot -Arch $arch }
if (Test-BootstrapStepEnabled -Step "TUP") { Ensure-Tup -Root $resolvedRoot }
if (Test-BootstrapStepEnabled -Step "CT_REMOTE") { Ensure-CtRemote -Root $resolvedRoot -Arch $arch }

Write-Host "Bootstrap complete."
Write-Host "RUSTUP_HOME=$(Join-Path $resolvedRoot 'rustup')"
Write-Host "CARGO_HOME=$(Join-Path $resolvedRoot 'cargo')"
$nargoInstallMetaFile = Join-Path $resolvedRoot "nargo/nargo.install.meta"
if (Test-Path -LiteralPath $nargoInstallMetaFile -PathType Leaf) {
  $nargoInstallMeta = Read-KeyValueFile -Path $nargoInstallMetaFile
  if ($nargoInstallMeta.ContainsKey("revision")) {
    Write-Host "NARGO_NOIR_REVISION=$($nargoInstallMeta['revision'])"
  }
  $nargoInstallPathFile = Join-Path $resolvedRoot "nargo/nargo.install.relative-path"
  if (Test-Path -LiteralPath $nargoInstallPathFile -PathType Leaf) {
    $nargoRelativePath = (Get-Content -LiteralPath $nargoInstallPathFile -Raw).Trim()
    if (-not [string]::IsNullOrWhiteSpace($nargoRelativePath)) {
      Write-Host "NARGO_DIR=$(Join-Path $resolvedRoot $nargoRelativePath)"
    }
  }
}
Write-Host "NODE_VERSION=$($toolchain.nodeVersion)"
Write-Host "UV_VERSION=$($toolchain.uvVersion)"
Write-Host "DOTNET_SDK_VERSION=$($toolchain.dotnetSdkVersion)"
Write-Host "NIM_VERSION=$($toolchain.nimVersion)"
$nimInstallMetaFile = Join-Path $resolvedRoot "nim/$($toolchain.nimVersion)/nim.install.meta"
if (Test-Path -LiteralPath $nimInstallMetaFile -PathType Leaf) {
  $nimInstallMeta = Read-KeyValueFile -Path $nimInstallMetaFile
  if ($nimInstallMeta.ContainsKey("requested_mode")) {
    Write-Host "NIM_WINDOWS_SOURCE_MODE_REQUESTED=$($nimInstallMeta['requested_mode'])"
  }
  if ($nimInstallMeta.ContainsKey("effective_mode")) {
    Write-Host "NIM_WINDOWS_SOURCE_MODE_EFFECTIVE=$($nimInstallMeta['effective_mode'])"
  }
  if ($nimInstallMeta.ContainsKey("install_relative_path")) {
    Write-Host "NIM_INSTALL_RELATIVE_PATH=$($nimInstallMeta['install_relative_path'])"
  }
}
Write-Host "CT_REMOTE_VERSION=$($toolchain.ctRemoteVersion)"
Write-Host "CT_REMOTE_DIR=$(Join-Path $resolvedRoot "ct-remote/$($toolchain.ctRemoteVersion)")"
$effectiveCtRemoteMode = [Environment]::GetEnvironmentVariable("CT_REMOTE_WINDOWS_SOURCE_MODE")
if ([string]::IsNullOrWhiteSpace($effectiveCtRemoteMode)) { $effectiveCtRemoteMode = "auto" }
$effectiveCtRemoteRepo = [Environment]::GetEnvironmentVariable("CT_REMOTE_WINDOWS_SOURCE_REPO")
if ([string]::IsNullOrWhiteSpace($effectiveCtRemoteRepo)) { $effectiveCtRemoteRepo = "../../../codetracer-ci" }
$effectiveCtRemoteRepo = Resolve-AbsolutePathFromScriptRoot -PathValue $effectiveCtRemoteRepo
$effectiveCtRemotePublishScript = [Environment]::GetEnvironmentVariable("CT_REMOTE_WINDOWS_PUBLISH_SCRIPT")
if ([string]::IsNullOrWhiteSpace($effectiveCtRemotePublishScript)) {
  $effectiveCtRemotePublishScript = Join-Path $effectiveCtRemoteRepo "non-nix-build/windows/publish-desktop-client.ps1"
} else {
  $effectiveCtRemotePublishScript = Resolve-AbsolutePathWithBase -PathValue $effectiveCtRemotePublishScript -BasePath $effectiveCtRemoteRepo
}
$effectiveCtRemoteRid = [Environment]::GetEnvironmentVariable("CT_REMOTE_WINDOWS_SOURCE_RID")
if ([string]::IsNullOrWhiteSpace($effectiveCtRemoteRid)) { $effectiveCtRemoteRid = Get-DefaultCtRemoteSourceRid -Arch $arch }
Write-Host "CT_REMOTE_WINDOWS_SOURCE_MODE=$effectiveCtRemoteMode"
Write-Host "CT_REMOTE_WINDOWS_SOURCE_REPO=$effectiveCtRemoteRepo"
Write-Host "CT_REMOTE_WINDOWS_PUBLISH_SCRIPT=$effectiveCtRemotePublishScript"
Write-Host "CT_REMOTE_WINDOWS_SOURCE_RID=$effectiveCtRemoteRid"
Write-Host "CAPNP_VERSION=$($toolchain.capnpVersion)"
$effectiveCapnpMode = [Environment]::GetEnvironmentVariable("CAPNP_WINDOWS_SOURCE_MODE")
if ([string]::IsNullOrWhiteSpace($effectiveCapnpMode)) { $effectiveCapnpMode = "auto" }
$effectiveCapnpRepo = [Environment]::GetEnvironmentVariable("CAPNP_WINDOWS_SOURCE_REPO")
if ([string]::IsNullOrWhiteSpace($effectiveCapnpRepo)) { $effectiveCapnpRepo = $toolchain.capnpSourceRepo }
$effectiveCapnpRef = [Environment]::GetEnvironmentVariable("CAPNP_WINDOWS_SOURCE_REF")
if ([string]::IsNullOrWhiteSpace($effectiveCapnpRef)) { $effectiveCapnpRef = $toolchain.capnpSourceRef }
Write-Host "CAPNP_WINDOWS_SOURCE_MODE=$effectiveCapnpMode"
Write-Host "CAPNP_WINDOWS_SOURCE_REPO=$effectiveCapnpRepo"
Write-Host "CAPNP_WINDOWS_SOURCE_REF=$effectiveCapnpRef"
$capnpInstallMetaFile = Join-Path $resolvedRoot "capnp/$($toolchain.capnpVersion)/capnp.install.meta"
if (Test-Path -LiteralPath $capnpInstallMetaFile -PathType Leaf) {
  $capnpInstallMeta = Read-KeyValueFile -Path $capnpInstallMetaFile
  if ($capnpInstallMeta.ContainsKey("requested_mode")) {
    Write-Host "CAPNP_WINDOWS_SOURCE_MODE_REQUESTED=$($capnpInstallMeta['requested_mode'])"
  }
  if ($capnpInstallMeta.ContainsKey("effective_mode")) {
    Write-Host "CAPNP_WINDOWS_SOURCE_MODE_EFFECTIVE=$($capnpInstallMeta['effective_mode'])"
  }
  if ($capnpInstallMeta.ContainsKey("install_relative_path")) {
    Write-Host "CAPNP_INSTALL_RELATIVE_PATH=$($capnpInstallMeta['install_relative_path'])"
    Write-Host "CAPNP_DIR=$(Join-Path $resolvedRoot $capnpInstallMeta['install_relative_path'])"
  }
}
Write-Host "TUP_SOURCE_REPO=$($toolchain.tupSourceRepo)"
Write-Host "TUP_SOURCE_REF=$($toolchain.tupSourceRef)"
Write-Host "TUP_MSYS2_BASE_VERSION=$($toolchain.tupMsys2BaseVersion)"
Write-Host "TUP_MSYS2_PACKAGES=$($toolchain.tupMsys2Packages)"
$effectiveTupMode = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_SOURCE_MODE")
if ([string]::IsNullOrWhiteSpace($effectiveTupMode)) { $effectiveTupMode = "prebuilt" }
$effectiveTupRepo = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_SOURCE_REPO")
if ([string]::IsNullOrWhiteSpace($effectiveTupRepo)) { $effectiveTupRepo = $toolchain.tupSourceRepo }
$effectiveTupRef = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_SOURCE_REF")
if ([string]::IsNullOrWhiteSpace($effectiveTupRef)) { $effectiveTupRef = $toolchain.tupSourceRef }
$effectiveTupBuildCommand = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_SOURCE_BUILD_COMMAND")
if ([string]::IsNullOrWhiteSpace($effectiveTupBuildCommand)) { $effectiveTupBuildCommand = $toolchain.tupSourceBuildCommand }
 $effectiveTupPrebuiltVersion = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_PREBUILT_VERSION")
if ([string]::IsNullOrWhiteSpace($effectiveTupPrebuiltVersion)) { $effectiveTupPrebuiltVersion = $toolchain.tupPrebuiltVersion }
$effectiveTupPrebuiltUrl = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_PREBUILT_URL")
if ([string]::IsNullOrWhiteSpace($effectiveTupPrebuiltUrl)) { $effectiveTupPrebuiltUrl = $toolchain.tupPrebuiltUrl }
$effectiveTupPrebuiltSha = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_PREBUILT_SHA256")
if ([string]::IsNullOrWhiteSpace($effectiveTupPrebuiltSha)) { $effectiveTupPrebuiltSha = $toolchain.tupPrebuiltSha256 }
Write-Host "TUP_WINDOWS_SOURCE_MODE=$effectiveTupMode"
Write-Host "TUP_WINDOWS_SOURCE_REPO=$effectiveTupRepo"
Write-Host "TUP_WINDOWS_SOURCE_REF=$effectiveTupRef"
Write-Host "TUP_WINDOWS_SOURCE_BUILD_COMMAND=$effectiveTupBuildCommand"
Write-Host "TUP_WINDOWS_PREBUILT_VERSION=$effectiveTupPrebuiltVersion"
Write-Host "TUP_WINDOWS_PREBUILT_URL=$effectiveTupPrebuiltUrl"
Write-Host "TUP_WINDOWS_PREBUILT_SHA256=$effectiveTupPrebuiltSha"
$effectiveTupMsys2Version = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_MSYS2_BASE_VERSION")
if ([string]::IsNullOrWhiteSpace($effectiveTupMsys2Version)) { $effectiveTupMsys2Version = $toolchain.tupMsys2BaseVersion }
$effectiveTupMsys2Packages = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_MSYS2_PACKAGES")
if ([string]::IsNullOrWhiteSpace($effectiveTupMsys2Packages)) { $effectiveTupMsys2Packages = $toolchain.tupMsys2Packages }
Write-Host "TUP_WINDOWS_MSYS2_BASE_VERSION=$effectiveTupMsys2Version"
Write-Host "TUP_WINDOWS_MSYS2_PACKAGES=$effectiveTupMsys2Packages"
$tupInstallMetaFile = Join-Path $resolvedRoot "tup/tup.install.meta"
if (Test-Path -LiteralPath $tupInstallMetaFile -PathType Leaf) {
  $tupInstallMeta = Read-KeyValueFile -Path $tupInstallMetaFile
  if ($tupInstallMeta.ContainsKey("requested_mode")) {
    Write-Host "TUP_WINDOWS_SOURCE_MODE_REQUESTED=$($tupInstallMeta['requested_mode'])"
  }
  if ($tupInstallMeta.ContainsKey("effective_mode")) {
    Write-Host "TUP_WINDOWS_SOURCE_MODE_EFFECTIVE=$($tupInstallMeta['effective_mode'])"
  }
  if ($tupInstallMeta.ContainsKey("install_relative_path")) {
    Write-Host "TUP_INSTALL_RELATIVE_PATH=$($tupInstallMeta['install_relative_path'])"
    Write-Host "TUP_DIR=$(Join-Path $resolvedRoot $tupInstallMeta['install_relative_path'])"
  }
}

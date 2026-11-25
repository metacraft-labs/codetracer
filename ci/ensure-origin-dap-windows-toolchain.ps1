[CmdletBinding()]
param(
  [string]$InstallRoot = $(
    if ($env:RUNNER_TEMP) {
      Join-Path $env:RUNNER_TEMP "codetracer-origin-dap-toolchain"
    }
    else {
      Join-Path ([IO.Path]::GetTempPath()) "codetracer-origin-dap-toolchain"
    }
  ),
  [string]$GitHubPath = $env:GITHUB_PATH,
  [string]$ToolchainFile = $(
    Join-Path $PSScriptRoot "..\non-nix-build\windows\toolchain-versions.env"
  )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# The required Windows origin-DAP gate is intentionally independent of a
# machine-wide package manager. These official, versioned assets are resolved
# from the repository's canonical Windows pins and verified before any
# installation is activated:
#
# * https://capnproto.org/install.html#installation-windows
# * https://nim-lang.org/install_windows.html
# * https://github.com/casey/just#pre-built-binaries

function Read-CodeTracerOriginToolchainPins {
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "The Windows toolchain pin file does not exist: '$Path'."
  }

  $pins = @{}
  foreach ($line in (Get-Content -LiteralPath $Path)) {
    $trimmed = ([string]$line).Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
      continue
    }
    $separator = $trimmed.IndexOf("=")
    if ($separator -lt 1) {
      throw "Malformed Windows toolchain pin: '$trimmed'."
    }
    $name = $trimmed.Substring(0, $separator).Trim()
    $value = $trimmed.Substring($separator + 1).Trim()
    if ($pins.ContainsKey($name)) {
      throw "Duplicate Windows toolchain pin '$name'."
    }
    $pins[$name] = $value
  }
  return $pins
}

function Get-CodeTracerRequiredPin {
  param(
    [Parameter(Mandatory)][hashtable]$Pins,
    [Parameter(Mandatory)][string]$Name
  )

  if (-not $Pins.ContainsKey($Name) -or
      [string]::IsNullOrWhiteSpace([string]$Pins[$Name])) {
    throw "The Windows toolchain pin '$Name' is missing."
  }
  return [string]$Pins[$Name]
}

function Get-CodeTracerOriginToolSpecifications {
  param([Parameter(Mandatory)][string]$Path)

  $pins = Read-CodeTracerOriginToolchainPins -Path $Path
  $capnpVersion = Get-CodeTracerRequiredPin -Pins $pins -Name "CAPNP_VERSION"
  $nimVersion = Get-CodeTracerRequiredPin -Pins $pins -Name "NIM_VERSION"
  $nimbleVersion = Get-CodeTracerRequiredPin -Pins $pins -Name "NIMBLE_VERSION"
  $justVersion = Get-CodeTracerRequiredPin -Pins $pins -Name "JUST_VERSION"
  $specifications = @(
    [PSCustomObject]@{
      Name = "capnp"
      CommandName = "capnp.exe"
      Version = [Version]$capnpVersion
      ArchiveName = "capnproto-c++-win32-$capnpVersion.zip"
      Url = "https://capnproto.org/capnproto-c++-win32-$capnpVersion.zip"
      Sha256 = (Get-CodeTracerRequiredPin -Pins $pins -Name "CAPNP_WIN_X64_SHA256")
      RelativeExecutable = "capnp\capnproto-tools-win32-$capnpVersion\capnp.exe"
      VersionPattern = '^Cap''n Proto version\s+(?<version>[0-9]+(?:\.[0-9]+)+)\s*$'
      CompanionExecutables = @(
        [PSCustomObject]@{
          Name = "capnpc-c++.exe"
          Version = [Version]$capnpVersion
          VersionPattern = '^Cap''n Proto C\+\+ plugin version\s+(?<version>[0-9]+(?:\.[0-9]+)+)\s*$'
        },
        [PSCustomObject]@{
          Name = "capnpc-capnp.exe"
          Version = [Version]$capnpVersion
          VersionPattern = '^Cap''n Proto loopback plugin version\s+(?<version>[0-9]+(?:\.[0-9]+)+)\s*$'
        }
      )
    },
    [PSCustomObject]@{
      Name = "nim"
      CommandName = "nim.exe"
      Version = [Version]$nimVersion
      ArchiveName = "nim-$($nimVersion)_x64.zip"
      Url = "https://nim-lang.org/download/nim-$($nimVersion)_x64.zip"
      Sha256 = (Get-CodeTracerRequiredPin -Pins $pins -Name "NIM_WIN_X64_SHA256")
      RelativeExecutable = "nim\nim-$nimVersion\bin\nim.exe"
      VersionPattern = '^Nim Compiler Version\s+(?<version>[0-9]+(?:\.[0-9]+)+)(?:\s|$)'
      CompanionExecutables = @(
        [PSCustomObject]@{
          Name = "nimble.exe"
          Version = [Version]$nimbleVersion
          VersionPattern = '^nimble v(?<version>[0-9]+(?:\.[0-9]+)+)(?:\s|$)'
        }
      )
    },
    [PSCustomObject]@{
      Name = "just"
      CommandName = "just.exe"
      Version = [Version]$justVersion
      ArchiveName = "just-$justVersion-x86_64-pc-windows-msvc.zip"
      Url = "https://github.com/casey/just/releases/download/$justVersion/just-$justVersion-x86_64-pc-windows-msvc.zip"
      Sha256 = (Get-CodeTracerRequiredPin -Pins $pins -Name "JUST_WIN_X64_SHA256")
      RelativeExecutable = "just\just.exe"
      VersionPattern = '^just\s+(?<version>[0-9]+(?:\.[0-9]+)+)(?:\s.*)?$'
      CompanionExecutables = @()
    }
  )

  foreach ($specification in $specifications) {
    $specification.Sha256 = ([string]$specification.Sha256).ToLowerInvariant()
    if ($specification.Sha256 -cnotmatch '^[0-9a-f]{64}$') {
      throw "The pinned $($specification.Name) SHA256 is invalid."
    }
    if ([string]$specification.Url -cnotmatch '^https://') {
      throw "The pinned $($specification.Name) URL must use HTTPS."
    }
  }
  return $specifications
}

function Get-CodeTracerOriginExecutableVersion {
  param(
    [Parameter(Mandatory)]$ExecutableSpecification,
    [Parameter(Mandatory)][string]$Executable
  )

  try {
    $versionText = (& $Executable --version 2>&1 | Out-String).Trim()
    $status = $LASTEXITCODE
  }
  catch {
    return $null
  }
  if ($null -eq $status) {
    $status = if ($?) { 0 } else { 1 }
  }
  if ($status -ne 0) {
    return $null
  }

  if ($versionText -notmatch ([string]$ExecutableSpecification.VersionPattern)) {
    return $null
  }
  try {
    return [Version]$matches.version
  }
  catch {
    return $null
  }
}

function Get-CodeTracerOriginExecutableSpecifications {
  param(
    [Parameter(Mandatory)]$ToolSpecification,
    [Parameter(Mandatory)][string]$PrimaryExecutable
  )

  $directory = Split-Path -Parent $PrimaryExecutable
  $executables = @(
    [PSCustomObject]@{
      Name = $ToolSpecification.CommandName
      Path = $PrimaryExecutable
      Version = [Version]$ToolSpecification.Version
      VersionPattern = $ToolSpecification.VersionPattern
    }
  )
  foreach ($companion in @($ToolSpecification.CompanionExecutables)) {
    $executables += [PSCustomObject]@{
      Name = $companion.Name
      Path = Join-Path $directory $companion.Name
      Version = [Version]$companion.Version
      VersionPattern = $companion.VersionPattern
    }
  }
  return $executables
}

function Test-CodeTracerOriginExecutableSet {
  param(
    [Parameter(Mandatory)]$ToolSpecification,
    [Parameter(Mandatory)][string]$PrimaryExecutable,
    [Parameter(Mandatory)][scriptblock]$VersionReader
  )

  foreach ($executable in @(Get-CodeTracerOriginExecutableSpecifications `
      -ToolSpecification $ToolSpecification `
      -PrimaryExecutable $PrimaryExecutable)) {
    if (-not (Test-Path -LiteralPath $executable.Path -PathType Leaf)) {
      return $false
    }
    $version = & $VersionReader $executable $executable.Path
    if ($null -eq $version -or [Version]$version -ne $executable.Version) {
      return $false
    }
  }
  return $true
}

function Get-CodeTracerOriginToolCandidates {
  param([Parameter(Mandatory)]$Specification)

  $command = Get-Command $Specification.CommandName `
    -CommandType Application `
    -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($null -eq $command) {
    return @()
  }
  return @($command.Source)
}

function New-CodeTracerOriginToolchainResult {
  param([Parameter(Mandatory)][array]$Tools)

  $pathEntries = New-Object System.Collections.Generic.List[string]
  foreach ($tool in $Tools) {
    $directory = Split-Path -Parent ([string]$tool.Path)
    if (-not $pathEntries.Contains($directory)) {
      $pathEntries.Add($directory)
    }
  }
  return [PSCustomObject]@{
    Tools = $Tools
    PathEntries = @($pathEntries)
  }
}

function Find-CodeTracerOriginToolchain {
  param(
    [Parameter(Mandatory)][array]$Specifications,
    [scriptblock]$CandidateProvider = {
      param($specification)
      Get-CodeTracerOriginToolCandidates -Specification $specification
    },
    [scriptblock]$VersionReader = {
      param($executableSpecification, $executable)
      Get-CodeTracerOriginExecutableVersion `
        -ExecutableSpecification $executableSpecification `
        -Executable $executable
    }
  )

  $tools = @()
  foreach ($specification in $Specifications) {
    $selected = $null
    foreach ($candidate in @(& $CandidateProvider $specification)) {
      if ([string]::IsNullOrWhiteSpace([string]$candidate) -or
          -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        continue
      }
      if (Test-CodeTracerOriginExecutableSet `
          -ToolSpecification $specification `
          -PrimaryExecutable $candidate `
          -VersionReader $VersionReader) {
        $selected = [PSCustomObject]@{
          Name = $specification.Name
          Path = (Resolve-Path -LiteralPath $candidate).Path
          Version = [Version]$specification.Version
        }
        break
      }
    }
    if ($null -eq $selected) {
      return $null
    }
    $tools += $selected
  }
  return New-CodeTracerOriginToolchainResult -Tools $tools
}

function Invoke-CodeTracerOriginToolDownload {
  param(
    [Parameter(Mandatory)]$Specification,
    [Parameter(Mandatory)][string]$OutFile
  )

  [Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor
    [Net.SecurityProtocolType]::Tls12
  $savedProgressPreference = $ProgressPreference
  try {
    $ProgressPreference = "SilentlyContinue"
    Invoke-WebRequest `
      -Uri $Specification.Url `
      -OutFile $OutFile `
      -UseBasicParsing
  }
  finally {
    $ProgressPreference = $savedProgressPreference
  }
}

function Get-CodeTracerOriginArchiveSha256 {
  param([Parameter(Mandatory)][string]$Path)

  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Expand-CodeTracerOriginToolArchive {
  param(
    [Parameter(Mandatory)]$Specification,
    [Parameter(Mandatory)][string]$ArchivePath,
    [Parameter(Mandatory)][string]$Destination
  )

  Expand-Archive `
    -LiteralPath $ArchivePath `
    -DestinationPath $Destination `
    -Force
}

function Install-CodeTracerOriginToolchain {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Destination,
    [Parameter(Mandatory)][array]$Specifications,
    [scriptblock]$DownloadFile = {
      param($specification, $path)
      Invoke-CodeTracerOriginToolDownload `
        -Specification $specification `
        -OutFile $path
    },
    [scriptblock]$HashFile = {
      param($path)
      Get-CodeTracerOriginArchiveSha256 -Path $path
    },
    [scriptblock]$ExtractArchive = {
      param($specification, $archive, $destination)
      Expand-CodeTracerOriginToolArchive `
        -Specification $specification `
        -ArchivePath $archive `
        -Destination $destination
    },
    [scriptblock]$VersionReader = {
      param($executableSpecification, $executable)
      Get-CodeTracerOriginExecutableVersion `
        -ExecutableSpecification $executableSpecification `
        -Executable $executable
    },
    [scriptblock]$ActivateInstallation = {
      param($staging, $destination)
      Move-Item -LiteralPath $staging -Destination $destination
    }
  )

  if ([string]::IsNullOrWhiteSpace($Destination)) {
    throw "The origin-DAP toolchain destination must not be empty."
  }
  if ($Specifications.Count -ne 3) {
    throw "The origin-DAP toolchain must contain exactly capnp, nim, and just."
  }
  $expectedNames = @("capnp", "nim", "just")
  if ((@($Specifications | ForEach-Object { $_.Name }) -join "`0") -cne
      ($expectedNames -join "`0")) {
    throw "The origin-DAP toolchain specification is incomplete or out of order."
  }

  $parent = Split-Path -Parent $Destination
  if ([string]::IsNullOrWhiteSpace($parent)) {
    throw "The origin-DAP toolchain destination must have a parent directory."
  }
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $nonce = [Guid]::NewGuid().ToString("N")
  $downloadRoot = Join-Path $parent "origin-dap-downloads-$nonce"
  $stagingRoot = Join-Path $parent "origin-dap-staging-$nonce"
  $backupRoot = Join-Path $parent "origin-dap-backup-$nonce"
  $previousInstallationMoved = $false

  try {
    New-Item -ItemType Directory -Path $downloadRoot, $stagingRoot | Out-Null
    foreach ($specification in $Specifications) {
      if ([string]$specification.Sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw "The pinned $($specification.Name) SHA256 is invalid."
      }
      $archivePath = Join-Path $downloadRoot $specification.ArchiveName
      & $DownloadFile $specification $archivePath | Out-Null
      if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        throw "$($specification.Name) download did not create the expected archive."
      }
      $actualSha256 = ([string](& $HashFile $archivePath)).ToLowerInvariant()
      if ($actualSha256 -cne [string]$specification.Sha256) {
        throw "$($specification.Name) SHA256 mismatch. Expected $($specification.Sha256), got $actualSha256."
      }

      $toolExtractRoot = Join-Path $stagingRoot $specification.Name
      New-Item -ItemType Directory -Path $toolExtractRoot | Out-Null
      & $ExtractArchive $specification $archivePath $toolExtractRoot | Out-Null
      $stagedExecutable = Join-Path $stagingRoot $specification.RelativeExecutable
      if (-not (Test-Path -LiteralPath $stagedExecutable -PathType Leaf)) {
        throw "$($specification.Name) archive did not contain '$($specification.RelativeExecutable)'."
      }
      foreach ($executable in @(Get-CodeTracerOriginExecutableSpecifications `
          -ToolSpecification $specification `
          -PrimaryExecutable $stagedExecutable)) {
        if (-not (Test-Path -LiteralPath $executable.Path -PathType Leaf)) {
          throw "$($specification.Name) archive did not contain required executable '$($executable.Name)'."
        }
        $stagedVersion = & $VersionReader $executable $executable.Path
        if ($null -eq $stagedVersion -or
            [Version]$stagedVersion -ne $executable.Version) {
          $reported = if ($null -eq $stagedVersion) { "unparseable" } else { $stagedVersion }
          throw "$($executable.Name) reported version $reported; expected $($executable.Version)."
        }
      }
    }

    if (Test-Path -LiteralPath $Destination) {
      Move-Item -LiteralPath $Destination -Destination $backupRoot
      $previousInstallationMoved = $true
    }
    try {
      & $ActivateInstallation $stagingRoot $Destination | Out-Null
    }
    catch {
      Remove-Item `
        -LiteralPath $Destination `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
      if ($previousInstallationMoved) {
        Move-Item -LiteralPath $backupRoot -Destination $Destination
        $previousInstallationMoved = $false
      }
      throw
    }
    if ($previousInstallationMoved) {
      Remove-Item -LiteralPath $backupRoot -Recurse -Force
      $previousInstallationMoved = $false
    }

    $tools = @()
    foreach ($specification in $Specifications) {
      $tools += [PSCustomObject]@{
        Name = $specification.Name
        Path = Join-Path $Destination $specification.RelativeExecutable
        Version = [Version]$specification.Version
      }
    }
    return New-CodeTracerOriginToolchainResult -Tools $tools
  }
  finally {
    Remove-Item `
      -LiteralPath $downloadRoot `
      -Recurse `
      -Force `
      -ErrorAction SilentlyContinue
    Remove-Item `
      -LiteralPath $stagingRoot `
      -Recurse `
      -Force `
      -ErrorAction SilentlyContinue
    # A backup is preserved only if restoring the last known-good install
    # itself failed, so a human can recover it instead of losing both copies.
    if (-not $previousInstallationMoved) {
      Remove-Item `
        -LiteralPath $backupRoot `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
    }
  }
}

function Add-CodeTracerOriginToolchainToPath {
  param(
    [Parameter(Mandatory)]$Toolchain,
    [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$GitHubPathFile,
    [scriptblock]$PersistEntries = {
      param($pathFile, $entries)
      foreach ($entry in $entries) {
        Add-Content -LiteralPath $pathFile -Value $entry
      }
    }
  )

  if ([string]::IsNullOrWhiteSpace($GitHubPathFile)) {
    throw "GITHUB_PATH is unavailable; the origin-DAP toolchain cannot be propagated."
  }
  if (Test-Path -LiteralPath $GitHubPathFile -PathType Container) {
    throw "GITHUB_PATH points to a directory instead of a file."
  }

  $entries = @($Toolchain.PathEntries)
  foreach ($entry in $entries) {
    if ([string]::IsNullOrWhiteSpace([string]$entry) -or
        ([string]$entry).Contains("`r") -or
        ([string]$entry).Contains("`n")) {
      throw "An origin-DAP PATH entry is empty or contains a newline."
    }
    if (-not (Test-Path -LiteralPath $entry -PathType Container)) {
      throw "Origin-DAP PATH entry '$entry' is not a directory."
    }
  }

  $savedPath = $env:PATH
  $pathFileExisted = Test-Path -LiteralPath $GitHubPathFile -PathType Leaf
  $savedPathFile = if ($pathFileExisted) {
    [IO.File]::ReadAllBytes($GitHubPathFile)
  }
  else {
    $null
  }
  try {
    $prefix = $entries -join [IO.Path]::PathSeparator
    $env:PATH = if ([string]::IsNullOrEmpty($env:PATH)) {
      $prefix
    }
    else {
      "$prefix$([IO.Path]::PathSeparator)$env:PATH"
    }
    & $PersistEntries $GitHubPathFile $entries
  }
  catch {
    $env:PATH = $savedPath
    if ($pathFileExisted) {
      [IO.File]::WriteAllBytes($GitHubPathFile, $savedPathFile)
    }
    else {
      Remove-Item -LiteralPath $GitHubPathFile -Force -ErrorAction SilentlyContinue
    }
    throw
  }
  return $entries
}

function Ensure-CodeTracerOriginDapWindowsToolchain {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Destination,
    [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$GitHubPathFile,
    [Parameter(Mandatory)][array]$Specifications,
    [scriptblock]$CandidateProvider = {
      param($specification)
      Get-CodeTracerOriginToolCandidates -Specification $specification
    },
    [scriptblock]$VersionReader = {
      param($executableSpecification, $executable)
      Get-CodeTracerOriginExecutableVersion `
        -ExecutableSpecification $executableSpecification `
        -Executable $executable
    },
    [scriptblock]$ProvisionToolchain = {
      param($destination, $specifications, $versionReader)
      Install-CodeTracerOriginToolchain `
        -Destination $destination `
        -Specifications $specifications `
        -VersionReader $versionReader
    }
  )

  $toolchain = Find-CodeTracerOriginToolchain `
    -Specifications $Specifications `
    -CandidateProvider $CandidateProvider `
    -VersionReader $VersionReader
  if ($null -eq $toolchain) {
    $toolchain = & $ProvisionToolchain `
      $Destination `
      $Specifications `
      $VersionReader
  }
  if ($null -eq $toolchain -or $toolchain.Tools.Count -ne 3) {
    throw "Origin-DAP toolchain provisioning did not return all three tools."
  }
  foreach ($tool in $toolchain.Tools) {
    $specification = $Specifications |
      Where-Object { $_.Name -ceq $tool.Name } |
      Select-Object -First 1
    if ($null -eq $specification -or -not (Test-CodeTracerOriginExecutableSet `
        -ToolSpecification $specification `
        -PrimaryExecutable $tool.Path `
        -VersionReader $VersionReader)) {
      throw "Origin-DAP toolchain provisioning returned an unusable $($tool.Name) executable."
    }
  }
  Add-CodeTracerOriginToolchainToPath `
    -Toolchain $toolchain `
    -GitHubPathFile $GitHubPathFile | Out-Null
  foreach ($tool in $toolchain.Tools) {
    Write-Host "Using $($tool.Name) $($tool.Version) from $($tool.Path)."
  }
  return $toolchain
}

if ($MyInvocation.InvocationName -ne '.') {
  $specifications = Get-CodeTracerOriginToolSpecifications -Path $ToolchainFile
  Ensure-CodeTracerOriginDapWindowsToolchain `
    -Destination $InstallRoot `
    -GitHubPathFile $GitHubPath `
    -Specifications $specifications | Out-Null
}

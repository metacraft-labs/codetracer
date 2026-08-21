[CmdletBinding()]
param(
  [string]$InstallRoot = $(
    if ($env:RUNNER_TEMP) {
      Join-Path $env:RUNNER_TEMP "codetracer-portable-git"
    }
    else {
      Join-Path ([IO.Path]::GetTempPath()) "codetracer-portable-git"
    }
  ),
  [string]$GitHubPath = $env:GITHUB_PATH,
  [string]$GitHubEnv = $env:GITHUB_ENV
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Keep this fallback immutable: the release URL identifies one official
# Git-for-Windows asset and the digest is the value published by GitHub for
# that asset. PortableGit is used instead of MinGit because the required gate
# also needs Git Bash after actions/checkout finishes.
# https://github.com/git-for-windows/git/releases/tag/v2.55.0.windows.3
$script:MinimumGitVersion = [Version]"2.18.0"
$script:PortableGitVersion = [Version]"2.55.0"
$script:PortableGitUrl =
  "https://github.com/git-for-windows/git/releases/download/" +
  "v2.55.0.windows.3/PortableGit-2.55.0.3-64-bit.7z.exe"
$script:PortableGitSha256 =
  "ab00566336b5472120f9a52d34f2e79c5406535792acb0548001ffd0bd090e5d"

function Get-CodeTracerFileSha256 {
  param([Parameter(Mandatory)][string]$Path)

  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-CodeTracerGitVersion {
  param([Parameter(Mandatory)][string]$GitPath)

  try {
    $versionText = (& $GitPath --version 2>&1 | Out-String).Trim()
    $status = $LASTEXITCODE
  }
  catch {
    return $null
  }
  if ($null -eq $status) {
    $status = if ($?) { 0 } else { 1 }
  }
  if ($status -ne 0 -or
      $versionText -notmatch '^git version (?<version>[0-9]+\.[0-9]+\.[0-9]+)(?:\.windows\.[0-9]+)?(?:\s.*)?$') {
    return $null
  }
  try {
    return [Version]$matches.version
  }
  catch {
    return $null
  }
}

function Get-CodeTracerGitCandidates {
  $candidates = @()
  $pathGit = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($pathGit) {
    $candidates += $pathGit.Source
  }
  $candidates += @(
    "C:\Program Files\Git\cmd\git.exe",
    "C:\Program Files\Git\bin\git.exe",
    "C:\Program Files (x86)\Git\cmd\git.exe",
    "C:\Program Files (x86)\Git\bin\git.exe"
  )
  return @($candidates | Select-Object -Unique)
}

function Get-CodeTracerGitBashPath {
  param([Parameter(Mandatory)][string]$GitPath)

  $gitDirectory = Split-Path -Parent $GitPath
  $directoryName = [IO.Path]::GetFileName($gitDirectory)
  if ($directoryName -ieq "cmd") {
    return Join-Path (Join-Path (Split-Path -Parent $gitDirectory) "bin") "bash.exe"
  }
  if ($directoryName -ieq "bin") {
    return Join-Path $gitDirectory "bash.exe"
  }
  return $null
}

function Find-CodeTracerUsableGit {
  param(
    [Version]$MinimumVersion = $script:MinimumGitVersion,
    [scriptblock]$CandidateProvider = { Get-CodeTracerGitCandidates },
    [scriptblock]$VersionReader = { param($path) Get-CodeTracerGitVersion $path }
  )

  foreach ($candidate in @(& $CandidateProvider)) {
    if ([string]::IsNullOrWhiteSpace([string]$candidate) -or
        -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      continue
    }
    try {
      $version = & $VersionReader $candidate
    }
    catch {
      continue
    }
    $bashPath = Get-CodeTracerGitBashPath $candidate
    if ($null -ne $version -and
        [Version]$version -ge $MinimumVersion -and
        $null -ne $bashPath -and
        (Test-Path -LiteralPath $bashPath -PathType Leaf)) {
      return [PSCustomObject]@{
        Path = (Resolve-Path -LiteralPath $candidate).Path
        Version = [Version]$version
      }
    }
  }
  return $null
}

function Invoke-CodeTracerPortableGitDownload {
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$OutFile
  )

  # Windows PowerShell 5.1 does not consistently negotiate TLS 1.2 by default.
  [Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor
    [Net.SecurityProtocolType]::Tls12
  $savedProgressPreference = $ProgressPreference
  try {
    $ProgressPreference = "SilentlyContinue"
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
  }
  finally {
    $ProgressPreference = $savedProgressPreference
  }
}

function Expand-CodeTracerPortableGit {
  param(
    [Parameter(Mandatory)][string]$ArchivePath,
    [Parameter(Mandatory)][string]$Destination
  )

  $output = & $ArchivePath -y "-o$Destination" 2>&1 | Out-String
  $status = $LASTEXITCODE
  if ($null -eq $status) {
    $status = if ($?) { 0 } else { 1 }
  }
  if ($status -ne 0) {
    throw "PortableGit extraction failed (exit $status).`n$($output.TrimEnd())"
  }
}

function Install-CodeTracerPortableGit {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Destination,
    [string]$AssetUrl = $script:PortableGitUrl,
    [string]$ExpectedSha256 = $script:PortableGitSha256,
    [Version]$ExpectedGitVersion = $script:PortableGitVersion,
    [scriptblock]$DownloadFile = {
      param($url, $path)
      Invoke-CodeTracerPortableGitDownload -Url $url -OutFile $path
    },
    [scriptblock]$HashFile = {
      param($path)
      Get-CodeTracerFileSha256 $path
    },
    [scriptblock]$ExtractArchive = {
      param($archive, $destination)
      Expand-CodeTracerPortableGit -ArchivePath $archive -Destination $destination
    },
    [scriptblock]$VersionReader = { param($path) Get-CodeTracerGitVersion $path },
    [scriptblock]$ActivateInstallation = {
      param($staging, $destination)
      Move-Item -LiteralPath $staging -Destination $destination
    }
  )

  if ($ExpectedSha256 -cnotmatch '^[0-9a-f]{64}$') {
    throw "The pinned PortableGit SHA256 is invalid."
  }
  if ([string]::IsNullOrWhiteSpace($Destination)) {
    throw "The PortableGit destination must not be empty."
  }

  $parent = Split-Path -Parent $Destination
  if ([string]::IsNullOrWhiteSpace($parent)) {
    throw "The PortableGit destination must have a parent directory."
  }
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $nonce = [Guid]::NewGuid().ToString("N")
  $archivePath = Join-Path $parent "codetracer-portable-git-$nonce.exe"
  $stagingRoot = Join-Path $parent "codetracer-portable-git-staging-$nonce"
  $backupRoot = Join-Path $parent "codetracer-portable-git-backup-$nonce"
  $previousInstallationMoved = $false

  try {
    & $DownloadFile $AssetUrl $archivePath | Out-Null
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
      throw "PortableGit download did not create the expected archive."
    }
    $actualSha256 = [string](& $HashFile $archivePath)
    if ($actualSha256.ToLowerInvariant() -cne $ExpectedSha256) {
      throw "PortableGit SHA256 mismatch. Expected $ExpectedSha256, got $actualSha256."
    }

    New-Item -ItemType Directory -Path $stagingRoot | Out-Null
    & $ExtractArchive $archivePath $stagingRoot | Out-Null
    $stagedGit = Join-Path (Join-Path $stagingRoot "cmd") "git.exe"
    if (-not (Test-Path -LiteralPath $stagedGit -PathType Leaf)) {
      throw "PortableGit extraction did not produce cmd\git.exe."
    }
    $stagedBash = Get-CodeTracerGitBashPath $stagedGit
    if ($null -eq $stagedBash -or
        -not (Test-Path -LiteralPath $stagedBash -PathType Leaf)) {
      throw "PortableGit extraction did not produce bin\bash.exe."
    }
    $stagedVersion = & $VersionReader $stagedGit
    if ($null -eq $stagedVersion -or
        [Version]$stagedVersion -ne $ExpectedGitVersion) {
      $reportedVersion = if ($null -eq $stagedVersion) { "unparseable" } else { $stagedVersion }
      throw "PortableGit reported version $reportedVersion; expected $ExpectedGitVersion."
    }

    if (Test-Path -LiteralPath $Destination) {
      Move-Item -LiteralPath $Destination -Destination $backupRoot
      $previousInstallationMoved = $true
    }
    try {
      & $ActivateInstallation $stagingRoot $Destination | Out-Null
    }
    catch {
      # Staging and the destination share a parent so activation is a local
      # rename. Still restore the previous installation if the provider or an
      # injected failure interrupts that final step.
      Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
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
    return [PSCustomObject]@{
      Path = Join-Path (Join-Path $Destination "cmd") "git.exe"
      Version = [Version]$stagedVersion
    }
  }
  finally {
    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    # A failed restore deliberately leaves the backup intact for recovery.
    if (-not $previousInstallationMoved) {
      Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

function Get-CodeTracerGitPathEntries {
  param([Parameter(Mandatory)][string]$GitPath)

  $gitDirectory = Split-Path -Parent $GitPath
  $entries = @($gitDirectory)
  $bashPath = Get-CodeTracerGitBashPath $GitPath
  if ($null -eq $bashPath -or
      -not (Test-Path -LiteralPath $bashPath -PathType Leaf)) {
    throw "The selected Git installation does not include Git Bash."
  }
  $bashDirectory = Split-Path -Parent $bashPath
  if ($bashDirectory -cne $gitDirectory) {
    $entries += $bashDirectory
  }
  return @($entries | Select-Object -Unique)
}

function Add-CodeTracerGitToPath {
  param(
    [Parameter(Mandatory)][string]$GitPath,
    [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$GitHubPathFile
  )

  if ([string]::IsNullOrWhiteSpace($GitHubPathFile)) {
    throw "GITHUB_PATH is unavailable; Git cannot be propagated to checkout."
  }
  $entries = @(Get-CodeTracerGitPathEntries -GitPath $GitPath)
  foreach ($entry in $entries) {
    if ($entry.Contains("`r") -or $entry.Contains("`n")) {
      throw "A Git PATH entry contains an invalid newline."
    }
    if (-not (Test-Path -LiteralPath $entry -PathType Container)) {
      throw "Git PATH entry '$entry' is not a directory."
    }
  }

  $prefix = $entries -join [IO.Path]::PathSeparator
  $env:PATH = if ([string]::IsNullOrEmpty($env:PATH)) {
    $prefix
  }
  else {
    "$prefix$([IO.Path]::PathSeparator)$env:PATH"
  }
  foreach ($entry in $entries) {
    Add-Content -LiteralPath $GitHubPathFile -Value $entry
  }
  return $entries
}

function Add-CodeTracerGitLongPathEnvironment {
  param(
    [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$GitHubEnvFile
  )

  if ([string]::IsNullOrWhiteSpace($GitHubEnvFile)) {
    throw "GITHUB_ENV is unavailable; Windows long-path support cannot be propagated to checkout."
  }

  # actions/checkout runs in a later step, so a process-local `git -c` is not
  # sufficient. Git's documented process environment is job-scoped here and
  # avoids changing persistent runner configuration. Resetting COUNT to one
  # prevents inherited numbered entries from becoming active. The older
  # GIT_CONFIG_PARAMETERS channel has later command-scope precedence, so it
  # must be cleared explicitly or an inherited `core.longpaths=false` can
  # override the bounded entry below.
  # https://git-scm.com/docs/git#Documentation/git.txt-codeGITCONFIGCOUNTcode
  $settings = @(
    "GIT_CONFIG_PARAMETERS=",
    "GIT_CONFIG_COUNT=1",
    "GIT_CONFIG_KEY_0=core.longpaths",
    "GIT_CONFIG_VALUE_0=true"
  )
  Add-Content -LiteralPath $GitHubEnvFile -Value $settings
  $env:GIT_CONFIG_PARAMETERS = ""
  $env:GIT_CONFIG_COUNT = "1"
  $env:GIT_CONFIG_KEY_0 = "core.longpaths"
  $env:GIT_CONFIG_VALUE_0 = "true"
}

function Invoke-CodeTracerGitCommand {
  param(
    [Parameter(Mandatory)][string]$GitPath,
    [Parameter(Mandatory)][string[]]$Arguments
  )

  $output = (& $GitPath @Arguments 2>&1 | Out-String)
  $status = $LASTEXITCODE
  if ($null -eq $status) {
    $status = if ($?) { 0 } else { 1 }
  }
  return [PSCustomObject]@{
    ExitCode = $status
    Output = $output.Trim()
  }
}

function Enable-CodeTracerGitSystemLongPaths {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$GitPath,
    [scriptblock]$GitRunner = {
      param($gitPath, $arguments)
      Invoke-CodeTracerGitCommand -GitPath $gitPath -Arguments $arguments
    }
  )

  # Windows refuses paths longer than MAX_PATH (260 characters), and Git for
  # Windows gates its `\\?\` long-path expansion on `core.longpaths`. The gate
  # is git's own: without this key git fails with "Filename too long" even on a
  # host where the machine-wide LongPathsEnabled policy is already set, so the
  # registry policy (which every OTHER tool needs) is not a substitute for it.
  # codetracer's recursively nested submodules cross 260 characters under the
  # runner's `C:\actions-runner\_work\...` workspace, which is where the
  # eph-win-x64 jobs were dying.
  #
  # This is the SYSTEM scope, and it is not a duplicate of the job-scoped
  # numbered environment installed below. That environment reaches the git
  # processes this job's own steps launch; `actions/checkout` is a separate
  # action that runs its own git -- and, for `submodules: recursive`, a tree of
  # further git processes below that -- so the setting has to live somewhere
  # that does not depend on the environment being handed down intact. A
  # configuration FILE is read by every git process on the machine whatever
  # environment it was given. `--local` and `--global` would not do: the deep
  # paths are inside the submodules, and each submodule is its own repository,
  # cloned by a process that never reads the superproject's config.
  # https://git-scm.com/docs/git-config#Documentation/git-config.txt-corelongpaths
  $set = & $GitRunner $GitPath `
    @("config", "--system", "--replace-all", "core.longpaths", "true")
  if ($null -eq $set -or $set.ExitCode -ne 0) {
    $detail = if ($null -eq $set) { "no result" } else { "git exit $($set.ExitCode): $($set.Output)" }
    throw "Enabling core.longpaths in the system Git configuration failed ($detail)."
  }

  # Read it back rather than trusting the exit status. `git config --system`
  # writes into the Git installation's own configuration file, which the runner
  # account may not own; a write that is reported as successful but lands
  # nowhere would otherwise surface minutes later, in the middle of
  # actions/checkout, as the original "Filename too long" -- with nothing
  # pointing at the cause. Failing here fails the job's FIRST step instead.
  $read = & $GitRunner $GitPath @("config", "--system", "--get", "core.longpaths")
  if ($null -eq $read) {
    throw "Reading back the system core.longpaths setting produced no result."
  }
  $value = ([string]$read.Output).Trim()
  if ($read.ExitCode -ne 0 -or $value -cne "true") {
    throw ("Windows long-path support is not enabled: system core.longpaths " +
      "reads back as '$value' (git exit $($read.ExitCode)).")
  }
  return $value
}

function Ensure-CodeTracerGitForCheckout {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Destination,
    [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$GitHubPathFile,
    [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$GitHubEnvFile,
    [Version]$MinimumVersion = $script:MinimumGitVersion,
    [scriptblock]$CandidateProvider = { Get-CodeTracerGitCandidates },
    [scriptblock]$VersionReader = { param($path) Get-CodeTracerGitVersion $path },
    [scriptblock]$ProvisionGit = {
      param($destination, $versionReader)
      Install-CodeTracerPortableGit `
        -Destination $destination `
        -VersionReader $versionReader
    },
    [scriptblock]$EnableSystemLongPaths = {
      param($gitPath)
      Enable-CodeTracerGitSystemLongPaths -GitPath $gitPath
    }
  )

  $git = Find-CodeTracerUsableGit `
    -MinimumVersion $MinimumVersion `
    -CandidateProvider $CandidateProvider `
    -VersionReader $VersionReader
  if ($null -eq $git) {
    $git = & $ProvisionGit $Destination $VersionReader
  }
  if ($null -eq $git -or
      -not (Test-Path -LiteralPath $git.Path -PathType Leaf)) {
    throw "Git provisioning did not return a usable executable."
  }

  $verifiedVersion = & $VersionReader $git.Path
  if ($null -eq $verifiedVersion -or [Version]$verifiedVersion -lt $MinimumVersion) {
    throw "Selected Git does not satisfy the required minimum $MinimumVersion."
  }
  $entries = @(Add-CodeTracerGitToPath `
    -GitPath $git.Path `
    -GitHubPathFile $GitHubPathFile)
  # Both long-path channels are installed here, before this function returns,
  # because the step that returns from it is immediately followed by
  # actions/checkout. The selected git is named by absolute path so the system
  # write goes to the installation that checkout will actually use, not to
  # whichever git happens to be first on PATH.
  & $EnableSystemLongPaths $git.Path | Out-Null
  Add-CodeTracerGitLongPathEnvironment -GitHubEnvFile $GitHubEnvFile
  Write-Host "Using git version $verifiedVersion from $($git.Path) for checkout."
  return [PSCustomObject]@{
    Path = $git.Path
    Version = [Version]$verifiedVersion
    PathEntries = $entries
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  Ensure-CodeTracerGitForCheckout `
    -Destination $InstallRoot `
    -GitHubPathFile $GitHubPath `
    -GitHubEnvFile $GitHubEnv | Out-Null
}

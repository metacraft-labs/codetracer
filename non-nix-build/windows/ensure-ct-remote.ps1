Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-DefaultCtRemoteSourceRid {
  param([Parameter(Mandatory = $true)][string]$Arch)

  switch ($Arch) {
    "x64" { return "win-x64" }
    "arm64" { return "win-arm64" }
    default { throw "Unsupported architecture '$Arch' for ct-remote source RID selection." }
  }
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

function Ensure-CtRemote {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain,
    [Parameter(Mandatory = $true)][string]$WindowsDir
  )

  $version = $Toolchain["CT_REMOTE_VERSION"]
  $archiveSha256 = $Toolchain["CT_REMOTE_WIN_X64_SHA256"]
  $asset = "DesktopClient.App-win-x64-$version.tar.gz"
  $baseUrl = "https://downloads.codetracer.com/DesktopClient.App"
  $archiveUrl = "$baseUrl/$asset"
  $sourceModeRaw = [Environment]::GetEnvironmentVariable("CT_REMOTE_WINDOWS_SOURCE_MODE")
  $sourceMode = if ([string]::IsNullOrWhiteSpace($sourceModeRaw)) { "auto" } else { $sourceModeRaw.Trim().ToLowerInvariant() }
  $localRepoRaw = [Environment]::GetEnvironmentVariable("CT_REMOTE_WINDOWS_SOURCE_REPO")
  if ([string]::IsNullOrWhiteSpace($localRepoRaw)) {
    $localRepoRaw = "../../../codetracer-ci"
  }
  $localRepoRoot = Resolve-AbsolutePathWithBase -PathValue $localRepoRaw -BasePath $WindowsDir
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
        throw "CT_REMOTE_WINDOWS_SOURCE_MODE=download is only supported on Windows x64 because only '$asset' is pinned with '$($Toolchain["CT_REMOTE_WIN_X64_SHA256"])'."
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

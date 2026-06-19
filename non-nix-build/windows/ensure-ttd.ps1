Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Defensive AppX probe — mirrors env.ps1's Invoke-AppxPackageQuery so
# this script can be sourced standalone. The Appx module is only
# available on the Desktop edition of Windows; on hosted Server 2022
# GitHub Actions runners any cmdlet from it fails with HRESULT
# 0x80131539 ("Operation is not supported on this platform"). We
# swallow that specific failure (and related "module not found"
# variants) so the probe degrades to "package unavailable" instead of
# crashing the sync.
function Invoke-AppxPackageQuery {
  param([Parameter(Mandatory = $true)][string]$Name)
  try {
    return Get-AppxPackage -Name $Name -ErrorAction Stop
  } catch {
    $msg = ""
    if ($null -ne $_.Exception) { $msg = [string]$_.Exception.Message }
    $isPlatformUnsupported =
      ($msg -match "0x80131539") -or
      ($msg -match "not supported on this platform") -or
      ($msg -match "Appx") -or
      ($msg -match "PackageManager")
    if ($isPlatformUnsupported) { return $null }
    throw
  }
}

function Get-WindowsArchForTtd {
  if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { return "arm64" }
  return "x64"
}

# Original AppX-backed install: assumes Microsoft.TimeTravelDebugging is
# already installed under Program Files\WindowsApps, copies the TTD
# files out of the AppX container into a regular directory so SSH/CI
# sessions (which cannot execute AppX binaries) can launch them.
function Install-TtdFromAppx {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)]$TtdPkg
  )

  $ttdVersion = [string]$TtdPkg.Version
  $ttdCacheDir = Join-Path $Root "ttd/$ttdVersion"
  $ttdCacheExe = Join-Path $ttdCacheDir "TTD.exe"
  $metaFile = Join-Path $ttdCacheDir "ttd.install.meta"

  $ttdSource = [string]$TtdPkg.InstallLocation
  $expectedMeta = @{
    ttd_version = $ttdVersion
    ttd_source  = $ttdSource
  }

  if ((Test-Path -LiteralPath $ttdCacheExe -PathType Leaf) -and (Test-Path -LiteralPath $metaFile -PathType Leaf)) {
    $cachedMeta = Read-KeyValueFile -Path $metaFile
    if (Test-KeyValueFileMatches -Expected $expectedMeta -Actual $cachedMeta) {
      Write-Host "TTD $ttdVersion already cached at $ttdCacheDir"
      return
    }
  }

  if ([string]::IsNullOrWhiteSpace($ttdSource) -or -not (Test-Path -LiteralPath $ttdSource -PathType Container)) {
    throw "TTD AppX InstallLocation is missing or inaccessible: '$ttdSource'"
  }

  Write-Host "Copying TTD files from AppX to DIY cache: $ttdCacheDir"
  if (Test-Path -LiteralPath $ttdCacheDir) {
    Remove-Item -LiteralPath $ttdCacheDir -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $ttdCacheDir | Out-Null

  $sourceFiles = Get-ChildItem -LiteralPath $ttdSource -File -ErrorAction SilentlyContinue
  foreach ($f in $sourceFiles) {
    Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $ttdCacheDir $f.Name) -Force
  }
  $sourceDirs = Get-ChildItem -LiteralPath $ttdSource -Directory -ErrorAction SilentlyContinue
  foreach ($d in $sourceDirs) {
    Copy-Item -LiteralPath $d.FullName -Destination (Join-Path $ttdCacheDir $d.Name) -Recurse -Force
  }

  if (-not (Test-Path -LiteralPath $ttdCacheExe -PathType Leaf)) {
    throw "TTD.exe not found after copying from AppX. Source: $ttdSource, Dest: $ttdCacheDir"
  }
  Write-KeyValueFile -Path $metaFile -Values $expectedMeta
  Write-Host "TTD $ttdVersion cached successfully at $ttdCacheDir"
}

# Non-AppX install: download the WinDbg .msixbundle from Microsoft's
# CDN, unzip it (twice — outer msixbundle, then per-architecture
# .msix), and extract TTD.exe + companion DLLs. This is the fallback
# for environments where AppX is not supported (hosted Windows Server
# 2022 GHA runners — see
# https://github.com/MicrosoftDocs/WindowsAppSDK/issues/4163). Both
# layers of the bundle are plain ZIP archives, so no AppX runtime is
# touched.
function Install-TtdViaMsixBundle {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][string]$BundleUrl,
    [Parameter(Mandatory = $true)][string]$BundleVersion,
    [string]$BundleSha256 = ""
  )

  $ttdCacheDir = Join-Path $Root "ttd/$BundleVersion"
  $ttdCacheExe = Join-Path $ttdCacheDir "TTD.exe"
  $metaFile = Join-Path $ttdCacheDir "ttd.install.meta"
  $expectedMeta = @{
    ttd_version = $BundleVersion
    ttd_source  = $BundleUrl
  }

  if ((Test-Path -LiteralPath $ttdCacheExe -PathType Leaf) -and (Test-Path -LiteralPath $metaFile -PathType Leaf)) {
    $cachedMeta = Read-KeyValueFile -Path $metaFile
    if (Test-KeyValueFileMatches -Expected $expectedMeta -Actual $cachedMeta) {
      Write-Host "TTD $BundleVersion already cached at $ttdCacheDir (msixbundle path)."
      return
    }
  }

  $workDir = Join-Path $env:TEMP ("windbg-bundle-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $workDir | Out-Null
  try {
    $bundlePath = Join-Path $workDir "windbg.msixbundle"
    Write-Host "Downloading WinDbg msixbundle from $BundleUrl ..."
    $progressPreference = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
      Invoke-WebRequest -Uri $BundleUrl -OutFile $bundlePath -UseBasicParsing
    } finally {
      $ProgressPreference = $progressPreference
    }

    if (-not [string]::IsNullOrWhiteSpace($BundleSha256)) {
      $actual = (Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256).Hash
      if ($actual -ne $BundleSha256.ToUpper()) {
        throw "Downloaded windbg.msixbundle SHA256 mismatch. Expected: $BundleSha256, got: $actual"
      }
      Write-Host "msixbundle SHA256 verified."
    } else {
      Write-Host "WARNING: TTD_BUNDLE_SHA256 not pinned for $BundleVersion — skipping integrity check."
    }

    # Layer 1: msixbundle (a zip of per-architecture .msix files).
    $bundleExtractDir = Join-Path $workDir "bundle"
    $bundleAsZip = Join-Path $workDir "windbg.zip"
    Copy-Item -LiteralPath $bundlePath -Destination $bundleAsZip -Force
    Expand-Archive -LiteralPath $bundleAsZip -DestinationPath $bundleExtractDir -Force

    $msixPattern = "*-$Arch.msix"
    # @(...) forces array semantics so .Count is valid even when
    # Get-ChildItem returns a single FileInfo (which under
    # Set-StrictMode -Version Latest would otherwise throw on .Count).
    $msixCandidates = @(Get-ChildItem -LiteralPath $bundleExtractDir -Filter $msixPattern -File -ErrorAction SilentlyContinue)
    if ($msixCandidates.Count -eq 0) {
      $available = @(Get-ChildItem -LiteralPath $bundleExtractDir -Filter "*.msix" -File -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name }) -join ", "
      throw "WinDbg msixbundle did not contain a $Arch .msix. Available: $available"
    }
    $msixPath = $msixCandidates[0].FullName

    # Layer 2: per-arch .msix (also a zip).
    $msixExtractDir = Join-Path $workDir "msix"
    $msixAsZip = Join-Path $workDir "windbg-arch.zip"
    Copy-Item -LiteralPath $msixPath -Destination $msixAsZip -Force
    Expand-Archive -LiteralPath $msixAsZip -DestinationPath $msixExtractDir -Force

    # TTD ships at the package root in current WinDbg versions; older
    # layouts nest it under <arch>\ttd\. Search recursively so we
    # tolerate both.
    $ttdExeCandidate = Get-ChildItem -LiteralPath $msixExtractDir -Filter "TTD.exe" -File -Recurse -ErrorAction SilentlyContinue |
      Select-Object -First 1
    if ($null -eq $ttdExeCandidate) {
      throw "TTD.exe not found inside extracted msix at $msixExtractDir"
    }
    $ttdSourceDir = $ttdExeCandidate.Directory.FullName

    Write-Host "Copying TTD files from extracted msix to DIY cache: $ttdCacheDir"
    if (Test-Path -LiteralPath $ttdCacheDir) {
      Remove-Item -LiteralPath $ttdCacheDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $ttdCacheDir | Out-Null

    $sourceFiles = Get-ChildItem -LiteralPath $ttdSourceDir -File -ErrorAction SilentlyContinue
    foreach ($f in $sourceFiles) {
      Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $ttdCacheDir $f.Name) -Force
    }
    $sourceDirs = Get-ChildItem -LiteralPath $ttdSourceDir -Directory -ErrorAction SilentlyContinue
    foreach ($d in $sourceDirs) {
      Copy-Item -LiteralPath $d.FullName -Destination (Join-Path $ttdCacheDir $d.Name) -Recurse -Force
    }

    if (-not (Test-Path -LiteralPath $ttdCacheExe -PathType Leaf)) {
      throw "TTD.exe not found at $ttdCacheExe after copying from extracted msix."
    }
    Write-KeyValueFile -Path $metaFile -Values $expectedMeta
    Write-Host "TTD $BundleVersion cached successfully at $ttdCacheDir (msixbundle path)."
  } finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Ensure-Ttd {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [hashtable]$Toolchain = $null
  )

  # Step 1: AppX-backed detection (desktop Windows + developer
  # workstations). Returns $null on Server 2022 / Core SKUs where AppX
  # is not supported.
  $ttdPkg = Invoke-AppxPackageQuery -Name "Microsoft.TimeTravelDebugging" |
    Sort-Object Version -Descending | Select-Object -First 1
  $windbgPkg = Invoke-AppxPackageQuery -Name "Microsoft.WinDbg" |
    Sort-Object Version -Descending | Select-Object -First 1

  if ($null -ne $ttdPkg -and -not [string]::IsNullOrWhiteSpace([string]$ttdPkg.InstallLocation)) {
    Write-Host "Microsoft.TimeTravelDebugging detected via AppX (version $($ttdPkg.Version))."
    Install-TtdFromAppx -Root $Root -TtdPkg $ttdPkg
    return
  }

  # Step 2: AppX present but TTD not installed → winget install, then
  # re-probe. The presence of a working WinDbg AppX entry is our proxy
  # for AppX itself being usable.
  $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
  $appxAvailable = $null -ne $windbgPkg
  if (-not $appxAvailable) {
    $appAppx = Invoke-AppxPackageQuery -Name "Microsoft.WindowsStore"
    $appxAvailable = $null -ne $appAppx
  }

  if ($appxAvailable -and $null -ne $wingetCmd) {
    Write-Host "Installing Microsoft.TimeTravelDebugging via winget..."
    & winget install --id Microsoft.TimeTravelDebugging --exact --source winget --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
      Write-Host "::warning::winget install failed (exit $LASTEXITCODE). Falling back to msixbundle download path."
    } else {
      $ttdPkg = Invoke-AppxPackageQuery -Name "Microsoft.TimeTravelDebugging" |
        Sort-Object Version -Descending | Select-Object -First 1
      if ($null -ne $ttdPkg) {
        Install-TtdFromAppx -Root $Root -TtdPkg $ttdPkg
        return
      }
    }
  }

  # Step 3: AppX is unavailable on this SKU — download the msixbundle
  # directly and extract TTD.exe by hand. Pins come from
  # toolchain-versions.env via the $Toolchain hashtable; env vars
  # override (for ad-hoc testing).
  $bundleUrl = [Environment]::GetEnvironmentVariable("TTD_BUNDLE_URL")
  $bundleVersion = [Environment]::GetEnvironmentVariable("WINDBG_BUNDLE_VERSION")
  $bundleSha = [Environment]::GetEnvironmentVariable("TTD_BUNDLE_SHA256")
  if ([string]::IsNullOrWhiteSpace($bundleUrl) -and $null -ne $Toolchain) {
    $bundleUrl = [string]$Toolchain["TTD_BUNDLE_URL"]
  }
  if ([string]::IsNullOrWhiteSpace($bundleVersion) -and $null -ne $Toolchain) {
    $bundleVersion = [string]$Toolchain["WINDBG_BUNDLE_VERSION"]
  }
  if ([string]::IsNullOrWhiteSpace($bundleSha) -and $null -ne $Toolchain) {
    $bundleSha = [string]$Toolchain["TTD_BUNDLE_SHA256"]
  }
  if ([string]::IsNullOrWhiteSpace($bundleUrl) -or [string]::IsNullOrWhiteSpace($bundleVersion)) {
    throw "AppX is unavailable on this Windows SKU and TTD_BUNDLE_URL / WINDBG_BUNDLE_VERSION are not set. Pin them in non-nix-build/windows/toolchain-versions.env so Ensure-Ttd can fall back to the bundle-download path."
  }
  $arch = Get-WindowsArchForTtd
  Install-TtdViaMsixBundle -Root $Root -Arch $arch -BundleUrl $bundleUrl -BundleVersion $bundleVersion -BundleSha256 $bundleSha
}

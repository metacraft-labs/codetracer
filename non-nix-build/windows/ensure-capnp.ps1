Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-CapnpPrebuiltFileArch {
  param([string]$Arch)
  switch ($Arch) {
    "x64" { return "win32" }
    default { throw "Cap'n Proto prebuilt mode currently supports Windows x64 only. No pinned official asset/hash is configured for '$Arch'." }
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
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["CAPNP_VERSION"]
  $archiveSha256 = $Toolchain["CAPNP_WIN_X64_SHA256"]
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
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["CAPNP_VERSION"]
  $capnpVersionRoot = Join-Path $Root "capnp/$version"
  $sourceCacheRoot = Join-Path $capnpVersionRoot "cache/source"
  $capnpRepo = [Environment]::GetEnvironmentVariable("CAPNP_WINDOWS_SOURCE_REPO")
  if ([string]::IsNullOrWhiteSpace($capnpRepo)) {
    $capnpRepo = $Toolchain["CAPNP_SOURCE_REPO"]
  }
  $capnpRef = [Environment]::GetEnvironmentVariable("CAPNP_WINDOWS_SOURCE_REF")
  if ([string]::IsNullOrWhiteSpace($capnpRef)) {
    $capnpRef = $Toolchain["CAPNP_SOURCE_REF"]
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
  Ensure-NimSourceCompilerEnvironment -Arch $Arch -Root $Root -Toolchain $Toolchain
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
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $requestedModeRaw = [Environment]::GetEnvironmentVariable("CAPNP_WINDOWS_SOURCE_MODE")
  $requestedMode = if ([string]::IsNullOrWhiteSpace($requestedModeRaw)) { "auto" } else { $requestedModeRaw.Trim().ToLowerInvariant() }
  $capnpVersionRoot = Join-Path $Root "capnp/$($Toolchain["CAPNP_VERSION"])"
  $installPathFile = Join-Path $capnpVersionRoot "capnp.install.relative-path"
  $installMetaFile = Join-Path $capnpVersionRoot "capnp.install.meta"

  $result = $null
  switch ($requestedMode) {
    "prebuilt" {
      if ($Arch -ne "x64") {
        throw "CAPNP_WINDOWS_SOURCE_MODE=prebuilt is supported on Windows x64 only. Detected architecture '$Arch'. Use CAPNP_WINDOWS_SOURCE_MODE=source to build from source."
      }
      $result = Ensure-CapnpPrebuilt -Root $Root -Arch $Arch -Toolchain $Toolchain
    }
    "source" {
      $result = Ensure-CapnpFromSource -Root $Root -Arch $Arch -Toolchain $Toolchain
    }
    "auto" {
      if ($Arch -eq "x64") {
        $result = Ensure-CapnpPrebuilt -Root $Root -Arch $Arch -Toolchain $Toolchain
      } else {
        $result = Ensure-CapnpFromSource -Root $Root -Arch $Arch -Toolchain $Toolchain
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
    capnp_version = $Toolchain["CAPNP_VERSION"]
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

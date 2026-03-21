Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-NimFileArch {
  param([string]$Arch)
  switch ($Arch) {
    "x64" { return "x64" }
    default { throw "Nim bootstrap currently supports Windows x64 only. No pinned official asset/hash is configured for '$Arch'." }
  }
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
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
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
      $msys2 = Ensure-TupMsys2BuildPrereqs -Root $Root -Toolchain $Toolchain
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
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["NIM_VERSION"]
  $archiveSha256 = $Toolchain["NIM_WIN_X64_SHA256"]
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
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["NIM_VERSION"]
  $nimVersionRoot = Join-Path $Root "nim/$version"
  $sourceCacheRoot = Join-Path $nimVersionRoot "cache/source"
  $nimRepo = [Environment]::GetEnvironmentVariable("NIM_WINDOWS_SOURCE_REPO")
  if ([string]::IsNullOrWhiteSpace($nimRepo)) {
    $nimRepo = $Toolchain["NIM_SOURCE_REPO"]
  }
  $nimRef = [Environment]::GetEnvironmentVariable("NIM_WINDOWS_SOURCE_REF")
  if ([string]::IsNullOrWhiteSpace($nimRef)) {
    $nimRef = $Toolchain["NIM_SOURCE_REF"]
  }
  $nimRevisionOverride = [Environment]::GetEnvironmentVariable("NIM_WINDOWS_SOURCE_REVISION")
  $csourcesRepo = [Environment]::GetEnvironmentVariable("NIM_WINDOWS_CSOURCES_REPO")
  if ([string]::IsNullOrWhiteSpace($csourcesRepo)) {
    $csourcesRepo = $Toolchain["NIM_CSOURCES_REPO"]
  }
  $csourcesRef = [Environment]::GetEnvironmentVariable("NIM_WINDOWS_CSOURCES_REF")
  if ([string]::IsNullOrWhiteSpace($csourcesRef)) {
    $csourcesRef = $Toolchain["NIM_CSOURCES_REF"]
  }
  $nimRevision = if ([string]::IsNullOrWhiteSpace($nimRevisionOverride)) {
    Resolve-GitRefToRevision -Repository $nimRepo -RefName $nimRef
  } else {
    $nimRevisionOverride.Trim().ToLowerInvariant()
  }
  Ensure-NimSourceCompilerEnvironment -Arch $Arch -Root $Root -Toolchain $Toolchain
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
    & $gitCommand.Source -C $csourcesDir checkout --detach $csourcesRef
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to checkout csources ref '$csourcesRef'."
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
        $prebuiltBootstrap = Ensure-NimPrebuilt -Root $Root -Arch "x64" -Toolchain $Toolchain
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
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["NIM_VERSION"]
  $nimVersionRoot = Join-Path $Root "nim/$version"
  $installPathFile = Join-Path $nimVersionRoot "nim.install.relative-path"
  $installMetaFile = Join-Path $nimVersionRoot "nim.install.meta"

  # Fast path: if Nim is already installed at the expected version, skip all
  # expensive work (git ls-remote, compiler probing, cache key computation).
  if ((Test-Path -LiteralPath $installPathFile -PathType Leaf) -and (Test-Path -LiteralPath $installMetaFile -PathType Leaf)) {
    $existingRelPath = (Get-Content -LiteralPath $installPathFile -Raw).Trim()
    if (-not [string]::IsNullOrWhiteSpace($existingRelPath)) {
      $existingNimExe = Join-Path $Root "$existingRelPath/bin/nim.exe"
      if (Test-Path -LiteralPath $existingNimExe -PathType Leaf) {
        try {
          $existingVersion = Get-NimCompilerVersion -NimExe $existingNimExe
          if ($existingVersion -eq $version) {
            Write-Host "Nim $version already installed at $(Split-Path -Parent (Split-Path -Parent $existingNimExe))"
            return
          }
        } catch {
          # Version check failed; fall through to full bootstrap
        }
      }
    }
  }

  $requestedModeRaw = [Environment]::GetEnvironmentVariable("NIM_WINDOWS_SOURCE_MODE")
  $requestedMode = if ([string]::IsNullOrWhiteSpace($requestedModeRaw)) { "auto" } else { $requestedModeRaw.Trim().ToLowerInvariant() }

  $result = $null
  switch ($requestedMode) {
    "prebuilt" {
      if ($Arch -ne "x64") {
        throw "NIM_WINDOWS_SOURCE_MODE=prebuilt is supported on Windows x64 only. Detected architecture '$Arch'. Use NIM_WINDOWS_SOURCE_MODE=source to attempt source bootstrap on this architecture."
      }
      $result = Ensure-NimPrebuilt -Root $Root -Arch $Arch -Toolchain $Toolchain
    }
    "source" {
      $result = Ensure-NimFromSource -Root $Root -Arch $Arch -Toolchain $Toolchain
    }
    "auto" {
      try {
        $result = Ensure-NimFromSource -Root $Root -Arch $Arch -Toolchain $Toolchain
      } catch {
        if ($Arch -ne "x64") {
          throw "NIM_WINDOWS_SOURCE_MODE=auto attempted Nim source bootstrap on '$Arch' and failed: $($_.Exception.Message) Prebuilt fallback is x64-only. Re-run with NIM_WINDOWS_SOURCE_MODE=source after fixing the source-bootstrap issue."
        }
        Write-Warning "Nim source bootstrap failed in auto mode. Falling back to pinned prebuilt asset. Error: $($_.Exception.Message)"
        $result = Ensure-NimPrebuilt -Root $Root -Arch $Arch -Toolchain $Toolchain
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
    nim_version = $Toolchain["NIM_VERSION"]
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

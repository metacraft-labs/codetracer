Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Innoextract {
  # innoextract.exe at the pinned version, under the install root; returns its
  # path. Used to unpack the FreePascal installer without running it.
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )
  $version = $Toolchain["INNOEXTRACT_VERSION"]
  $expected = $Toolchain["INNOEXTRACT_WIN_SHA256"]
  if ([string]::IsNullOrWhiteSpace($version) -or [string]::IsNullOrWhiteSpace($expected)) {
    throw "INNOEXTRACT_VERSION and INNOEXTRACT_WIN_SHA256 must be set in toolchain-versions.env."
  }
  $dir = Join-Path $Root "innoextract/$version"
  $exe = Join-Path $dir "innoextract.exe"
  if (Test-Path -LiteralPath $exe -PathType Leaf) {
    return $exe
  }
  $zip = Join-Path $env:TEMP "innoextract-$version-windows.zip"
  Download-File -Url "https://github.com/dscharrer/innoextract/releases/download/$version/innoextract-$version-windows.zip" -OutFile $zip
  try {
    Assert-FileSha256 -Path $zip -Expected $expected
    Ensure-CleanDirectory -Path $dir
    $tarExe = Get-WindowsTarExe
    & $tarExe -xf $zip -C $dir
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to extract '$zip' with '$tarExe' (exit $LASTEXITCODE)."
    }
  } finally {
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
  }
  if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw "innoextract $version did not provide '$exe'."
  }
  return $exe
}

function Ensure-Fpc {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["FPC_VERSION"]
  $fpcVersionRoot = Join-Path $Root "fpc/$version"
  $fpcBinDir = Join-Path $fpcVersionRoot "bin/i386-win32"
  $fpcExe = Join-Path $fpcBinDir "fpc.exe"

  if (Test-Path -LiteralPath $fpcExe -PathType Leaf) {
    $currentVersion = ""
    try {
      $versionOutput = & $fpcExe -iV 2>&1
      $currentVersion = ([string]$versionOutput).Trim()
    } catch {}

    if ($currentVersion -eq $version) {
      Write-Host "FreePascal $version already installed at $fpcVersionRoot"
      return
    }
  }

  New-Item -ItemType Directory -Force -Path $fpcVersionRoot | Out-Null

  $expectedSha = $Toolchain["FPC_WIN_SHA256"]
  if ([string]::IsNullOrWhiteSpace($expectedSha)) {
    throw "FPC_WIN_SHA256 is not set in toolchain-versions.env; refusing to run an unverified FreePascal installer."
  }
  $asset = "fpc-$version.win32.and.win64.exe"
  $tempInstaller = Join-Path $env:TEMP $asset

  # FreePascal's own distribution server first; SourceForge (through curl.exe,
  # which gets past its bot challenge) second. Both serve the pinned bytes.
  Write-Host "Downloading FPC $version..."
  $downloaded = $false
  try {
    Download-File -Url "https://downloads.freepascal.org/fpc/dist/$version/i386-win32/$asset" -OutFile $tempInstaller
    Assert-FileSha256 -Path $tempInstaller -Expected $expectedSha
    $downloaded = $true
  } catch {
    Write-Host "FPC download from downloads.freepascal.org failed ($($_.Exception.Message)); trying SourceForge."
  }
  if (-not $downloaded) {
    curl.exe -L -o $tempInstaller "https://downloads.sourceforge.net/project/freepascal/Win32/$version/$asset"
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to download the FreePascal installer from SourceForge (curl exit $LASTEXITCODE)."
    }
    Assert-FileSha256 -Path $tempInstaller -Expected $expectedSha
  }

  try {
    # The payload is UNPACKED with innoextract, not installed: the installer
    # (Inno Setup 5.6.1) aborts without administrator rights -- its log on
    # win-ci-vm-001, codetracer run 44577379303: "User privileges: None ...
    # You must be logged in as an administrator when installing this
    # program. Got EAbort exception." -- and the runner service has none.
    # win-ci-bare-001 passed only because FreePascal was installed there
    # earlier. Unpacking needs no rights, writes nothing outside the install
    # root and leaves no registry entries. Inno's {app} files land under
    # app/; fpc.cfg, which the installer generates at install time, is
    # written below with the tree's own fpcmkcfg.
    $innoextract = Ensure-Innoextract -Root $Root -Toolchain $Toolchain
    $stage = Join-Path $env:TEMP ("fpc-$version-extract-" + [guid]::NewGuid().ToString("N"))
    try {
      $exitCode = Invoke-BoundedNativeCommand -FilePath $innoextract `
        -ArgumentList @("--silent", "--output-dir", $stage, $tempInstaller) `
        -Activity "innoextract of the FreePascal $version installer" -TimeoutSeconds 900
      if ($exitCode -ne 0) {
        throw "innoextract could not unpack the FreePascal installer (exit $exitCode)."
      }
      $appDir = Join-Path $stage "app"
      if (-not (Test-Path -LiteralPath (Join-Path $appDir "bin/i386-win32/fpc.exe") -PathType Leaf)) {
        throw "The unpacked FreePascal installer has no app/bin/i386-win32/fpc.exe under '$stage'."
      }
      Ensure-CleanDirectory -Path $fpcVersionRoot
      Get-ChildItem -LiteralPath $appDir -Force | ForEach-Object {
        Move-Item -LiteralPath $_.FullName -Destination $fpcVersionRoot -Force
      }
    } finally {
      Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }

    # What the installer's post-install step writes: fpc.cfg beside fpc.exe,
    # with the unit search paths rooted at this install.
    $fpcmkcfg = Join-Path $fpcBinDir "fpcmkcfg.exe"
    $fpcCfg = Join-Path $fpcBinDir "fpc.cfg"
    $exitCode = Invoke-BoundedNativeCommand -FilePath $fpcmkcfg `
      -ArgumentList @("-d", "basepath=$fpcVersionRoot", "-o", $fpcCfg) `
      -Activity "fpcmkcfg for FreePascal $version" -TimeoutSeconds 120
    if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $fpcCfg -PathType Leaf)) {
      throw "fpcmkcfg did not write '$fpcCfg' (exit $exitCode)."
    }
  } finally {
    Remove-Item -LiteralPath $tempInstaller -Force -ErrorAction SilentlyContinue
  }

  if (-not (Test-Path -LiteralPath $fpcExe -PathType Leaf)) {
    throw "FreePascal extraction did not produce fpc.exe. Expected '$fpcExe'."
  }

  Write-Host "Installed FreePascal $version to $fpcVersionRoot"
}

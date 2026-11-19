Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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
  $installLog = Join-Path $env:TEMP "fpc-$version-install.log"

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
    # Inno Setup silent install: /VERYSILENT + /SP- + /SUPPRESSMSGBOXES keep it
    # non-interactive; /DIR sets our deterministic install root; /LOG keeps
    # the installer's own account of a failure. It runs bounded and with a
    # closed stdin (Invoke-BoundedNativeCommand), which also quotes /DIR=...
    # and /LOG=... when the paths have spaces. An unbounded `Start-Process
    # -Wait` could leave an installer running on a persistent host when its job
    # was cancelled, and Inno Setup exits 1 ("failed to initialize") on
    # win-ci-vm-001 in codetracer run 44444132651 with nothing said about why.
    $innoArgs = @("/VERYSILENT", "/SP-", "/SUPPRESSMSGBOXES", "/NORESTART",
                  "/NOICONS", "/DIR=$fpcVersionRoot", "/LOG=$installLog")
    $env:__compat_layer = 'RunAsInvoker'
    $exitCode = 0
    foreach ($attempt in 1..2) {
      Ensure-CleanDirectory -Path $fpcVersionRoot
      Remove-Item -LiteralPath $installLog -Force -ErrorAction SilentlyContinue
      $exitCode = Invoke-BoundedNativeCommand -FilePath $tempInstaller -ArgumentList $innoArgs `
        -Activity "the FreePascal $version installer" -TimeoutSeconds 900
      if ($exitCode -eq 0) { break }
      Write-Host "FreePascal installer exited with code $exitCode (attempt $attempt of 2)."
      if (Test-Path -LiteralPath $installLog -PathType Leaf) {
        Write-Host "--- the installer's log (last 40 lines): $installLog"
        Get-Content -LiteralPath $installLog -Tail 40 | ForEach-Object { Write-Host "  $_" }
      } else {
        Write-Host "--- the installer wrote no log at $installLog (it stopped before Setup initialized)."
      }
      $others = @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -like "fpc-*" -or $_.ProcessName -like "is-*" } |
        ForEach-Object {
          $started = try { [string]$_.StartTime } catch { "unknown" }
          "$($_.ProcessName) (pid $($_.Id), started $started)"
        })
      Write-Host "--- installer processes still running: $(if ($others.Count) { $others -join '; ' } else { 'none' })"
      if ($attempt -eq 1) { Start-Sleep -Seconds 15 }
    }
    if ($exitCode -ne 0) {
      throw "FreePascal installer exited with code $exitCode twice; its log and the running installer processes are printed above."
    }
  } finally {
    Remove-Item -LiteralPath $tempInstaller -Force -ErrorAction SilentlyContinue
  }

  if (-not (Test-Path -LiteralPath $fpcExe -PathType Leaf)) {
    throw "FreePascal extraction did not produce fpc.exe. Expected '$fpcExe'."
  }

  Write-Host "Installed FreePascal $version to $fpcVersionRoot"
}

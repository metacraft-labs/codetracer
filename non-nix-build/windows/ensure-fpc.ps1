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
  $fpcExe = Join-Path $fpcVersionRoot "bin/x86_64-win64/fpc.exe"

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
  # FreePascal ships its Windows distribution as an Inno Setup installer
  # .exe — there is no .zip on SourceForge (the old code downloaded a
  # non-existent .zip; SourceForge's project/files/.../download URL
  # served an HTML interstitial that then failed Expand-Archive).
  # Download the installer via the direct mirror host and run it silently.
  $asset = "fpc-$version.i386-win32.cross.x86_64-win64.exe"
  $downloadUrl = "https://downloads.sourceforge.net/project/freepascal/Win32/$version/$asset"

  $tempInstaller = Join-Path $env:TEMP "fpc-$version-x86_64-win64.exe"
  Download-File -Url $downloadUrl -OutFile $tempInstaller

  try {
    Ensure-CleanDirectory -Path $fpcVersionRoot
    # Inno Setup silent install: /VERYSILENT + /SP- + /SUPPRESSMSGBOXES
    # keep it non-interactive; /DIR sets our deterministic install root.
    $innoArgs = @("/VERYSILENT", "/SP-", "/SUPPRESSMSGBOXES", "/NORESTART",
                  "/NOICONS", "/DIR=$fpcVersionRoot")
    $proc = Start-Process -FilePath $tempInstaller -ArgumentList $innoArgs -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
      throw "FreePascal installer exited with code $($proc.ExitCode)."
    }
  } finally {
    Remove-Item -LiteralPath $tempInstaller -Force -ErrorAction SilentlyContinue
  }

  # The zip may extract into a nested directory; try to locate fpc.exe.
  if (-not (Test-Path -LiteralPath $fpcExe -PathType Leaf)) {
    # Search for fpc.exe within the extraction root.
    $candidates = Get-ChildItem -LiteralPath $fpcVersionRoot -Recurse -Filter "fpc.exe" -ErrorAction SilentlyContinue
    if ($candidates.Count -gt 0) {
      Write-Host "FreePascal fpc.exe found at $($candidates[0].FullName) (expected at $fpcExe)."
    } else {
      throw "FreePascal extraction did not produce fpc.exe. Expected '$fpcExe'."
    }
  }

  Write-Host "Installed FreePascal $version to $fpcVersionRoot"
}

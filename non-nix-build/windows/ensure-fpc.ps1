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
  
  $asset = "fpc-$version.win32.and.win64.exe"
  $downloadUrl = "https://downloads.sourceforge.net/project/freepascal/Win32/$version/$asset"
  
  $tempInstaller = Join-Path $env:TEMP $asset
  Write-Host "Downloading FPC $version..."
  
  # Using curl.exe to bypass Cloudflare bot challenge on SourceForge
  curl.exe -L -o $tempInstaller $downloadUrl
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to download FreePascal compiler from $downloadUrl"
  }

  try {
    Ensure-CleanDirectory -Path $fpcVersionRoot
    # Inno Setup silent install: /VERYSILENT + /SP- + /SUPPRESSMSGBOXES
    # keep it non-interactive; /DIR sets our deterministic install root.
    $innoArgs = @("/VERYSILENT", "/SP-", "/SUPPRESSMSGBOXES", "/NORESTART",
                  "/NOICONS", "/DIR=$fpcVersionRoot")
    $env:__compat_layer = 'RunAsInvoker'
    $proc = Start-Process -FilePath $tempInstaller -ArgumentList $innoArgs -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
      throw "FreePascal installer exited with code $($proc.ExitCode)."
    }
  } finally {
    Remove-Item -LiteralPath $tempInstaller -Force -ErrorAction SilentlyContinue
  }

  if (-not (Test-Path -LiteralPath $fpcExe -PathType Leaf)) {
    throw "FreePascal extraction did not produce fpc.exe. Expected '$fpcExe'."
  }

  Write-Host "Installed FreePascal $version to $fpcVersionRoot"
}

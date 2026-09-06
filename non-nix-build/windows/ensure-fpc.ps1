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
    # NOT `Start-Process -ArgumentList`, and the reason is `/DIR=`.
    #
    # `Start-Process` joins its argument array with spaces and quotes nothing,
    # so `/DIR=C:\Users\Jane Doe\...\fpc\3.2.2` would arrive as `/DIR=C:\Users\Jane`
    # plus a stray `Doe\...` operand -- a silent install into the wrong
    # directory, or a rejected switch, on any host whose dev-deps root contains
    # a space. CI's root has none, which is exactly why a bug of this shape can
    # sit here indefinitely without being seen.
    #
    # `Invoke-BoundedNativeCommand` passes a real per-argument list, and brings
    # two things this call also wanted anyway: a wall-clock bound, and a closed
    # stdin so a silent installer that decides to ask something fails fast
    # rather than holding the runner.
    $installerExit = Invoke-BoundedNativeCommand `
      -FilePath $tempInstaller `
      -ArgumentList $innoArgs `
      -Activity "FreePascal $version silent install"
    if ($installerExit -ne 0) {
      throw "FreePascal installer exited with code $installerExit."
    }
  } finally {
    Remove-Item -LiteralPath $tempInstaller -Force -ErrorAction SilentlyContinue
  }

  if (-not (Test-Path -LiteralPath $fpcExe -PathType Leaf)) {
    throw "FreePascal extraction did not produce fpc.exe. Expected '$fpcExe'."
  }

  Write-Host "Installed FreePascal $version to $fpcVersionRoot"
}

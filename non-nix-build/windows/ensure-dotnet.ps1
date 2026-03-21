Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Dotnet {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["DOTNET_SDK_VERSION"]
  $dotnetRoot = Join-Path $Root "dotnet/$version"
  $dotnetExe = Join-Path $dotnetRoot "dotnet.exe"

  # Check if dotnet is already installed at the managed location with the right SDK.
  if (Test-Path -LiteralPath $dotnetExe -PathType Leaf) {
    $sdkLines = & $dotnetExe --list-sdks 2>$null
    if ($LASTEXITCODE -eq 0) {
      foreach ($line in $sdkLines) {
        if ([string]$line -match "^\s*([0-9]+\.[0-9]+\.[0-9]+)\s") {
          if ($matches[1] -eq $version) {
            Write-Host "dotnet SDK $version already installed at $dotnetRoot"
            return
          }
        }
      }
    }
  }

  # Also check the system-wide install and WINDOWS_DIY_DOTNET_ROOT override;
  # if the right SDK is already present there, skip the managed install.
  $systemCandidates = @()
  $override = [Environment]::GetEnvironmentVariable("WINDOWS_DIY_DOTNET_ROOT")
  if (-not [string]::IsNullOrWhiteSpace($override)) {
    $systemCandidates += $override.Trim()
  }
  $systemCandidates += (Join-Path ${env:ProgramFiles} "dotnet")

  foreach ($candidate in $systemCandidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    $candidateExe = Join-Path $candidate "dotnet.exe"
    if (-not (Test-Path -LiteralPath $candidateExe -PathType Leaf)) { continue }
    $sdkLines = & $candidateExe --list-sdks 2>$null
    if ($LASTEXITCODE -ne 0) { continue }
    foreach ($line in $sdkLines) {
      if ([string]$line -match "^\s*([0-9]+\.[0-9]+\.[0-9]+)\s") {
        if ($matches[1] -eq $version) {
          Write-Host "dotnet SDK $version found at system location $candidate — skipping managed install"
          return
        }
      }
    }
  }

  # Install using Microsoft's official dotnet-install.ps1 script.
  Write-Host "Installing dotnet SDK $version to $dotnetRoot ..."
  $installerPath = Join-Path $env:TEMP "dotnet-install.ps1"
  Download-File -Url "https://dot.net/v1/dotnet-install.ps1" -OutFile $installerPath

  New-Item -ItemType Directory -Force -Path $dotnetRoot | Out-Null
  & $installerPath -Version $version -InstallDir $dotnetRoot -NoPath
  if ($LASTEXITCODE -ne 0) {
    throw "dotnet-install.ps1 failed with exit code $LASTEXITCODE."
  }

  if (-not (Test-Path -LiteralPath $dotnetExe -PathType Leaf)) {
    throw "dotnet-install.ps1 did not produce '$dotnetExe'."
  }

  Write-Host "Installed dotnet SDK $version to $dotnetRoot"
}

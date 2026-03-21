Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Ttd {
  # TTD and WinDbg are system-level AppX packages installed via winget,
  # not into the DIY cache. This function installs them if missing and
  # validates that the installed versions meet minimum requirements.
  $ttdPkg = Get-AppxPackage "Microsoft.TimeTravelDebugging" -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending | Select-Object -First 1
  $windbgPkg = Get-AppxPackage "Microsoft.WinDbg" -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending | Select-Object -First 1

  $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
  if ($null -eq $wingetCmd) {
    if ($null -eq $ttdPkg -or $null -eq $windbgPkg) {
      throw "winget is required to install TTD/WinDbg but was not found on PATH. Install winget (App Installer from Microsoft Store) or install TTD/WinDbg manually."
    }
    Write-Host "winget not found; TTD and WinDbg already installed, skipping install step."
  } else {
    if ($null -eq $ttdPkg) {
      Write-Host "Installing Microsoft.TimeTravelDebugging via winget..."
      & winget install --id Microsoft.TimeTravelDebugging --exact --source winget --accept-source-agreements --accept-package-agreements
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to install Microsoft.TimeTravelDebugging via winget (exit code $LASTEXITCODE)."
      }
      $ttdPkg = Get-AppxPackage "Microsoft.TimeTravelDebugging" -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    } else {
      Write-Host "Microsoft.TimeTravelDebugging already installed (version $($ttdPkg.Version))."
    }

    if ($null -eq $windbgPkg) {
      Write-Host "Installing Microsoft.WinDbg via winget..."
      & winget install --id Microsoft.WinDbg --exact --source winget --accept-source-agreements --accept-package-agreements
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to install Microsoft.WinDbg via winget (exit code $LASTEXITCODE)."
      }
      $windbgPkg = Get-AppxPackage "Microsoft.WinDbg" -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    } else {
      Write-Host "Microsoft.WinDbg already installed (version $($windbgPkg.Version))."
    }
  }

  # Validate installation
  if ($null -eq $ttdPkg) {
    throw "Microsoft.TimeTravelDebugging is not installed after attempted install."
  }
  if ($null -eq $windbgPkg) {
    throw "Microsoft.WinDbg is not installed after attempted install."
  }

  Write-Host "TTD version: $($ttdPkg.Version), WinDbg version: $($windbgPkg.Version)"
}

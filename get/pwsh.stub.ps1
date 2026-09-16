# CodeTracer PowerShell installer — coming soon
#
# Served from https://get.codetracer.com/pwsh
#
# A native PowerShell bootstrapper for Windows is not available yet. In the
# meantime:
#
#   * Windows desktop app / downloads:  https://downloads.codetracer.com
#   * Releases:                         https://github.com/metacraft-labs/codetracer/releases
#   * Or install under WSL:
#       wsl -- bash -c "curl -fsSL https://get.codetracer.com/sh | sh"
#
# This script intentionally exits non-zero so nothing is silently installed.

Write-Host "CodeTracer: a native PowerShell installer is not available yet." -ForegroundColor Yellow
Write-Host "Get the Windows desktop app: https://downloads.codetracer.com"
Write-Host "Releases: https://github.com/metacraft-labs/codetracer/releases"
Write-Host "Or install under WSL:" -ForegroundColor Yellow
Write-Host '  wsl -- bash -c "curl -fsSL https://get.codetracer.com/sh | sh"'
exit 1

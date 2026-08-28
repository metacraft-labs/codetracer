# CodeTracer Windows installer (PowerShell).
#
# Served as https://get.codetracer.com/pwsh. Typical use:
#
#   irm https://get.codetracer.com/pwsh | iex
#
# Inspect before running:  irm https://get.codetracer.com/pwsh | more
#
# It downloads the signed NSIS installer (CodeTracer-Setup.exe) from the release
# store, verifies its GPG signature against the CodeTracer signing key when gpg
# is available, then runs it silently (`/S`) and confirms `ct` is installed.
#
# Artifacts come from the release store (GitHub Releases / downloads.codetracer.com).
# This mirrors the POSIX installer (install-on-distributions.sh -> /sh): same
# CodeTracer.pub.asc key, same "verify-or-refuse" posture with a
# CODETRACER_INSTALL_ALLOW_UNVERIFIED=1 escape hatch.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DownloadBase = 'https://downloads.codetracer.com'
$Arch         = 'win-x64'
$InstallerKey = "CodeTracer-latest-$Arch.exe"

function Write-Note { param([string]$Message) Write-Host "[CodeTracer installer] $Message" }
function Write-Warn { param([string]$Message) Write-Host "[CodeTracer installer Warning]: $Message" -ForegroundColor Yellow }

function Stop-Fatal {
    param([string]$Message)
    Write-Host "[CodeTracer installer Error]: $Message" -ForegroundColor Red
    exit 1
}

# Refuse-by-default when integrity cannot be established at all (gpg missing, key
# import failed) -- distinct from a signature that was checked and did NOT match,
# which is always fatal below with no opt-out. This is an irm|iex path, so
# silently proceeding is how an unsigned or substituted download gets executed.
function Deny-Unverified {
    param([string]$Reason, [string]$InstallerPath, [string]$SignaturePath)
    if ($env:CODETRACER_INSTALL_ALLOW_UNVERIFIED -eq '1') {
        Write-Warn "Installing CodeTracer WITHOUT verifying its integrity: $Reason.`n  Proceeding because CODETRACER_INSTALL_ALLOW_UNVERIFIED=1 is set."
        return
    }
    Remove-Item -Force -ErrorAction SilentlyContinue $InstallerPath, $SignaturePath
    Stop-Fatal ("Cannot verify the integrity of $InstallerKey`: $Reason.`n" +
        "  Refusing to install an unverified bundle, and the download has been deleted.`n" +
        "  Install gnupg (e.g. ``winget install GnuPG.GnuPG``) and retry, or re-run with`n" +
        "  `$env:CODETRACER_INSTALL_ALLOW_UNVERIFIED='1' if you accept the risk.")
}

function Get-File {
    param([string]$Url, [string]$OutFile, [string]$What, [switch]$Optional)
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    } catch {
        if ($Optional) { return $false }
        Stop-Fatal "Couldn't download $What from $Url`n  ($($_.Exception.Message))`n  The Windows build may not be published yet -- see https://get.codetracer.com."
    }
    return $true
}

$workDir = Join-Path ([IO.Path]::GetTempPath()) ("codetracer-install-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
$installer = Join-Path $workDir 'CodeTracer-Setup.exe'
$signature = "$installer.asc"
$pubKey    = Join-Path $workDir 'CodeTracer.pub.asc'

try {
    Write-Note "Downloading $InstallerKey"
    [void](Get-File -Url "$DownloadBase/$InstallerKey" -OutFile $installer -What 'the CodeTracer installer')

    # Integrity verification is a security control: a present-but-mismatched
    # signature is never tolerated; only "could not verify at all" has the
    # explicit opt-out above.
    $gpg = Get-Command gpg -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gpg) {
        $haveKey = Get-File -Url "$DownloadBase/CodeTracer.pub.asc" -OutFile $pubKey -What 'the CodeTracer signing key' -Optional
        $haveSig = Get-File -Url "$DownloadBase/$InstallerKey.asc" -OutFile $signature -What 'the GPG signature' -Optional
        if (-not ($haveKey -and $haveSig)) {
            Deny-Unverified -Reason 'the signing key or detached signature could not be downloaded' -InstallerPath $installer -SignaturePath $signature
        } else {
            & $gpg.Source --import $pubKey 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Deny-Unverified -Reason 'the CodeTracer signing key could not be imported' -InstallerPath $installer -SignaturePath $signature
            } else {
                & $gpg.Source --verify $signature $installer 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Remove-Item -Force -ErrorAction SilentlyContinue $installer, $signature
                    Stop-Fatal ("SIGNATURE VERIFICATION FAILED for $InstallerKey.`n" +
                        "  The download does not match the CodeTracer signing key. It may be corrupt`n" +
                        "  or tampered with. Refusing to install, and the download has been deleted.")
                }
                Write-Note 'Successfully verified installer signature'
            }
        }
    } else {
        Deny-Unverified -Reason 'gpg is not installed' -InstallerPath $installer -SignaturePath $signature
    }

    Write-Note 'Running the CodeTracer installer (silent)'
    # NSIS silent-install flag is `/S` (must be upper-case, before other args).
    $proc = Start-Process -FilePath $installer -ArgumentList '/S' -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Stop-Fatal "The CodeTracer installer exited with code $($proc.ExitCode)."
    }

    # The installer edits the persistent PATH, but this session's PATH was
    # captured at launch. Refresh it from the registry so we can confirm the
    # install in-place instead of telling every user to reopen their terminal.
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machinePath, $userPath) | Where-Object { $_ }) -join ';'

    $ct = Get-Command ct -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ct) {
        Write-Note "CodeTracer installed: $($ct.Source)"
        Write-Note 'Run `ct` in a new terminal to get started.'
    } else {
        Write-Warn ("CodeTracer was installed, but ``ct`` is not on PATH in this session.`n" +
            "  Open a new terminal and run ``ct``. If it is still missing, check the`n" +
            '  install directory (default: %LOCALAPPDATA%\Programs\CodeTracer).')
    }
    Write-Host '[CodeTracer installer] Done.' -ForegroundColor Green
} finally {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $workDir
}

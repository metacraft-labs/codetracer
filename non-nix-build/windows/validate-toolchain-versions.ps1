[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$FilePath = "$PSScriptRoot/toolchain-versions.env"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$requiredKeys = @(
  "RUSTUP_VERSION",
  "RUST_TOOLCHAIN_VERSION",
  "NODE_VERSION",
  "UV_VERSION",
  "DOTNET_SDK_VERSION",
  "NIM_VERSION",
  "NIM_WIN_X64_SHA256",
  "NIM_SOURCE_REPO",
  "NIM_SOURCE_REF",
  "NIM_CSOURCES_REPO",
  "NIM_CSOURCES_REF",
  "CT_REMOTE_VERSION",
  "CT_REMOTE_WIN_X64_SHA256",
  "CAPNP_VERSION",
  "CAPNP_WIN_X64_SHA256",
  "CAPNP_SOURCE_REPO",
  "CAPNP_SOURCE_REF",
  "TUP_SOURCE_REPO",
  "TUP_SOURCE_REF",
  "TUP_SOURCE_BUILD_COMMAND",
  "TUP_PREBUILT_VERSION",
  "TUP_PREBUILT_URL",
  "TUP_PREBUILT_SHA256",
  "TUP_MSYS2_BASE_VERSION",
  "TUP_MSYS2_BASE_X64_SHA256",
  "TUP_MSYS2_PACKAGES"
)

$valuePatterns = @{
  "RUSTUP_VERSION" = '^[0-9]+(?:\.[0-9]+)*(?:[-+][0-9A-Za-z.-]+)?$'
  "RUST_TOOLCHAIN_VERSION" = '^[0-9]+(?:\.[0-9]+)*(?:[-+][0-9A-Za-z.-]+)?$'
  "NODE_VERSION" = '^[0-9]+(?:\.[0-9]+)*(?:[-+][0-9A-Za-z.-]+)?$'
  "UV_VERSION" = '^[0-9]+(?:\.[0-9]+)*(?:[-+][0-9A-Za-z.-]+)?$'
  "DOTNET_SDK_VERSION" = '^[0-9]+(?:\.[0-9]+)*(?:[-+][0-9A-Za-z.-]+)?$'
  "NIM_VERSION" = '^[0-9]+(?:\.[0-9]+)*(?:[-+][0-9A-Za-z.-]+)?$'
  "NIM_WIN_X64_SHA256" = '^[A-Fa-f0-9]{64}$'
  "NIM_SOURCE_REPO" = '^https?://\S+$'
  "NIM_SOURCE_REF" = '^[0-9A-Za-z._/\-]+$'
  "NIM_CSOURCES_REPO" = '^https?://\S+$'
  "NIM_CSOURCES_REF" = '^[0-9A-Za-z._/\-]+$'
  "CT_REMOTE_VERSION" = '^[0-9A-Za-z._-]+$'
  "CT_REMOTE_WIN_X64_SHA256" = '^[A-Fa-f0-9]{64}$'
  "CAPNP_VERSION" = '^[0-9]+(?:\.[0-9]+)*(?:[-+][0-9A-Za-z.-]+)?$'
  "CAPNP_WIN_X64_SHA256" = '^[A-Fa-f0-9]{64}$'
  "CAPNP_SOURCE_REPO" = '^https?://\S+$'
  "CAPNP_SOURCE_REF" = '^[0-9A-Za-z._/\-]+$'
  "TUP_SOURCE_REPO" = '^https?://\S+$'
  "TUP_SOURCE_REF" = '^[0-9A-Za-z._/\-]+$'
  "TUP_SOURCE_BUILD_COMMAND" = '^.+$'
  "TUP_PREBUILT_VERSION" = '^[0-9A-Za-z._/\-]+$'
  "TUP_PREBUILT_URL" = '^https?://\S+$'
  "TUP_PREBUILT_SHA256" = '^[A-Fa-f0-9]{64}$'
  "TUP_MSYS2_BASE_VERSION" = '^[0-9]{8}$'
  "TUP_MSYS2_BASE_X64_SHA256" = '^[A-Fa-f0-9]{64}$'
  "TUP_MSYS2_PACKAGES" = '^[A-Za-z0-9+_.-]+(?: [A-Za-z0-9+_.-]+)*$'
}

if (-not (Test-Path -LiteralPath $FilePath)) {
  throw "Missing required file: $FilePath"
}

$keyCounts = @{}
$keyValues = @{}
$errors = New-Object System.Collections.Generic.List[string]

$lines = Get-Content -LiteralPath $FilePath
for ($lineNumber = 1; $lineNumber -le $lines.Count; $lineNumber++) {
  $line = $lines[$lineNumber - 1]
  if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) {
    continue
  }

  if ($line -notmatch '^\s*(?<key>[A-Z0-9_]+)\s*=\s*(?<value>.*)\s*$') {
    $errors.Add("Line $lineNumber is not in KEY=VALUE format: '$line'")
    continue
  }

  $key = $Matches.key
  $value = $Matches.value.Trim()
  if ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2) {
    $value = $value.Substring(1, $value.Length - 2)
  } elseif ($value.StartsWith("'") -and $value.EndsWith("'") -and $value.Length -ge 2) {
    $value = $value.Substring(1, $value.Length - 2)
  }

  if (-not $keyCounts.ContainsKey($key)) {
    $keyCounts[$key] = 0
  }
  $keyCounts[$key] += 1

  if (-not $keyValues.ContainsKey($key)) {
    $keyValues[$key] = $value
  }
}

foreach ($key in $requiredKeys) {
  if (-not $keyCounts.ContainsKey($key)) {
    $errors.Add("Missing required key: $key")
    continue
  }

  if ($keyCounts[$key] -ne 1) {
    $errors.Add("Key '$key' must appear exactly once, found $($keyCounts[$key])")
  }

  $value = $keyValues[$key]
  if ([string]::IsNullOrWhiteSpace($value)) {
    $errors.Add("Key '$key' has an empty value")
    continue
  }

  $pattern = $valuePatterns[$key]
  if (-not $pattern) {
    $errors.Add("Missing validation pattern for key '$key'")
    continue
  }

  if ($value -notmatch $pattern) {
    $errors.Add("Key '$key' has invalid value '$value'")
  }
}

if ($errors.Count -gt 0) {
  throw ("toolchain-versions.env validation failed:`n - " + ($errors -join "`n - "))
}

Write-Host "toolchain-versions.env validation passed for '$FilePath'."

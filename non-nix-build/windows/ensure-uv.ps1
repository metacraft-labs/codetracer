Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-UvTarget {
  param([string]$Arch)
  switch ($Arch) {
    "x64" { return "x86_64-pc-windows-msvc" }
    "arm64" { return "aarch64-pc-windows-msvc" }
    default { throw "Unsupported uv target arch '$Arch'." }
  }
}

function Ensure-Uv {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["UV_VERSION"]
  $target = ConvertTo-UvTarget -Arch $Arch
  $asset = "uv-$target.zip"
  $uvRoot = Join-Path $Root "uv/$version"
  $uvExe = Join-Path $uvRoot "uv.exe"

  if (Test-Path $uvExe) {
    $current = (& $uvExe --version).Split(" ")[1]
    if ($current -eq $version) {
      Write-Host "uv $version already installed at $uvRoot"
      return
    }
  }

  $baseUrl = "https://github.com/astral-sh/uv/releases/download/$version"
  $zipUrl = "$baseUrl/$asset"
  $shaUrl = "$baseUrl/$asset.sha256"
  $tempZip = Join-Path $env:TEMP "$asset"

  Download-File -Url $zipUrl -OutFile $tempZip
  $shaText = Download-String -Url $shaUrl
  $expected = Get-ExpectedSha256 -ShaSource $shaText -AssetName $asset
  Assert-FileSha256 -Path $tempZip -Expected $expected

  Ensure-CleanDirectory -Path $uvRoot
  Expand-Archive -Path $tempZip -DestinationPath $uvRoot -Force
  Remove-Item -LiteralPath $tempZip -Force

  if (-not (Test-Path $uvExe)) {
    throw "uv extraction did not produce '$uvExe'."
  }

  Write-Host "Installed uv $version to $uvRoot"
}

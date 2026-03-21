Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-NodeFileArch {
  param([string]$Arch)
  switch ($Arch) {
    "x64" { return "x64" }
    "arm64" { return "arm64" }
    default { throw "Unsupported Node arch '$Arch'." }
  }
}

function Ensure-Node {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["NODE_VERSION"]
  $nodeArch = ConvertTo-NodeFileArch -Arch $Arch
  $asset = "node-v$version-win-$nodeArch.zip"
  $nodeVersionRoot = Join-Path $Root "node/$version"
  $extractDir = Join-Path $nodeVersionRoot "node-v$version-win-$nodeArch"
  $nodeExe = Join-Path $extractDir "node.exe"

  if (Test-Path $nodeExe) {
    $installedVersion = (& $nodeExe --version).TrimStart("v")
    if ($installedVersion -eq $version) {
      Write-Host "Node.js $version already installed at $extractDir"
      return
    }
  }

  New-Item -ItemType Directory -Force -Path $nodeVersionRoot | Out-Null
  $downloadUrl = "https://nodejs.org/dist/v$version/$asset"
  $sumsUrl = "https://nodejs.org/dist/v$version/SHASUMS256.txt"

  $tempZip = Join-Path $env:TEMP "$asset"
  Download-File -Url $downloadUrl -OutFile $tempZip

  $sumsText = Download-String -Url $sumsUrl
  $expected = Get-ExpectedSha256 -ShaSource $sumsText -AssetName $asset
  Assert-FileSha256 -Path $tempZip -Expected $expected

  Ensure-CleanDirectory -Path $nodeVersionRoot
  Expand-Archive -Path $tempZip -DestinationPath $nodeVersionRoot -Force
  Remove-Item -LiteralPath $tempZip -Force

  if (-not (Test-Path $nodeExe)) {
    throw "Node.js extraction did not produce '$nodeExe'."
  }

  Write-Host "Installed Node.js $version to $extractDir"
}

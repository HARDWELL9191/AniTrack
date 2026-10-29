# Installs the Windows App SDK runtime AniTrack's AI helper needs, if it isn't there yet.
# Downloaded from Microsoft at install time (instead of making AniTrack's installer 120 MB
# bigger), and only run after Windows confirms it's signed by Microsoft.
# Run by AniTrack's installer (with admin rights) and by the build's own check.
param([string]$Framework = "__FRAMEWORK_NAME__", [string]$Version = "__RUNTIME_VERSION__")
$ErrorActionPreference = "Stop"

$installed = Get-AppxPackage -Name $Framework -PackageTypeFilter Framework -AllUsers -ErrorAction SilentlyContinue |
  Where-Object { "$($_.Architecture)" -eq "Arm64" }
if (-not $installed) { $installed = Get-AppxPackage -Name $Framework -ErrorAction SilentlyContinue }
if ($installed) {
  Write-Output "Windows App SDK runtime already installed ($Framework)."
  exit 0
}

$url = "https://aka.ms/windowsappsdk/$($Version.Split('.')[0..1] -join '.')/$Version/windowsappruntimeinstall-arm64.exe"
$exe = Join-Path ([System.IO.Path]::GetTempPath()) "anitrack-windowsappruntime-$Version.exe"
Write-Output "Downloading the Windows App SDK runtime $Version..."
$ProgressPreference = "SilentlyContinue"
Invoke-WebRequest $url -OutFile $exe -UseBasicParsing

$signature = Get-AuthenticodeSignature $exe
if ($signature.Status -ne "Valid" -or $signature.SignerCertificate.Subject -notmatch "O=Microsoft Corporation") {
  Remove-Item $exe -Force
  throw "The downloaded runtime isn't signed by Microsoft ($($signature.Status)); not installing it."
}
& $exe --quiet
$code = $LASTEXITCODE
Remove-Item $exe -Force -ErrorAction SilentlyContinue
Write-Output "Windows App SDK runtime installer exit code: $code"
exit $code

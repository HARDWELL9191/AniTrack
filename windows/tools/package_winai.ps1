# Builds what "Why would I like this?" needs to use Windows' on-device language model:
#  - the AI helper (ai-helper/, .NET 10, ARM64) -> src-tauri/resources/ai-helper
#  - the Windows App SDK 2.5.4-experimental runtime installer          -> src-tauri/resources/winai
#  - AniTrack.AI.msix: the identity package (packaged with external location), signed with a
#    certificate made for this build; its public part (AniTrack.cer) is what the installer
#    trusts. The private key never leaves this build machine.
$ErrorActionPreference = "Stop"
# Results and errors as GitHub annotations (readable from the run page and the API).
function Note($message) { Write-Host "::notice::$(($message | Out-String).Trim() -replace "`r?`n", '%0A')" }
trap { Write-Host "::error::$($_.Exception.Message -replace "`r?`n", '%0A')"; break }
$RuntimeVersion = "2.5.4-experimental"
$RuntimeUrl = "https://aka.ms/windowsappsdk/2.5/$RuntimeVersion/windowsappruntimeinstall-arm64.exe"

# The Appx cmdlets: native in newer PowerShell 7, through Windows PowerShell compatibility otherwise.
try { Get-AppxPackage -Name "None.Such.Package" | Out-Null } catch { Import-Module Appx -UseWindowsPowerShell -WarningAction SilentlyContinue }
$root = Split-Path -Parent $PSScriptRoot
$res = Join-Path $root "src-tauri/resources"
$winai = Join-Path $res "winai"
$helperOut = Join-Path $res "ai-helper"
New-Item -ItemType Directory -Force -Path $winai, $helperOut | Out-Null

# 1. The helper.
dotnet publish (Join-Path $root "ai-helper/AniTrack.AI.csproj") -c Release -r win-arm64 --self-contained -o $helperOut
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }
if (-not (Test-Path (Join-Path $helperOut "AniTrack.AI.exe"))) { throw "AniTrack.AI.exe missing" }

# 2. The Windows App SDK runtime the helper runs on (installed by AniTrack's installer).
$runtimeExe = Join-Path $winai "windowsappruntimeinstall-arm64.exe"
Invoke-WebRequest $RuntimeUrl -OutFile $runtimeExe

# 3. Which framework package that runtime provides (name + version for the manifest): read from
#    the Windows App SDK NuGet packages' MSIX inventory, or else from Windows after installing it.
$pattern = "(Microsoft\.WindowsAppRuntime\.\d[^_\s]*)_([0-9.]+)_arm64__"
$nugetRoot = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $env:USERPROFILE ".nuget/packages" }
$framework = $null
$inventories = Get-ChildItem $nugetRoot -Directory -Filter "microsoft.windowsappsdk*" |
  ForEach-Object { Get-ChildItem (Join-Path $_.FullName $RuntimeVersion) -Recurse -Filter "MSIX.inventory" -ErrorAction SilentlyContinue }
foreach ($inv in $inventories) {
  Write-Host "Inventory: $($inv.FullName)"
  foreach ($line in Get-Content $inv.FullName) {
    if (-not $framework -and $line -match $pattern) { $framework = [pscustomobject]@{ Name = $Matches[1]; Version = $Matches[2] } }
  }
}
if (-not $framework) {
  Write-Host "No MSIX inventory with the framework; installing the runtime to read it from Windows."
  & $runtimeExe --quiet
  $framework = Get-AppxPackage -Name "Microsoft.WindowsAppRuntime.2.5*" |
    Where-Object { $_.IsFramework -and "$($_.Architecture)" -eq "Arm64" } |
    Sort-Object Version -Descending | Select-Object -First 1 |
    ForEach-Object { [pscustomobject]@{ Name = $_.Name; Version = "$($_.Version)" } }
}
if (-not $framework) { throw "couldn't find the Windows App SDK $RuntimeVersion framework package" }
Note "Windows App SDK framework: $($framework.Name) $($framework.Version)"

# 4. The identity package.
$run = if ($env:GITHUB_RUN_NUMBER) { [int]$env:GITHUB_RUN_NUMBER } else { 0 }
$version = "1.0.$run.0"
$stage = Join-Path ([System.IO.Path]::GetTempPath()) "anitrack-winai"
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Copy-Item -Recurse (Join-Path $root "winai/Assets") $stage
$manifest = Get-Content (Join-Path $root "winai/AppxManifest.xml") -Raw
$manifest = $manifest.Replace("__VERSION__", $version)
$manifest = $manifest.Replace("__FRAMEWORK_NAME__", $framework.Name)
$manifest = $manifest.Replace("__FRAMEWORK_VERSION__", $framework.Version)
Set-Content (Join-Path $stage "AppxManifest.xml") $manifest -Encoding utf8

function Find-SdkTool($name) {
  $found = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter $name -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "\\(arm64|x64)\\" } | Sort-Object FullName -Descending | Select-Object -First 1
  if ($found) { return $found.FullName }
  $pkg = Join-Path ([System.IO.Path]::GetTempPath()) "sdk-buildtools"
  if (-not (Test-Path $pkg)) {
    Invoke-WebRequest "https://www.nuget.org/api/v2/package/Microsoft.Windows.SDK.BuildTools" -OutFile "$pkg.zip"
    Expand-Archive "$pkg.zip" $pkg
  }
  $found = Get-ChildItem $pkg -Recurse -Filter $name | Where-Object { $_.FullName -match "\\(arm64|x64)\\" } | Sort-Object FullName -Descending | Select-Object -First 1
  if (-not $found) { throw "$name not found" }
  return $found.FullName
}
$makeappx = Find-SdkTool "makeappx.exe"
$signtool = Find-SdkTool "signtool.exe"
Write-Host "makeappx: $makeappx`nsigntool: $signtool"

$msix = Join-Path $winai "AniTrack.AI.msix"
& $makeappx pack /d $stage /p $msix /nv /o
if ($LASTEXITCODE -ne 0) { throw "makeappx failed" }

# 5. Sign it with a certificate made just for this build.
$cert = New-SelfSignedCertificate -Type Custom -Subject "CN=AniTrack" -FriendlyName "AniTrack Windows AI" `
  -KeyUsage DigitalSignature -CertStoreLocation "Cert:\CurrentUser\My" `
  -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}")
$password = [System.Guid]::NewGuid().ToString()
$pfx = Join-Path ([System.IO.Path]::GetTempPath()) "anitrack-winai.pfx"
Export-PfxCertificate -Cert $cert -FilePath $pfx -Password (ConvertTo-SecureString $password -AsPlainText -Force) | Out-Null
Export-Certificate -Cert $cert -FilePath (Join-Path $winai "AniTrack.cer") | Out-Null
& $signtool sign /fd SHA256 /f $pfx /p $password $msix
$signed = $LASTEXITCODE
Remove-Item $pfx -Force
Remove-Item "Cert:\CurrentUser\My\$($cert.Thumbprint)" -Force
if ($signed -ne 0) { throw "signtool failed" }

Set-Content (Join-Path $winai "version.txt") $version -NoNewline
$size = (Get-ChildItem $winai, $helperOut -Recurse -File | Measure-Object -Property Length -Sum).Sum
Note ("Windows AI files: {0:N1} MB, identity package {1}" -f ($size / 1MB), $version)

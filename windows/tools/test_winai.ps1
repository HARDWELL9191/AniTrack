# CI check of the Windows AI plumbing: installs the runtime, trusts the build's certificate,
# registers the identity package against the resources folder and asks the helper for its
# status. The build machine has no Copilot+ NPU, so the expected answer is a clean "not
# supported" (or similar) reply, which proves the identity, the capability and the Windows App
# SDK runtime all work. A crash, no reply or an access error fails the build.
$ErrorActionPreference = "Stop"
# Results and errors as GitHub annotations (readable from the run page and the API).
function Note($message) { Write-Host "::notice::$(($message | Out-String).Trim() -replace "`r?`n", '%0A')" }
trap { Write-Host "::error::$($_.Exception.Message -replace "`r?`n", '%0A')"; break }
# The Appx cmdlets: native in newer PowerShell 7, through Windows PowerShell compatibility otherwise.
try { Get-AppxPackage -Name "None.Such.Package" | Out-Null } catch { Import-Module Appx -UseWindowsPowerShell -WarningAction SilentlyContinue }
$root = Split-Path -Parent $PSScriptRoot
$res = Resolve-Path (Join-Path $root "src-tauri/resources")
$winai = Join-Path $res "winai"

& (Join-Path $winai "windowsappruntimeinstall-arm64.exe") --quiet
Write-Host "runtime installer exit code: $LASTEXITCODE"
Import-Certificate -FilePath (Join-Path $winai "AniTrack.cer") -CertStoreLocation "Cert:\LocalMachine\TrustedPeople" | Out-Null
Add-AppxPackage -Path (Join-Path $winai "AniTrack.AI.msix") -ExternalLocation $res -ForceUpdateFromAnyVersion
Get-AppxPackage -Name "AniTrack.WindowsAI" | Format-List Name, Version, Architecture, IsDevelopmentMode, Dependencies

$exe = Join-Path $res "ai-helper/AniTrack.AI.exe"
$requests = '{"cmd":"status"}', '{"cmd":"explain","prompt":"Say hi."}'
$errFile = Join-Path ([System.IO.Path]::GetTempPath()) "winai-helper.err"
$replies = @($requests | & $exe 2> $errFile)
$exit = $LASTEXITCODE
$stderr = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
if ($stderr) { Note "helper stderr (exit $exit):`n$stderr" }
Note ("helper replies:`n" + ($replies -join "`n"))
if (@($replies).Count -ne 2) { throw "the helper didn't answer both requests" }
$status = $replies[0] | ConvertFrom-Json
if (-not $status.ok -or -not $status.state) { throw "status request failed: $($replies[0])" }
if ($replies -match "UnauthorizedAccess|0x80070005|Not declared|not registered|0x80040154") { throw "identity or runtime problem: $replies" }
Note "Windows AI plumbing OK (state on this machine: $($status.state))"

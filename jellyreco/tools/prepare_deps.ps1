# Fills the installer's resource folders:
#  resources/mpv : libmpv-2.dll for Windows ARM64 (mpv + FFmpeg: the playback engine), from the
#                  newest zhongfly/mpv-winbuild release (fallback: shinchiro/mpv-winbuild-cmake),
#                  checked to really be an ARM64 DLL. Also leaves the matching ffmpeg.exe in
#                  $env:RUNNER_TEMP\ffmpeg for the playback check (not shipped).
#  resources/ai  : ONNX Runtime 1.31.1 (ARM64) + Qualcomm's QNN plugin for the Snapdragon NPU,
#                  and BAAI bge-small-en-v1.5 with its input fixed to 1 x 128 tokens (as AniReco).
$ErrorActionPreference = "Stop"
function Note($message) { Write-Host "::notice::$(($message | Out-String).Trim() -replace "`r?`n", '%0A')" }
trap { Write-Host "::error::$($_.Exception.Message -replace "`r?`n", '%0A')"; break }

$root = Split-Path -Parent $PSScriptRoot
$mpvOut = Join-Path $root "src-tauri/resources/mpv"
$aiOut = Join-Path $root "src-tauri/resources/ai"
$work = Join-Path ([System.IO.Path]::GetTempPath()) "jellyreco-deps"
New-Item -ItemType Directory -Force -Path $mpvOut, $aiOut, $work | Out-Null

# --- 7-Zip (the mpv builds are .7z) ---------------------------------------------------------------
$sevenZip = (Get-Command 7z -ErrorAction SilentlyContinue).Source
if (-not $sevenZip -and (Test-Path "C:\Program Files\7-Zip\7z.exe")) { $sevenZip = "C:\Program Files\7-Zip\7z.exe" }
if (-not $sevenZip) {
  $sevenZip = Join-Path $work "7zr.exe"
  Invoke-WebRequest "https://www.7-zip.org/a/7zr.exe" -OutFile $sevenZip
}

# --- libmpv for ARM64 ------------------------------------------------------------------------------
$headers = @{ "User-Agent" = "jellyreco-build"; "Accept" = "application/vnd.github+json" }
if ($env:GITHUB_TOKEN) { $headers["Authorization"] = "Bearer $env:GITHUB_TOKEN" }
$sources = @(
  @{ Repo = "zhongfly/mpv-winbuild"; Patterns = @('^mpv-dev-aarch64-\d{8}-git-[0-9a-f]+\.7z$', '^mpv-dev-lgpl-aarch64-\d{8}-git-[0-9a-f]+\.7z$') },
  @{ Repo = "shinchiro/mpv-winbuild-cmake"; Patterns = @('^mpv-dev-aarch64-\d{8}-git-[0-9a-f]+\.7z$') }
)
$picked = $null
foreach ($s in $sources) {
  try {
    $releases = Invoke-RestMethod -Headers $headers "https://api.github.com/repos/$($s.Repo)/releases?per_page=5"
  } catch { Write-Host "Couldn't list $($s.Repo): $_"; continue }
  foreach ($rel in $releases) {
    foreach ($pattern in $s.Patterns) {
      $asset = $rel.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
      if ($asset) { $picked = @{ Repo = $s.Repo; Release = $rel; Asset = $asset }; break }
    }
    if ($picked) { break }
  }
  if ($picked) { break }
}
if (-not $picked) { throw "No ARM64 libmpv build found (zhongfly/mpv-winbuild, shinchiro/mpv-winbuild-cmake)." }
$archive = Join-Path $work $picked.Asset.name
Invoke-WebRequest $picked.Asset.browser_download_url -OutFile $archive -Headers @{ "User-Agent" = "jellyreco-build" }
$mpvDir = Join-Path $work "mpv-dev"
& $sevenZip x $archive "-o$mpvDir" -y | Out-Null
if ($LASTEXITCODE -ne 0) { throw "7-Zip couldn't extract $($picked.Asset.name)" }
$dll = Get-ChildItem $mpvDir -Recurse -Filter "libmpv-2.dll" | Select-Object -First 1
if (-not $dll) { $dll = Get-ChildItem $mpvDir -Recurse -Filter "mpv-2.dll" | Select-Object -First 1 }
if (-not $dll) { throw "No libmpv-2.dll in $($picked.Asset.name)" }

# The DLL must be ARM64 (PE machine 0xAA64), not x64 running under emulation.
$bytes = [System.IO.File]::ReadAllBytes($dll.FullName)
$pe = [BitConverter]::ToInt32($bytes, 0x3C)
$machine = [BitConverter]::ToUInt16($bytes, $pe + 4)
if ($machine -ne 0xAA64) { throw ("libmpv-2.dll isn't ARM64 (machine 0x{0:X4})" -f $machine) }
Copy-Item $dll.FullName (Join-Path $mpvOut "libmpv-2.dll") -Force
# Anything else the DLL ships with (some builds split out d3dcompiler or vulkan loaders).
Get-ChildItem $dll.DirectoryName -Filter "*.dll" | Where-Object { $_.Name -ne $dll.Name } | ForEach-Object { Copy-Item $_.FullName $mpvOut -Force }
Note "libmpv: $($picked.Asset.name) from $($picked.Repo) $($picked.Release.tag_name) ($([math]::Round($dll.Length / 1MB)) MB, ARM64)"

# The matching ffmpeg.exe (same release) makes the test videos for the playback check.
$ff = $picked.Release.assets | Where-Object { $_.name -match '^ffmpeg-aarch64-git-[0-9a-f]+\.7z$' } | Select-Object -First 1
if (-not $ff) { $ff = $picked.Release.assets | Where-Object { $_.name -match '^ffmpeg-.*aarch64.*\.7z$' } | Select-Object -First 1 }
if ($ff -and $env:RUNNER_TEMP) {
  $ffArchive = Join-Path $work $ff.name
  Invoke-WebRequest $ff.browser_download_url -OutFile $ffArchive -Headers @{ "User-Agent" = "jellyreco-build" }
  $ffDir = Join-Path $env:RUNNER_TEMP "ffmpeg"
  & $sevenZip x $ffArchive "-o$ffDir" -y | Out-Null
  $exe = Get-ChildItem $ffDir -Recurse -Filter "ffmpeg.exe" | Select-Object -First 1
  if ($exe) { "FFMPEG_EXE=$($exe.FullName)" | Out-File -FilePath $env:GITHUB_ENV -Append; Note "Test-media FFmpeg: $($ff.name)" }
}

# --- On-device AI (same files and versions as AniReco's Windows build) -------------------------------
$OrtVersion = "1.31.1"
$QnnVersion = "2.7.0"
$ModelRepo = "https://huggingface.co/BAAI/bge-small-en-v1.5/resolve/main"
function Get-Wheel($name, $version, $folder, $files) {
  python -m pip download "$name==$version" --platform win_arm64 --only-binary=:all: --python-version 3.12 --no-deps -d $work
  if ($LASTEXITCODE -ne 0) { throw "pip download $name failed" }
  $wheel = Get-ChildItem $work -Filter "$($name.Replace('-', '_'))-$version-*win_arm64.whl" | Select-Object -First 1
  if (-not $wheel) { throw "$name wheel not found" }
  $unzip = Join-Path $work $name
  Expand-Archive -Path $wheel.FullName -DestinationPath $unzip -Force
  foreach ($f in $files) {
    $src = Join-Path (Join-Path $unzip $folder) $f
    if (-not (Test-Path $src)) { throw "missing in $name wheel: $f" }
    Copy-Item $src $aiOut -Force
  }
}
Get-Wheel "onnxruntime" $OrtVersion "onnxruntime/capi" @("onnxruntime.dll", "onnxruntime_providers_shared.dll")
Get-Wheel "onnxruntime-qnn" $QnnVersion "onnxruntime_qnn" @(
  "onnxruntime_providers_qnn.dll", "Qualcomm_LICENSE.pdf",
  "QnnHtp.dll", "QnnHtpPrepare.dll", "QnnSystem.dll", "QnnHtpNetRunExtensions.dll",
  "QnnHtpV68Stub.dll", "QnnHtpV73Stub.dll", "QnnHtpV81Stub.dll",
  "libQnnHtpV68Skel.so", "libQnnHtpV73Skel.so", "libQnnHtpV81Skel.so",
  "libqnnhtpv73.cat", "libqnnhtpv81.cat"
)
Invoke-WebRequest "$ModelRepo/onnx/model.onnx" -OutFile (Join-Path $aiOut "model.onnx")
Invoke-WebRequest "$ModelRepo/vocab.txt" -OutFile (Join-Path $aiOut "vocab.txt")
python -m pip install --quiet "onnx==1.23.2"
python -I (Join-Path $PSScriptRoot "static_shapes.py") (Join-Path $aiOut "model.onnx") 128
if ($LASTEXITCODE -ne 0) { throw "static_shapes.py failed" }

Get-ChildItem $mpvOut, $aiOut | ForEach-Object { "{0,-36} {1,14:N0} bytes" -f $_.Name, $_.Length }

# Fills the installer's resource folders for one Windows architecture ($env:JR_ARCH: arm64 or x64):
#  resources/mpv : libmpv-2.dll (mpv + FFmpeg: the playback engine) from the newest
#                  zhongfly/mpv-winbuild release (fallback: shinchiro/mpv-winbuild-cmake), checked to
#                  really be built for that architecture. x64 uses the baseline build (any 64-bit
#                  CPU), not the x86_64-v3 one (Haswell and newer only). Also leaves the matching
#                  ffmpeg.exe in $env:RUNNER_TEMP\ffmpeg for the playback check (not shipped).
#  resources/ai  : ONNX Runtime 1.31.1, BAAI bge-small-en-v1.5 with its input fixed to 1 x 128 tokens
#                  (as AniReco), and the hardware plugins:
#                    arm64: Qualcomm's QNN plugin (Snapdragon NPU) + WebGPU plugin (Adreno GPU)
#                    x64:   Intel's OpenVINO plugin in ai/openvino (Core Ultra NPU) + WebGPU plugin
#                           (any DirectX 12 GPU: AMD, Nvidia, Intel)
$ErrorActionPreference = "Stop"
function Note($message) { Write-Host "::notice::$(($message | Out-String).Trim() -replace "`r?`n", '%0A')" }
trap { Write-Host "::error::$($_.Exception.Message -replace "`r?`n", '%0A')"; break }

$Arch = if ($env:JR_ARCH) { $env:JR_ARCH } else { "arm64" }
if ($Arch -notin @("arm64", "x64")) { throw "JR_ARCH must be arm64 or x64, not $Arch" }
$MpvArch = @{ arm64 = "aarch64"; x64 = "x86_64" }[$Arch]
$PeMachine = @{ arm64 = 0xAA64; x64 = 0x8664 }[$Arch]
$WheelPlatform = @{ arm64 = "win_arm64"; x64 = "win_amd64" }[$Arch]
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

# --- libmpv ---------------------------------------------------------------------------------------
$headers = @{ "User-Agent" = "jellyreco-build"; "Accept" = "application/vnd.github+json" }
if ($env:GITHUB_TOKEN) { $headers["Authorization"] = "Bearer $env:GITHUB_TOKEN" }
# "x86_64-" followed by the date: the baseline x64 build, never the x86_64-v3 one.
$sources = @(
  @{ Repo = "zhongfly/mpv-winbuild"; Patterns = @("^mpv-dev-$MpvArch-\d{8}-git-[0-9a-f]+\.7z$", "^mpv-dev-lgpl-$MpvArch-\d{8}-git-[0-9a-f]+\.7z$") },
  @{ Repo = "shinchiro/mpv-winbuild-cmake"; Patterns = @("^mpv-dev-$MpvArch-\d{8}-git-[0-9a-f]+\.7z$") }
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
if (-not $picked) { throw "No $MpvArch libmpv build found (zhongfly/mpv-winbuild, shinchiro/mpv-winbuild-cmake)." }
$archive = Join-Path $work $picked.Asset.name
Invoke-WebRequest $picked.Asset.browser_download_url -OutFile $archive -Headers @{ "User-Agent" = "jellyreco-build" }
$mpvDir = Join-Path $work "mpv-dev"
& $sevenZip x $archive "-o$mpvDir" -y | Out-Null
if ($LASTEXITCODE -ne 0) { throw "7-Zip couldn't extract $($picked.Asset.name)" }
$dll = Get-ChildItem $mpvDir -Recurse -Filter "libmpv-2.dll" | Select-Object -First 1
if (-not $dll) { $dll = Get-ChildItem $mpvDir -Recurse -Filter "mpv-2.dll" | Select-Object -First 1 }
if (-not $dll) { throw "No libmpv-2.dll in $($picked.Asset.name)" }

# The DLL must be built for this architecture (PE machine 0xAA64 ARM64 / 0x8664 x64), not one
# that would run under emulation or not at all.
function Get-PeMachine($path) {
  $bytes = [System.IO.File]::ReadAllBytes($path)
  $pe = [BitConverter]::ToInt32($bytes, 0x3C)
  [BitConverter]::ToUInt16($bytes, $pe + 4)
}
$machine = Get-PeMachine $dll.FullName
if ($machine -ne $PeMachine) { throw ("libmpv-2.dll is machine 0x{0:X4}, expected 0x{1:X4} ($Arch)" -f $machine, $PeMachine) }
Copy-Item $dll.FullName (Join-Path $mpvOut "libmpv-2.dll") -Force
# Anything else the DLL ships with (some builds split out d3dcompiler or vulkan loaders).
Get-ChildItem $dll.DirectoryName -Filter "*.dll" | Where-Object { $_.Name -ne $dll.Name } | ForEach-Object { Copy-Item $_.FullName $mpvOut -Force }
Note "libmpv: $($picked.Asset.name) from $($picked.Repo) $($picked.Release.tag_name) ($([math]::Round($dll.Length / 1MB)) MB, $Arch)"

# The matching ffmpeg.exe (same release) makes the test videos for the playback check.
$ff = $picked.Release.assets | Where-Object { $_.name -match "^ffmpeg-$MpvArch-git-[0-9a-f]+\.7z$" } | Select-Object -First 1
if (-not $ff) { $ff = $picked.Release.assets | Where-Object { $_.name -match "^ffmpeg-$MpvArch-.*\.7z$" -and $_.name -notmatch "v3" } | Select-Object -First 1 }
if ($ff -and $env:RUNNER_TEMP) {
  $ffArchive = Join-Path $work $ff.name
  Invoke-WebRequest $ff.browser_download_url -OutFile $ffArchive -Headers @{ "User-Agent" = "jellyreco-build" }
  $ffDir = Join-Path $env:RUNNER_TEMP "ffmpeg"
  & $sevenZip x $ffArchive "-o$ffDir" -y | Out-Null
  $exe = Get-ChildItem $ffDir -Recurse -Filter "ffmpeg.exe" | Select-Object -First 1
  if ($exe) { "FFMPEG_EXE=$($exe.FullName)" | Out-File -FilePath $env:GITHUB_ENV -Append; Note "Test-media FFmpeg: $($ff.name)" }
}

# --- On-device AI (same model and ONNX Runtime as AniReco's Windows build) --------------------------
$OrtVersion = "1.31.1"
$QnnVersion = "2.7.0"
$OpenVinoVersion = "1.8.1"
$WebGpuVersion = "0.5.0"
$ModelRepo = "https://huggingface.co/BAAI/bge-small-en-v1.5/resolve/main"
function Get-Wheel($name, $version) {
  # (Output goes to the log, not into the function's result: only the folder is returned.)
  python -m pip download "$name==$version" --platform $WheelPlatform --only-binary=:all: --python-version 3.12 --no-deps -d $work | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "pip download $name failed" }
  $wheel = Get-ChildItem $work -Filter "$($name.Replace('-', '_'))-$version-*$WheelPlatform.whl" | Select-Object -First 1
  if (-not $wheel) { throw "$name wheel not found" }
  $unzip = Join-Path $work "$name-$Arch"
  Expand-Archive -Path $wheel.FullName -DestinationPath $unzip -Force | Out-Null
  return $unzip
}
function Copy-FromWheel($unzip, $folder, $files, $dest) {
  foreach ($f in $files) {
    $src = Join-Path (Join-Path $unzip $folder) $f
    if (-not (Test-Path $src)) { throw "missing in wheel: $folder/$f" }
    Copy-Item $src $dest -Force
  }
}
$ort = Get-Wheel "onnxruntime" $OrtVersion
Copy-FromWheel $ort "onnxruntime/capi" @("onnxruntime.dll", "onnxruntime_providers_shared.dll") $aiOut
# Any GPU through DirectX 12 (the plugin brings its own shader compiler).
$webgpu = Get-Wheel "onnxruntime-ep-webgpu" $WebGpuVersion
Copy-FromWheel $webgpu "onnxruntime_ep_webgpu" @("onnxruntime_providers_webgpu.dll", "dxcompiler.dll") $aiOut
Copy-Item (Join-Path $webgpu "onnxruntime_ep_webgpu-$WebGpuVersion.dist-info/licenses/ThirdPartyNotices.txt") (Join-Path $aiOut "WebGPU_ThirdPartyNotices.txt") -Force
if ($Arch -eq "arm64") {
  # Snapdragon NPU.
  $qnn = Get-Wheel "onnxruntime-qnn" $QnnVersion
  Copy-FromWheel $qnn "onnxruntime_qnn" @(
    "onnxruntime_providers_qnn.dll", "Qualcomm_LICENSE.pdf",
    "QnnHtp.dll", "QnnHtpPrepare.dll", "QnnSystem.dll", "QnnHtpNetRunExtensions.dll",
    "QnnHtpV68Stub.dll", "QnnHtpV73Stub.dll", "QnnHtpV81Stub.dll",
    "libQnnHtpV68Skel.so", "libQnnHtpV73Skel.so", "libQnnHtpV81Skel.so",
    "libqnnhtpv73.cat", "libqnnhtpv81.cat"
  ) $aiOut
} else {
  # Intel Core Ultra NPU: the OpenVINO plugin with its whole runtime (as Intel ships it), in its own
  # folder so its libraries are found next to it.
  $ov = Get-Wheel "onnxruntime-ep-openvino" $OpenVinoVersion
  $ovOut = Join-Path $aiOut "openvino"
  New-Item -ItemType Directory -Force -Path $ovOut | Out-Null
  Get-ChildItem (Join-Path $ov "onnxruntime_ep_openvino") -File | Where-Object { $_.Extension -ne ".py" } | ForEach-Object { Copy-Item $_.FullName $ovOut -Force }
  if (-not (Test-Path (Join-Path $ovOut "onnxruntime_providers_openvino_plugin.dll"))) { throw "OpenVINO plugin missing" }
  if (-not (Test-Path (Join-Path $ovOut "openvino_intel_npu_plugin.dll"))) { throw "OpenVINO NPU plugin missing" }
}
# ONNX Runtime, WebGPU and OpenVINO must be built for this architecture too (Qualcomm's own QNN
# libraries are left as Qualcomm ships them).
Get-ChildItem $aiOut -Recurse -Filter "*.dll" | Where-Object { $_.Name -notmatch "^(Qnn|onnxruntime_providers_qnn)" } | ForEach-Object {
  $m = Get-PeMachine $_.FullName
  if ($m -ne $PeMachine) { throw ("{0} is machine 0x{1:X4}, expected 0x{2:X4} ($Arch)" -f $_.Name, $m, $PeMachine) }
}
Invoke-WebRequest "$ModelRepo/onnx/model.onnx" -OutFile (Join-Path $aiOut "model.onnx")
Invoke-WebRequest "$ModelRepo/vocab.txt" -OutFile (Join-Path $aiOut "vocab.txt")
python -m pip install --quiet "onnx==1.23.2"
python -I (Join-Path $PSScriptRoot "static_shapes.py") (Join-Path $aiOut "model.onnx") 128
if ($LASTEXITCODE -ne 0) { throw "static_shapes.py failed" }

Get-ChildItem $mpvOut, $aiOut -Recurse -File | ForEach-Object { "{0,-36} {1,14:N0} bytes" -f $_.Name, $_.Length }

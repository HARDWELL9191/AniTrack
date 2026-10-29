# Fills src-tauri/resources/ai with what the on-device AI needs:
#  - ONNX Runtime 1.24.4 with Qualcomm's QNN execution provider (Snapdragon NPU), ARM64. The
#    files come from the official onnxruntime-qnn wheel (a zip), which ships the same native
#    libraries as the NuGet package, including the HTP (NPU) backend for Snapdragon X (V73),
#    X2 (V81) and 8cx Gen 3 (V68).
#  - all-MiniLM-L6-v2 (sentence-transformers) as ONNX, plus its vocab.txt.
$ErrorActionPreference = "Stop"
$OrtVersion = "1.24.4"
# The model's files haven't changed in years; the hashes are printed below for each build.
$ModelRepo = "https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/main"

$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root "src-tauri/resources/ai"
$work = Join-Path ([System.IO.Path]::GetTempPath()) "anitrack-ai"
New-Item -ItemType Directory -Force -Path $out, $work | Out-Null

# 1. ONNX Runtime + QNN, win_arm64.
python -m pip download "onnxruntime-qnn==$OrtVersion" --platform win_arm64 --only-binary=:all: --python-version 3.12 --no-deps -d $work
$wheel = Get-ChildItem $work -Filter "onnxruntime_qnn-$OrtVersion-*win_arm64.whl" | Select-Object -First 1
if (-not $wheel) { throw "onnxruntime-qnn wheel not found" }
$unzip = Join-Path $work "wheel"
Expand-Archive -Path $wheel.FullName -DestinationPath $unzip -Force
$capi = Join-Path $unzip "onnxruntime/capi"
$keep = @(
  "onnxruntime.dll", "onnxruntime_providers_shared.dll", "onnxruntime_providers_qnn.dll",
  "QnnHtp.dll", "QnnHtpPrepare.dll", "QnnSystem.dll",
  "QnnHtpV68Stub.dll", "QnnHtpV73Stub.dll", "QnnHtpV81Stub.dll",
  "libQnnHtpV68Skel.so", "libQnnHtpV73Skel.so", "libQnnHtpV81Skel.so",
  "libqnnhtpv73.cat", "libqnnhtpv81.cat"
)
foreach ($f in $keep) {
  $src = Join-Path $capi $f
  if (Test-Path $src) { Copy-Item $src $out -Force } else { Write-Warning "missing in wheel: $f" }
}
if (-not (Test-Path (Join-Path $out "onnxruntime.dll"))) { throw "onnxruntime.dll missing" }

# 2. The sentence model and its vocabulary.
Invoke-WebRequest "$ModelRepo/onnx/model.onnx" -OutFile (Join-Path $out "model.onnx")
Invoke-WebRequest "$ModelRepo/vocab.txt" -OutFile (Join-Path $out "vocab.txt")

# 3. Show what goes into the installer.
Get-ChildItem $out | ForEach-Object {
  "{0,-34} {1,12:N0} bytes  {2}" -f $_.Name, $_.Length, (Get-FileHash $_.FullName -Algorithm SHA256).Hash.Substring(0, 16)
}

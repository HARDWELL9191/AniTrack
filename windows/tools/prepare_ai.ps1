# Fills src-tauri/resources/ai with what the on-device AI needs:
#  - ONNX Runtime 1.31.1 (Windows ARM64) and Qualcomm's QNN execution provider plugin 2.7.0
#    (onnxruntime-qnn) for the Snapdragon NPU, with the HTP (NPU) libraries for Snapdragon X
#    (V73), X2 (V81) and 8cx Gen 3 (V68). Both come from the official wheels (zip files).
#  - BAAI bge-small-en-v1.5 as ONNX plus its vocab.txt, with its input fixed to 1 x 128 tokens
#    (the NPU needs fixed shapes).
$ErrorActionPreference = "Stop"
# Results and errors as GitHub annotations (readable from the run page and the API).
function Note($message) { Write-Host "::notice::$(($message | Out-String).Trim() -replace "`r?`n", '%0A')" }
trap { Write-Host "::error::$($_.Exception.Message -replace "`r?`n", '%0A')"; break }
$OrtVersion = "1.31.1"
$QnnVersion = "2.7.0"
$ModelRepo = "https://huggingface.co/BAAI/bge-small-en-v1.5/resolve/main"

$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root "src-tauri/resources/ai"
$work = Join-Path ([System.IO.Path]::GetTempPath()) "anitrack-ai"
New-Item -ItemType Directory -Force -Path $out, $work | Out-Null

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
    Copy-Item $src $out -Force
  }
}

# 1. ONNX Runtime itself.
Get-Wheel "onnxruntime" $OrtVersion "onnxruntime/capi" @("onnxruntime.dll", "onnxruntime_providers_shared.dll")

# 2. The QNN plugin and Qualcomm's NPU libraries (the GPU, LLM and debugging ones are left out).
Get-Wheel "onnxruntime-qnn" $QnnVersion "onnxruntime_qnn" @(
  "onnxruntime_providers_qnn.dll",
  "QnnHtp.dll", "QnnHtpPrepare.dll", "QnnSystem.dll", "QnnHtpNetRunExtensions.dll",
  "QnnHtpV68Stub.dll", "QnnHtpV73Stub.dll", "QnnHtpV81Stub.dll",
  "libQnnHtpV68Skel.so", "libQnnHtpV73Skel.so", "libQnnHtpV81Skel.so",
  "libqnnhtpv73.cat", "libqnnhtpv81.cat"
)

# 3. The sentence model and its vocabulary.
Invoke-WebRequest "$ModelRepo/onnx/model.onnx" -OutFile (Join-Path $out "model.onnx")
Invoke-WebRequest "$ModelRepo/vocab.txt" -OutFile (Join-Path $out "vocab.txt")
python -m pip install --quiet "onnx==1.23.2"
python -I (Join-Path $PSScriptRoot "static_shapes.py") (Join-Path $out "model.onnx") 128
if ($LASTEXITCODE -ne 0) { throw "static_shapes.py failed" }

# 4. What goes into the installer.
Get-ChildItem $out | ForEach-Object {
  "{0,-34} {1,12:N0} bytes  {2}" -f $_.Name, $_.Length, (Get-FileHash $_.FullName -Algorithm SHA256).Hash.Substring(0, 16)
}

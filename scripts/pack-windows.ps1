# Pack slim CUDA + TensorRT packages for Windows x64

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir   = Split-Path -Parent $ScriptDir

# read versions
$versions = Get-Content "$RepoDir\versions.json" | ConvertFrom-Json
$CudaVer   = $versions.win64.cuda
$TrtVer    = $versions.win64.tensorrt
$TrtVerShort = ($TrtVer -split '\.' | Select-Object -First 3) -join '.'

Write-Output "Platform : win64"
Write-Output "CUDA     : $CudaVer"
Write-Output "TensorRT : $TrtVer"

# ── Install 7-Zip (for packing) ───────────────────────────────────────────────
if (!(Get-Command 7z -ErrorAction SilentlyContinue)) {
    Write-Output "::group::Install 7-Zip ..."
    winget install --id 7zip.7zip -e --silent
    $env:PATH += ";C:\Program Files\7-Zip"
    Write-Output "::endgroup::"
}

# ── Install CUDA (full toolkit; we cherry-pick what we need) ──────────────────
$CudaRoot = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v${CudaVer}"
if (!(Test-Path $CudaRoot)) {
    Write-Output "::group::Install CUDA $CudaVer ..."
    winget install Nvidia.CUDA --version $CudaVer -s winget --silent
    Write-Output "::endgroup::"
}

# ── Download TensorRT ─────────────────────────────────────────────────────────
$TrtZip = "$env:TEMP\TensorRT.zip"
$TrtExtract = "$env:TEMP\TensorRT-extract"
if (!(Test-Path "$TrtExtract\TensorRT-$TrtVer")) {
    Write-Output "::group::Download TensorRT $TrtVer ..."
    $TrtUrl = "https://developer.nvidia.com/downloads/compute/machine-learning/tensorrt/${TrtVerShort}/zip/TensorRT-${TrtVer}.Windows.win10.cuda-${CudaVer}.zip"
    Invoke-WebRequest $TrtUrl -OutFile $TrtZip
    Expand-Archive $TrtZip $TrtExtract
    Remove-Item $TrtZip
    Write-Output "::endgroup::"
}
$TrtDir = "$TrtExtract\TensorRT-$TrtVer"

# ── Pack slim package ─────────────────────────────────────────────────────────
Write-Output "::group::Pack slim package ..."
$SlimDir = "$env:TEMP\cuda-trt-slim"
New-Item -ItemType Directory -Force -Path "$SlimDir\cuda\bin"           | Out-Null
New-Item -ItemType Directory -Force -Path "$SlimDir\cuda\include"       | Out-Null
New-Item -ItemType Directory -Force -Path "$SlimDir\cuda\lib\x64"       | Out-Null
New-Item -ItemType Directory -Force -Path "$SlimDir\TensorRT\include"   | Out-Null
New-Item -ItemType Directory -Force -Path "$SlimDir\TensorRT\lib"       | Out-Null

# CUDA: compiler
Copy-Item "$CudaRoot\bin\nvcc.exe"  "$SlimDir\cuda\bin\"
# CUDA: headers
Copy-Item "$CudaRoot\include\*" "$SlimDir\cuda\include\" -Recurse -Force
# CUDA: static runtime lib + stub
Copy-Item "$CudaRoot\lib\x64\cudart_static.lib"  "$SlimDir\cuda\lib\x64\"
Copy-Item "$CudaRoot\lib\x64\cuda.lib"           "$SlimDir\cuda\lib\x64\"

# TensorRT: headers
Copy-Item "$TrtDir\include\*" "$SlimDir\TensorRT\include\" -Recurse -Force
# TensorRT: import libs (for linking)
Copy-Item "$TrtDir\lib\nvinfer_10.lib"         "$SlimDir\TensorRT\lib\" -ErrorAction SilentlyContinue
# TensorRT: runtime DLLs
Copy-Item "$TrtDir\lib\nvinfer_10.dll"         "$SlimDir\TensorRT\lib\"
Get-Item  "$TrtDir\lib\nvinfer_lean_10*"       | Copy-Item -Destination "$SlimDir\TensorRT\lib\" -ErrorAction SilentlyContinue
Get-Item  "$TrtDir\lib\nvinfer_dispatch_10*"   | Copy-Item -Destination "$SlimDir\TensorRT\lib\" -ErrorAction SilentlyContinue

$SlimFilename = "cuda-trt-${CudaVer}-${TrtVer}-win64.7z"
7z a -mx=5 "$RepoDir\$SlimFilename" "$SlimDir\*" | Out-Null
Write-Output "Slim package: $SlimFilename ($([math]::Round((Get-Item "$RepoDir\$SlimFilename").Length / 1MB))MB)"
Remove-Item $SlimDir -Recurse
Write-Output "::endgroup::"

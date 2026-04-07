#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# detect architecture
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then
    DISTRO="sbsa"
    BUNDLE="linux-arm64"
else
    ARCH="x86_64"
    DISTRO="x86_64"
    BUNDLE="linux"
fi

# read versions for this platform
CUDA_VER=$(jq -r ".${DISTRO}.cuda" "$REPO_DIR/versions.json")
TRT_VER=$(jq -r ".${DISTRO}.tensorrt" "$REPO_DIR/versions.json")
TRT_VER_SHORT=$(echo "$TRT_VER" | cut -d. -f1-3)

CUDA_MAJOR=$(echo "$CUDA_VER" | cut -d. -f1)
CUDA_MINOR=$(echo "$CUDA_VER" | cut -d. -f2)

echo "Platform : $BUNDLE"
echo "CUDA     : $CUDA_VER"
echo "TensorRT : $TRT_VER"

# working directory — cleaned up on exit
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

# ── Install minimal CUDA (headers + libcudart_static.a + stub) ────────────────
echo "::group::Install CUDA dev package ..."
UBUNTU_VER=$(lsb_release -rs | tr -d '.')
wget -q "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${UBUNTU_VER}/${DISTRO}/cuda-keyring_1.1-1_all.deb" -O /tmp/cuda.deb
sudo dpkg -i /tmp/cuda.deb
sudo apt-get update -qq
sudo apt-get install -y "cuda-cudart-dev-${CUDA_MAJOR}-${CUDA_MINOR}"
echo "::endgroup::"

# ── Download TensorRT tarball ─────────────────────────────────────────────────
echo "::group::Download TensorRT $TRT_VER ..."
TRT_URL="https://developer.nvidia.com/downloads/compute/machine-learning/tensorrt/${TRT_VER_SHORT}/tars/TensorRT-${TRT_VER}.Linux.${ARCH}-gnu.cuda-${CUDA_VER}.tar.gz"
curl -L -s "$TRT_URL" | tar -zxf - -C "$WORK_DIR/"
TRT_DIR="$WORK_DIR/TensorRT-${TRT_VER}"
echo "::endgroup::"

CUDA_ROOT="/usr/local/cuda-${CUDA_VER}"

# ── Pack slim package ─────────────────────────────────────────────────────────
echo "::group::Pack slim package ..."
SLIM_DIR="$WORK_DIR/slim"
mkdir -p \
    "$SLIM_DIR/cuda/bin" \
    "$SLIM_DIR/cuda/include" \
    "$SLIM_DIR/cuda/lib64/stubs" \
    "$SLIM_DIR/TensorRT/include" \
    "$SLIM_DIR/TensorRT/lib"

# CUDA: compiler
cp "$CUDA_ROOT/bin/nvcc" "$SLIM_DIR/cuda/bin/"
# CUDA: all runtime headers
cp -r "$CUDA_ROOT/include/." "$SLIM_DIR/cuda/include/"
# CUDA: static runtime lib (for CUDA::cudart_static)
cp "$CUDA_ROOT/lib64/libcudart_static.a" "$SLIM_DIR/cuda/lib64/"
# CUDA: linker stub (needed at link time even with static cudart)
cp "$CUDA_ROOT/lib64/stubs/libcuda.so" "$SLIM_DIR/cuda/lib64/stubs/"

# TensorRT: headers
cp -r "$TRT_DIR/include/." "$SLIM_DIR/TensorRT/include/"
# TensorRT: core inference libs
cp "$TRT_DIR/lib"/libnvinfer.so*            "$SLIM_DIR/TensorRT/lib/"
cp "$TRT_DIR/lib"/libnvinfer_lean.so*       "$SLIM_DIR/TensorRT/lib/" 2>/dev/null || true
cp "$TRT_DIR/lib"/libnvinfer_dispatch.so*   "$SLIM_DIR/TensorRT/lib/" 2>/dev/null || true
# TensorRT: static lib (kept for future static-link investigation)
cp "$TRT_DIR/lib"/libnvinfer_static.a       "$SLIM_DIR/TensorRT/lib/" 2>/dev/null || true

SLIM_FILENAME="cuda-trt-${CUDA_VER}-${TRT_VER}-${BUNDLE}.tar.zst"
tar "-I zstd -3 -T4 --long=27" -cf "$REPO_DIR/$SLIM_FILENAME" -C "$SLIM_DIR" .
echo "Slim package: $SLIM_FILENAME ($(du -sh "$REPO_DIR/$SLIM_FILENAME" | cut -f1))"
echo "::endgroup::"

# ── Pack tools package ────────────────────────────────────────────────────────
echo "::group::Pack tools package ..."
TOOLS_DIR="$WORK_DIR/tools"
mkdir -p \
    "$TOOLS_DIR/TensorRT/bin" \
    "$TOOLS_DIR/TensorRT/lib"

cp "$TRT_DIR/bin/trtexec"                           "$TOOLS_DIR/TensorRT/bin/"
cp "$TRT_DIR/lib"/libnvinfer_plugin.so*             "$TOOLS_DIR/TensorRT/lib/" 2>/dev/null || true
cp "$TRT_DIR/lib"/libnvinfer_onnxparser.so*         "$TOOLS_DIR/TensorRT/lib/" 2>/dev/null || true
cp "$TRT_DIR/lib"/libnvonnxparser.so*               "$TOOLS_DIR/TensorRT/lib/" 2>/dev/null || true
cp "$TRT_DIR/lib"/libnvrtc.so*                      "$TOOLS_DIR/TensorRT/lib/" 2>/dev/null || true

TOOLS_FILENAME="cuda-trt-tools-${CUDA_VER}-${TRT_VER}-${BUNDLE}.tar.zst"
tar "-I zstd -3 -T4 --long=27" -cf "$REPO_DIR/$TOOLS_FILENAME" -C "$TOOLS_DIR" .
echo "Tools package: $TOOLS_FILENAME ($(du -sh "$REPO_DIR/$TOOLS_FILENAME" | cut -f1))"
echo "::endgroup::"

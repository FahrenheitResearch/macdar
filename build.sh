#!/bin/bash
set -e
cd "$(dirname "$0")"

# Check dependencies
if ! command -v cmake &>/dev/null; then
    echo "CMake not found. Install with: brew install cmake"
    exit 1
fi

if ! xcode-select -p &>/dev/null; then
    echo "Xcode Command Line Tools not found. Install with: xcode-select --install"
    exit 1
fi

JOBS=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)

echo "Building macdar..."
mkdir -p build
cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
cmake --build . -j"$JOBS"
echo ""
echo "Build complete. Run with: ./build/macdar"

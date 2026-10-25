#!/bin/sh
# Builds the standalone nav_air storage tests and the offline baker with g++ (never scons).
# Usage: build_air_storage_tests.sh OUTPUT_DIR   (then run OUTPUT_DIR/air_storage_tests OUTPUT_DIR)
set -e
here=$(cd "$(dirname "$0")" && pwd)
air="$here/../nav_air"
out=${1:?output directory}
mkdir -p "$out"
flags="-std=c++17 -fno-exceptions -O2 -g -Wall -Wextra -pthread -I$air"
g++ $flags "$here/air_storage_tests.cpp" "$air/air_tiles.cpp" "$air/air_voxelize.cpp" "$air/air_serialize.cpp" \
	-o "$out/air_storage_tests"
g++ $flags "$air/air_bake_main.cpp" "$air/air_tiles.cpp" "$air/air_voxelize.cpp" "$air/air_serialize.cpp" \
	-o "$out/air_bake"

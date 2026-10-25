#!/bin/sh
# Builds the standalone air search tests (nav_air search slice) with g++, never scons.
# Usage: build_air_search_tests.sh OUTPUT_DIR [storage]
#   storage: also compile the storage half (air_tiles, air_voxelize) and run the real-tile test.
set -e
here=$(cd "$(dirname "$0")" && pwd)
src="$here/.."
out=${1:?output directory}
mkdir -p "$out"
sources="$here/air_search_tests.cpp $src/air_search.cpp $src/air_shorten.cpp $src/air_dynamic.cpp $src/air_test_space.cpp"
flags=""
if [ "${2:-}" = "storage" ]; then
	sources="$sources $src/air_tiles.cpp $src/air_voxelize.cpp"
	flags="-DAIR_WITH_STORAGE"
fi
g++ -std=c++17 -fno-exceptions -O2 -g -Wall -Wextra -pthread $flags -I"$src" $sources -o "$out/air_search_tests"

#!/bin/sh
# Builds the standalone native navigation tests from the same sources as the GDExtension.
# Usage: build_navigation_tests.sh OUTPUT_DIR   (then run OUTPUT_DIR/navigation_tests)
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=${1:?output directory}
mkdir -p "$out"
g++ -std=c++17 -fno-exceptions -O2 -g -Wall -Wextra -pthread -I"$here/../src" \
	"$here/navigation_tests.cpp" "$here/../src/navigation_world.cpp" "$here/../src/navigation_ground.cpp" \
	"$here/../src/navigation_jobs.cpp" "$here/../src/navigation_follow.cpp" "$here/../src/navigation_steering.cpp" \
	"$here/../src/navigation_progress.cpp" "$here/../src/navigation_batch.cpp" -o "$out/navigation_tests"

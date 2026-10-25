#!/bin/sh
# Builds the standalone nav_air transition tests (AIR_TRANSITIONS slice) with g++, never scons.
# Usage: build_air_transitions_tests.sh OUTPUT_DIR   (then run OUTPUT_DIR/air_transitions_tests)
set -e
here=$(cd "$(dirname "$0")" && pwd)
air="$here/../nav_air"
out=${1:?output directory}
mkdir -p "$out"
g++ -std=c++17 -fno-exceptions -O2 -g -Wall -Wextra -pthread -I"$air" \
	"$here/air_transitions_tests.cpp" "$air/air_transitions.cpp" "$air/air_reservations.cpp" \
	"$air/air_search.cpp" "$air/air_shorten.cpp" "$air/air_dynamic.cpp" "$air/air_test_space.cpp" \
	-o "$out/air_transitions_tests"

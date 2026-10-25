#!/usr/bin/env bash
# Builds every library pony_solver.gdextension lists, in place, then checks that none of them
# carries this machine's paths, user name or host name (docs/NAVIGATION_PLATFORMS_2026_10_02.md):
#   linux   template_debug + template_release x86_64   system g++
#   windows template_debug + template_release x86_64   llvm-mingw (UCRT)
#   android template_release arm64                     Android NDK (android.debug.arm64 loads it too)
#
# Usage: build_all.sh [PROJECT_DIR]     PROJECT_DIR defaults to this script's folder; pass a copy
#                                       of it (SConstruct + src/) to build somewhere else.
# Env overrides: GODOT_CPP, SCONS, MINGW_PREFIX, ANDROID_HOME, NDK_VERSION, JOBS, SCONS_LOCK.
#
# godot-cpp writes its objects and libgodot-cpp.<platform>.<target>.<arch>.a into its own tree and
# its generated bindings (gen/) are shared by every platform, so every scons call that uses the
# same GODOT_CPP must hold the same lock. The SConstruct's -ffile-prefix-map must stay: it turns
# this machine's home folder into "~/" in the assert and __FILE__ strings the libraries carry.
set -euo pipefail

DIR="$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")}" && pwd -P)"
GODOT_CPP="${GODOT_CPP:-$HOME/tools/godot-cpp}"
SCONS="${SCONS:-$HOME/tools/scons-venv/bin/scons}"
MINGW_PREFIX="${MINGW_PREFIX:-$HOME/tools/llvm-mingw-20260922-ucrt-ubuntu-22.04-x86_64}"
ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
NDK_VERSION="${NDK_VERSION:-27.1.12297006}"
SCONS_LOCK="${SCONS_LOCK:-$HOME/project/captures/navigation-overhaul-2026-10-02/scons.lock}"
cores="$(nproc)"
JOBS="${JOBS:-$(( cores > 1 ? cores / 2 : 1 ))}"  # the desktop is shared with a running game

[[ -f "$DIR/SConstruct" && -d "$DIR/src" ]] || { echo "build_all: $DIR has no SConstruct/src" >&2; exit 2; }
grep -q -- '-ffile-prefix-map=' "$DIR/SConstruct" \
	|| { echo "build_all: $DIR/SConstruct lost its -ffile-prefix-map flag" >&2; exit 2; }
for tool in "$SCONS" "$MINGW_PREFIX/bin/x86_64-w64-mingw32-clang++" \
		"$ANDROID_HOME/ndk/$NDK_VERSION/toolchains/llvm/prebuilt/linux-x86_64/bin/clang++"; do
	[[ -x "$tool" ]] || { echo "build_all: missing $tool" >&2; exit 2; }
done
[[ -f "$GODOT_CPP/SConstruct" ]] || { echo "build_all: no godot-cpp at $GODOT_CPP" >&2; exit 2; }
mkdir -p "$(dirname "$SCONS_LOCK")"

echo "build_all: $DIR (jobs $JOBS, lock $SCONS_LOCK)"
echo "  g++:        $(g++ --version | head -n 1)"
echo "  llvm-mingw: $("$MINGW_PREFIX/bin/x86_64-w64-mingw32-clang++" --version | head -n 1)"
echo "  NDK:        $NDK_VERSION, $("$ANDROID_HOME/ndk/$NDK_VERSION/toolchains/llvm/prebuilt/linux-x86_64/bin/clang++" --version | head -n 1)"
echo "  SCons:      $("$SCONS" --version | grep -m 1 -o -E 'v[0-9]+(\.[0-9]+)+')"
echo "  godot-cpp:  $(git -C "$GODOT_CPP" describe --tags --always 2>/dev/null || echo unknown)"

build() {
	echo "== scons $*"
	local start=$SECONDS
	(cd "$DIR" && GODOT_CPP="$GODOT_CPP" ANDROID_HOME="$ANDROID_HOME" \
		flock "$SCONS_LOCK" nice -n 10 "$SCONS" -j"$JOBS" "$@")
	echo "   done in $(( SECONDS - start )) s"
}

build platform=linux target=template_debug arch=x86_64
build platform=linux target=template_release arch=x86_64
build platform=windows use_mingw=yes use_llvm=yes mingw_prefix="$MINGW_PREFIX" target=template_debug arch=x86_64
build platform=windows use_mingw=yes use_llvm=yes mingw_prefix="$MINGW_PREFIX" target=template_release arch=x86_64
build platform=android arch=arm64 target=template_release ndk_version="$NDK_VERSION"

outputs=(
	libpony_solver.linux.template_debug.x86_64.so
	libpony_solver.linux.template_release.x86_64.so
	libpony_solver.windows.template_debug.x86_64.dll
	libpony_solver.windows.template_release.x86_64.dll
	libpony_solver.android.template_release.arm64.so
)
user="$(id -un)"
host="$(hostname)"
needles=("/home/$user" "$HOME/" "~/Projects")
(( ${#host} > 3 )) && needles+=("$host")
fail=0
echo "== outputs"
for name in "${outputs[@]}"; do
	path="$DIR/bin/$name"
	if [[ ! -s "$path" ]]; then
		echo "MISSING $name"; fail=1; continue
	fi
	hits=()
	for needle in "${needles[@]}"; do
		grep -q -a -F -- "$needle" "$path" && hits+=("'$needle'")
	done
	# The user name as a word of its own (identifiers such as _${user}_input do not count).
	grep -q -a -P -- "(?<![A-Za-z0-9_])\Q$user\E(?![A-Za-z0-9_])" "$path" && hits+=("user name '$user'")
	if (( ${#hits[@]} )); then
		echo "LEAK    $name: ${hits[*]}"; fail=1
	else
		printf 'clean   %-52s %10d bytes\n' "$name" "$(stat -c %s "$path")"
	fi
done
if (( fail )); then
	echo "BUILD_ALL FAIL"; exit 1
fi
echo "BUILD_ALL PASS"

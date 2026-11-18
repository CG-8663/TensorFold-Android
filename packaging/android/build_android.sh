#!/bin/sh
# Cross-compiles the Vulkan bring-up tools for an Android phone: tf-vulkan-probe and tf-vulkan-kernel-contract.
# They are plain executables for `adb shell`, with no JVM and no model engine. See docs/android-bringup.md.
#
#   ANDROID_NDK_HOME=/path/to/ndk packaging/android/build_android.sh
#
# Environment:
#   ANDROID_NDK_HOME  the NDK root, r27 or later (required)
#   ANDROID_API       the API level whose crt objects are linked (default 35)
#   TF_ANDROID_TARGET the Zig target (default aarch64-linux-android)
#   TF_ANDROID_CPU    the Zig CPU (default: unset, the target's baseline)
#   GLSLANG           glslang on the build host (default: glslang on PATH)
set -eu

: "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to the Android NDK root (r27 or later)}"
api="${ANDROID_API:-35}"
target="${TF_ANDROID_TARGET:-aarch64-linux-android}"
glslang="${GLSLANG:-glslang}"
root="$(cd "$(dirname "$0")/../.." && pwd)"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) host=linux-x86_64 ;;
  Darwin-*) host=darwin-x86_64 ;; # the NDK's one macOS toolchain directory, universal binaries
  *) echo "build_android.sh: no NDK prebuilt toolchain known for $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac
sysroot="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host/sysroot"

for need in "$sysroot/usr/include/vulkan/vulkan_core.h" "$sysroot/usr/lib/aarch64-linux-android/$api/crtbegin_dynamic.o"; do
  [ -e "$need" ] || { echo "build_android.sh: missing $need (NDK too old, or ANDROID_API=$api not in it)" >&2; exit 1; }
done
command -v "$glslang" >/dev/null || { echo "build_android.sh: $glslang not found; install glslang or set GLSLANG" >&2; exit 1; }
want="$(cat "$root/.zig-version")"
have="$(zig version)"
[ "$have" = "$want" ] || { echo "build_android.sh: Zig $want required, found $have" >&2; exit 1; }

out="$root/zig-out/android"
mkdir -p "$out"
sed -e "s|@SYSROOT@|$sysroot|g" -e "s|@API@|$api|g" "$root/packaging/android/libc.txt.in" | grep -v '^#' > "$out/libc.txt"

cd "$root"
set -- zig build vulkan-probe-build tf-vulkan-kernel-contract \
  -Dvulkan=true \
  -Dtarget="$target" \
  -Doptimize=fast \
  -Dvulkan-include="$sysroot/usr/include" \
  -Dglslang="$glslang" \
  --libc "$out/libc.txt" \
  --prefix "$out"
[ -z "${TF_ANDROID_CPU:-}" ] || set -- "$@" -Dcpu="$TF_ANDROID_CPU"
echo "+ $*"
"$@"

echo
echo "Built:"
ls -l "$out/bin/tf-vulkan-probe" "$out/bin/tf-vulkan-kernel-contract"
echo
echo "Next: docs/android-bringup.md, 'Run on the phone'."

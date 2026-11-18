#!/bin/sh
# Cross-compiles the Vulkan bring-up tools for an Android phone: tf-vulkan-probe and tf-vulkan-kernel-contract.
# They are plain executables for `adb shell`, with no JVM and no model engine. See docs/android-bringup.md.
#
#   On a Linux or macOS host:  ANDROID_NDK_HOME=/path/to/ndk packaging/android/build_android.sh
#   On the phone, in Termux:   packaging/android/build_android.sh
#
# Environment:
#   ANDROID_NDK_HOME  the NDK root, r27 or later (required on a host; unused in Termux, whose $PREFIX is the sysroot)
#   ANDROID_API       the API level whose crt objects are linked (default 35; unused in Termux)
#   TF_ANDROID_TARGET the Zig target (default aarch64-linux-android)
#   TF_ANDROID_CPU    the Zig CPU (default: unset, the target's baseline)
#   GLSLANG           glslang on the build host (default: glslang on PATH)
set -eu

api="${ANDROID_API:-35}"
target="${TF_ANDROID_TARGET:-aarch64-linux-android}"
glslang="${GLSLANG:-glslang}"
root="$(cd "$(dirname "$0")/../.." && pwd)"

if [ -n "${TERMUX_VERSION:-}" ]; then
  # Termux: the ndk-sysroot package lays bionic's headers and crt objects out under $PREFIX
  : "${PREFIX:?Termux sets PREFIX}"
  include="$PREFIX/include"
  crt="$PREFIX/lib"
  hint="pkg install ndk-sysroot vulkan-headers"
else
  : "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to the Android NDK root (r27 or later)}"
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) host=linux-x86_64 ;;
    Darwin-*) host=darwin-x86_64 ;; # the NDK's one macOS toolchain directory, universal binaries
    *) echo "build_android.sh: no NDK prebuilt toolchain known for $(uname -s) $(uname -m)" >&2; exit 1 ;;
  esac
  include="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host/sysroot/usr/include"
  crt="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host/sysroot/usr/lib/aarch64-linux-android/$api"
  hint="NDK too old, or ANDROID_API=$api not in it"
fi

for need in "$include/vulkan/vulkan_core.h" "$include/aarch64-linux-android/asm/types.h" "$crt/crtbegin_dynamic.o"; do
  [ -e "$need" ] || { echo "build_android.sh: missing $need ($hint)" >&2; exit 1; }
done
command -v "$glslang" >/dev/null || { echo "build_android.sh: $glslang not found; install glslang or set GLSLANG" >&2; exit 1; }
want="$(cat "$root/.zig-version")"
have="$(zig version)"
[ "$have" = "$want" ] || { echo "build_android.sh: Zig $want required, found $have" >&2; exit 1; }

out="$root/zig-out/android"
mkdir -p "$out"
sed -e "s|@INCLUDE@|$include|g" -e "s|@CRT@|$crt|g" "$root/packaging/android/libc.txt.in" | grep -v '^#' > "$out/libc.txt"

cd "$root"
set -- zig build vulkan-probe-build tf-vulkan-kernel-contract \
  -Dvulkan=true \
  -Dtarget="$target" \
  -Doptimize=fast \
  -Dvulkan-include="$include" \
  -Dglslang="$glslang" \
  --libc "$out/libc.txt" \
  --prefix "$out"
[ -z "${TF_ANDROID_CPU:-}" ] || set -- "$@" -Dcpu="$TF_ANDROID_CPU"
echo "+ $*"
"$@"

# bionic on arm64 refuses an executable whose TLS segment is aligned below 64 bytes, which Zig's linker may emit
if command -v termux-elf-cleaner >/dev/null; then
  termux-elf-cleaner "$out/bin/tf-vulkan-probe" "$out/bin/tf-vulkan-kernel-contract"
else
  echo "build_android.sh: termux-elf-cleaner not found; if the phone reports an underaligned TLS segment, run it on the binaries" >&2
fi

echo
echo "Built:"
ls -l "$out/bin/tf-vulkan-probe" "$out/bin/tf-vulkan-kernel-contract"
echo
echo "Next: docs/android-bringup.md, 'Run on the phone'."

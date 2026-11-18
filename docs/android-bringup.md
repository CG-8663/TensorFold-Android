# Android Vulkan bring-up

This fork's first step toward running TensorFold on an Android phone (first target: Samsung Galaxy Z Fold8,
Snapdragon 8 Elite Gen 5, Adreno 840). It does not serve a model. It cross-compiles the two Vulkan bring-up tools
that already exist upstream and runs them on the phone over `adb shell`:

- `tf-vulkan-probe` reports what the phone's Vulkan driver offers and runs the one Vulkan kernel TensorFold has
  (the MLX affine 4-bit, group-64 projection) against a float64 reference.
- `tf-vulkan-kernel-contract` runs the same kernel through the kernel contract's gates and planted controls.

Upstream has measured these only on Apple GPUs under Mesa. Nothing here has been built or run on Android yet: the
first run of the steps below is the test.

## What this branch changes

- `zig/src/vulkan/runtime.zig`: the loader falls back to `libvulkan.so`, Android's unversioned name, when
  `libvulkan.so.1` is absent.
- `zig/src/vulkan/memory.zig`: a third buffer kind, `shared`, whose memory is `DEVICE_LOCAL | HOST_VISIBLE |
  HOST_COHERENT`. Kernels bind it and the host reads and writes it through its mapping, with no staging copy.
  A device without such a memory type refuses it (`error.MissingFeature`).
- `zig/src/vulkan/device.zig`: `Device.offered` (every optional feature the driver offers) and `Device.extensions`.
- `zig/tests/vulkan/probe.zig`: four report lines (limits, features, memory, extensions) and a shared-buffer
  round trip.
- `packaging/android/`: the NDK libc template and `build_android.sh`.

A `shared` buffer saves the staging copy; it is not yet zero-copy from an `mmap`-ed checkpoint. The weights are
still written into Vulkan-allocated memory once. Importing a file mapping as buffer memory needs
`VK_EXT_external_memory_host`, which the probe reports and nothing uses yet.

## Build

On a Linux or macOS host with Zig 0.17.0, Android NDK r27 or later and `glslang`:

```sh
ANDROID_NDK_HOME=/path/to/android-ndk packaging/android/build_android.sh
```

Or on the phone itself, in Termux (from F-Droid or GitHub, not the Play Store build), with Zig 0.17.0 unpacked
from ziglang.org's `aarch64-linux` archive and on `PATH`:

```sh
pkg install git glslang ndk-sysroot vulkan-headers termux-elf-cleaner
packaging/android/build_android.sh
zig-out/android/bin/tf-vulkan-probe --timeout-ms 20000
```

Built in Termux, the tools run in place from Termux's shell; `adb` is not needed. Do not install a Termux Vulkan
loader package: the probe should load the system's `libvulkan.so`, which is the Adreno driver's.

The binaries land in `zig-out/android/bin/`. `ANDROID_API` (default 35) picks the NDK crt directory;
`TF_ANDROID_CPU` passes a Zig `-Dcpu` (for example `generic+v9a+dotprod+i8mm+fullfp16`; Zig's name for
half-precision arithmetic is `fullfp16`). The probe needs neither.

The host tests of the changed files run without a phone or a GPU:

```sh
zig build vulkan-host-test -Dvulkan=true -Dvulkan-include=/path/to/vulkan-headers/include
```

## Run on the phone

With USB debugging on and the phone authorised:

```sh
adb push zig-out/android/bin/tf-vulkan-probe /data/local/tmp/
adb push zig-out/android/bin/tf-vulkan-kernel-contract /data/local/tmp/
adb shell chmod +x /data/local/tmp/tf-vulkan-probe /data/local/tmp/tf-vulkan-kernel-contract

adb shell '/data/local/tmp/tf-vulkan-probe --timeout-ms 20000 2>&1; echo exit=$?' | tee probe.log
adb shell '/data/local/tmp/tf-vulkan-kernel-contract 2>&1; echo exit=$?' | tee contract.log
```

Qualcomm's PCI vendor is `0x5143`; add `--vendor 0x5143` to refuse any other device.

The probe exits 0 on a pass, 1 on a failure, 2 on bad arguments and 124 when a fence wait times out.

## Reading the probe's output

| Line | What it settles |
|---|---|
| `MILESTONE device-found` | The driver, its version and the subgroup size it reports. |
| `MILESTONE device-limits` | Subgroup size range, shared memory, workgroup limits, the largest buffer and allocation. The largest allocation bounds how a checkpoint must be split across buffers. |
| `MILESTONE device-features` | Which of float16, int8, int16, int64, float64 and 8/16-bit storage the driver offers. A missing `float64` is expected on a phone GPU and matters only to kernels that ask for it. |
| `MILESTONE device-memory` | `shared_type` is the memory type a `shared` buffer would use, or -1 when there is none. |
| `MILESTONE device-extensions` | Whether cooperative matrix, bfloat16, integer dot product, float16/int8, host-memory import and AHardwareBuffer import are listed. |
| `MILESTONE roundtrip-equal` | Staged upload and readback agree. |
| `MILESTONE shared-roundtrip-equal` or `SKIP shared-roundtrip` | Host writes are seen by the GPU and GPU writes by the host through a shared buffer, or the device has no memory type for one. |
| `MILESTONE affine-fp64` (one per case) | The 4-bit projection is within its float64 bound, byte-identical over five repeats. |
| `RESULT vulkan-probe` | The tally. |

Keep `probe.log` and `contract.log`: a backend's choices (workgroup size, FP16 storage, buffer splitting, whether
shared buffers are usable) should follow these lines, not the chip's data sheet.

## If the build or run fails

- `translate-c` cannot find `stdint.h` or a `bits/` header: the Vulkan header is being translated without the
  NDK's libc headers. `-Dvulkan-include` already names the sysroot's `usr/include`; the architecture directory
  `usr/include/aarch64-linux-android` may need adding in `zig/build/vulkan.zig`.
- `zig build` stops while configuring, before compiling: some other step in `build.zig` does not accept an
  Android target. The message names the file under `zig/build/`.
- The phone refuses to start the binary over an underaligned TLS segment: run `termux-elf-cleaner` on it (the
  build script does when the tool is installed).
- `error.DriverUnavailable` on the phone: neither `libvulkan.so.1` nor `libvulkan.so` loaded.
- `error.VulkanVersion`: the driver is below Vulkan 1.3.
- The contract runner asks for 16-bit storage and fails with `MissingFeature` if the driver lacks it.

## What comes after

No model family has a Vulkan engine: upstream's Qwen3.5 engines are written against Metal and CUDA. Serving a
model on the phone means writing that engine (embedding, norms, attention over a KV cache, the recurrence path,
the head and sampling) kernel by kernel, each admitted through the kernel contract as the projection was. A
Hexagon NPU delegate and Arm CPU kernels are separate work after that.

# Building PrivateLM for Linux

Status: **Linux port implemented (M1–M8).** Standalone Linux chat works, and
Linux can host or join an AI cluster: the same `rpc7` protocol as
Android/iOS/Windows, served by `bundle/lib/privatelm_rpc_worker`. Pairing works
over the LAN, a USB cable through `adb`, USB tethering, and Tailscale. See
`docs/ai-cluster.md` for cluster setup, `docs/usb-adb.md` for the cable bridge,
and `PLAN-privatelm-linux-ai-cluster.md` (kept outside the repository) for the
full sequence.

## Supported targets

| Target | State |
|---|---|
| Linux x64, X11 and Wayland | Built and run by this document |
| CPU inference | Default |
| Vulkan inference | Opt-in at build time |
| Linux ARM64 | Deferred |

Linux is an FFI desktop target: `flutter build linux` produces a normal GTK
bundle with `libllama_flutter_android.so` and `privatelm_rpc_worker` in
`bundle/lib/`. The same `llama.cpp` source tree as Android/Windows is compiled
in, so prompt templates, vision projectors and the `rpc7` cluster protocol
match.

## Prerequisites

- Flutter stable with Linux desktop support (`flutter config --enable-linux-desktop`)
- Dart (bundled with Flutter)
- A C/C++ toolchain, CMake, Ninja and pkg-config
- GTK 3, GLib and GIO development headers
- xkbcommon development headers

Ubuntu / Debian / Linux Mint:

```bash
sudo apt update
sudo apt install -y \
  clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev libxkbcommon-dev
```

Fedora:

```bash
sudo dnf install -y \
  clang cmake ninja-build pkgconf-pkg-config \
  gtk3-devel glib2-devel xz-devel \
  libxkbcommon-devel gcc-c++
```

Arch:

```bash
sudo pacman -S --needed \
  clang cmake ninja pkgconf gtk3 glib2 xz xkbcommon base-devel
```

Optional, for faster CPU inference (clang needs the LLVM runtime; the
distribution `clang` package does not ship it):

- Ubuntu / Debian / Mint: `libomp-18-dev` (match your clang major, or
  `libomp-dev`)
- Fedora: `libomp-devel`
- Arch: `openmp`

Without it the build succeeds with `CMake Warning ... OpenMP not found`
and llama.cpp uses its std::thread backend: tokens still stream, but
prompt processing is slower.

Optional, only for GPU inference:

- Vulkan loader and development headers (`libvulkan-dev` / `vulkan-devel`)
- A Vulkan-capable driver
- `glslc` from the Vulkan SDK for shader compilation

Verify:

```bash
flutter doctor -v
```

The **Linux toolchain** section must be green.

## Build

From the repository root:

```bash
flutter pub get
flutter analyze
flutter build linux --debug
```

Or use the script, which locates Flutter from `PATH`, `android/local.properties`
or the common install directories, and checks the native dependencies first:

```bash
scripts/build_linux.sh
scripts/build_linux.sh --release
scripts/build_linux.sh --release --vulkan
scripts/build_linux.sh --release --package
```

Output:

```text
build/linux/x64/debug/bundle/privatelm
build/linux/x64/release/bundle/privatelm
```

The bundle also contains:

```text
bundle/lib/libllama_flutter_android.so   # llama.cpp + the plm_* C ABI
bundle/lib/libflutter_linux_gtk.so
bundle/data/…                            # Flutter assets, ICU data
```

`--package` writes `build/linux/privatelm-<version>-linux-x64.tar.gz`.

## Run

```bash
flutter run -d linux
# or
build/linux/x64/debug/bundle/privatelm
```

The window opens at 1100×800 and cannot be resized below 900×600.

Set `PLM_LLM_LOG=1` to tee llama.cpp logs to stderr.

## Vulkan (opt-in)

The default build is CPU-only and needs no Vulkan SDK. To compile the Vulkan
backend:

```bash
PRIVATELM_LINUX_VULKAN=1 flutter build linux --release
# equivalent:
scripts/build_linux.sh --release --vulkan
```

The backend is linked into `libllama_flutter_android.so`. A machine without a
Vulkan ICD (or with a driver that does not expose Vulkan) still starts: the
backend registers zero devices, GPU detection reports no GPU, and the engine
falls back to the CPU. Unset `PRIVATELM_LINUX_VULKAN` for a CPU-only build.

## Verify the native ABI

```bash
nm -D build/linux/x64/release/bundle/lib/libllama_flutter_android.so \
  | grep ' plm_'
```

Expected symbols include `plm_load_model`, `plm_generate`, `plm_stop`,
`plm_unload`, `plm_context_info_json`, `plm_detect_gpu_json`,
`plm_free_ram_mb`, `plm_set_cluster` and `plm_free_string`.

Optional engine smoke test, using a small GGUF:

```bash
PRIVATELM_TEST_GGUF=/path/to/model.gguf flutter test test/linux_engine_smoke_test.dart
```

## Verify the cluster worker

`bundle/lib/privatelm_rpc_worker` must be executable (`install(FILES)` would
strip the mode, so the Linux runner installs bundled artifacts as programs).
The desktop cluster tests start the real worker and connect a master to it:

```bash
flutter test test/desktop_worker_test.dart test/desktop_master_test.dart
```

They skip when the bundle has not been built. Setting
`PRIVATELM_TEST_WORKER=/path/to/privatelm_rpc_worker` points them at another
build.

A manual check of the status file and port:

```bash
bundle/lib/privatelm_rpc_worker \
  --host 0.0.0.0 --port 50052 \
  --status-file /tmp/worker.json --id test
cat /tmp/worker.json      # {"state":"running", ...}
ss -ltn | grep 50052
```

Cluster setup, firewall commands and the data directory are covered in
[docs/ai-cluster.md](ai-cluster.md).

## How the library is found

`local_plugins/llama_flutter_android/lib/src/llama_desktop_ffi.dart` resolves,
in order:

1. `PRIVATELM_TEST_DLL` (test/developer override)
2. `<exe dir>/lib/libllama_flutter_android.so` (Flutter bundle layout)
3. `<exe dir>/libllama_flutter_android.so`
4. the bare name `libllama_flutter_android.so` (loader search path)

## Troubleshooting

**`Missing build tool: cmake` / `ninja` / `clang++`.** Install the packages
above. Flutter does not bundle a Linux C++ toolchain.

**`gtk+-3.0` not found by `pkg-config`.** Install `libgtk-3-dev`
(Ubuntu/Debian) or `gtk3-devel` (Fedora).

**`CMake Warning ... OpenMP not found`.** Harmless, but CPU prompt processing
is slower without it. Install the OpenMP runtime for your clang
(`libomp-18-dev`, or `libomp-dev`) and remove the CMake cache
(`rm -rf build/linux`) so `find_package(OpenMP)` runs again. Fedora:
`libomp-devel`; Arch: `openmp`.

**The build succeeds but the app reports the library is missing.** Check that
`bundle/lib/libllama_flutter_android.so` exists. If it does not, the plugin's
`linux/CMakeLists.txt` was not reached — confirm `linux: ffiPlugin: true` in
`local_plugins/llama_flutter_android/pubspec.yaml` and rerun `flutter pub get`.

**`undefined reference` while linking the plugin.** The shared ABI adapter
lives in `local_plugins/llama_flutter_android/src/llama_ffi.cpp` and the header
in `include/llama_ffi.h`. Both Windows and Linux CMake must compile that file;
do not add a Linux-only copy.

**Wayland vs X11.** Both are supported by Flutter's GTK runner. If a window
manager behaves oddly, try `GDK_BACKEND=x11` or `GDK_BACKEND=wayland` to
isolate the cause.

## Not included yet

- Linux ARM64
- iOS over USB (`usbmuxd`/`iproxy`)
- AppImage/Flatpak/Snap packaging and in-app auto-update

The USB bridge and Tailscale are desktop-only features; the Android/iOS apps
can still be masters or workers for a Linux PC.

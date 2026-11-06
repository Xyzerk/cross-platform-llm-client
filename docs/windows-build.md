# Building PrivateLM for Windows

Phases 0–5 are done: the runner, window sizing, the FFI plugin target, the
build script, the real engine — `llama_flutter_android.dll` embeds a static
llama.cpp (CPU + RPC + mtmd, the same tree the Android build compiles) — the
Dart Windows inference host, the cluster transport abstraction,
`privatelm_rpc_worker.exe`, which lets an Android/iOS master use this PC as a
cluster worker, and the master side, which spreads a model across phone
workers. Standalone Windows chat with a GGUF model works through the C ABI in
`local_plugins/llama_flutter_android/windows/include/llama_ffi.h`. Vulkan/GPU
inference (Phase 2c) is the remaining item. See
[windows-port-plan.md](windows-port-plan.md) for the full roadmap.

## Prerequisites

- Flutter 3.47+ (stable) with the Windows desktop toolchain
- Visual Studio 2022 with the **Desktop development with C++** workload. The
  three components that matter, by installer ID:
  - `Microsoft.VisualStudio.Component.VC.Tools.x86.x64` — MSVC toolset (v143)
  - `Microsoft.VisualStudio.Component.VC.CMake.Project` — C++ CMake tools
  - `Microsoft.VisualStudio.Component.Windows11SDK.26100` — Windows SDK
- Optional: Vulkan SDK, only when GPU inference is enabled later

Flutter resolves CMake from a fixed path inside the Visual Studio installation:

```
<VS install>\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe
```

A standalone CMake on `PATH` does not satisfy this, so the CMake component must
be installed through the Visual Studio Installer.

Verify the toolchain before building:

```powershell
flutter doctor -v
```

The **Visual Studio** section must show a green check. If it lists missing
components, open the Visual Studio Installer, modify the installation, and add
them. A machine can have Visual Studio installed and still fail this check when
the C++ workload is incomplete.

> **Ignore the "MSVC v142" wording.** `flutter doctor` prints that string for
> every VS 2022 install; it is the `default` branch of a hardcoded switch, not
> what is checked. The real requirement is
> `Microsoft.VisualStudio.Component.VC.Tools.x86.x64`, satisfied by the current
> v143 toolset. Do not install v142 on that basis alone.

## Troubleshooting

These are the failures this project actually hit, in order.

**`Building with plugins requires symlink support.`**
Developer Mode is off. Flutter creates plugin symlinks under
`windows/flutter/ephemeral/.plugin_symlinks`. Enable Developer Mode, then
restart your terminal — an already-running shell keeps the old token and still
fails to create symlinks.

**`Unable to find suitable Visual Studio toolchain.`**
`vswhere` could not find both required components. Check directly:

```powershell
& "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe" `
  -latest -products * `
  -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            Microsoft.VisualStudio.Component.VC.CMake.Project `
  -property installationPath
```

Empty output means one is missing. Install them in the Visual Studio Installer.

**`CMake Error at CMakeLists.txt:3 (project): No CMAKE_CXX_COMPILER could be found.`**
The MSVC toolset is present but the **Windows SDK is not**. CMake's compiler
probe fails because `windows.h` cannot be found. Confirm with:

```powershell
cmd /c "`"C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat`" >nul && cl /nologo /EHsc t.cpp"
```

`fatal error C1083: Cannot open include file: 'windows.h'` means the SDK is
missing. Check `C:\Program Files (x86)\Windows Kits\10\Include` — if it is
absent or empty, add the SDK component:

```powershell
& "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vs_installer.exe" modify `
  --installPath "C:\Program Files\Microsoft Visual Studio\2022\Community" `
  --add Microsoft.VisualStudio.Component.Windows11SDK.26100 `
  --passive --norestart
```

Reboot afterward if `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component
Based Servicing\RebootPending` exists; the installer leaves the SDK half-written
until the transaction completes.

**`error MSB3491: ... exceeds the OS max path limit.`**
MSBuild's plugin build tree passes 260 characters. Enable long paths once
(elevated):

```powershell
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
  -Name LongPathsEnabled -Value 1 -Type DWord
```

No reboot needed, but reopen the terminal so MSBuild sees it. This is not
optional tidiness: the Windows `llama.cpp` build in later phases also produces
deep paths.

**`Nuget is not installed!` then `NUGET-NOTFOUND install ... exited with code 9009`**
`flutter_inappwebview_windows` downloads WIL, WebView2 and nlohmann.json with
NuGet. It only does `find_program(NUGET nuget)`, so `nuget` must be on `PATH`:

```powershell
$dir = "$env:LOCALAPPDATA\Programs\nuget"
New-Item -ItemType Directory -Force $dir | Out-Null
Invoke-WebRequest 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe' `
  -OutFile "$dir\nuget.exe"
[Environment]::SetEnvironmentVariable('Path', "$dir;" + [Environment]::GetEnvironmentVariable('Path', 'User'), 'User')
```

If the lookup was already cached as `NUGET-NOTFOUND`, delete
`build\windows\x64\CMakeCache.txt` and rebuild.

> `flutter_inappwebview` is currently an unused dependency in `pubspec.yaml`
> (no references under `lib/`). Dropping it removes this NuGet requirement, the
> `flutter_inappwebview_windows` compile step, and the WebView2 runtime from the
> bundle.

**`error C1189: <experimental/coroutine> ... only supported with /await`**
`gal` 2.3.3 forces `/std:c++20` but deleted the `/await` flag that 2.3.2 had, and
its Windows code is C++/WinRT. The `cppwinrt` headers in Windows SDK
10.0.19041.0 are pre-C++20 and need `/std:c++17 /await`; `/std:c++20 /await`
then fails with `'wait_for' is not a member of 'winrt::impl'`. This is patched
for `gal_plugin` in `windows/CMakeLists.txt` (search for "Third-party plugin
workarounds"). Remove that block once `gal` ships a Windows build against
Windows SDK 10.0.22621+.

## Enable Developer Mode

Flutter builds Windows plugins using symlinks. Without Developer Mode the build
fails with:

```
Building with plugins requires symlink support.
Please enable Developer Mode in your system settings.
```

Enable it once:

```powershell
start ms-settings:developers
```

Turn on **Developer Mode**, then reopen the terminal.

## Build

From `cross-platform-llm-client/`:

```powershell
flutter pub get
flutter analyze
flutter build windows --debug
```

Or use the script, which locates Flutter from `PATH` or
`android/local.properties`:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build_windows.ps1
powershell -ExecutionPolicy Bypass -File scripts/build_windows.ps1 -Mode release
```

The executable is written to:

```
build\windows\x64\runner\Debug\privatelm.exe
build\windows\x64\runner\Release\privatelm.exe
```

## Run

```powershell
flutter run -d windows
```

The window opens at 1100×800, cannot be resized below 900×600, and is clamped to
the monitor work area so its frame never lands off-screen on small displays.

## What Phase 1 includes

- The shared engine core lives in `local_plugins/llama_flutter_android/src/`:
  - `plm_core.{h,cpp}` — process-global state, cluster planning, memory
    bandwidth, and the llama.cpp log hook (load buffers, worker peer, load
    error capture).
  - `plm_engine.{h,cpp}` — model/context lifecycle, the generation loop with
    KV-cache prefix reuse, the sampling chain, vision (mtmd), stop/unload and
    GPU detection. Exact same code the Android JNI layer runs.
- `android/src/main/cpp/jni_wrapper.cpp` is now a thin JNI adapter; all JNI
  symbols and error messages are unchanged, so Android behavior is identical.
- `windows/llama_ffi.cpp` + `include/llama_ffi.h` export the C ABI
  (`plm_load_model`, `plm_generate`, `plm_stop`, `plm_unload`, …) from
  `llama_flutter_android.dll`.
- The Windows build compiles the plugin's llama.cpp tree statically
  (`GGML_RPC=ON`, mtmd ON, Vulkan off — deferred to Phase 2c), so the only
  bundled artifact is `llama_flutter_android.dll` itself.
  - llama.cpp's own unconditional `install()` rules must be severed from
    Flutter's INSTALL step: llama.cpp targets resolve destinations like
    `${CMAKE_INSTALL_PREFIX}/lib` at *install-script runtime*, where the
    runner's `$<TARGET_FILE_DIR:privatelm>` prefix is a raw genex string
    that cannot resolve. `EXCLUDE_FROM_ALL` on the plugin's
    `add_subdirectory(... llama.cpp)` removes the subtree from the install
    chain (targets still build — the DLL links them) without touching
    Flutter's runner rules. Beware alternatives: `CMAKE_SKIP_INSTALL_RULES`
    set in a subdirectory does nothing there, and a no-op
    `function(install)` override in a subdirectory leaks to the parent
    scope and silently kills all of Flutter's install rules.
- `test/windows_engine_smoke_test.dart` (skipped unless Windows +
  `PRIVATELM_TEST_GGUF=<model.gguf>`; optionally `PRIVATELM_TEST_DLL=<path>`)
  loads a real GGUF through the DLL and checks token streaming.
- Set `PLM_LLM_LOG=1` to tee llama.cpp logs to stderr when debugging the
  native side.

## What Phase 2 includes

- `llama_flutter_android` now exposes a `LlamaHost` abstraction
  (`lib/src/llama_host.dart`) instead of calling the Pigeon API directly:
  - `LlamaHostPigeon` on Android/iOS — the existing MethodChannel contract,
    unchanged.
  - `LlamaHostFfi` on Windows — loads `llama_flutter_android.dll` and calls the
    C ABI in-process.
  - `LlamaHost` is web-safe; web never sees `dart:ffi`.
- Blocking native calls (`plm_load_model`, `plm_generate`) run in a short-lived
  worker isolate. Tokens and load progress are copied through
  `NativeCallable.isolateLocal` and a `SendPort`, so streaming works without
  blocking the UI isolate and without dangling `char*` pointers.
- `stop` calls `plm_stop` directly from the UI isolate and suppresses late
  token/done events from the stopped run.
- `chat_templates.dart` is a bug-for-bug Dart port of Android's
  `ChatTemplates.kt` (14 formatters, family auto-detection, custom-template
  registry), so Windows and Android produce the same prompts.
- The app extracts its fallback prompt builders into
  `lib/services/chat_prompt_builder.dart`, shared by the Android and Windows
  paths.
- Windows specifics in `lib/services/inference_android.dart`:
  `supportsLocalInference` includes Windows; thread count follows
  `Platform.numberOfProcessors` (capped at 16); `.litertlm` and `.safetensors`
  are rejected with clear messages.
- `inference_service.dart` uses `p.basename` for model names, so Windows paths
  with backslashes and drive letters work.
- C ABI additions: `plm_generate` takes an optional `image_path` (vision
  turns), and `plm_clear_context` was added.
- `test/chat_templates_test.dart` covers prompt parity with the Kotlin
  formatter.

## What Phase 3 and 4 include

- `lib/services/cluster_backend.dart` is the only cluster API the app uses.
  Its conditional import picks `cluster_backend_io.dart` (`LlamaClusterBackend`
  on Android/iOS, `WindowsClusterBackend` on Windows) or
  `cluster_backend_stub.dart` on web. `ClusterBackend.instance` is a
  per-process singleton, because the Windows backend owns a child process.
- `lib/services/cluster_windows_backend.dart`:
  - starts `privatelm_rpc_worker.exe` detached with `--parent-pid`, `--id`,
    `--model`, `--advertise-ip` and a status-file path;
  - reads `%LOCALAPPDATA%\PrivateLM\cluster\worker.json` (rewritten every
    second) for `workerStatus()`, and treats a file older than 6 s as a dead
    worker;
  - puts the worker in a Windows Job Object with
    `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` via `dart:ffi`, so closing PrivateLM
    stops the worker even if it is killed from Task Manager;
  - keeps the machine awake with `SetThreadExecutionState`;
  - plans loads through the plugin DLL (`plm_free_ram_mb`,
    `plm_benchmark_bandwidth`, `plm_set_cluster`, `plm_last_load_buffers`);
  - browses `_privatelm._tcp.local` with `multicast_dns` for "Find nearby".
- `local_plugins/llama_flutter_android/windows/rpc_worker/`:
  - `main.cpp` — arg parsing, CPU/RPC backend lookup, a pre-bind check so port
    conflicts surface the real Winsock message, Ctrl+C handling, a
    `--parent-pid` watchdog, and the 1 s status loop.
  - `status_writer.cpp` — atomic JSON status (temp file + replace).
  - `mdns_advertiser.cpp` — best-effort DNS-SD registration via
    `DnsServiceRegister` (no extra responder to ship).
  - The CMake target links the same static llama.cpp as the DLL, so the RPC
    protocol version (`rpc7`) matches every Android/iOS worker, and Flutter
    copies the exe next to `privatelm.exe`.
- Cluster UI on Windows: Master/Worker roles, a network-interface picker
  (persisted as `cluster_interface`), "Paste a worker link" instead of the
  camera scanner, a firewall warning with an "Allow through Windows Firewall"
  button (one UAC prompt), and a QR code plus `IP:port` for the master to scan
  or type.
- `plm::loadRpcBackendLocked()` now accepts a statically linked RPC backend
  before trying to load `libggml-rpc.so`, so a Windows master can use RPC
  workers without a separately shipped backend library.
- `test/windows_worker_test.dart` starts the real exe, checks the status file,
  and checks that a port already in use is reported. It skips when the Windows
  app has not been built.

## What Phase 5 includes

- A Windows PC can be the master: `WindowsClusterBackend` plans the load
  through the same `plm_set_cluster` / `plm_load_model` path Android uses, so
  the layer count, weights, `tensor_split`, the output-layer override and
  `op_offload = false` match the phone implementation exactly (both call
  `plm::planCluster`).
- Every worker is probed before the plan reaches llama.cpp, because
  `ggml_backend_rpc_add_server` can abort the process on an unreachable peer.
- `discover` browses `_privatelm._tcp.local` (PTR → SRV → A → TXT) and skips
  entries whose `v` is not `rpc7`; `ClusterService.relocateWorkers` matches
  saved workers by their stable ID after an IP change.
- `lastLoadBuffers` feeds `ClusterService.refreshSplit`, so the split card
  shows this PC's share and each worker's share (RPC buffers are named
  `RPC0[host:port]`).
- The Windows worker's status file reports the master's address too: the RPC
  transport patch used to log client addresses only on non-Windows builds.
- `test/windows_master_test.dart` starts the real worker, plans a load onto it
  and checks that llama.cpp's RPC client connects, using a metadata-only GGUF
  stub so no model file is needed. It skips when the app has not been built.

## What is not here yet

- Vulkan/GPU inference on Windows (Phase 2c)

## What Phase 0 includes

- `windows/` Flutter runner (generated by `flutter create --platforms=windows`)
- Window title `PrivateLM`, default size 1100×800, minimum size 900×600,
  clamped to the monitor work area
- `path` and `multicast_dns` dependencies for later path/discovery work
- `llama_flutter_android` declared as a Windows FFI plugin
- `scripts/build_windows.ps1`
- `gal` build workaround in `windows/CMakeLists.txt`

The placeholder `plm_phase0_probe()` export was replaced by the real engine
ABI in Phase 1.

## Cluster firewall note

Cluster mode uses TCP port `50052` and mDNS (UDP `5353`). Windows Firewall must
allow both on a **private** network profile. The cluster screen checks for the
`PrivateLM Cluster` rule and offers an "Allow through Windows Firewall" button
(one UAC prompt) that adds the TCP rule; allow mDNS/UDP 5353 by hand if
"Find nearby" should work too. Manual IP pairing needs only the TCP rule.

If the port cannot be bound, the worker's status file carries the Winsock
message and the cluster screen shows it verbatim instead of a generic failure.

The ggml RPC protocol has no authentication. Only run workers on a trusted
private LAN.

# PrivateLM Windows Port Plan

Goal: a Windows 10/11 x64 desktop build of PrivateLM with **local GGUF inference** and **two-way phone clustering**:

- Windows as master, Android/iOS phones as workers.
- Android phone as master, Windows as worker.
- Windows + Windows.
- Existing Android/iOS behavior unchanged.

This document is an implementation plan, not a promise of scope. Phases are ordered so the app is usable after Phase 2 and cluster-capable after Phase 5.

---

## 1. Decisions up front

| Decision                          | Choice                                                                                                       | Why                                                                                                                                                                                                                             |
|-----------------------------------|--------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Native engine                     | Reuse the bundled `llama.cpp` tree from `local_plugins/llama_flutter_android/android/src/main/cpp/llama.cpp` | The ggml RPC protocol version is compiled into both sides. Building Windows from the same commit is the only reliable way to interoperate with Android/iOS.                                                                     |
| Windows transport                 | Dart FFI against a new `llama_flutter_android.dll`                                                           | The plugin's Dart controller already owns load/generate/stop logic. Pigeon C++ codegen and StandardMessageCodec in C++ would add a lot of surface for no benefit. `sd_flutter_android` already uses FFI, so the pattern exists. |
| Worker model                      | Separate `privatelm_rpc_worker.exe` child process                                                            | `ggml_backend_rpc_start_server` blocks forever and cannot be stopped in-process. Android already isolates it in a `:cluster` process for this reason.                                                                           |
| Cluster discovery                 | Manual IP + QR guaranteed; mDNS as an enhancement                                                            | Windows firewall and router multicast filtering make mDNS unreliable. Manual/QR already exists and is the fallback.                                                                                                             |
| Windows master                    | Supported                                                                                                    | Required by "Windows master + phone workers".                                                                                                                                                                                   |
| iOS master                        | Not added                                                                                                    | Out of scope; iOS stays worker-only.                                                                                                                                                                                            |
| LiteRT-LM on Windows              | Deferred                                                                                                     | `flutter_litert_lm` has no Windows runtime. `.litertlm` is rejected with a clear message.                                                                                                                                       |
| Local Stable Diffusion on Windows | Deferred                                                                                                     | `sd_flutter_android` is Android-only and depends on a native submodule. `.safetensors` is rejected with a clear message.                                                                                                        |
| Windows ARM64                     | Deferred                                                                                                     | x64 first.                                                                                                                                                                                                                      |

---

## 2. Target architecture

```text
Windows app (Flutter)
├─ InferenceService
│  └─ InferenceEngine (inference_android.dart, shared by Android/iOS/Windows)
│     └─ LlamaController
│        └─ LlamaHost
│           ├─ LlamaHostPigeon  → Android/iOS MethodChannel (existing)
│           └─ LlamaHostFfi     → llama_flutter_android.dll (new)
│
├─ ClusterService
│  └─ ClusterBackend
│     ├─ LlamaClusterBackend  → Android/iOS MethodChannel (existing)
│     └─ WindowsClusterBackend
│        ├─ llama_flutter_android.dll : setCluster / probe / benchmark / RAM
│        ├─ privatelm_rpc_worker.exe   : RPC server + status + mDNS
│        └─ multicast_dns              : browse workers
│
└─ windows/ runner (new)

Native (built from the same llama.cpp tree)
├─ llama_flutter_android.dll
│  ├─ shared engine core (extracted from jni_wrapper.cpp)
│  ├─ llama.cpp (CPU + RPC client + optional Vulkan)
│  └─ C ABI for Dart FFI
├─ privatelm_rpc_worker.exe
│  ├─ ggml_backend_rpc_start_server
│  ├─ status JSON writer
│  └─ mDNS advertiser
└─ ggml-cpu.dll / ggml-rpc.dll / ggml-vulkan.dll (if dynamic backends)
```

Key invariant: **the Windows master and the Windows worker both use the same `llama.cpp` commit as the phones.** The worker advertises `v=rpc7` (same TXT key as Android/iOS), and the master should refuse a worker whose `v` does not match.

---

## 3. Phase 0 — Runner and build scaffolding

**Deliverable:** `flutter build windows --debug` launches an empty PrivateLM shell.

1. Add the Windows runner:
   ```bash
   cd cross-platform-llm-client
   flutter create --platforms=windows .
   ```
   Keep the generated `windows/` directory; do not touch Android/iOS.
2. Set a sensible default window size and minimum size in `windows/runner/main.cpp` (the UI is phone-shaped; a 1100×800 default with a 900×600 minimum is a reasonable start).
3. Add build prerequisites to `docs/windows-build.md`:
   - Visual Studio 2022 with **Desktop development with C++**
   - Windows 10/11 SDK
   - CMake (bundled with VS)
   - Optional: Vulkan SDK for GPU inference
4. Add dependencies to `pubspec.yaml`:
   ```yaml
   path: ^1.9.0
   multicast_dns: ^1.0.0   # browse _privatelm._tcp on Windows
   ```
   (`ffi` is already present.)
5. Add `windows` to `local_plugins/llama_flutter_android/pubspec.yaml` as an FFI plugin:
   ```yaml
   flutter:
     plugin:
       platforms:
         android: ...
         ios: ...
         windows:
           ffiPlugin: true
   ```
   Create `local_plugins/llama_flutter_android/windows/CMakeLists.txt`.
6. Add `scripts/build_windows.ps1` that runs `flutter pub get`, configures the native build, builds, and copies runtime DLLs/EXE next to the runner.

**Verify:** `flutter analyze`, `flutter build windows --debug`, launch, window opens.

---

## 4. Phase 1 — Extract the native engine core

**Deliverable:** a Windows DLL that loads a GGUF and streams tokens, built from the same source as Android.

The current engine lives in `local_plugins/llama_flutter_android/android/src/main/cpp/jni_wrapper.cpp` (≈55 KB). Most of it is not JNI-specific.

1. Create a shared native directory:
   ```text
   local_plugins/llama_flutter_android/native/
     llama_engine_core.h
     llama_engine_core.cpp
     llama_cluster_plan.h
     llama_cluster_plan.cpp
   ```
2. Move the platform-neutral pieces out of `jni_wrapper.cpp`:
   - model/context lifecycle (`llama_model_load_from_file`, `llama_init_from_model`)
   - generation loop and sampling
   - stop flag
   - context-info reporting
   - GGUF block-count reading
   - cluster plan (`ClusterPlan`: devices, `tensor_split`, `n_gpu_layers`, `tensor_buft_overrides`)
   - load-buffer log parsing (`RPC<n>[host:port]`)
   - GPU detection
   - RAM / bandwidth measurement
   - mtmd / vision projector loading (optional in Phase 2b)
3. Keep `jni_wrapper.cpp` as a thin JNI adapter that calls the core. Android behavior must not change.
4. Add the core to `android/CMakeLists.txt`.
5. Create the Windows adapter:
   ```text
   local_plugins/llama_flutter_android/windows/
     CMakeLists.txt
     llama_ffi.cpp
     llama_ffi.h
   ```
   Export a stable C ABI, for example:
   ```c
   int  plm_load_model(const char* path, int threads, int ctx, int gpu_layers,
                       const char* mmproj, plm_progress_cb cb, void* user);
   int  plm_generate(const char* prompt, int max_tokens, double temperature,
                     /* sampling params */ plm_token_cb cb, plm_done_cb done,
                     void* user);
   void plm_stop(void);
   void plm_unload(void);
   int  plm_is_model_loaded(void);
   char* plm_context_info_json(void);
   char* plm_detect_gpu_json(void);
   char* plm_last_load_buffers(void);
   int  plm_free_ram_mb(void);
   double plm_benchmark_bandwidth(void);
   void plm_set_cluster(const char** endpoints, const float* weights,
                        int count, float local_weight);
   void plm_clear_cluster(void);
   void plm_free_string(char* s);
   ```
6. Build options for Windows:
   - `GGML_RPC=ON` (required)
   - CPU backend enabled
   - `GGML_VULKAN=ON` optional (Phase 2c)
   - Prefer **static CPU + RPC** for the first build; if `GGML_BACKEND_DL=ON` is used, package `ggml-cpu.dll` / `ggml-rpc.dll` / `ggml-vulkan.dll` next to the exe.
7. Keep the RPC client logic from `jni_wrapper.cpp`:
   - `ggml_backend_reg_by_name("RPC")`
   - `ggml_backend_reg_get_proc_address(rpc, "ggml_backend_rpc_add_server")`
   - register each worker once, push its devices, compute `tensor_split`, `n_gpu_layers`, and `tensor_buft_overrides`
   - `model_params.devices = cluster.devices.data()`
   - `ctx_params.op_offload = false` while clustering

**Verify:**
- `flutter build windows --debug` links the DLL.
- A small Dart test (`test/windows_engine_smoke_test.dart`, skipped unless Windows + model path env var) loads a small GGUF and prints tokens.
- Android still builds and runs (regression check on `jni_wrapper.cpp`).

---

## 5. Phase 2 — Dart Windows inference

**Deliverable:** standalone Windows chat with a GGUF model, including the existing prompt/template behavior.

1. Add a `LlamaHost` abstraction inside the plugin:
   ```text
   lib/src/llama_host.dart          # web-safe factory
   lib/src/llama_host_io.dart       # dart:io + dart:ffi, picks by Platform.isWindows
   lib/src/llama_host_stub.dart     # web no-op
   lib/src/llama_host_pigeon.dart   # current LlamaHostApi
   lib/src/llama_host_ffi.dart      # Windows FFI implementation
   lib/src/llama_windows_ffi.dart   # FFI typedefs / DynamicLibrary.open
   ```
   - `llama_host.dart` uses a conditional export so web never sees `dart:ffi`.
   - `llama_host_io.dart` returns `LlamaHostPigeon()` on Android/iOS and `LlamaHostFfi()` on Windows.
2. Change `LlamaController` to use `createLlamaHost()` instead of `LlamaHostApi()`. Keep `LlamaFlutterApi` registration for Android/iOS; the FFI host invokes `onToken` / `onDone` / `onError` / `onLoadProgress` directly.
3. Implement `LlamaHostFfi`:
   - `loadModel`: convert `ModelConfig` to the C ABI; bridge progress with `NativeCallable`.
   - `generate`: build a prompt, call `plm_generate`, stream tokens through a `NativeCallable`, complete on done/error.
   - **Implementation note:** the blocking calls run in short-lived worker isolates with
     `NativeCallable.isolateLocal`, not `NativeCallable.listener` on the UI isolate. Tokens are
     copied to Dart inside the native callback (the `char*` is only valid during the call) and
     forwarded over a `SendPort`. `stop()` still calls `plm_stop` directly from the UI isolate.
     Late tokens/done from a stopped run are suppressed, matching Android's `isStopping` behavior.
   - `generateChat`: format the messages in Dart and call `generate`. **Do not port `ChatTemplates.kt` to C++.**
     The Dart port lives in `lib/src/chat_templates.dart` (bug-for-bug, including the literal
     `"\n"` sequences in the Alpaca/Vicuna/Phi templates).
   - `stop`, `dispose`, `isModelLoaded`, `getContextInfo`, `clearContext`, `setSystemPromptLength`, `registerCustomTemplate`, `unregisterCustomTemplate`, `detectGpu`.
4. Extract the prompt builders from `lib/services/inference_android.dart` (`_buildPrompt`, `_buildChatML`, `_buildGemma`, `_buildLlama3`, and the message conversion) into a shared `lib/services/chat_prompt_builder.dart`. Both the Android engine and the Windows host use it, so templates do not drift.
5. Update `lib/services/inference_android.dart`:
   - `supportsLocalInference => Platform.isAndroid || Platform.isIOS || Platform.isWindows`
   - `isRunning32Bit` stays Android-only.
   - Reject `.litertlm` on Windows with a clear message.
   - Reject `.safetensors` on Windows with a clear message.
   - Guard LiteRT branches with `Platform.isWindows`.
6. `lib/services/inference_service.dart`:
   - Replace `modelPath.split('/').last` with `p.basename(modelPath)`.
   - Keep the existing conditional import (`inference_android.dart` for IO, `inference_stub.dart` for web).
7. Vision (Phase 2b, done):
   - `plm_generate` takes an extra `const char* image_path`; the core already had the mtmd
     load/generate path, so this is the only ABI change.
   - `plm_load_model` returns `PLM_ERROR_VISION_FAILED` (with `plm_last_error`) when `mmproj` is
     set but unusable; text still works. This matches the existing contract in
     `LlamaController.loadModel`.

**Verify:**
- Windows chat streams tokens with a small GGUF.
- Stop button halts generation.
- Context-info and GPU detection return sensible values.
- Android regression: same prompt produces the same output as before the refactor.

---

## 6. Phase 3 — Cluster transport abstraction

**Deliverable:** `ClusterService` works on Windows without importing platform channels.

1. Add an app-level backend:
   ```text
   lib/services/cluster_backend.dart       # conditional export
   lib/services/cluster_backend_io.dart    # dart:io, runtime dispatch
   lib/services/cluster_backend_stub.dart  # web no-op
   lib/services/cluster_windows_backend.dart
   ```
   Interface (mirror `LlamaCluster`):
   ```dart
   abstract class ClusterBackend {
     static const int defaultPort = 50052;
     Future<void> startWorker({int port, int? threads});
     Future<void> stopWorker();
     Future<ClusterWorkerStatus> workerStatus();
     Future<void> setKeepScreenOn(bool on);
     Future<void> requestBatteryUnrestricted();
     Future<int> localFreeRamMb();
     Future<double> benchmark();
     Future<List<({String name, double mb})>> lastLoadBuffers();
     Future<List<ClusterWorker>> discover({Duration? timeout});
     Future<bool> probe(String endpoint);
     Future<void> setCluster(List<ClusterWorker> workers,
         {List<double>? weights, double localWeight});
     Future<void> clear();
   }
   ```
2. `cluster_backend_io.dart` returns `LlamaClusterBackend` (wraps `LlamaCluster`) on Android/iOS and `WindowsClusterBackend` on Windows.
3. Update `lib/services/cluster_service.dart`:
   - Replace `LlamaCluster.*` with `ClusterBackend.instance.*`.
   - `isSupported => !kIsWeb && (Android || iOS || Windows)`.
   - `canBeMaster => !kIsWeb && (Android || Windows)`.
   - `workerStopsWithApp => !kIsWeb && Platform.isIOS` (unchanged).
   - Device name: `Platform.localHostname` on Windows, `WindowsDeviceInfo.computerName` if available.
   - `refreshWifiAddress`: on Windows, prefer the interface whose name contains `Wi-Fi`; otherwise the first non-loopback IPv4 that is not `vEthernet`, `Hyper-V`, `WSL`, `VirtualBox`, `VMware`, or `Loopback`. Add a settings key `cluster_interface` so a multi-NIC PC can pick one explicitly.
   - Replace `modelPath.split('/').last` with `p.basename`.
4. Update `lib/views/cluster_view.dart`:
   - Copy: "device" instead of "phone" where it reads badly on desktop.
   - On Windows, hide the camera QR scanner (`mobile_scanner` has no Windows implementation) and show a "Paste worker link" field. `addFromQr` already parses `privatelm://worker?...`.
   - Add a network-interface dropdown when more than one candidate exists.
5. `main.dart`: skip `SystemChrome.setPreferredOrientations` on Windows.

**Verify:** `flutter analyze`; Windows shows Master/Worker; role switching persists in Hive; `wifiAddress` is the LAN IPv4.

---

## 7. Phase 4 — Windows worker process

**Deliverable:** Android/iOS master can use a Windows PC as a worker.

1. Add a new CMake target:
   ```text
   local_plugins/llama_flutter_android/windows/rpc_worker/
     main.cpp
     status_writer.cpp
     mdns_advertiser.cpp   # optional; manual IP works without it
   ```
   Arguments:
   ```text
   --host 0.0.0.0 --port 50052 --threads N
   --cache-dir <temp> --status-file <temp>/worker.json --id <stable-id>
   ```
2. `main.cpp`:
   - load the CPU backend
   - call `ggml_backend_rpc_start_server(endpoint, cache_dir, n_threads, n_devices, devices)`
   - write status JSON every second: `state`, `peer`, `heldMb`, `ramMb`, `bandwidth`, `throttled=false`, `batteryUnrestricted=true`, `id`
   - exit cleanly on Ctrl+C / parent death (Windows Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`)
3. `WindowsClusterBackend.startWorker`:
   - resolve `privatelm_rpc_worker.exe` next to the app
   - `Process.start(exe, args, mode: ProcessStartMode.detached)`
   - wait for the status file to report `running` (timeout ~10 s)
   - keep the `Process` handle if available; `stopWorker` kills the tree and deletes the status file
4. `workerStatus()` reads and parses the status JSON. Map it to `ClusterWorkerStatus`.
5. `setKeepScreenOn` uses `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)`; `requestBatteryUnrestricted` is a no-op.
6. `id`: a UUID generated once and stored in Hive (`cluster_worker_id`) so the worker can be relocated when its IP changes.
7. Firewall:
   - On first worker start, detect the active network profile. If it is Public, show a warning and instructions.
   - Provide a "Allow through Windows Firewall" action that runs an elevated helper (or `netsh advfirewall firewall add rule name="PrivateLM Cluster" dir=in action=allow protocol=TCP localport=50052` plus UDP 5353 for mDNS).
   - Never silently fail: if the port cannot be bound, surface the OS error in `ClusterWorkerStatus.error`.
8. mDNS advertising (Phase 4b):
   - Preferred: Windows DNS-SD (`DnsServiceRegister`) with type `_privatelm._tcp`, TXT `ram`, `bw`, `model`, `v=rpc7`, `id`.
   - If Android NSD does not see it on the target network, fall back to a minimal mDNS responder in the worker exe (join 224.0.0.251:5353, answer PTR/SRV/TXT/A, send unsolicited announcements).
   - Manual IP + QR remains the guaranteed path.

**Verify:**
- Android master → "Add by IP" with the Windows LAN IP → load a model → tokens stream.
- Windows worker status shows `peer` = Android master IP.
- Stop worker from Windows; Android load fails with the existing readable "worker unreachable" error, not a crash.

---

## 8. Phase 5 — Windows master with phone workers

**Deliverable:** Windows can spread a model across Android/iOS workers.

1. `WindowsClusterBackend.setCluster` calls `plm_set_cluster(...)`; the next `plm_load_model` uses the stored plan.
2. Ensure the plan matches Android exactly:
   - register each endpoint once
   - `n_gpu_layers = n_layer + 1 - local_layers`
   - `tensor_split` by weight
   - output layer offloaded with the last offloaded layer
   - `ctx_params.op_offload = false` while clustering
3. `probe` uses `Socket.connect(host, port, timeout: 2s)`; call it before `setCluster` because `ggml_backend_rpc_add_server` can abort on an unreachable worker.
4. `discover` uses `multicast_dns` to browse `_privatelm._tcp.local`, parses PTR → SRV → TXT, and returns `ClusterWorker` entries. Filter out entries whose `v != rpc7` and show a "protocol mismatch" toast.
5. `relocateWorkers` works by `id` (already in `ClusterService`).
6. `localFreeRamMb` and `benchmark` use the native helpers.
7. `lastLoadBuffers` parses the native buffer log and feeds `ClusterService.split`, so the split bar shows Windows + phone shares.

**Verify:**
- Windows master + Android worker: a model that does not fit on Windows alone loads and streams.
- Windows master + iOS worker: same (iOS worker path already exists).
- Windows + Windows: two PCs cluster.
- Mixed 3 devices: Windows master + Android + iOS workers.
- Worker IP change: `relocateWorkers` finds it by `id`.

---

## 9. Phase 6 — Platform guards, paths, and UI

**Deliverable:** Windows build compiles and no unsupported feature crashes at runtime.

1. **Paths** — replace every `split('/')` used for filenames:
   - `lib/services/download_native.dart:34`
   - `lib/services/inference_service.dart` (`loadingModelName`, `requestedModelName`)
   - `lib/services/cluster_service.dart` (`applyForNextLoad`)
   - `lib/services/local_image_service.dart` and `local_image_service_native.dart`
   - use `p.basename`, `p.join`; add `path` to `pubspec.yaml`.
2. **Model directory** — `getModelsDir()` uses `p.join(dir.path, 'models')`; model import works with Windows drive letters and spaces.
3. **Local image generation** — `LocalImageService.loadModel` returns a clear "Local image generation is not available on Windows" before constructing `SdIsolateProcessor`. `chat_controller.dart` should not offer image generation for `.safetensors` on Windows.
4. **Model lists** — hide `.litertlm` and `.safetensors` on Windows (or show them disabled with a reason). Keep `.gguf` only.
5. **Updates** — `UpdateService.isSupported` stays Android-only. On Windows, show a "Releases" link instead of an in-app APK update.
6. **Crash reporting** — `crash_reporting_service.dart` uses `AndroidDeviceInfo`; add a Windows branch (or disable Crashlytics on Windows if Firebase is not configured). Do not let a missing `google-services.json` break the Windows build.
7. **Plugin audit** — run `flutter build windows --debug` and fix every compile failure. Guard runtime-unsupported features:
   - `mobile_scanner` (no Windows) → manual/paste add
   - `speech_to_text` → hide mic button
   - `gal`, `share_plus`, `image_picker` → hide or use `file_picker`
   - `permission_handler` → no-op on Windows
   - `flutter_local_notifications` → no-op or Windows toast later
   - `firebase_messaging` → Android-only
   - `flutter_inappwebview` → check webviews on Windows
8. **Layout** — verify the chat/model/cluster screens at 900×600 and 1440×900; add scroll behavior and mouse hover where needed.
9. **OpenAI server** — `openai_server_service_io.dart` is pure `dart:io`; verify it binds and serves on Windows (useful for LAN clients).

**Verify:** `flutter analyze`, `flutter build windows --release`, manual smoke test of every screen.

---

## 10. Phase 7 — Tests, packaging, docs

**Deliverable:** reproducible build and a regression baseline.

1. **Unit tests (pure Dart):**
   - Extract `_fillFastestFirst`, `_splitBySpeed`, `_gb` from `ClusterService` into `lib/services/cluster_planner.dart`; add `test/cluster_planner_test.dart`.
   - Add `test/path_helpers_test.dart` for model-name extraction.
   - Add `test/cluster_backend_test.dart` with a fake backend to cover role switching and `applyForNextLoad`.
   - Add `local_plugins/llama_flutter_android/test/llama_controller_test.dart` with a fake `LlamaHost` to cover streaming, stop, and error paths.
2. **Manual integration matrix** (see §11).
3. **Packaging:**
   - Portable zip: `privatelm.exe`, `flutter_windows.dll`, `llama_flutter_android.dll`, `privatelm_rpc_worker.exe`, `ggml-*.dll` (if dynamic), `data/`.
   - Optional MSIX later.
   - `scripts/build_windows.ps1` produces the zip with a version from `pubspec.yaml`.
4. **Docs:**
   - `docs/windows-build.md`: prerequisites, build, run.
   - `docs/windows-cluster.md`: firewall, private network profile, manual IP, QR, trusted-LAN warning, troubleshooting.
5. **Release:**
   - Add the Windows zip to the GitHub release alongside the APKs. Do not change the Android version code or signing key.

---

## 11. Verification matrix

| #  | Scenario                                    | Expected                                                                |
|----|---------------------------------------------|-------------------------------------------------------------------------|
| 1  | Windows standalone, GGUF, CPU               | Model loads, tokens stream, stop works                                  |
| 2  | Windows standalone, GGUF, Vulkan (if built) | GPU detected, load succeeds or falls back to CPU                        |
| 3  | Windows master + Android worker             | Split bar shows both; tokens stream; worker shows master peer           |
| 4  | Windows master + iOS worker                 | Same as #3                                                              |
| 5  | Android master + Windows worker             | Android adds Windows by IP/QR; tokens stream; Windows status shows peer |
| 6  | Windows master + Windows worker             | Same as #3                                                              |
| 7  | Windows master + Android + iOS workers      | 3-way split; model fits                                                 |
| 8  | Model too big for all devices               | Planning error names the shortfall; no crash                            |
| 9  | Worker unreachable at load                  | Readable error; master process survives                                 |
| 10 | Worker IP changes                           | `relocateWorkers` finds it by `id`                                      |
| 11 | Worker stopped/restarted                    | Master reloads without stale RPC state                                  |
| 12 | Firewall blocks 50052                       | Clear OS error / instructions, not a hang                               |
| 13 | Public network profile                      | Warning + instructions                                                  |
| 14 | Multiple NICs (Wi-Fi + Ethernet + Hyper-V)  | User can pick the LAN interface                                         |
| 15 | `.litertlm` on Windows                      | Clear "not supported on Windows" message                                |
| 16 | `.safetensors` on Windows                   | Clear "not supported on Windows" message                                |
| 17 | Windows paths with spaces / non-ASCII       | Download, import, load all work                                         |
| 18 | Android/iOS regression                      | Existing cluster + inference behavior unchanged                         |

---

## 12. Risks and mitigations

| Risk                                                       | Impact                     | Mitigation                                                                                                                                       |
|------------------------------------------------------------|----------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------|
| RPC protocol mismatch                                      | Workers connect but fail   | Build Windows from the same `llama.cpp` commit; advertise/check `v=rpc7`; show a mismatch error                                                  |
| Windows firewall / Public profile                          | Master cannot reach worker | First-run guidance, elevated rule helper, manual IP, docs                                                                                        |
| mDNS blocked by router                                     | Auto-discovery fails       | Manual IP + QR are guaranteed; UDP beacon as a later enhancement                                                                                 |
| `ggml_backend_rpc_add_server` aborts on unreachable worker | App process dies           | Always `probe` first; keep the existing "unreachable" error path; consider running master load in a child process only if this proves unreliable |
| Unsupported Flutter plugins on Windows                     | Build or runtime failure   | Phase 6 audit; runtime guards; conditional imports                                                                                               |
| `flutter_litert_lm` / `sd_flutter_android` compile issues  | Windows build breaks       | They declare no Windows platform, so Flutter skips their native builds; guard Dart entry points and verify `flutter build windows`               |
| Unsigned exe / SmartScreen                                 | Users cannot run           | Document "More info → Run anyway"; code signing later                                                                                            |
| Windows Defender flags the worker exe                      | Worker fails to start      | Sign binaries; document exclusions; keep the worker small and transparent                                                                        |
| RAM detection differences                                  | Bad cluster plan           | Use `GlobalMemoryStatusEx`; cap local share at 70% like Android; show the planned split before load                                              |
| Vulkan driver issues                                       | Crash on load              | CPU first; make Vulkan opt-in; keep the existing CPU fallback                                                                                    |
| Long paths / spaces                                        | File operations fail       | `p.join`, quote process args, avoid manual string concatenation                                                                                  |

---

## 13. File-level change map

### App

| File                                        | Change                                                                                                 |
|---------------------------------------------|--------------------------------------------------------------------------------------------------------|
| `windows/`                                  | New runner (generated), window sizing, resources                                                       |
| `pubspec.yaml`                              | Add `path`, `multicast_dns`; Windows platform for the plugin                                           |
| `lib/main.dart`                             | Skip orientation lock on Windows                                                                       |
| `lib/services/cluster_service.dart`         | Use `ClusterBackend`; Windows in `isSupported`/`canBeMaster`; device name; Wi-Fi address; `p.basename` |
| `lib/services/cluster_backend.dart`         | New conditional export                                                                                 |
| `lib/services/cluster_backend_io.dart`      | New runtime dispatch                                                                                   |
| `lib/services/cluster_backend_stub.dart`    | New web no-op                                                                                          |
| `lib/services/cluster_windows_backend.dart` | New FFI + process + mDNS backend                                                                       |
| `lib/services/cluster_planner.dart`         | New extracted pure planning logic                                                                      |
| `lib/services/inference_android.dart`       | Windows support; LiteRT/SD guards; shared prompt builder                                               |
| `lib/services/chat_prompt_builder.dart`     | New shared prompt/template builders                                                                    |
| `lib/services/inference_service.dart`       | `p.basename`; keep platform selection                                                                  |
| `lib/services/device_info_native.dart`      | Windows RAM/SoC/GPU branch                                                                             |
| `lib/services/download_native.dart`         | `p.basename` / `p.join`                                                                                |
| `lib/services/local_image_service.dart`     | Windows guard with clear message                                                                       |
| `lib/services/update_service.dart`          | Keep Android-only; Windows link                                                                        |
| `lib/services/crash_reporting_service.dart` | Windows branch / safe disable                                                                          |
| `lib/views/cluster_view.dart`               | Desktop copy; hide scanner; paste-link; interface picker                                               |
| `lib/views/model_view.dart`                 | Hide unsupported model types on Windows                                                                |
| `lib/controllers/model_controller.dart`     | Windows path handling; model-type filtering                                                            |
| `lib/controllers/chat_controller.dart`      | Guard image generation on Windows                                                                      |
| `lib/core/constants.dart`                   | `cluster_interface`, `cluster_worker_id` keys                                                          |
| `docs/windows-build.md`                     | New                                                                                                    |
| `docs/windows-cluster.md`                   | New                                                                                                    |
| `scripts/build_windows.ps1`                 | New                                                                                                    |

### Plugin `llama_flutter_android`

| File                                              | Change                                    |
|---------------------------------------------------|-------------------------------------------|
| `pubspec.yaml`                                    | Add `windows: ffiPlugin: true`            |
| `lib/src/llama_host.dart`                         | New web-safe factory                      |
| `lib/src/llama_host_io.dart`                      | New platform dispatch                     |
| `lib/src/llama_host_stub.dart`                    | New web no-op                             |
| `lib/src/llama_host_pigeon.dart`                  | New wrapper around `LlamaHostApi`         |
| `lib/src/llama_host_ffi.dart`                     | New Windows FFI host                      |
| `lib/src/llama_windows_ffi.dart`                  | New FFI bindings                          |
| `lib/src/llama_controller.dart`                   | Use `LlamaHost` instead of `LlamaHostApi` |
| `lib/llama_flutter_android.dart`                  | Export new host types if needed           |
| `android/src/main/cpp/jni_wrapper.cpp`            | Thin JNI adapter over the core            |
| `android/src/main/cpp/llama_engine_core.{h,cpp}`  | New shared core                           |
| `android/src/main/cpp/llama_cluster_plan.{h,cpp}` | New shared cluster plan                   |
| `android/CMakeLists.txt`                          | Add core sources                          |
| `windows/CMakeLists.txt`                          | New DLL + worker targets                  |
| `windows/llama_ffi.{h,cpp}`                       | New C ABI adapter                         |
| `windows/rpc_worker/main.cpp`                     | New worker process                        |
| `windows/rpc_worker/status_writer.cpp`            | New status JSON                           |
| `windows/rpc_worker/mdns_advertiser.cpp`          | New (Phase 4b)                            |
| `README.md`                                       | Windows section                           |

### Tests

| File                                                                  | Change                                                     |
|-----------------------------------------------------------------------|------------------------------------------------------------|
| `test/cluster_planner_test.dart`                                      | New                                                        |
| `test/path_helpers_test.dart`                                         | New                                                        |
| `test/cluster_backend_test.dart`                                      | New                                                        |
| `test/windows_engine_smoke_test.dart`                                 | New, skipped unless Windows + `PRIVATELM_TEST_GGUF` is set |
| `local_plugins/llama_flutter_android/test/llama_controller_test.dart` | New                                                        |

---

## 14. Milestones and estimate

| Milestone                | Phases | Outcome                                     | Estimate |
|--------------------------|--------|---------------------------------------------|----------|
| M1: Windows shell        | 0      | App launches on Windows                     | 1–2 days |
| M2: Standalone inference | 1–2    | GGUF chat works on Windows                  | 5–8 days |
| M3: Cluster plumbing     | 3      | Master/Worker UI works on Windows           | 2 days   |
| M4: Windows worker       | 4      | Android/iOS master can use a Windows worker | 3–5 days |
| M5: Windows master       | 5      | Windows can use phone workers               | 2–3 days |
| M6: Polish               | 6      | No unsupported-feature crashes; paths fixed | 2–4 days |
| M7: Release              | 7      | Tests, zip, docs                            | 2–3 days |

Total: roughly **17–27 developer-days** (4–5 weeks for one developer). Standalone Windows inference is usable after M2; full two-way clustering after M5.

---

## 15. Recommended first PR sequence

1. **PR 1:** Windows runner + `pubspec` platform entry + empty DLL target. No behavior change on Android/iOS.
2. **PR 2:** Extract the native core and make `jni_wrapper.cpp` a thin adapter. Android regression test.
3. **PR 3:** `LlamaHost` abstraction + `LlamaHostPigeon` wrapper (no Windows FFI yet). Android/iOS regression.
4. **PR 4:** Windows FFI host + standalone inference.
5. **PR 5:** `ClusterBackend` abstraction + `WindowsClusterBackend` (manual IP, worker process).
6. **PR 6:** Windows master (setCluster, probe, split bar).
7. **PR 7:** mDNS, firewall helper, UI polish, docs, packaging.

Each PR should keep `flutter analyze` and `flutter test` green, and PRs 2–4 must include a manual Android regression check.

---

## 16. Explicit deferrals

- LiteRT-LM (`.litertlm`) on Windows.
- Local Stable Diffusion (`.safetensors`) on Windows.
- Windows ARM64.
- In-app auto-update on Windows (link to GitHub releases instead).
- iOS as master.
- Code signing / MSIX installer.
- UDP beacon discovery fallback (add only if mDNS proves unreliable).
- GPU (Vulkan) inference on Windows: CPU first, then opt-in Vulkan.

---

## 17. Trusted-LAN warning (keep in UI and docs)

The ggml RPC protocol has **no authentication**. A worker exposes its CPU and memory to anyone who can reach port 50052. Only run cluster mode on a trusted private LAN. Do not port-forward 50052. The existing Android/iOS UI already says this; Windows must say it too.

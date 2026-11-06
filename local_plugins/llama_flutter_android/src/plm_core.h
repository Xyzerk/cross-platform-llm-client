// Platform-neutral core extracted from jni_wrapper.cpp.
//
// Holds the process-global engine state and the cluster planning / memory
// bandwidth helpers that both Android (JNI) and Windows (FFI) need. Keeping
// these in one place avoids a third hand-synced copy (Android, iOS, Windows).
//
// The JNI entry points in jni_wrapper.cpp (and the Windows C ABI in
// windows/llama_ffi.cpp) are thin marshalling shims that delegate here.
// Symbol names/signatures on the JNI side are unchanged.
#pragma once

#include <string>
#include <vector>
#include <mutex>
#include <atomic>

#include "llama.h"
#include "ggml-backend.h"
#include "gguf.h"

// ---------------------------------------------------------------------------
// Process-global state (one engine per process). Defined in plm_core.cpp.
// ---------------------------------------------------------------------------

extern std::mutex g_backend_mutex;
extern std::string g_lib_dir;
extern bool g_cpu_backend_loaded;
extern bool g_gpu_backend_loaded;
extern bool g_rpc_backend_loaded;

extern std::vector<std::string> g_cluster_endpoints;
extern std::vector<float> g_cluster_weights;
extern float g_cluster_local_weight;
extern std::vector<std::string> g_registered_endpoints;

extern std::mutex g_load_log_mutex;
extern std::string g_load_buffers;
extern std::string g_worker_peer;
extern std::string g_load_error;
extern bool g_capture_load_error;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

struct ClusterPlan {
    std::vector<ggml_backend_dev_t> devices;  // null-terminated
    std::vector<float> split;                 // llama_max_devices() entries
    int n_gpu_layers = 0;
    llama_model_tensor_buft_override overrides[2] = {};
};

// ---------------------------------------------------------------------------
// Core API
// ---------------------------------------------------------------------------

namespace plm {

/// The model's transformer block count from its GGUF header, or -1.
int readBlockCount(const char* model_path);

/// Connects to every configured worker and decides which layers go where.
/// Returns an error message, or empty on success.
std::string planCluster(const char* model_path, ClusterPlan& plan);

/// Memory read speed in GB/s with `threads` threads.
double memBandwidth(int threads);

/// RPC backend registry, loading it on first use (caller holds g_backend_mutex).
ggml_backend_reg_t loadRpcBackendLocked();

/// Cluster configuration setters/getters used by the marshalling shims.
void setCluster(const std::vector<std::string>& endpoints,
                const std::vector<float>& weights,
                float local_weight);
std::string lastLoadBuffers();
std::string workerPeer();

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------
//
// llama.cpp logs through one hook installed here. The hook reproduces what the
// Android code used to do in androidLlamaLog: skip DEBUG noise, scrape the
// load-buffer lines ("load_tensors: <name> model buffer size = <MiB> MiB"),
// track the connected cluster worker ("RPC client connected: <peer>") and,
// while a load is in flight, capture the error text. Non-debug lines are then
// forwarded to the platform sink (logcat on Android, stderr on Windows).

/// Platform log sink. Receives the *effective* level (CONT lines arrive as the
/// level they continue). Compiled with llama.cpp LOG_TAG semantics in mind.
using LogSink = void (*)(ggml_log_level effective_level, const char* text);

void setLogSink(LogSink sink);

/// Platform hook that must ensure a CPU backend is registered before a model
/// load. On Android this loads the fastest CPU variant .so; Windows builds the
/// CPU backend statically and leaves the hook unset (a no-op).
using EnsureCpuBackend = void (*)();
void setEnsureCpuBackendHook(EnsureCpuBackend hook);
void ensureCpuBackend();

/// (Re)sets llama.cpp's log callback to the shared hook.
void installLogHandler();

/// The shared hook itself, for libraries that install their own logger
/// (mtmd_helper_log_set) but must keep the same capture behaviour.
ggml_log_callback logHook();

/// Internal logging with the same sink, for engine status messages that used
/// to go straight to logcat (LOGI/LOGE).
void logf(ggml_log_level level, const char* fmt, ...);

/// Starts error capture for the next load (clears buffers + error).
void beginLoadCapture();
/// Ends capture and returns the captured error text (trimmed), or empty.
std::string consumeLoadError();

/// First local GPU device registered by a loaded backend, or nullptr.
/// Cluster workers show up as GPU devices named "RPC<n>"; they never count.
ggml_backend_dev_t firstLocalGpuDevice();

} // namespace plm

// Platform-neutral core: process-global state + cluster planning + bandwidth
// + shared llama.cpp log plumbing. The generation engine lives in plm_engine.
#include "plm_core.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

// ---------------------------------------------------------------------------
// Process-global state definitions
// ---------------------------------------------------------------------------
std::mutex g_backend_mutex;
std::string g_lib_dir;
bool g_cpu_backend_loaded = false;
bool g_gpu_backend_loaded = false;
bool g_rpc_backend_loaded = false;

std::vector<std::string> g_cluster_endpoints;
std::vector<float> g_cluster_weights;
float g_cluster_local_weight = 0.0f;
std::vector<std::string> g_registered_endpoints;

std::mutex g_load_log_mutex;
std::string g_load_buffers;
std::string g_worker_peer;
std::string g_load_error;
bool g_capture_load_error = false;

namespace plm {

int readBlockCount(const char* model_path) {
    gguf_init_params params = {/* .no_alloc = */ true, /* .ctx = */ nullptr};
    gguf_context* gguf = gguf_init_from_file(model_path, params);
    if (!gguf) return -1;
    int count = -1;
    const int64_t arch_id = gguf_find_key(gguf, "general.architecture");
    if (arch_id >= 0) {
        const std::string key = std::string(gguf_get_val_str(gguf, arch_id)) + ".block_count";
        const int64_t id = gguf_find_key(gguf, key.c_str());
        if (id >= 0) {
            switch (gguf_get_kv_type(gguf, id)) {
                case GGUF_TYPE_UINT32: count = (int)gguf_get_val_u32(gguf, id); break;
                case GGUF_TYPE_INT32:  count = gguf_get_val_i32(gguf, id); break;
                default: break;
            }
        }
    }
    gguf_free(gguf);
    return count;
}

ggml_backend_reg_t loadRpcBackendLocked() {
    if (!g_rpc_backend_loaded) {
        const std::string path = g_lib_dir + "/libggml-rpc.so";
        if (!ggml_backend_load(path.c_str())) {
            return nullptr;
        }
        g_rpc_backend_loaded = true;
    }
    return ggml_backend_reg_by_name("RPC");
}

std::string planCluster(const char* model_path, ClusterPlan& plan) {
    std::vector<std::string> endpoints;
    std::vector<float> weights;
    float local_weight;
    ggml_backend_reg_t rpc;
    {
        std::lock_guard<std::mutex> lock(g_backend_mutex);
        endpoints = g_cluster_endpoints;
        weights = g_cluster_weights;
        local_weight = g_cluster_local_weight;
        rpc = loadRpcBackendLocked();
    }
    if (!rpc) return "This build has no cluster (RPC) support";
    using add_server_fn = ggml_backend_reg_t (*)(const char*);
    auto add_server = reinterpret_cast<add_server_fn>(
        ggml_backend_reg_get_proc_address(rpc, "ggml_backend_rpc_add_server"));
    if (!add_server) return "RPC backend is missing ggml_backend_rpc_add_server";

    const int n_layer = readBlockCount(model_path);
    if (n_layer <= 0) return "Could not read the model's layer count";

    float remote_weight = 0.0f;
    std::vector<float> device_weights;
    for (size_t i = 0; i < endpoints.size(); i++) {
        ggml_backend_reg_t reg = add_server(endpoints[i].c_str());
        if (!reg) return "Worker " + endpoints[i] + " reported no devices";
        if (std::find(g_registered_endpoints.begin(), g_registered_endpoints.end(),
                      endpoints[i]) == g_registered_endpoints.end()) {
            ggml_backend_register(reg);
            g_registered_endpoints.push_back(endpoints[i]);
        }
        const size_t n_dev = ggml_backend_reg_dev_count(reg);
        for (size_t d = 0; d < n_dev; d++) {
            plan.devices.push_back(ggml_backend_reg_dev_get(reg, d));
            device_weights.push_back(std::max(weights[i], 0.01f) / n_dev);
        }
        remote_weight += std::max(weights[i], 0.01f);
    }
    if (plan.devices.empty()) return "No cluster workers";
    plan.devices.push_back(nullptr);

    plan.split.assign(llama_max_devices(), 0.0f);
    for (size_t d = 0; d < device_weights.size() && d < plan.split.size(); d++) {
        plan.split[d] = device_weights[d];
    }

    const float total = std::max(local_weight, 0.0f) + remote_weight;
    int local = (int)std::lround(n_layer * std::max(local_weight, 0.0f) / total);
    local = std::clamp(local, 0, n_layer);
    plan.n_gpu_layers = n_layer + 1 - local;

    ggml_backend_dev_t cpu = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
    if (cpu) {
        plan.overrides[0] = {"^(output|token_embd)\\.weight$", ggml_backend_dev_buffer_type(cpu)};
        plan.overrides[1] = {nullptr, nullptr};
    }
    return {};
}

double memBandwidth(int threads) {
    const int n = std::max(1, threads);
    const size_t per_thread = (64u << 20) / sizeof(uint64_t) / n;  // 64 MB total
    std::vector<uint64_t> data(per_thread * n, 1);
    std::vector<uint64_t> sums(n, 0);
    const int passes = 4;
    auto run = [&](int t) {
        const uint64_t* p = data.data() + per_thread * t;
        uint64_t a = 0, b = 0, c = 0, d = 0;
        for (int pass = 0; pass < passes; pass++) {
            for (size_t i = 0; i + 4 <= per_thread; i += 4) {
                a += p[i]; b += p[i + 1]; c += p[i + 2]; d += p[i + 3];
            }
        }
        sums[t] = a + b + c + d;
    };
    run(0);  // warm up: page in the buffer
    const auto start = std::chrono::steady_clock::now();
    std::vector<std::thread> pool;
    for (int t = 0; t < n; t++) pool.emplace_back(run, t);
    for (auto& th : pool) th.join();
    const double secs = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - start).count();
    const double bytes = (double)data.size() * sizeof(uint64_t) * passes;
    return secs > 0 ? bytes / secs / 1e9 : 0.0;
}

void setCluster(const std::vector<std::string>& endpoints,
                const std::vector<float>& weights,
                float local_weight) {
    std::lock_guard<std::mutex> lock(g_backend_mutex);
    g_cluster_endpoints = endpoints;
    g_cluster_weights = weights;
    g_cluster_local_weight = local_weight;
}

std::string lastLoadBuffers() {
    std::lock_guard<std::mutex> lock(g_load_log_mutex);
    return g_load_buffers;
}

std::string workerPeer() {
    std::lock_guard<std::mutex> lock(g_load_log_mutex);
    return g_worker_peer;
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

static LogSink g_log_sink = nullptr;
static EnsureCpuBackend g_ensure_cpu_backend = nullptr;

// CONT lines continue the previous message; keep its level for them.
static ggml_log_level g_last_log_level = GGML_LOG_LEVEL_INFO;

void setLogSink(LogSink sink) { g_log_sink = sink; }

void setEnsureCpuBackendHook(EnsureCpuBackend hook) { g_ensure_cpu_backend = hook; }

void ensureCpuBackend() {
    if (g_ensure_cpu_backend) g_ensure_cpu_backend();
}

/// Cluster workers show up as GPU devices named "RPC<n>"; they must never be
/// mistaken for this device's own GPU.
static bool isRpcDevice(ggml_backend_dev_t dev) {
    const char* name = ggml_backend_dev_name(dev);
    return name && std::strncmp(name, "RPC", 3) == 0;
}

ggml_backend_dev_t firstLocalGpuDevice() {
    for (size_t i = 0; i < ggml_backend_dev_count(); i++) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        const auto type = ggml_backend_dev_type(dev);
        if ((type == GGML_BACKEND_DEVICE_TYPE_GPU ||
             type == GGML_BACKEND_DEVICE_TYPE_IGPU) && !isRpcDevice(dev)) {
            return dev;
        }
    }
    return nullptr;
}

static void llamaLogHook(ggml_log_level level, const char* text, void*) {
    if (!text) return;
    // Newer llama.cpp logs thousands of DEBUG lines per model load (graph
    // dumps); forwarding them to the platform log slows loading for no benefit.
    const ggml_log_level effective =
        level == GGML_LOG_LEVEL_CONT ? g_last_log_level : level;
    if (level != GGML_LOG_LEVEL_CONT) g_last_log_level = level;
    if (effective == GGML_LOG_LEVEL_DEBUG) return;

    if (g_log_sink) g_log_sink(effective, text);

    std::lock_guard<std::mutex> lock(g_load_log_mutex);
    if (const char* at = std::strstr(text, " model buffer size = ")) {
        // "load_tensors: <name> model buffer size = <MiB> MiB"
        const char* colon = std::strchr(text, ':');
        const char* start = colon && colon < at ? colon + 1 : text;
        while (start < at && *start == ' ') start++;
        const double mib = std::strtod(at + std::strlen(" model buffer size = "), nullptr);
        g_load_buffers.append(start, at - start).append("\t")
            .append(std::to_string(mib)).append("\n");
    }
    static const char kConnected[] = "RPC client connected: ";
    if (std::strncmp(text, kConnected, sizeof(kConnected) - 1) == 0) {
        g_worker_peer.assign(text + sizeof(kConnected) - 1);
        while (!g_worker_peer.empty() && std::isspace((unsigned char)g_worker_peer.back())) {
            g_worker_peer.pop_back();
        }
    } else if (std::strncmp(text, "RPC client disconnected", 23) == 0) {
        g_worker_peer.clear();
    }
    if (!g_capture_load_error) return;
    if (level == GGML_LOG_LEVEL_ERROR) {
        g_load_error.assign(text);
    } else if (level == GGML_LOG_LEVEL_CONT && !g_load_error.empty()) {
        g_load_error.append(text);
    }
    if (g_load_error.size() > 4096) {
        g_load_error.erase(0, g_load_error.size() - 4096);
    }
}

void installLogHandler() {
    llama_log_set(llamaLogHook, nullptr);
}

ggml_log_callback logHook() {
    return llamaLogHook;
}

void logf(ggml_log_level level, const char* fmt, ...) {
    if (!g_log_sink) return;
    char buf[512];
    va_list args;
    va_start(args, fmt);
    std::vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    g_log_sink(level, buf);
}

void beginLoadCapture() {
    std::lock_guard<std::mutex> lock(g_load_log_mutex);
    g_load_error.clear();
    g_load_buffers.clear();
    g_capture_load_error = true;
}

std::string consumeLoadError() {
    std::lock_guard<std::mutex> lock(g_load_log_mutex);
    g_capture_load_error = false;
    while (!g_load_error.empty() &&
           (g_load_error.back() == '\n' || g_load_error.back() == '\r')) {
        g_load_error.pop_back();
    }
    return g_load_error;
}

} // namespace plm

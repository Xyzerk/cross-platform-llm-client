// Windows FFI adapter over the shared engine core (src/plm_engine.cpp,
// src/plm_core.cpp). Marshals the C ABI in llama_ffi.h to plm:: — the same
// code path the Android JNI layer uses.
#include "llama_ffi.h"

#include <windows.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "plm_core.h"
#include "plm_engine.h"

// ---------------------------------------------------------------------------
// Error tracking
// ---------------------------------------------------------------------------

static std::mutex g_error_mutex;
static std::string g_last_error;

static int fail(const std::string& message) {
    std::lock_guard<std::mutex> lock(g_error_mutex);
    g_last_error = message;
    return PLM_ERROR_FAILED;
}

static char* mallocString(const std::string& s) {
    char* out = static_cast<char*>(::malloc(s.size() + 1));
    if (out) {
        std::memcpy(out, s.c_str(), s.size() + 1);
    }
    return out;
}

static std::string jsonEscape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 2);
    for (const char c : s) {
        switch (c) {
            case '\\': out += "\\\\"; break;
            case '"': out += "\\\""; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default: out += c;
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Logging: llama.cpp messages go to stderr only when PLM_LLM_LOG is set,
// so a GUI run stays quiet. Capture behaviour (load buffers, RPC peer, load
// errors) is handled by plm_core's shared hook.
// ---------------------------------------------------------------------------

static void windowsLogSink(ggml_log_level level, const char* text) {
    if (!text) return;
    // stderr only when explicitly asked for, so a GUI run stays quiet.
    static const bool enabled = [] {
        char buf[8] = {};
        const DWORD size = GetEnvironmentVariableA("PLM_LLM_LOG", buf, sizeof(buf));
        return size > 0 && size < sizeof(buf) && buf[0] != '0';
    }();
    if (!enabled) return;
    ::fprintf(stderr, "[llama:%d] %s", (int)level, text);
    const size_t len = std::strlen(text);
    if (len == 0 || text[len - 1] != '\n') ::fputc('\n', stderr);
    ::fflush(stderr);
}

// Registers the Windows hooks at DLL load time; llama.cpp's static CPU (and
// RPC) backends self-register, so no platform backend loader is needed here.
namespace {
struct PlmWindowsHooks {
    PlmWindowsHooks() {
        plm::setLogSink(windowsLogSink);
    }
};
static PlmWindowsHooks g_plm_hooks_init;
} // namespace

// ---------------------------------------------------------------------------
// Model loading
// ---------------------------------------------------------------------------

static void progressRelay(plm_progress_cb cb, void* user, double progress) {
    if (cb) cb(user, progress);
}

int plm_load_model(const char* path, int threads, int ctx, int gpu_layers,
                   const char* mmproj, plm_progress_cb progress, void* user) {
    if (!path || !*path) {
        return fail("GGUF model path is missing");
    }
    plm::LoadProgress relay;
    if (progress) {
        relay = [progress, user](double value) { progressRelay(progress, user, value); };
    }
    const std::string error = plm::loadModel(path, threads, ctx, gpu_layers, relay);
    if (!error.empty()) {
        return fail(error);
    }

    if (mmproj && *mmproj) {
        const std::string vision_error = plm::loadMmproj(mmproj, threads);
        if (!vision_error.empty()) {
            std::lock_guard<std::mutex> lock(g_error_mutex);
            g_last_error = vision_error;
            return PLM_ERROR_VISION_FAILED;
        }
    }
    return PLM_OK;
}

// ---------------------------------------------------------------------------
// Generation
// ---------------------------------------------------------------------------

int plm_generate(const char* prompt, const char* image_path, int max_tokens,
                 double temperature,
                 double top_p, int top_k, double min_p,
                 double typical_p,
                 double repeat_penalty, double frequency_penalty,
                 double presence_penalty, int repeat_last_n,
                 int mirostat, double mirostat_tau,
                 double mirostat_eta, long long seed,
                 plm_token_cb token_cb, plm_done_cb done_cb, void* user) {
    if (!plm::isModelLoaded()) {
        if (done_cb) done_cb(user, "Model not loaded");
        std::lock_guard<std::mutex> lock(g_error_mutex);
        g_last_error = "Model not loaded";
        return PLM_ERROR_NOT_LOADED;
    }
    if (!prompt) {
        if (done_cb) done_cb(user, "Prompt is missing");
        std::lock_guard<std::mutex> lock(g_error_mutex);
        g_last_error = "Prompt is missing";
        return PLM_ERROR_FAILED;
    }

    plm::SamplingParams params;
    params.max_tokens = max_tokens;
    params.temperature = temperature;
    params.top_p = top_p;
    params.top_k = top_k;
    params.min_p = min_p;
    params.typical_p = typical_p;
    params.repeat_penalty = repeat_penalty;
    params.frequency_penalty = frequency_penalty;
    params.presence_penalty = presence_penalty;
    params.repeat_last_n = repeat_last_n;
    params.mirostat = mirostat;
    params.mirostat_tau = mirostat_tau;
    params.mirostat_eta = mirostat_eta;
    params.seed = seed;

    plm::TokenSink token;
    if (token_cb) {
        token = [token_cb, user](const std::string& piece) {
            token_cb(user, piece.c_str());
        };
    }

    const std::string error =
        plm::generate(prompt, image_path ? image_path : "", params, token);
    if (done_cb) done_cb(user, error.empty() ? nullptr : error.c_str());
    if (!error.empty()) {
        return fail(error);
    }
    return PLM_OK;
}

void plm_stop(void) {
    plm::stopGeneration();
}

// ---------------------------------------------------------------------------
// State queries / lifecycle
// ---------------------------------------------------------------------------

void plm_unload(void) {
    plm::unloadModel();
}

int plm_is_model_loaded(void) {
    return plm::isModelLoaded() ? 1 : 0;
}

char* plm_context_info_json(void) {
    char buf[192];
    std::snprintf(buf, sizeof(buf),
                  "{\"modelLoaded\":%s,\"tokensUsed\":%d,\"contextSize\":%d}",
                  plm::isModelLoaded() ? "true" : "false",
                  plm::tokensUsed(), plm::contextSize());
    return mallocString(buf);
}

int plm_clear_context(void) {
    return plm::clearContext() ? 1 : 0;
}

char* plm_detect_gpu_json(void) {
    // A statically linked backend (Windows Vulkan builds) is already
    // registered; this only flips the engine's flag so detectGpu looks at it.
    plm::probeLinkedGpuBackend();

    std::string name;
    long long total_mem = 0;
    if (!plm::detectGpu(name, total_mem)) return nullptr;
    const std::string out =
        "{\"name\":\"" + jsonEscape(name) + "\",\"totalMb\":" +
        std::to_string(total_mem / (1024 * 1024)) + "}";
    return mallocString(out);
}

char* plm_last_load_buffers(void) {
    return mallocString(plm::lastLoadBuffers());
}

int plm_free_ram_mb(void) {
    MEMORYSTATUSEX status;
    ZeroMemory(&status, sizeof(status));
    status.dwLength = sizeof(status);
    if (!GlobalMemoryStatusEx(&status)) return 0;
    return (int)(status.ullAvailPhys / (1024 * 1024));
}

double plm_benchmark_bandwidth(void) {
    unsigned int threads = std::thread::hardware_concurrency();
    if (threads == 0) threads = 4;
    // Past physical cores the sweep gets slower, not faster.
    if (threads > 32) threads = 32;
    return plm::memBandwidth((int)threads);
}

// ---------------------------------------------------------------------------
// Cluster
// ---------------------------------------------------------------------------

void plm_set_cluster(const char** endpoints, const float* weights,
                     int count, float local_weight) {
    std::vector<std::string> eps;
    std::vector<float> ws;
    if (endpoints && count > 0) {
        eps.reserve(count);
        ws.reserve(count);
        for (int i = 0; i < count; i++) {
            eps.push_back(endpoints[i] ? endpoints[i] : "");
            ws.push_back(weights && weights[i] > 0 ? weights[i] : 1.0f);
        }
    }
    plm::setCluster(eps, ws, local_weight);
}

void plm_clear_cluster(void) {
    plm::setCluster({}, {}, 1.0f);
}

const char* plm_last_error(void) {
    std::lock_guard<std::mutex> lock(g_error_mutex);
    return g_last_error.empty() ? nullptr : g_last_error.c_str();
}

void plm_free_string(char* s) {
    ::free(s);
}

// Thin JNI adapter over the shared engine core (../src/plm_engine.cpp) and
// backend plumbing (../src/plm_core.cpp). Everything platform-neutral lives
// in the core; this file only marshals JNI ↔ C++ and owns the Android
// specifics: CPU variant loading from the library dir, logcat output, and the
// radio keep-alive used by cluster workers.
//
// JNI symbol names/signatures must stay in sync with
// lib/src/llama_api.dart; do not rename entry points here.
#include <jni.h>
#include <string>
#include <vector>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <thread>
#include <android/log.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#include <dlfcn.h>
#include <setjmp.h>
#include <signal.h>
#include "plm_core.h"
#include "plm_engine.h"
#define LOG_TAG "LlamaJNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ---------------------------------------------------------------------------
// Runtime backend loading (GGML_BACKEND_DL)
//
// Backends ship as separate modules in the app's native library dir:
//  - libggml-cpu-android_*.so, one per Arm generation. The fastest variant
//    this CPU supports is loaded (each reports a score; 0 = unsupported).
//  - libggml-vulkan.so, loaded only when the app explicitly allows the GPU.
//    Merely registering it initialises Vulkan, which some drivers can't
//    handle, so phones that aren't allowed GPU never load it at all.
// ---------------------------------------------------------------------------

#ifdef LLAMA_JNI_BACKEND_DL
// Best first. The armv9 (SVE2/SME) variants are deliberately excluded: on a
// Pixel 8 (Tensor G3) the SVE2 repack path produced out-of-range values and
// aborted on the first decode, so they aren't shipped or loaded.
static const char* const kCpuVariants[] = {
    "android_armv8.6_1", "android_armv8.2_2", "android_armv8.2_1",
    "android_armv8.0_1",
};

// Some kernels don't report CPU features the cores have. The Poco F1's
// LineageOS 4.9 kernel leaves dot-product (asimddp) and FP16 (asimdhp) out of
// HWCAP, so ggml picks the plain armv8.0 build, several times slower at
// quantized matmuls. Instead of trusting HWCAP, run one instruction of each
// kind and catch SIGILL if the core can't.
static sigjmp_buf g_probe_jmp;
static void probeSigill(int) { siglongjmp(g_probe_jmp, 1); }

static bool cpuRuns(void (*probe)()) {
    struct sigaction ill = {}, old = {};
    ill.sa_handler = probeSigill;
    sigemptyset(&ill.sa_mask);
    sigaction(SIGILL, &ill, &old);
    bool ok = false;
    if (sigsetjmp(g_probe_jmp, 1) == 0) {
        probe();
        ok = true;
    }
    sigaction(SIGILL, &old, nullptr);
    return ok;
}

#if defined(__aarch64__)
// Raw encodings, so the assembler needs no +dotprod/+fp16 flags.
static void probeDotprod() { asm volatile(".inst 0x4e829420" ::: "v0"); }  // sdot v0.4s, v1.16b, v2.16b
static void probeFp16() { asm volatile(".inst 0x4e421420" ::: "v0"); }     // fadd v0.8h, v1.8h, v2.8h
#else
static void probeDotprod() {}
static void probeFp16() {}
#endif

/// Loads a CPU variant without ggml's HWCAP-based score check (which
/// load_backend enforces). Only for features probed above.
static bool loadCpuVariantUnchecked(const std::string& path) {
    void* handle = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!handle) return false;
    using init_fn = ggml_backend_reg_t (*)();
    auto init = reinterpret_cast<init_fn>(dlsym(handle, "ggml_backend_init"));
    ggml_backend_reg_t reg = init ? init() : nullptr;
    if (!reg) {
        dlclose(handle);
        return false;
    }
    ggml_backend_register(reg);  // the library stays loaded for the app's life
    return true;
}

static void loadCpuBackendLocked() {
    if (g_cpu_backend_loaded) return;
    std::string best_path;
    std::string best_name;
    int best_score = 0;
    for (const char* variant : kCpuVariants) {
        const std::string path = g_lib_dir + "/libggml-cpu-" + variant + ".so";
        void* handle = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
        if (!handle) continue;
        using score_fn = int (*)();
        auto score = reinterpret_cast<score_fn>(dlsym(handle, "ggml_backend_score"));
        const int value = score ? score() : 0;
        dlclose(handle);
        if (value > best_score) {
            best_score = value;
            best_path = path;
            best_name = variant;
        }
    }
    if (best_name == "android_armv8.0_1" && cpuRuns(probeDotprod)) {
        const char* variant = cpuRuns(probeFp16) ? "android_armv8.2_2" : "android_armv8.2_1";
        const std::string path = g_lib_dir + "/libggml-cpu-" + variant + ".so";
        if (loadCpuVariantUnchecked(path)) {
            g_cpu_backend_loaded = true;
            LOGI("CPU backend: %s (kernel hides these features; probed them instead)", variant);
            return;
        }
    }
    if (!best_path.empty() && ggml_backend_load(best_path.c_str())) {
        g_cpu_backend_loaded = true;
        LOGI("CPU backend: %s (score %d)", best_name.c_str(), best_score);
    } else {
        LOGE("No CPU backend could be loaded from %s", g_lib_dir.c_str());
    }
}

static bool loadGpuBackendLocked() {
    if (g_gpu_backend_loaded) return true;
    const std::string path = g_lib_dir + "/libggml-vulkan.so";
    if (ggml_backend_load(path.c_str())) {
        g_gpu_backend_loaded = true;
        LOGI("Vulkan backend loaded");
    } else {
        LOGE("Vulkan backend unavailable (%s)", path.c_str());
    }
    return g_gpu_backend_loaded;
}

#else
static void loadCpuBackendLocked() { g_cpu_backend_loaded = true; }
static bool loadGpuBackendLocked() { return false; }
#endif

static void platformEnsureCpuBackend() {
    std::lock_guard<std::mutex> lock(g_backend_mutex);
    loadCpuBackendLocked();
}

// Platform log sink: llama.cpp already decided which lines matter
// (DEBUG is dropped in the shared hook); everything else goes to logcat.
static void androidLogSink(ggml_log_level /* effective_level */, const char* text) {
    if (!text) return;
    __android_log_write(ANDROID_LOG_INFO, LOG_TAG, text);
}

// Registers the Android hooks with the shared core at library load time.
namespace {
struct PlmAndroidHooks {
    PlmAndroidHooks() {
        plm::setLogSink(androidLogSink);
        plm::setEnsureCpuBackendHook(platformEnsureCpuBackend);
    }
};
static PlmAndroidHooks g_plm_hooks_init;
} // namespace

// ---------------------------------------------------------------------------
// Phone cluster (RPC backend)
//
// A worker phone serves its CPU over ggml's RPC protocol. The coordinator adds
// each worker as a remote device and offloads the model's last layers to them;
// workers only ever see tensors, never the prompt text. The cluster set here
// applies to the next nativeLoadModel call.
// ---------------------------------------------------------------------------
static std::string jstringToStd(JNIEnv* env, jstring value) {
    if (!value) return {};
    const char* chars = env->GetStringUTFChars(value, nullptr);
    if (!chars) return {};
    std::string out(chars);
    env->ReleaseStringUTFChars(value, chars);
    return out;
}

extern "C" JNIEXPORT void JNICALL
Java_com_write4me_llama_1flutter_1android_ClusterNative_nativeSetCluster(
        JNIEnv* env, jobject /* this */, jobjectArray endpoints, jfloatArray weights,
        jfloat local_weight) {
    const jsize n = endpoints ? env->GetArrayLength(endpoints) : 0;
    const jsize n_weights = weights ? env->GetArrayLength(weights) : 0;
    std::vector<jfloat> w(n_weights);
    if (n_weights > 0) env->GetFloatArrayRegion(weights, 0, n_weights, w.data());
    std::vector<std::string> eps;
    std::vector<float> ws;
    eps.reserve(n);
    ws.reserve(n);
    for (jsize i = 0; i < n; i++) {
        auto item = static_cast<jstring>(env->GetObjectArrayElement(endpoints, i));
        eps.push_back(jstringToStd(env, item));
        ws.push_back(i < n_weights ? w[i] : 1.0f);
        env->DeleteLocalRef(item);
    }
    plm::setCluster(eps, ws, local_weight);
    LOGI("Cluster set: %zu worker(s)", eps.size());
}

/// Where the last model load put its weights: "<buffer name>\t<MiB>" lines.
extern "C" JNIEXPORT jstring JNICALL
Java_com_write4me_llama_1flutter_1android_ClusterNative_nativeLastLoadBuffers(
        JNIEnv* env, jobject /* this */) {
    const std::string buffers = plm::lastLoadBuffers();
    return env->NewStringUTF(buffers.c_str());
}

/// Cluster worker: the connected master's address, or null.
extern "C" JNIEXPORT jstring JNICALL
Java_com_write4me_llama_1flutter_1android_ClusterNative_nativeWorkerPeer(
        JNIEnv* env, jobject /* this */) {
    const std::string peer = plm::workerPeer();
    return peer.empty() ? nullptr : env->NewStringUTF(peer.c_str());
}

/// Memory read speed in GB/s with `threads` threads. Token generation is
/// limited by how fast weights stream from RAM, so this ranks phones for the
/// cluster better than core counts or clock speeds do. Takes ~0.2 s.
extern "C" JNIEXPORT jdouble JNICALL
Java_com_write4me_llama_1flutter_1android_ClusterNative_nativeMemBandwidth(
        JNIEnv* /* env */, jobject /* this */, jint threads) {
    const double result = plm::memBandwidth((int)threads);
    LOGI("Memory bandwidth: %.1f GB/s", result);
    return result;
}

// Keeps this device's Wi-Fi radio awake while a master is connected. Phones
// and iPads doze the radio between packets (tens to 200+ ms to wake), and
// every token makes a few round trips to each worker. A device that is
// transmitting stays out of power save, so send the master one tiny UDP
// datagram (discard port 9) every 20 ms: ~50 bytes/s. Measured iPad latency
// from the master: 28 ms average with 111 ms spikes when idle.
static void runRadioKeepAwake(const std::atomic<bool>& running, std::string (*peer)()) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return;
    const char byte = 0;
    while (running) {
        const std::string ip = peer();
        if (ip.empty()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
            continue;
        }
        sockaddr_in to = {};
        to.sin_family = AF_INET;
        to.sin_port = htons(9);
        if (inet_pton(AF_INET, ip.c_str(), &to.sin_addr) == 1) {
            sendto(fd, &byte, 1, 0, (const sockaddr*)&to, sizeof(to));
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    close(fd);
}

static std::atomic<bool> g_worker_running{false};

static std::string currentWorkerPeer() {
    std::lock_guard<std::mutex> lock(g_load_log_mutex);
    return g_worker_peer;
}

/// Runs this phone as a cluster worker. Blocks for as long as the server
/// runs (ggml has no way to stop it), so it lives in its own process; only
/// returns, with the reason, if the server couldn't start.
extern "C" JNIEXPORT jstring JNICALL
Java_com_write4me_llama_1flutter_1android_ClusterNative_nativeServe(
        JNIEnv* env, jobject /* this */, jstring lib_dir, jstring endpoint,
        jstring cache_dir, jlong n_threads) {
    ggml_backend_reg_t rpc;
    ggml_backend_dev_t cpu;
    {
        std::lock_guard<std::mutex> lock(g_backend_mutex);
        if (g_lib_dir.empty()) g_lib_dir = jstringToStd(env, lib_dir);
        plm::installLogHandler();
        loadCpuBackendLocked();
        rpc = plm::loadRpcBackendLocked();
        cpu = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
    }
    if (!rpc) return env->NewStringUTF("This build has no cluster (RPC) support");
    if (!cpu) return env->NewStringUTF("No CPU backend could be loaded");
    using start_fn = void (*)(const char*, const char*, size_t, size_t, ggml_backend_dev_t*);
    auto start = reinterpret_cast<start_fn>(
        ggml_backend_reg_get_proc_address(rpc, "ggml_backend_rpc_start_server"));
    if (!start) return env->NewStringUTF("RPC backend is missing its server");

    const std::string ep = jstringToStd(env, endpoint);
    const std::string cache = jstringToStd(env, cache_dir);
    LOGI("Cluster worker listening on %s (cache %s)", ep.c_str(), cache.c_str());
    g_worker_running = true;
    std::thread([] { runRadioKeepAwake(g_worker_running, currentWorkerPeer); }).detach();
    start(ep.c_str(), cache.empty() ? nullptr : cache.c_str(),
          (size_t)std::max<jlong>(1, n_threads), 1, &cpu);
    g_worker_running = false;
    return env->NewStringUTF("Worker stopped: the port may already be in use");
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeInitBackends(
        JNIEnv* env, jobject /* this */, jstring lib_dir, jboolean allow_gpu) {
    std::lock_guard<std::mutex> lock(g_backend_mutex);
    if (g_lib_dir.empty() && lib_dir) {
        const char* dir = env->GetStringUTFChars(lib_dir, nullptr);
        if (dir) {
            g_lib_dir = dir;
            env->ReleaseStringUTFChars(lib_dir, dir);
        }
    }
    plm::installLogHandler();
    loadCpuBackendLocked();
    if (allow_gpu == JNI_TRUE) loadGpuBackendLocked();
    return g_gpu_backend_loaded && plm::firstLocalGpuDevice() != nullptr ? JNI_TRUE : JNI_FALSE;
}

static void throwLoadError(JNIEnv* env, const std::string& message) {
    LOGE("%s", message.c_str());
    jclass exception = env->FindClass("java/lang/RuntimeException");
    env->ThrowNew(exception, message.c_str());
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeDetectGpu(
        JNIEnv* env, jobject /* this */, jlongArray outStats) {
    std::string description;
    long long total_mem = 0;
    if (!plm::detectGpu(description, total_mem)) return nullptr;

    jlong stats[2] = {-1L, static_cast<jlong>(total_mem)};
    env->SetLongArrayRegion(outStats, 0, 2, stats);
    return env->NewStringUTF(description.c_str());
}

extern "C" JNIEXPORT void JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeLoadModel(
    JNIEnv* env, jobject thiz,
    jstring path, jlong n_threads, jlong ctx_size, jlong n_gpu_layers,
    jobject progress_callback) {

    if (!path) {
        throwLoadError(env, "GGUF model path is missing");
        return;
    }
    const std::string model_path = jstringToStd(env, path);
    if (model_path.empty()) {
        throwLoadError(env, "Could not read the GGUF model path");
        return;
    }

    // Keeps the Kotlin functional callback alive across the call and hands
    // the engine the exact same final Double(1.0) callback it always made.
    plm::LoadProgress progress;
    if (progress_callback) {
        progress = [env, progress_callback](double value) {
            jclass callbackClass = env->GetObjectClass(progress_callback);
            jmethodID invokeMethod = env->GetMethodID(
                callbackClass, "invoke", "(Ljava/lang/Object;)Ljava/lang/Object;");
            jclass doubleClass = env->FindClass("java/lang/Double");
            jmethodID doubleConstructor = env->GetMethodID(doubleClass, "<init>", "(D)V");
            jobject doubleObj = env->NewObject(doubleClass, doubleConstructor, value);
            env->CallObjectMethod(progress_callback, invokeMethod, doubleObj);
            env->DeleteLocalRef(doubleObj);
            env->DeleteLocalRef(doubleClass);
            env->DeleteLocalRef(callbackClass);
        };
    }

    const std::string error = plm::loadModel(
        model_path.c_str(), (int)n_threads, (int)ctx_size, (int)n_gpu_layers, progress);
    if (!error.empty()) throwLoadError(env, error);
}

/// Loads the vision projector for the current model. Returns null on
/// success, or an error message (the text model stays loaded either way).
extern "C" JNIEXPORT jstring JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeLoadMmproj(
        JNIEnv* env, jobject /* this */, jstring path, jlong n_threads) {
    const std::string mmproj = jstringToStd(env, path);
    const std::string error = plm::loadMmproj(
        mmproj.empty() ? nullptr : mmproj.c_str(), (int)n_threads);
    return error.empty() ? nullptr : env->NewStringUTF(error.c_str());
}

static jobject g_token_callback = nullptr;

extern "C" JNIEXPORT void JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeGenerate(
    JNIEnv* env, jobject thiz,
    jstring prompt, jstring image_path, jlong max_tokens,
    jdouble temperature, jdouble top_p, jlong top_k, jdouble min_p, jdouble typical_p,
    jdouble repeat_penalty, jdouble frequency_penalty, jdouble presence_penalty, jlong repeat_last_n,
    jlong mirostat, jdouble mirostat_tau, jdouble mirostat_eta,
    jlong seed, jboolean penalize_newline,
    jobject token_callback) {

    if (g_token_callback != nullptr) {
        env->DeleteGlobalRef(g_token_callback);
        g_token_callback = nullptr;
    }
    g_token_callback = env->NewGlobalRef(token_callback);

    if (!plm::isModelLoaded()) {
        jclass exception = env->FindClass("java/lang/IllegalStateException");
        env->ThrowNew(exception, "Model not loaded");
        return;
    }

    const std::string prompt_str = jstringToStd(env, prompt);
    const std::string image_file = jstringToStd(env, image_path);
    if (!image_file.empty() && !plm::isVisionLoaded()) {
        jclass exception = env->FindClass("java/lang/IllegalStateException");
        env->ThrowNew(exception, "This model has no vision file loaded, so it can't read images");
        return;
    }

    plm::SamplingParams params;
    params.max_tokens = (int)max_tokens;
    params.temperature = temperature;
    params.top_p = top_p;
    params.top_k = (int)top_k;
    params.min_p = min_p;
    params.typical_p = typical_p;
    params.repeat_penalty = repeat_penalty;
    params.frequency_penalty = frequency_penalty;
    params.presence_penalty = presence_penalty;
    params.repeat_last_n = (int)repeat_last_n;
    params.mirostat = (int)mirostat;
    params.mirostat_tau = mirostat_tau;
    params.mirostat_eta = mirostat_eta;
    params.seed = (long long)seed;
    // penalize_newline: unchanged behaviour — accepted but not wired into the
    // sampler chain (the engine doesn't consume it either).

    // Streamed tokens go straight back to the Kotlin functional callback,
    // exactly as before — same thread, same invoke signature.
    jclass callbackClass = env->GetObjectClass(token_callback);
    jmethodID invokeMethod = env->GetMethodID(
        callbackClass, "invoke", "(Ljava/lang/Object;)Ljava/lang/Object;");
    plm::TokenSink sink = [env, invokeMethod](const std::string& piece) {
        if (!g_token_callback) return;
        jstring token_str = env->NewStringUTF(piece.c_str());
        env->CallObjectMethod(g_token_callback, invokeMethod, token_str);
        env->DeleteLocalRef(token_str);
    };

    const std::string error = plm::generate(prompt_str, image_file, params, sink);
    env->DeleteLocalRef(callbackClass);
    if (!error.empty()) throwLoadError(env, error);
}

extern "C" JNIEXPORT void JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeStop(
    JNIEnv* env, jobject thiz) {
    plm::stopGeneration();
    // When stopping generation, we just set the flag - KV cache management handled by llama.cpp
}

extern "C" JNIEXPORT void JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeFreeModel(
    JNIEnv* env, jobject thiz) {
    plm::unloadModel();
}

extern "C" JNIEXPORT jint JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeGetTokensUsed(
    JNIEnv* env, jobject thiz) {
    return plm::tokensUsed();
}

extern "C" JNIEXPORT jint JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeGetContextSize(
    JNIEnv* env, jobject thiz) {
    return plm::contextSize();
}

extern "C" JNIEXPORT void JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeClearContext(
    JNIEnv* env, jobject thiz) {
    plm::clearContext();
}

extern "C" JNIEXPORT void JNICALL
Java_com_write4me_llama_1flutter_1android_LlamaFlutterAndroidPlugin_nativeSetSystemPromptLength(
    JNIEnv* env, jobject thiz, jint length) {
    // Currently not used but available for future smart context management
    LOGI("System prompt length set to: %d tokens (currently unused)", length);
}

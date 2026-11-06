// Platform-neutral inference engine.
// Ported 1:1 from the engine parts of jni_wrapper.cpp; the JNI/FFI adapters
// only marshal parameters and callbacks around this. Error messages must stay
// identical to the originals so the Dart/Android layers keep showing the same
// text.
#include "plm_engine.h"
#include "plm_core.h"

#include <algorithm>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cmath>
#include <cstring>
#include <ctime>
#include <fstream>
#include <vector>

#include "llama.h"
#include "ggml-backend.h"
#include "gguf.h"
#include "mtmd.h"
#include "mtmd-helper.h"

namespace plm {

// ---------------------------------------------------------------------------
// Process-global engine state (one engine per process)
// ---------------------------------------------------------------------------

static llama_model* g_model = nullptr;
static llama_context* g_ctx = nullptr;
static const llama_vocab* g_vocab = nullptr;
static llama_sampler* g_sampler = nullptr;
static std::atomic<bool> g_stop_flag{false};
static int g_n_past = 0;  // Track the number of tokens already in KV cache
// Exactly the tokens held in the KV cache (sequence 0), in order. Lets each
// turn reuse the cached prefix it shares with the previous prompt + reply
// instead of re-feeding (and duplicating) the whole conversation.
static std::vector<llama_token> g_cached_tokens;
// Vision projector (mmproj) for multimodal GGUF models; null when text-only.
static mtmd_context* g_mtmd = nullptr;
// False after a turn that contained an image: those image embeddings aren't
// representable in g_cached_tokens, so the next turn must not reuse the cache.
static bool g_cache_reusable = true;

bool isModelLoaded() {
    return g_model && g_ctx && g_vocab;
}

bool isVisionLoaded() {
    return g_mtmd != nullptr;
}

// ---------------------------------------------------------------------------
// Logging helpers (same texts as the old LOGI/LOGE calls)
// ---------------------------------------------------------------------------

static void logInfo(const char* fmt, ...) {
    char buf[512];
    va_list args;
    va_start(args, fmt);
    std::vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    logf(GGML_LOG_LEVEL_INFO, "%s", buf);
}

static void logError(const char* fmt, ...) {
    char buf[512];
    va_list args;
    va_start(args, fmt);
    std::vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    logf(GGML_LOG_LEVEL_ERROR, "%s", buf);
}

// ---------------------------------------------------------------------------
// UTF-8 sanitizing (moved unchanged from jni_wrapper.cpp)
// ---------------------------------------------------------------------------

namespace {

// Helper function to validate UTF-8 strings
bool isValidUTF8(const char* str, size_t len) {
    if (!str) return false;

    const unsigned char* bytes = reinterpret_cast<const unsigned char*>(str);
    size_t i = 0;

    while (i < len) {
        unsigned char c = bytes[i];

        // ASCII character (0xxxxxxx)
        if ((c & 0x80) == 0) {
            i++;
            continue;
        }

        // Multi-byte sequence start (110xxxxx, 1110xxxx, or 11110xxx)
        int num_bytes = 0;
        if ((c & 0xE0) == 0xC0) {
            num_bytes = 2; // 110xxxxx
        } else if ((c & 0xF0) == 0xE0) {
            num_bytes = 3; // 1110xxxx
        } else if ((c & 0xF8) == 0xF0) {
            num_bytes = 4; // 11110xxx
        } else {
            // Invalid first byte
            return false;
        }

        // Check if we have enough bytes left
        if (i + num_bytes > len) {
            return false;
        }

        // Check continuation bytes (10xxxxxx)
        for (int j = 1; j < num_bytes; j++) {
            if ((bytes[i + j] & 0xC0) != 0x80) {
                return false;
            }
        }

        // Check for overlong encodings and invalid code points
        if (num_bytes == 2) {
            // Overlong encoding of ASCII character
            if ((c & 0x1E) == 0) return false;
        } else if (num_bytes == 3) {
            // Invalid surrogate halves (U+D800-U+DFFF)
            if (c == 0xED && (bytes[i + 1] & 0x20) == 0x20) return false;
            // Overlong encoding
            if (c == 0xE0 && (bytes[i + 1] & 0x20) == 0) return false;
        } else if (num_bytes == 4) {
            // Out of Unicode range (> U+10FFFF)
            if (c > 0xF4) return false;
            // Overlong encoding
            if (c == 0xF0 && (bytes[i + 1] & 0x30) == 0) return false;
            // Invalid code points (> U+10FFFF)
            if (c == 0xF4 && bytes[i + 1] > 0x8F) return false;
        }

        i += num_bytes;
    }

    return true;
}

// Helper function to sanitize UTF-8 strings
std::string sanitizeUTF8(const char* str, size_t len) {
    if (!str || len == 0) return "";

    // First try to validate as-is
    if (isValidUTF8(str, len)) {
        return std::string(str, len);
    }

    // If invalid, create a sanitized version
    std::string result;
    result.reserve(len);

    const unsigned char* bytes = reinterpret_cast<const unsigned char*>(str);
    size_t i = 0;

    while (i < len) {
        unsigned char c = bytes[i];

        // ASCII character (0xxxxxxx)
        if ((c & 0x80) == 0) {
            result += c;
            i++;
            continue;
        }

        // Multi-byte sequence start
        int num_bytes = 0;
        if ((c & 0xE0) == 0xC0) {
            num_bytes = 2;
        } else if ((c & 0xF0) == 0xE0) {
            num_bytes = 3;
        } else if ((c & 0xF8) == 0xF0) {
            num_bytes = 4;
        } else {
            // Invalid first byte, replace with replacement character
            result += "\xEF\xBF\xBD"; // 
            i++;
            continue;
        }

        // Check if we have enough bytes left
        if (i + num_bytes > len) {
            result += "\xEF\xBF\xBD"; // 
            break;
        }

        // Extract the sequence
        std::string seq(reinterpret_cast<const char*>(bytes + i), num_bytes);

        // Validate the sequence
        if (isValidUTF8(seq.c_str(), num_bytes)) {
            result += seq;
        } else {
            // Invalid sequence, replace with replacement character
            result += "\xEF\xBF\xBD"; // 
        }

        i += num_bytes;
    }

    return result;
}

/// Frees the vision projector, if any.
void freeMtmd() {
    if (g_mtmd) {
        mtmd_free(g_mtmd);
        g_mtmd = nullptr;
    }
}

} // namespace

// ---------------------------------------------------------------------------
// Model load
// ---------------------------------------------------------------------------

std::string loadModel(const char* model_path, int n_threads, int ctx_size,
                      int n_gpu_layers, const LoadProgress& progress) {
    if (!model_path || !*model_path) {
        return "GGUF model path is missing";
    }
    logInfo("Loading model: %s", model_path);

    std::ifstream model_file(model_path, std::ios::binary | std::ios::ate);
    if (!model_file) {
        return "GGUF model file is missing or unreadable";
    }
    const std::streamsize model_size = model_file.tellg();
    if (model_size < 4) {
        return "GGUF model file is empty or incomplete";
    }
    model_file.seekg(0, std::ios::beg);
    char magic[4] = {};
    model_file.read(magic, sizeof(magic));
    if (!model_file || std::memcmp(magic, "GGUF", sizeof(magic)) != 0) {
        return "Invalid GGUF model header";
    }
    model_file.close();

    ensureCpuBackend();

    // Model parameters
    llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = n_gpu_layers;
    // With no GPU layers requested, give llama.cpp an empty device list so
    // it can't touch a GPU at all (even if the Vulkan backend is loaded).
    static ggml_backend_dev_t no_gpu_devices[] = {nullptr};
    // Otherwise name the local GPU explicitly: once cluster workers are
    // registered, llama.cpp's default device list would include them too.
    ggml_backend_dev_t local_gpu_devices[] = {firstLocalGpuDevice(), nullptr};
    if (n_gpu_layers == 0) {
        model_params.devices = no_gpu_devices;
    } else {
        model_params.devices = local_gpu_devices;
    }

    // Cluster mode: this device runs on its CPU and the workers hold the rest.
    ClusterPlan cluster;
    bool has_cluster;
    {
        std::lock_guard<std::mutex> lock(g_backend_mutex);
        has_cluster = !g_cluster_endpoints.empty();
    }
    if (has_cluster) {
        const std::string error = planCluster(model_path, cluster);
        if (!error.empty()) {
            return "Cluster: " + error;
        }
        model_params.devices = cluster.devices.data();
        model_params.tensor_split = cluster.split.data();
        model_params.n_gpu_layers = cluster.n_gpu_layers;
        if (cluster.overrides[0].pattern) {
            model_params.tensor_buft_overrides = cluster.overrides;
        }
    }

    installLogHandler();
    beginLoadCapture();

    // Load model
    g_model = llama_model_load_from_file(model_path, model_params);

    if (!g_model) {
        const std::string detail = consumeLoadError();
        return detail.empty()
            ? "Failed to load GGUF model; check model compatibility and available RAM"
            : "Failed to load GGUF model: " + detail;
    }
    consumeLoadError();

    // Context parameters with memory optimizations for low-end devices
    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx = ctx_size;
    ctx_params.n_threads = n_threads;
    ctx_params.n_threads_batch = n_threads;

    // Memory optimization: reduce memory usage by limiting batch processing
    ctx_params.n_batch = 512;  // Process smaller batches to reduce memory spikes
    // Don't push CPU-resident tensor ops to the GPU in CPU-only mode, nor
    // over Wi-Fi to a worker in cluster mode.
    ctx_params.op_offload = n_gpu_layers != 0 && !has_cluster;

    // Create context (using new API)
    g_ctx = llama_init_from_model(g_model, ctx_params);
    if (!g_ctx) {
        llama_model_free(g_model);
        g_model = nullptr;
        return "Failed to create context";
    }

    // Get vocab for tokenization
    g_vocab = llama_model_get_vocab(g_model);
    logInfo("Vocab initialized: %p", (void*)g_vocab);

    if (!g_vocab) {
        llama_free(g_ctx);
        llama_model_free(g_model);
        g_ctx = nullptr;
        g_model = nullptr;
        return "Failed to get vocab from model";
    }

    // Reset KV cache position counter for new model
    g_n_past = 0;
    g_cached_tokens.clear();

    // Report progress completion
    if (progress) progress(1.0);

    logInfo("Model loaded successfully");
    return {};
}

// ---------------------------------------------------------------------------
// Vision projector (mmproj)
// ---------------------------------------------------------------------------

std::string loadMmproj(const char* path, int n_threads) {
    freeMtmd();
    if (!g_model) return "Load the text model first";
    if (!path || !*path) return "Vision file path is missing";

    mtmd_context_params params = mtmd_context_params_default();
    // Image encoding stays on the CPU: mobile Vulkan drivers have been
    // unreliable, and the projector is small enough to run there.
    params.use_gpu = false;
    params.n_threads = std::max(1, n_threads);
    params.print_timings = false;
    params.warmup = false;  // skip a dummy encode at load time

    {
        std::lock_guard<std::mutex> lock(g_load_log_mutex);
        g_load_error.clear();
        g_capture_load_error = true;
    }
    mtmd_helper_log_set(logHook(), nullptr);
    g_mtmd = mtmd_init_from_file(path, g_model, params);
    const std::string detail = consumeLoadError();

    if (!g_mtmd) {
        return detail.empty()
            ? "The vision file doesn't match this model or couldn't be loaded"
            : "Vision file failed to load: " + detail;
    }
    if (!mtmd_support_vision(g_mtmd)) {
        freeMtmd();
        return "This projector file doesn't support images";
    }
    logInfo("Vision projector loaded");
    return {};
}

// ---------------------------------------------------------------------------
// Generation
// ---------------------------------------------------------------------------

static std::string buildSampler(const SamplingParams& params) {
    if (g_sampler) {
        llama_sampler_free(g_sampler);
        g_sampler = nullptr;
    }

    // Use seed or current time
    uint32_t sampler_seed = (params.seed >= 0)
        ? static_cast<uint32_t>(params.seed)
        : static_cast<uint32_t>(time(nullptr));

    llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    g_sampler = llama_sampler_chain_init(sparams);

    // Add penalties first (applied to logits before sampling)
    if (params.repeat_penalty != 1.0f || params.frequency_penalty != 0.0f ||
        params.presence_penalty != 0.0f) {
        llama_sampler_chain_add(g_sampler, llama_sampler_init_penalties(
            llama_vocab_n_tokens(g_vocab),  // n_vocab
            params.repeat_last_n,           // penalty_last_n
            params.repeat_penalty,          // penalty_repeat
            params.frequency_penalty,       // penalty_freq
            params.presence_penalty         // penalty_present
        ));
    }

    // Temperature sampling
    llama_sampler_chain_add(g_sampler, llama_sampler_init_temp(params.temperature));

    // Add advanced samplers if enabled
    if (params.mirostat == 1) {
        llama_sampler_chain_add(g_sampler, llama_sampler_init_mirostat(
            llama_vocab_n_tokens(g_vocab),  // Use the vocab to get n_vocab
            sampler_seed,
            params.mirostat_tau,
            params.mirostat_eta,
            100  // m parameter
        ));
    } else if (params.mirostat == 2) {
        llama_sampler_chain_add(g_sampler, llama_sampler_init_mirostat_v2(
            sampler_seed,
            params.mirostat_tau,
            params.mirostat_eta
        ));
    } else {
        // Standard sampling chain (only if mirostat is disabled)
        if (params.min_p > 0.0f && params.min_p < 1.0f) {
            llama_sampler_chain_add(g_sampler, llama_sampler_init_min_p(params.min_p, 1));
        }

        if (params.typical_p < 1.0f) {
            llama_sampler_chain_add(g_sampler, llama_sampler_init_typical(params.typical_p, 1));
        }

        if (params.top_k > 0) {
            llama_sampler_chain_add(g_sampler, llama_sampler_init_top_k(params.top_k));
        }

        if (params.top_p < 1.0f) {
            llama_sampler_chain_add(g_sampler, llama_sampler_init_top_p(params.top_p, 1));
        }
    }

    // Final distribution sampler
    llama_sampler_chain_add(g_sampler, llama_sampler_init_dist(sampler_seed));
    return {};
}

/// Evaluates a text-only prompt with KV-cache prefix reuse.
/// On failure the batch is freed and an error message is returned.
static std::string evalPrompt(llama_batch batch, const std::string& prompt,
                              long long max_tokens) {
    // Never log prompt text: it is the user's conversation.
    const std::string sanitized_prompt = sanitizeUTF8(prompt.c_str(), prompt.size());
    const char* sanitized_cstr = sanitized_prompt.c_str();
    const int sanitized_len = sanitized_prompt.length();

    // Tokenize prompt - when tokens is NULL, llama_tokenize returns NEGATIVE count
    const int n_prompt_tokens = -llama_tokenize(g_vocab, sanitized_cstr, sanitized_len, nullptr, 0, true, true);
    logInfo("Token count: %d", n_prompt_tokens);

    if (n_prompt_tokens <= 0) {
        char error_msg[256];
        snprintf(error_msg, sizeof(error_msg), "Failed to tokenize prompt (got %d tokens)", n_prompt_tokens);
        return error_msg;
    }
    std::vector<llama_token> tokens(n_prompt_tokens);
    const int actual_tokens = llama_tokenize(g_vocab, sanitized_cstr, sanitized_len, tokens.data(), tokens.size(), true, true);
    if (actual_tokens < 0) {
        return "Failed to tokenize prompt";
    }
    tokens.resize(actual_tokens);

    const int n_ctx = llama_n_ctx(g_ctx);

    // Leave room for the reply. If the conversation is longer than that, keep
    // its start (system prompt) and its most recent part, dropping the middle.
    const long long reserve_ll =
        std::min<long long>(std::max<long long>(max_tokens, 64), n_ctx / 2);
    const int reserve = (int)reserve_ll;
    const int budget = n_ctx - reserve;
    if ((int)tokens.size() > budget) {
        const int head = std::min(256, budget / 4);
        std::vector<llama_token> trimmed(tokens.begin(), tokens.begin() + head);
        trimmed.insert(trimmed.end(), tokens.end() - (budget - head), tokens.end());
        logInfo("Prompt of %zu tokens trimmed to %d to fit context %d", tokens.size(), budget, n_ctx);
        tokens.swap(trimmed);
    }

    // Reuse the cached prefix shared with what's already in the KV cache;
    // drop everything after it. At least one token must be decoded so the
    // last position has logits to sample from.
    size_t n_keep = 0;
    if (!g_cache_reusable) {
        // Previous turn held an image: start this one from an empty cache.
        g_cached_tokens.clear();
        g_cache_reusable = true;
    }
    while (n_keep < g_cached_tokens.size() && n_keep < tokens.size() &&
           g_cached_tokens[n_keep] == tokens[n_keep]) {
        n_keep++;
    }
    if (n_keep >= tokens.size()) n_keep = tokens.size() - 1;
    llama_memory_seq_rm(llama_get_memory(g_ctx), 0, (llama_pos)n_keep, -1);
    g_cached_tokens.resize(n_keep);
    g_n_past = (int)n_keep;
    logInfo("Prompt: %zu tokens, %zu reused from cache, %zu to process",
            tokens.size(), n_keep, tokens.size() - n_keep);

    // Process prompt in batches to handle long inputs
    const int max_batch_size = 512;
    int tokens_processed = (int)n_keep;

    while (tokens_processed < (int)tokens.size()) {
        batch.n_tokens = 0;
        int batch_size = std::min((int)tokens.size() - tokens_processed, max_batch_size);

        for (int i = 0; i < batch_size; i++) {
            batch.token[batch.n_tokens] = tokens[tokens_processed + i];
            batch.pos[batch.n_tokens] = tokens_processed + i;
            batch.n_seq_id[batch.n_tokens] = 1;
            batch.seq_id[batch.n_tokens][0] = 0;
            batch.logits[batch.n_tokens] = (tokens_processed + i == (int)tokens.size() - 1);
            batch.n_tokens++;
        }

        int decode_result = llama_decode(g_ctx, batch);
        if (decode_result != 0) {
            logError("❌ DECODE FAILED! Result code: %d", decode_result);
            return "Failed to decode prompt";
        }
        tokens_processed += batch_size;
    }

    // The KV cache now holds exactly the prompt.
    g_n_past = (int)tokens.size();
    g_cached_tokens = tokens;
    return {};
}

/// Evaluates a turn whose prompt contains an image marker.
static std::string evalImagePrompt(llama_batch batch, const std::string& prompt,
                                   const std::string& image_path) {
    const std::string sanitized = sanitizeUTF8(prompt.c_str(), prompt.size());
    logInfo("Image prompt: %zu chars, marker %s", sanitized.size(),
            sanitized.find(mtmd_default_marker()) != std::string::npos ? "present" : "MISSING");

    mtmd_helper_bitmap_wrapper wrapped = mtmd_helper_bitmap_init_from_file(
        g_mtmd, image_path.c_str(), /*placeholder=*/false,
        mtmd_helper_init_opt_default());
    // Video is compiled out (MTMD_VIDEO=OFF), but free it if ever set.
    if (wrapped.video_ctx) mtmd_helper_video_free(wrapped.video_ctx);
    mtmd_bitmap* bitmap = wrapped.bitmap;
    if (!bitmap) {
        return "Couldn't read the image file";
    }
    // Zero-init: newer mtmd added fields (e.g. text_len) that must not
    // be left uninitialised.
    mtmd_input_text text{};
    text.text = sanitized.c_str();
    text.text_len = sanitized.size();
    text.add_special = true;
    text.parse_special = true;
    mtmd_input_chunks* chunks = mtmd_input_chunks_init();
    const mtmd_bitmap* bitmaps[] = {bitmap};
    const int32_t tok_res = mtmd_tokenize(g_mtmd, chunks, &text, bitmaps, 1);
    mtmd_bitmap_free(bitmap);
    if (tok_res != 0) {
        mtmd_input_chunks_free(chunks);
        return tok_res == 1
            ? "The prompt is missing the image marker"
            : "Couldn't process the image";
    }

    const int n_ctx_img = llama_n_ctx(g_ctx);
    const llama_pos n_pos = mtmd_helper_get_n_pos(chunks);
    if (n_pos + 64 > n_ctx_img) {
        mtmd_input_chunks_free(chunks);
        return "The image and conversation are too long for the context size. "
               "Start a new chat or raise the context size.";
    }

    llama_memory_seq_rm(llama_get_memory(g_ctx), 0, 0, -1);
    g_cached_tokens.clear();
    llama_pos new_n_past = 0;
    logInfo("Evaluating image prompt: %d positions", (int)n_pos);
    const int32_t eval_res = mtmd_helper_eval_chunks(
        g_mtmd, g_ctx, chunks, 0, 0, 512, true, &new_n_past);
    mtmd_input_chunks_free(chunks);
    if (eval_res != 0) {
        llama_memory_seq_rm(llama_get_memory(g_ctx), 0, 0, -1);
        g_n_past = 0;
        g_cache_reusable = true;
        return "Failed to encode the image";
    }
    g_n_past = (int)new_n_past;
    g_cache_reusable = false;
    return {};
}

std::string generate(const std::string& prompt, const std::string& image_path,
                     const SamplingParams& params, const TokenSink& token) {
    if (!(g_model && g_ctx && g_vocab)) {
        return "Model not loaded";
    }
    g_stop_flag = false;

    const bool with_image = !image_path.empty();
    if (with_image && !g_mtmd) {
        return "This model has no vision file loaded, so it can't read images";
    }

    llama_batch batch = llama_batch_init(512, 0, 1);

    std::string decode_error;
    if (with_image) {
        // Image turn: tokenize text + image into chunks and evaluate them from
        // an empty cache (image embeddings can't be prefix-matched).
        decode_error = evalImagePrompt(batch, prompt, image_path);
    } else {
        decode_error = evalPrompt(batch, prompt, params.max_tokens);
    }
    if (!decode_error.empty()) {
        llama_batch_free(batch);
        return decode_error;
    }

    const std::string sampler_error = buildSampler(params);
    if (!sampler_error.empty()) {
        llama_batch_free(batch);
        return sampler_error;
    }

    // Generation loop
    logInfo("Starting generation loop: max_tokens=%lld", (long long)params.max_tokens);
    for (int i = 0; i < params.max_tokens && !g_stop_flag; i++) {
        llama_token new_token_id = llama_sampler_sample(g_sampler, g_ctx, -1);

        // Check for end of generation (EOS/EOD tokens)
        if (llama_vocab_is_eog(g_vocab, new_token_id)) {
            logInfo("EOS token detected, ending generation.");
            break;
        }

        // Decode token to string
        char buffer[256];
        int32_t length = llama_token_to_piece(g_vocab, new_token_id, buffer, sizeof(buffer), 0, true);
        std::string piece;

        if (length > 0) {
            piece = sanitizeUTF8(buffer, length);
        } else {
            piece = "";
        }

        if (token) token(piece);

        // Prepare next batch
        batch.n_tokens = 0;
        batch.token[batch.n_tokens] = new_token_id;
        batch.pos[batch.n_tokens] = g_n_past;  // Use the tracked position
        batch.n_seq_id[batch.n_tokens] = 1;
        batch.seq_id[batch.n_tokens][0] = 0;
        batch.logits[batch.n_tokens] = true;
        batch.n_tokens++;

        if (llama_decode(g_ctx, batch) != 0) {
            logError("Failed to decode after sampling token %d", i + 1);
            break;
        }

        // Update position counter after each generated token
        g_n_past++;
        if (g_cache_reusable) g_cached_tokens.push_back(new_token_id);
    }
    logInfo("Generation loop finished.");

    // After generation completion, ensure the KV cache is properly managed
    // In some llama.cpp versions, KV cache management may be needed between generations
    // For chat applications, we want to maintain conversation context

    llama_batch_free(batch);
    return {};
}

// ---------------------------------------------------------------------------
// Simple queries and lifecycle
// ---------------------------------------------------------------------------

void stopGeneration() {
    g_stop_flag = true;
}

void unloadModel() {
    if (g_sampler) {
        llama_sampler_free(g_sampler);
        g_sampler = nullptr;
    }
    freeMtmd();
    g_cache_reusable = true;
    if (g_ctx) {
        llama_free(g_ctx);
        g_ctx = nullptr;
    }
    if (g_model) {
        llama_model_free(g_model);
        g_model = nullptr;
    }
    g_vocab = nullptr;
    g_n_past = 0;  // Reset position counter
    g_cached_tokens.clear();

    logInfo("Model freed");
}

int tokensUsed() {
    return g_n_past;
}

int contextSize() {
    return g_ctx ? llama_n_ctx(g_ctx) : 0;
}

bool clearContext() {
    if (!g_ctx) {
        logError("Cannot clear context: context is null");
        return false;
    }

    llama_memory_t mem = llama_get_memory(g_ctx);
    if (mem) {
        llama_memory_seq_rm(mem, 0, 0, -1);
        g_n_past = 0;
        g_cached_tokens.clear();
        g_cache_reusable = true;
        logInfo("Context cleared, g_n_past reset to 0");
        return true;
    }
    logError("Failed to get memory object from context");
    return false;
}

// ---------------------------------------------------------------------------
// GPU detection
// ---------------------------------------------------------------------------

bool detectGpu(std::string& description, long long& total_mem) {
    // Only reports a GPU if the app already allowed and loaded the backend
    // (nativeInitBackends on Android, backend plugin on Windows); this never
    // initialises Vulkan itself.
    ggml_backend_dev_t dev = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_backend_mutex);
        if (!g_gpu_backend_loaded) {
            logInfo("detectGpu: GPU backend not loaded");
            return false;
        }
        dev = firstLocalGpuDevice();
    }
    if (!dev) {
        logInfo("detectGpu: no local GPU device");
        return false;
    }
    size_t free_mem = 0, mem = 0;
    ggml_backend_dev_memory(dev, &free_mem, &mem);
    total_mem = (long long)mem;
    const char* desc = ggml_backend_dev_description(dev);
    logInfo("detectGpu: %s (%lld MB)", desc ? desc : "?", total_mem / (1024 * 1024));
    description = desc ? desc : "GPU";
    return true;
}

} // namespace plm

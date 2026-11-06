// Platform-neutral inference engine, extracted from jni_wrapper.cpp so that
// Android (JNI) and Windows (FFI) run the exact same model lifecycle,
// generation loop, sampling chain and vision pipeline from one copy.
//
// The engine owns the process-global model/context state; the marshalling
// layers (jni_wrapper.cpp, windows/llama_ffi.cpp) only translate parameters
// and callbacks. One generation runs at a time, on the caller's thread.
#pragma once

#include <functional>
#include <string>

#include "llama.h"
#include "ggml-backend.h"

namespace plm {

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Everything llama-agnostic the generation loop needs. Mirrors the JNI
/// nativeGenerate call signature exactly.
struct SamplingParams {
    int max_tokens = 256;
    double temperature = 0.8;
    double top_p = 0.95;
    int top_k = 40;
    double min_p = 0.05;
    double typical_p = 1.0;
    double repeat_penalty = 1.1;
    double frequency_penalty = 0.0;
    double presence_penalty = 0.0;
    int repeat_last_n = 64;
    int mirostat = 0;
    double mirostat_tau = 5.0;
    double mirostat_eta = 0.1;
    long long seed = -1;  // -1: derive from the current time
    // Note: penalize_newline existed in the JNI signature but was never wired
    // into the sampler chain; it is kept out here until it actually does
    // something.
};

/// One streamed token piece (already UTF-8 decoded from the vocab).
/// Called synchronously, on the thread that runs generate().
using TokenSink = std::function<void(const std::string& piece)>;

/// Load progress; the engine invokes it with 1.0 once loading succeeded.
using LoadProgress = std::function<void(double)>;

// ---------------------------------------------------------------------------
// Engine API
// ---------------------------------------------------------------------------

bool isModelLoaded();
/// Whether a vision projector (mmproj) is loaded for the current model.
bool isVisionLoaded();

int tokensUsed();
int contextSize();
/// Clears the KV cache. Returns false when no context exists.
bool clearContext();
void stopGeneration();
void unloadModel();

/// Loads a GGUF (optionally spread across configured cluster workers).
/// Returns an empty string on success, or a user-facing error message.
/// `progress` is called with 1.0 after the model loaded; Android's JNI layer
/// used to make that exact final callback with a Double(1.0).
std::string loadModel(const char* model_path, int n_threads, int ctx_size,
                      int n_gpu_layers, const LoadProgress& progress);

/// Loads the vision projector for the current model. Returns empty on
/// success, or an error message (the text model stays loaded either way).
std::string loadMmproj(const char* path, int n_threads);

/// Runs one generation turn. `image_path` empty = text-only turn.
/// Returns empty on success, or an error message; state stays consistent.
std::string generate(const std::string& prompt, const std::string& image_path,
                     const SamplingParams& params, const TokenSink& token);

/// Describes the first local GPU registered by a loaded backend, with its
/// total memory in bytes. False when the GPU backend isn't loaded or no GPU
/// exists (cluster RPC workers never count as the local GPU).
bool detectGpu(std::string& description, long long& total_mem);

} // namespace plm

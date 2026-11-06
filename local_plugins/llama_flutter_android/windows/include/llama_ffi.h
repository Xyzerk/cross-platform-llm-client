// Windows C ABI for the llama engine core.
//
// Exported from llama_flutter_android.dll. The Dart side (lib/src/
// llama_host_ffi.dart, Phase 2) binds these with dart:ffi; each function is a
// thin shim over the same plm::engine the Android JNI layer uses, so both
// platforms run identical model lifecycle / generation / cluster logic.
//
// ABI rules:
//  - All functions are synchronous and single-threaded (one generation at a
//    time); plm_generate blocks until generation completes.
//  - All char* return values are malloc'd and must be released with
//    plm_free_string.
//  - Callbacks fire on the calling thread, while the call is in progress.
#pragma once

#include <stddef.h>

#ifdef _WIN32
  #define PLM_EXPORT __declspec(dllexport)
#else
  #define PLM_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Return codes.
#define PLM_OK 0
#define PLM_ERROR_FAILED 1        // see plm_last_error()
#define PLM_ERROR_VISION_FAILED 2 // model loaded, mmproj failed to load
#define PLM_ERROR_NOT_LOADED 3    // no model loaded

typedef void (*plm_progress_cb)(void* user_data, double progress);
typedef void (*plm_token_cb)(void* user_data, const char* piece);
typedef void (*plm_done_cb)(void* user_data, const char* error);

/// Loads a GGUF. Call plm_generate afterwards. `mmproj` (may be NULL) loads
/// the vision projector; a failure there does NOT fail the load — the return
/// code is PLM_ERROR_VISION_FAILED and text-only generation still works.
/// `progress` is invoked with 1.0 once the model loaded (may be NULL).
PLM_EXPORT int plm_load_model(const char* path, int threads, int ctx,
                              int gpu_layers, const char* mmproj,
                              plm_progress_cb progress, void* user);

/// Runs one generation turn and streams token pieces through `token_cb`;
/// the turn ends on EOS, a stop request (plm_stop), or `max_tokens`. `done_cb`
/// is always invoked exactly once, with a NULL error on success. Blocks.
///
/// `image_path` (may be NULL) makes this a vision turn: the prompt must
/// contain llama.cpp's `<__media__>` marker, which is replaced by the encoded
/// image. Text-only turns pass NULL.
PLM_EXPORT int plm_generate(const char* prompt, const char* image_path,
                            int max_tokens,
                            double temperature,
                            double top_p, int top_k, double min_p,
                            double typical_p,
                            double repeat_penalty, double frequency_penalty,
                            double presence_penalty, int repeat_last_n,
                            int mirostat, double mirostat_tau,
                            double mirostat_eta, long long seed,
                            plm_token_cb token_cb, plm_done_cb done_cb,
                            void* user);

/// Sets the stop flag for the running generation.
PLM_EXPORT void plm_stop(void);

/// Unloads the model and frees everything native (safe, and a no-op, when no
/// model is loaded).
PLM_EXPORT void plm_unload(void);

PLM_EXPORT int plm_is_model_loaded(void);

/// Human-readable context state:
/// {"modelLoaded":true,"tokensUsed":128,"contextSize":4096}.
PLM_EXPORT char* plm_context_info_json(void);

/// Clears the KV cache while keeping the model loaded. Returns 1 on success,
/// 0 when no context exists.
PLM_EXPORT int plm_clear_context(void);

/// {"name":"...","totalMb":12345} or NULL when no GPU backend/device exists.
PLM_EXPORT char* plm_detect_gpu_json(void);

/// Where the last model load put its weights: "<buffer name>\t<MiB>" lines.
PLM_EXPORT char* plm_last_load_buffers(void);

/// Currently free physical RAM in MiB.
PLM_EXPORT int plm_free_ram_mb(void);

/// Memory read bandwidth in GB/s with the machine's core count. Takes ~0.2 s.
PLM_EXPORT double plm_benchmark_bandwidth(void);

/// Registers the cluster workers these devices serve their weights through,
/// used by the NEXT plm_load_model call. `weights` may be NULL (every worker
/// gets weight 1); values <= 0 are clamped to 0.01.
PLM_EXPORT void plm_set_cluster(const char** endpoints, const float* weights,
                                int count, float local_weight);
PLM_EXPORT void plm_clear_cluster(void);

/// The error message of the last PLM_*_FAILED result, or NULL. Valid until
/// the next call into this function.
PLM_EXPORT const char* plm_last_error(void);

PLM_EXPORT void plm_free_string(char* s);

#ifdef __cplusplus
} // extern "C"
#endif

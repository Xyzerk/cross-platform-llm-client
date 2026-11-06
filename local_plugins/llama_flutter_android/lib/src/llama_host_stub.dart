// Web/no-io fallback for LlamaHost.
//
// The plugin is not used on web (inference_stub.dart handles cloud-only mode),
// but the library still has to compile there. Every operation reports a clear
// unsupported error instead of touching dart:ffi.
library;

import 'llama_api.dart';
import 'llama_host.dart';

LlamaHost createLlamaHost(LlamaHostEvents events) => _UnsupportedLlamaHost();

class _UnsupportedLlamaHost implements LlamaHost {
  Never _unsupported() => throw UnsupportedError(
      'Local GGUF inference is not available on this platform.');

  @override
  Future<void> loadModel(ModelConfig config) async => _unsupported();

  @override
  Future<void> generate(GenerateRequest request) async => _unsupported();

  @override
  Future<void> generateChat(ChatRequest request) async => _unsupported();

  @override
  Future<List<String>> getSupportedTemplates() async => const [];

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<bool> isModelLoaded() async => false;

  @override
  Future<ContextInfo> getContextInfo() async => _unsupported();

  @override
  Future<void> clearContext() async => _unsupported();

  @override
  void setSystemPromptLength(int length) {}

  @override
  Future<void> registerCustomTemplate(String name, String content) async {}

  @override
  Future<void> unregisterCustomTemplate(String name) async {}

  @override
  Future<GpuInfo> detectGpu() async => _unsupported();
}

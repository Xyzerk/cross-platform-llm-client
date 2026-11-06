// Pigeon-backed LlamaHost used on Android and iOS.
//
// This is a transparent adapter over the existing LlamaHostApi, so the native
// MethodChannel contract (and every error string) stays unchanged.
library;

import 'llama_api.dart';
import 'llama_host.dart';

class LlamaHostPigeon implements LlamaHost {
  LlamaHostPigeon({LlamaHostApi? api}) : _api = api ?? LlamaHostApi();

  final LlamaHostApi _api;

  @override
  Future<void> loadModel(ModelConfig config) => _api.loadModel(config);

  @override
  Future<void> generate(GenerateRequest request) => _api.generate(request);

  @override
  Future<void> generateChat(ChatRequest request) => _api.generateChat(request);

  @override
  Future<List<String>> getSupportedTemplates() => _api.getSupportedTemplates();

  @override
  Future<void> stop() => _api.stop();

  @override
  Future<void> dispose() => _api.dispose();

  @override
  Future<bool> isModelLoaded() => _api.isModelLoaded();

  @override
  Future<ContextInfo> getContextInfo() => _api.getContextInfo();

  @override
  Future<void> clearContext() => _api.clearContext();

  @override
  void setSystemPromptLength(int length) {
    // Fire-and-forget, exactly like the previous controller call.
    _api.setSystemPromptLength(length);
  }

  @override
  Future<void> registerCustomTemplate(String name, String content) =>
      _api.registerCustomTemplate(name, content);

  @override
  Future<void> unregisterCustomTemplate(String name) =>
      _api.unregisterCustomTemplate(name);

  @override
  Future<GpuInfo> detectGpu() => _api.detectGpu();
}

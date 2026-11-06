// Platform-neutral host abstraction for the llama engine.
//
// LlamaController talks to a LlamaHost instead of the Pigeon-generated
// LlamaHostApi directly. Android/iOS keep using the existing MethodChannel
// host; Windows gets an in-process dart:ffi host over
// llama_flutter_android.dll.
//
// The conditional export keeps dart:ffi out of web builds.
library;

import 'llama_api.dart';

export 'llama_host_stub.dart' if (dart.library.io) 'llama_host_io.dart'
    show createLlamaHost;

/// Streaming callbacks a host pushes to its controller.
class LlamaHostEvents {
  const LlamaHostEvents({
    required this.onToken,
    required this.onDone,
    required this.onError,
    required this.onLoadProgress,
  });

  final void Function(String token) onToken;
  final void Function() onDone;
  final void Function(String error) onError;
  final void Function(double progress) onLoadProgress;
}

/// The operations LlamaController needs, independent of transport.
abstract class LlamaHost {
  Future<void> loadModel(ModelConfig config);

  Future<void> generate(GenerateRequest request);

  Future<void> generateChat(ChatRequest request);

  Future<List<String>> getSupportedTemplates();

  Future<void> stop();

  Future<void> dispose();

  Future<bool> isModelLoaded();

  Future<ContextInfo> getContextInfo();

  Future<void> clearContext();

  /// Native no-op on Android and Windows; kept for API parity.
  void setSystemPromptLength(int length);

  Future<void> registerCustomTemplate(String name, String content);

  Future<void> unregisterCustomTemplate(String name);

  Future<GpuInfo> detectGpu();
}

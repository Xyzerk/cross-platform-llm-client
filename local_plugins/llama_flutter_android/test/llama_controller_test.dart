// Unit tests for LlamaController with an injected LlamaHost, so no platform
// channel or native library is involved.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llama_flutter_android/src/llama_api.dart';
import 'package:llama_flutter_android/src/llama_controller.dart';
import 'package:llama_flutter_android/src/llama_host.dart';

class _FakeHost implements LlamaHost {
  ModelConfig? loaded;
  GenerateRequest? generated;
  ChatRequest? generatedChat;
  GpuInfo? gpu;
  Object? loadError;

  bool modelLoaded = false;
  bool stopped = false;
  bool disposed = false;
  int cleared = 0;
  int systemPromptLength = -1;
  final templates = <String>['chatml'];

  @override
  Future<void> loadModel(ModelConfig config) async {
    if (loadError != null) throw loadError!;
    loaded = config;
    modelLoaded = true;
  }

  @override
  Future<void> generate(GenerateRequest request) async {
    generated = request;
  }

  @override
  Future<void> generateChat(ChatRequest request) async {
    generatedChat = request;
  }

  @override
  Future<List<String>> getSupportedTemplates() async => templates;

  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  Future<bool> isModelLoaded() async => modelLoaded;

  @override
  Future<ContextInfo> getContextInfo() async =>
      ContextInfo(tokensUsed: 10, contextSize: 2048, usagePercentage: 0.5);

  @override
  Future<void> clearContext() async {
    cleared++;
  }

  @override
  void setSystemPromptLength(int length) {
    systemPromptLength = length;
  }

  @override
  Future<void> registerCustomTemplate(String name, String content) async {
    templates.add(name);
  }

  @override
  Future<void> unregisterCustomTemplate(String name) async {
    templates.remove(name);
  }

  @override
  Future<GpuInfo> detectGpu() async =>
      gpu ??
      GpuInfo(
        vulkanSupported: false,
        gpuName: 'None',
        vulkanApiVersion: -1,
        deviceLocalMemoryBytes: -1,
        freeRamBytes: -1,
        recommendedGpuLayers: 0,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeHost host;
  late LlamaController controller;

  setUp(() {
    host = _FakeHost();
    controller = LlamaController(host: host);
  });

  tearDown(() async {
    await controller.dispose();
  });

  test('loadModel forwards the configuration', () async {
    final error = await controller.loadModel(
      modelPath: r'C:\models\model.gguf',
      threads: 6,
      contextSize: 4096,
      gpuLayers: 20,
      mmprojPath: r'C:\models\mmproj.gguf',
    );

    expect(error, isNull);
    expect(host.loaded!.modelPath, r'C:\models\model.gguf');
    expect(host.loaded!.nThreads, 6);
    expect(host.loaded!.contextSize, 4096);
    expect(host.loaded!.nGpuLayers, 20);
    expect(host.loaded!.mmprojPath, r'C:\models\mmproj.gguf');
  });

  test('loadModel returns the vision failure reason', () async {
    host.loadError = PlatformException(
      code: 'VISION_LOAD_FAILED',
      message: 'VISION_LOAD_FAILED: projector is not a GGUF file',
    );

    final error = await controller.loadModel(modelPath: 'model.gguf');

    expect(error, 'projector is not a GGUF file');
  });

  test('loadModel rethrows unrelated platform errors', () async {
    host.loadError = PlatformException(code: 'LOAD_FAILED', message: 'no ram');

    await expectLater(
      controller.loadModel(modelPath: 'model.gguf'),
      throwsA(isA<PlatformException>()),
    );
  });

  test('generate streams tokens until done', () async {
    final tokens = <String>[];
    final done = Completer<void>();
    controller.generate(prompt: 'hello').listen(tokens.add, onDone: done.complete);

    expect(host.generated!.prompt, 'hello');
    expect(controller.isGenerating, isTrue);

    controller.onToken('Hel');
    controller.onToken('lo');
    controller.onDone();
    await done.future;

    expect(tokens, ['Hel', 'lo']);
    expect(controller.isGenerating, isFalse);
  });

  test('errors reach the generation stream', () async {
    final failure = Completer<Object>();
    controller.generate(prompt: 'hello').listen((_) {}, onError: failure.complete);

    controller.onError('model crashed');

    expect(await failure.future, isA<Exception>());
    expect(controller.isGenerating, isFalse);
  });

  test('stop tells the host and ends generation', () async {
    controller.generate(prompt: 'hello');

    await controller.stop();

    expect(host.stopped, isTrue);
    expect(controller.isGenerating, isFalse);
  });

  test('detectGpu and context helpers delegate to the host', () async {
    final info = await controller.getContextInfo();
    await controller.clearContext();
    controller.setSystemPromptLength(42);
    final gpu = await controller.detectGpu();

    expect(info.tokensUsed, 10);
    expect(host.cleared, 1);
    expect(host.systemPromptLength, 42);
    expect(gpu.vulkanSupported, isFalse);
  });

  test('chat generation forwards messages', () async {
    final tokens = <String>[];
    final done = Completer<void>();
    controller
        .generateChat(messages: [ChatMessage(role: 'user', content: 'hi')])
        .listen(tokens.add, onDone: done.complete);

    expect(host.generatedChat!.messages.single.content, 'hi');

    controller.onToken('ok');
    controller.onDone();
    await done.future;

    expect(tokens, ['ok']);
  });
}

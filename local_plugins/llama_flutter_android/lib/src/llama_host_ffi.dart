// Windows LlamaHost: in-process dart:ffi over llama_flutter_android.dll.
//
// Blocking native calls (model load, generation) run in a short-lived worker
// isolate. Callbacks are created with NativeCallable.isolateLocal inside that
// worker, so token strings are read synchronously while the native pointer is
// still valid, then forwarded to the main isolate through a SendPort.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart' show PlatformException;

import 'chat_templates.dart';
import 'llama_api.dart';
import 'llama_host.dart';
import 'llama_windows_ffi.dart';

/// llama.cpp's vision marker, as used by the Android plugin.
const String _mediaMarker = '<__media__>';

class LlamaHostFfi implements LlamaHost {
  LlamaHostFfi(this._events);

  final LlamaHostEvents _events;

  LlamaWindowsBindings? _mainBindings;
  String? _modelPath;
  Future<void> _tail = Future<void>.value();
  _FfiRun? _activeRun;

  LlamaWindowsBindings get _bindings =>
      _mainBindings ??= LlamaWindowsBindings.open();

  /// Serializes calls that touch the model/context. [stop] deliberately does
  /// not go through this queue: it must be able to cut in mid-generation.
  Future<void> _enqueue(Future<void> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  @override
  Future<void> loadModel(ModelConfig config) => _enqueue(() async {
        final port = ReceivePort();
        final exitPort = ReceivePort();
        final outcome = Completer<_LoadOutcome>();

        void fail(String message) {
          if (!outcome.isCompleted) {
            outcome.complete(_LoadOutcome(-1, message));
          }
        }

        port.listen((message) {
          if (message is double) {
            _events.onLoadProgress(_normalizeProgress(message));
          } else if (message is _LoadOutcome && !outcome.isCompleted) {
            outcome.complete(message);
          }
        });

        // Usually the worker sends _LoadOutcome first; this only surfaces a
        // missing result (for example, an isolate-level exception).
        exitPort.listen((message) {
          if (outcome.isCompleted) return;
          Timer.run(() {
            if (outcome.isCompleted) return;
            fail(message is List && message.isNotEmpty
                ? 'Model load failed: ${message[0]}'
                : 'Model load stopped unexpectedly');
          });
        });

        final request = _LoadRequest(
          sendPort: port.sendPort,
          modelPath: config.modelPath,
          threads: config.nThreads,
          contextSize: config.contextSize,
          gpuLayers: config.nGpuLayers ?? 0,
          mmprojPath: config.mmprojPath,
        );

        unawaited(Isolate.spawn(
          _loadWorker,
          request,
          onExit: exitPort.sendPort,
          onError: exitPort.sendPort,
        ).then<void>((_) {}, onError: (Object error, StackTrace _) {
          fail('Model load failed: $error');
        }));

        final result = await outcome.future;
        port.close();
        exitPort.close();

        // Both PLM_OK and PLM_ERROR_VISION_FAILED mean the text model loaded.
        if (result.status == _plmOk || result.status == _plmVisionFailed) {
          _modelPath = config.modelPath;
        }

        if (result.status == _plmVisionFailed) {
          final reason = result.error ?? 'unknown error';
          throw PlatformException(
            code: 'VISION_LOAD_FAILED',
            message: 'VISION_LOAD_FAILED: $reason',
          );
        }
        if (result.status != _plmOk) {
          throw PlatformException(
            code: 'load-error',
            message: result.error ?? 'Failed to load model',
          );
        }

        _events.onLoadProgress(1.0);
      });

  @override
  Future<void> generate(GenerateRequest request) => _enqueue(() {
        return _runGeneration(
          prompt: request.prompt,
          imagePath: null,
          maxTokens: request.maxTokens,
          temperature: request.temperature,
          topP: request.topP,
          topK: request.topK,
          minP: request.minP,
          typicalP: request.typicalP,
          repeatPenalty: request.repeatPenalty,
          frequencyPenalty: request.frequencyPenalty,
          presencePenalty: request.presencePenalty,
          repeatLastN: request.repeatLastN,
          mirostat: request.mirostat,
          mirostatTau: request.mirostatTau,
          mirostatEta: request.mirostatEta,
          seed: request.seed ?? -1,
        );
      });

  @override
  Future<void> generateChat(ChatRequest request) => _enqueue(() {
        // Only the newest image is sent; earlier ones stay as text. Its
        // message gets llama.cpp's media marker, which the native side
        // replaces with the encoded image.
        var imageIndex = -1;
        for (var i = request.messages.length - 1; i >= 0; i--) {
          final path = request.messages[i].imagePath;
          if (path != null && path.trim().isNotEmpty) {
            imageIndex = i;
            break;
          }
        }
        final imagePath = imageIndex >= 0
            ? request.messages[imageIndex].imagePath
            : null;

        final messages = <TemplateChatMessage>[];
        for (var i = 0; i < request.messages.length; i++) {
          final message = request.messages[i];
          final content = i == imageIndex
              ? '$_mediaMarker\n${message.content}'
              : message.content;
          messages.add(TemplateChatMessage(message.role, content));
        }

        final prompt = ChatTemplateManager.instance.formatMessages(
          messages,
          templateName: request.template,
          modelPath: _modelPath,
        );

        return _runGeneration(
          prompt: prompt,
          imagePath: imagePath,
          maxTokens: request.maxTokens,
          temperature: request.temperature,
          topP: request.topP,
          topK: request.topK,
          minP: request.minP,
          typicalP: request.typicalP,
          repeatPenalty: request.repeatPenalty,
          frequencyPenalty: request.frequencyPenalty,
          presencePenalty: request.presencePenalty,
          repeatLastN: request.repeatLastN,
          mirostat: request.mirostat,
          mirostatTau: request.mirostatTau,
          mirostatEta: request.mirostatEta,
          seed: request.seed ?? -1,
        );
      });

  Future<void> _runGeneration({
    required String prompt,
    required String? imagePath,
    required int maxTokens,
    required double temperature,
    required double topP,
    required int topK,
    required double minP,
    required double typicalP,
    required double repeatPenalty,
    required double frequencyPenalty,
    required double presencePenalty,
    required int repeatLastN,
    required int mirostat,
    required double mirostatTau,
    required double mirostatEta,
    required int seed,
  }) {
    final port = ReceivePort();
    final exitPort = ReceivePort();
    final finished = Completer<void>();
    final run = _FfiRun();
    _activeRun = run;

    void finish(String? error) {
      // A stopped run must not leak its last token/done into the next reply.
      // Matches Android's isStopping suppression.
      if (!run.stopped) {
        if (error == null) {
          _events.onDone();
        } else {
          _events.onError(error);
        }
      }
      if (!finished.isCompleted) finished.complete();
    }

    port.listen((message) {
      if (message is String) {
        if (!run.stopped) _events.onToken(message);
      } else if (message is _GenerateDone) {
        finish(message.error);
      }
    });

    exitPort.listen((message) {
      if (finished.isCompleted) return;
      // Let any already-sent done message through first.
      Timer.run(() {
        if (finished.isCompleted) return;
        finish(message is List && message.isNotEmpty
            ? 'Generation failed: ${message[0]}'
            : 'Generation stopped unexpectedly');
      });
    });

    final request = _GenerateRequest(
      sendPort: port.sendPort,
      prompt: prompt,
      imagePath: imagePath,
      maxTokens: maxTokens,
      temperature: temperature,
      topP: topP,
      topK: topK,
      minP: minP,
      typicalP: typicalP,
      repeatPenalty: repeatPenalty,
      frequencyPenalty: frequencyPenalty,
      presencePenalty: presencePenalty,
      repeatLastN: repeatLastN,
      mirostat: mirostat,
      mirostatTau: mirostatTau,
      mirostatEta: mirostatEta,
      seed: seed,
    );

    unawaited(Isolate.spawn(
      _generateWorker,
      request,
      onExit: exitPort.sendPort,
      onError: exitPort.sendPort,
    ).then<void>((_) {}, onError: (Object error, StackTrace _) {
      finish('Generation failed: $error');
    }));

    return finished.future.whenComplete(() {
      port.close();
      exitPort.close();
      if (identical(_activeRun, run)) _activeRun = null;
    });
  }

  @override
  Future<void> stop() async {
    _activeRun?.stopped = true;
    _activeRun = null;
    try {
      _bindings.stop();
    } catch (_) {
      // The DLL may not be loaded yet; nothing is running in that case.
    }
  }

  @override
  Future<void> dispose() => _enqueue(() async {
        _bindings.unload();
        _modelPath = null;
      });

  @override
  Future<bool> isModelLoaded() async => _bindings.isModelLoaded();

  @override
  Future<ContextInfo> getContextInfo() async {
    final pointer = _bindings.contextInfoJson();
    if (pointer == nullptr) {
      return ContextInfo(
        tokensUsed: 0,
        contextSize: 0,
        usagePercentage: 0,
      );
    }
    try {
      final json =
          jsonDecode(pointer.toDartString()) as Map<String, dynamic>;
      final used = (json['tokensUsed'] as num?)?.toInt() ?? 0;
      final size = (json['contextSize'] as num?)?.toInt() ?? 0;
      return ContextInfo(
        tokensUsed: used,
        contextSize: size,
        usagePercentage: size > 0 ? used / size * 100.0 : 0.0,
      );
    } finally {
      _bindings.freeString(pointer);
    }
  }

  @override
  Future<void> clearContext() => _enqueue(() async {
        _bindings.clearContext();
      });

  @override
  void setSystemPromptLength(int length) {
    // Currently unused by the native engine, matching Android.
  }

  @override
  Future<void> registerCustomTemplate(String name, String content) async {
    ChatTemplateManager.instance.registerCustomTemplate(name, content);
  }

  @override
  Future<void> unregisterCustomTemplate(String name) async {
    ChatTemplateManager.instance.unregisterCustomTemplate(name);
  }

  @override
  Future<List<String>> getSupportedTemplates() async =>
      ChatTemplateManager.instance.getSupportedTemplates();

  @override
  Future<GpuInfo> detectGpu() async {
    final pointer = _bindings.detectGpuJson();
    if (pointer == nullptr) return _noGpu();

    try {
      final json = jsonDecode(pointer.toDartString()) as Map<String, dynamic>;
      final name = json['name'] as String? ?? 'None';
      final totalMb = (json['totalMb'] as num?)?.toInt() ?? -1;
      final freeMb = _bindings.freeRamMb();
      return GpuInfo(
        vulkanSupported: true,
        gpuName: name,
        // The Windows build does not expose a Vulkan API version yet.
        vulkanApiVersion: -1,
        deviceLocalMemoryBytes: totalMb >= 0 ? totalMb * 1024 * 1024 : -1,
        freeRamBytes: freeMb > 0 ? freeMb * 1024 * 1024 : -1,
        // llama.cpp clamps 99 to the model's actual layer count. The caller
        // still checks free RAM before offloading.
        recommendedGpuLayers: totalMb > 0 ? 99 : 0,
      );
    } finally {
      _bindings.freeString(pointer);
    }
  }

  static GpuInfo _noGpu() => GpuInfo(
        vulkanSupported: false,
        gpuName: 'None',
        vulkanApiVersion: -1,
        deviceLocalMemoryBytes: -1,
        freeRamBytes: -1,
        recommendedGpuLayers: 0,
      );

  static double _normalizeProgress(double progress) {
    if (progress.isNaN || progress.isInfinite) return 0.0;
    final normalized = progress > 1 ? progress / 100 : progress;
    return normalized.clamp(0.0, 1.0).toDouble();
  }
}

// -- Worker isolates --------------------------------------------------------

const int _plmOk = 0;
const int _plmVisionFailed = 2;

class _FfiRun {
  bool stopped = false;
}

class _LoadRequest {
  const _LoadRequest({
    required this.sendPort,
    required this.modelPath,
    required this.threads,
    required this.contextSize,
    required this.gpuLayers,
    required this.mmprojPath,
  });

  final SendPort sendPort;
  final String modelPath;
  final int threads;
  final int contextSize;
  final int gpuLayers;
  final String? mmprojPath;
}

class _LoadOutcome {
  const _LoadOutcome(this.status, this.error);

  final int status;
  final String? error;
}

class _GenerateRequest {
  const _GenerateRequest({
    required this.sendPort,
    required this.prompt,
    required this.imagePath,
    required this.maxTokens,
    required this.temperature,
    required this.topP,
    required this.topK,
    required this.minP,
    required this.typicalP,
    required this.repeatPenalty,
    required this.frequencyPenalty,
    required this.presencePenalty,
    required this.repeatLastN,
    required this.mirostat,
    required this.mirostatTau,
    required this.mirostatEta,
    required this.seed,
  });

  final SendPort sendPort;
  final String prompt;
  final String? imagePath;
  final int maxTokens;
  final double temperature;
  final double topP;
  final int topK;
  final double minP;
  final double typicalP;
  final double repeatPenalty;
  final double frequencyPenalty;
  final double presencePenalty;
  final int repeatLastN;
  final int mirostat;
  final double mirostatTau;
  final double mirostatEta;
  final int seed;
}

class _GenerateDone {
  const _GenerateDone(this.error);

  final String? error;
}

/// Runs the blocking model load on its own isolate. Progress is forwarded
/// synchronously through an isolate-local native callback.
@pragma('vm:entry-point')
void _loadWorker(_LoadRequest request) {
  final bindings = LlamaWindowsBindings.open();
  NativeCallable<PlmProgressNative>? progress;
  Pointer<Utf8> modelPath = nullptr;
  Pointer<Utf8> mmprojPath = nullptr;
  try {
    progress = NativeCallable<PlmProgressNative>.isolateLocal(
      (Pointer<Void> user, double value) => request.sendPort.send(value),
    );
    modelPath = request.modelPath.toNativeUtf8();
    if (request.mmprojPath != null && request.mmprojPath!.isNotEmpty) {
      mmprojPath = request.mmprojPath!.toNativeUtf8();
    }

    final status = bindings.loadModel(
      modelPath,
      request.threads,
      request.contextSize,
      request.gpuLayers,
      mmprojPath,
      progress.nativeFunction,
      nullptr,
    );
    request.sendPort.send(_LoadOutcome(status, bindings.lastErrorString()));
  } catch (error) {
    request.sendPort.send(_LoadOutcome(-1, '$error'));
  } finally {
    if (modelPath != nullptr) malloc.free(modelPath);
    if (mmprojPath != nullptr) malloc.free(mmprojPath);
    progress?.close();
  }
}

/// Runs one blocking generation turn. Tokens are copied to Dart before the
/// native callback returns, then sent to the main isolate in order.
@pragma('vm:entry-point')
void _generateWorker(_GenerateRequest request) {
  final bindings = LlamaWindowsBindings.open();
  NativeCallable<PlmTokenNative>? token;
  Pointer<Utf8> prompt = nullptr;
  Pointer<Utf8> imagePath = nullptr;
  try {
    token = NativeCallable<PlmTokenNative>.isolateLocal(
      (Pointer<Void> user, Pointer<Utf8> piece) =>
          request.sendPort.send(piece.toDartString()),
    );
    prompt = request.prompt.toNativeUtf8();
    if (request.imagePath != null && request.imagePath!.isNotEmpty) {
      imagePath = request.imagePath!.toNativeUtf8();
    }

    final status = bindings.generate(
      prompt,
      imagePath,
      request.maxTokens,
      request.temperature,
      request.topP,
      request.topK,
      request.minP,
      request.typicalP,
      request.repeatPenalty,
      request.frequencyPenalty,
      request.presencePenalty,
      request.repeatLastN,
      request.mirostat,
      request.mirostatTau,
      request.mirostatEta,
      request.seed,
      token.nativeFunction,
      nullptr, // done callback: status + last_error carry the result
      nullptr,
    );
    request.sendPort.send(_GenerateDone(
      status == _plmOk
          ? null
          : (bindings.lastErrorString() ?? 'Generation failed'),
    ));
  } catch (error) {
    request.sendPort.send(_GenerateDone('$error'));
  } finally {
    if (prompt != nullptr) malloc.free(prompt);
    if (imagePath != nullptr) malloc.free(imagePath);
    token?.close();
  }
}

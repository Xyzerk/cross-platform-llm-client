import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 1 smoke test from docs/windows-port-plan.md §4: calls into
/// `llama_flutter_android.dll`, loads a small GGUF and streams tokens.
///
/// Skipped unless this machine is Windows and `PRIVATELM_TEST_GGUF` points at
/// a GGUF model (the test needs a real model and a built DLL, both outside
/// CI's control):
///
/// ```
/// PRIVATELM_TEST_GGUF=path\to\model.gguf flutter test test/windows_engine_smoke_test.dart
/// ```
///
/// The DLL is looked up in `PRIVATELM_TEST_DLL`, falling back to the normal
/// debug build output directory.
void main() {
  final modelPath = Platform.environment['PRIVATELM_TEST_GGUF'];
  if (!Platform.isWindows || modelPath == null || modelPath.isEmpty) {
    return; // skipped; the test body below only runs with a model provided
  }

  late final ffi.DynamicLibrary lib;

  setUpAll(() {
    final dllPath = Platform.environment['PRIVATELM_TEST_DLL'] ??
        'build\\windows\\x64\\runner\\Debug\\llama_flutter_android.dll';
    lib = ffi.DynamicLibrary.open(dllPath);
  });

  test('loads a GGUF through llama_flutter_android.dll and streams tokens',
      () {
    final load = lib.lookupFunction<PlmLoadModelNative, PlmLoadModelDart>(
        'plm_load_model');
    final generate =
        lib.lookupFunction<PlmGenerateNative, PlmGenerateDart>('plm_generate');
    final isLoaded = lib.lookupFunction<ffi.Int Function(), int Function()>(
        'plm_is_model_loaded');
    final infoJson = lib.lookupFunction<ffi.Pointer<Utf8> Function(),
        ffi.Pointer<Utf8> Function()>('plm_context_info_json');
    final unload =
        lib.lookupFunction<ffi.Void Function(), void Function()>('plm_unload');
    final freeString = lib.lookupFunction<ffi.Void Function(ffi.Pointer<Utf8>),
        void Function(ffi.Pointer<Utf8>)>('plm_free_string');

    final tokenCallback = ffi.Pointer.fromFunction<
        ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>)>(_tokenSink);
    final doneCallback = ffi.Pointer.fromFunction<
        ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>)>(
        _doneSink);
    final progressCallback = ffi.Pointer.fromFunction<
        ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Double)>(_progressSink);
    final user = ffi.Pointer<ffi.Void>.fromAddress(0);
    final none = ffi.Pointer<Utf8>.fromAddress(0);

    final model = modelPath.toNativeUtf8();
    final status =
        load(model, 4, 4096, 0, none, progressCallback, user);
    calloc.free(model);
    expect(status, plmOk, reason: 'the model must load');

    final info = infoJson();
    final contextJson = jsonDecode(info.toDartString()) as Map<String, dynamic>;
    freeString(info);
    expect(contextJson['modelLoaded'], true);
    expect(contextJson['contextSize'] as int, greaterThan(0));

    final prompt = 'Say "works" and nothing else.'.toNativeUtf8();
    final tokenStatus = generate(
      prompt,
      none, // no image: text-only turn
      8, // max tokens — deliberately tiny, this is a smoke test
      0.0, // greedy
      1.0, // top_p off
      1, // top_k off
      1.0, // min_p off
      1.0, // typical_p off
      1.0, // repeat_penalty off
      0.0, // frequency_penalty off
      0.0, // presence_penalty off
      0, // repeat_last_n off
      0, // mirostat off
      0, // mirostat_tau
      0, // mirostat_eta
      42, // fixed seed, deterministic
      tokenCallback,
      doneCallback,
      user,
    );
    calloc.free(prompt);
    expect(tokenStatus, plmOk);
    expect(gStreamedTokens, isNotEmpty,
        reason: 'tokens streamed through the callback');

    unload();
    expect(isLoaded(), 0);
  });
}

const int plmOk = 0;

/// Guarded because native callbacks arrive while the FFI call is on-stack.
final List<String> gStreamedTokens = [];

void _tokenSink(ffi.Pointer<ffi.Void> user, ffi.Pointer<Utf8> piece) {
  gStreamedTokens.add(piece.toDartString());
}

/// `done_cb` receives NULL on success, so it must not dereference the string.
void _doneSink(ffi.Pointer<ffi.Void> user, ffi.Pointer<Utf8> error) {
  if (error != ffi.nullptr) gStreamedErrors.add(error.toDartString());
}

final List<String> gStreamedErrors = [];

void _progressSink(ffi.Pointer<ffi.Void> user, double progress) {}

// -- dart:ffi signature aliases for plm_load_model / plm_generate ------------

typedef PlmLoadModelNative = ffi.Int Function(
    ffi.Pointer<Utf8>,
    ffi.Int,
    ffi.Int,
    ffi.Int,
    ffi.Pointer<Utf8>,
    ffi.Pointer<
        ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Double)>>,
    ffi.Pointer<ffi.Void>);
typedef PlmLoadModelDart = int Function(
    ffi.Pointer<Utf8>,
    int,
    int,
    int,
    ffi.Pointer<Utf8>,
    ffi.Pointer<
        ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Double)>>,
    ffi.Pointer<ffi.Void>);

typedef PlmGenerateNative = ffi.Int Function(
    ffi.Pointer<Utf8>,
    ffi.Pointer<Utf8>,
    ffi.Int,
    ffi.Double,
    ffi.Double,
    ffi.Int,
    ffi.Double,
    ffi.Double,
    ffi.Double,
    ffi.Double,
    ffi.Double,
    ffi.Int,
    ffi.Int,
    ffi.Double,
    ffi.Double,
    ffi.LongLong,
    ffi.Pointer<
        ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>)>>,
    ffi.Pointer<
        ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>)>>,
    ffi.Pointer<ffi.Void>);
typedef PlmGenerateDart = int Function(
    ffi.Pointer<Utf8>,
    ffi.Pointer<Utf8>,
    int,
    double,
    double,
    int,
    double,
    double,
    double,
    double,
    double,
    int,
    int,
    double,
    double,
    int,
    ffi.Pointer<
        ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>)>>,
    ffi.Pointer<
        ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>)>>,
    ffi.Pointer<ffi.Void>);

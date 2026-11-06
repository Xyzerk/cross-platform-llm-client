// dart:ffi bindings for llama_flutter_android.dll.
//
// This file must only be reached through the io conditional import in
// llama_host.dart: web builds never see dart:ffi. Nothing here runs at import
// time, so importing it on Android/iOS is harmless too; the library is opened
// lazily by LlamaHostFfi and never constructed off Windows.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

const String plmWindowsDllName = 'llama_flutter_android.dll';

/// Resolves the plugin DLL next to the running executable.
///
/// Flutter's Windows runner copies bundled plugin DLLs beside privatelm.exe;
/// falling back to a bare name lets the OS search path handle developer
/// setups where the DLL lives elsewhere on PATH.
String resolveWindowsLibraryPath() {
  // Test/developer override, matching test/windows_engine_smoke_test.dart.
  final override = Platform.environment['PRIVATELM_TEST_DLL'];
  if (override != null && override.isNotEmpty) return override;

  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final bundled = '$exeDir\\$plmWindowsDllName';
  if (File(bundled).existsSync()) return bundled;
  return plmWindowsDllName;
}

// -- C ABI callback types ---------------------------------------------------

typedef PlmProgressNative = Void Function(Pointer<Void>, Double);
typedef PlmTokenNative = Void Function(Pointer<Void>, Pointer<Utf8>);

typedef PlmLoadModelNative = Int32 Function(
    Pointer<Utf8>,
    Int32,
    Int32,
    Int32,
    Pointer<Utf8>,
    Pointer<NativeFunction<PlmProgressNative>>,
    Pointer<Void>);
typedef PlmLoadModelDart = int Function(
    Pointer<Utf8>,
    int,
    int,
    int,
    Pointer<Utf8>,
    Pointer<NativeFunction<PlmProgressNative>>,
    Pointer<Void>);

typedef PlmGenerateNative = Int32 Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
    Int32,
    Double,
    Double,
    Int32,
    Double,
    Double,
    Double,
    Double,
    Double,
    Int32,
    Int32,
    Double,
    Double,
    Int64,
    Pointer<NativeFunction<PlmTokenNative>>,
    Pointer<NativeFunction<PlmTokenNative>>,
    Pointer<Void>);
typedef PlmGenerateDart = int Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
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
    Pointer<NativeFunction<PlmTokenNative>>,
    Pointer<NativeFunction<PlmTokenNative>>,
    Pointer<Void>);

/// Thin, typed wrapper around the Windows C ABI from `llama_ffi.h`.
class LlamaWindowsBindings {
  LlamaWindowsBindings(this._library);

  /// Opens the plugin DLL. Safe to call from any isolate: each isolate gets
  /// its own bindings object pointing at the same loaded module.
  factory LlamaWindowsBindings.open([String? path]) =>
      LlamaWindowsBindings(DynamicLibrary.open(path ?? resolveWindowsLibraryPath()));

  final DynamicLibrary _library;

  late final PlmLoadModelDart loadModel =
      _library.lookupFunction<PlmLoadModelNative, PlmLoadModelDart>(
          'plm_load_model');

  late final PlmGenerateDart generate =
      _library.lookupFunction<PlmGenerateNative, PlmGenerateDart>(
          'plm_generate');

  late final void Function() stop =
      _library.lookupFunction<Void Function(), void Function()>('plm_stop');

  late final void Function() unload =
      _library.lookupFunction<Void Function(), void Function()>('plm_unload');

  bool isModelLoaded() => _isModelLoadedRaw() != 0;

  late final int Function() _isModelLoadedRaw =
      _library.lookupFunction<Int32 Function(), int Function()>(
          'plm_is_model_loaded');

  late final Pointer<Utf8> Function() contextInfoJson =
      _library.lookupFunction<Pointer<Utf8> Function(),
          Pointer<Utf8> Function()>('plm_context_info_json');

  late final int Function() clearContext =
      _library.lookupFunction<Int32 Function(), int Function()>(
          'plm_clear_context');

  late final Pointer<Utf8> Function() detectGpuJson =
      _library.lookupFunction<Pointer<Utf8> Function(),
          Pointer<Utf8> Function()>('plm_detect_gpu_json');

  late final int Function() freeRamMb =
      _library.lookupFunction<Int32 Function(), int Function()>(
          'plm_free_ram_mb');

  late final Pointer<Utf8> Function() lastError =
      _library.lookupFunction<Pointer<Utf8> Function(),
          Pointer<Utf8> Function()>('plm_last_error');

  late final void Function(Pointer<Utf8>) freeString =
      _library.lookupFunction<Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)>('plm_free_string');

  /// The last PLM_*_FAILED error, or null. Copies before the next native call
  /// can overwrite the static buffer.
  String? lastErrorString() {
    final pointer = lastError();
    if (pointer == nullptr) return null;
    final message = pointer.toDartString();
    return message.isEmpty ? null : message;
  }
}

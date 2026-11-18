// dart:ffi bindings for the desktop engine library:
// llama_flutter_android.dll on Windows, libllama_flutter_android.so on Linux.
//
// This file must only be reached through the io conditional import in
// llama_host.dart: web builds never see dart:ffi. Nothing here runs at import
// time, so importing it on Android/iOS is harmless too; the library is opened
// lazily by LlamaHostFfi and never constructed on mobile.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

const String plmWindowsDllName = 'llama_flutter_android.dll';
const String plmLinuxLibraryName = 'libllama_flutter_android.so';

/// Resolves the plugin library for the running desktop platform.
///
/// Flutter copies bundled plugin libraries beside the executable on Windows
/// and into `bundle/lib/` on Linux. Falling back to a bare name lets the OS
/// search path handle developer setups where the library lives elsewhere.
String resolveDesktopLibraryPath() {
  // Test/developer override, matching test/windows_engine_smoke_test.dart and
  // the planned Linux smoke test.
  final override = Platform.environment['PRIVATELM_TEST_DLL'];
  if (override != null && override.isNotEmpty) return override;

  final exeDir = File(Platform.resolvedExecutable).parent.path;

  if (Platform.isLinux) {
    final bundled = '$exeDir/lib/$plmLinuxLibraryName';
    if (File(bundled).existsSync()) return bundled;
    final besideExe = '$exeDir/$plmLinuxLibraryName';
    if (File(besideExe).existsSync()) return besideExe;
    return plmLinuxLibraryName;
  }

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

/// Thin, typed wrapper around the desktop C ABI from `llama_ffi.h`.
class LlamaDesktopBindings {
  LlamaDesktopBindings(this._library);

  /// Opens the plugin library. Safe to call from any isolate: each isolate
  /// gets its own bindings object pointing at the same loaded module.
  factory LlamaDesktopBindings.open([String? path]) => LlamaDesktopBindings(
      DynamicLibrary.open(path ?? resolveDesktopLibraryPath()));

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

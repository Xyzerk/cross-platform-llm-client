// IO platform dispatch for LlamaHost.
//
// Android/iOS keep the existing Pigeon MethodChannel host; Windows uses the
// in-process FFI host over llama_flutter_android.dll.
library;

import 'dart:io' show Platform;

import 'llama_host.dart';
import 'llama_host_ffi.dart';
import 'llama_host_pigeon.dart';

LlamaHost createLlamaHost(LlamaHostEvents events) {
  if (Platform.isWindows) return LlamaHostFfi(events);
  return LlamaHostPigeon();
}

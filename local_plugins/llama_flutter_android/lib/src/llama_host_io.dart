// IO platform dispatch for LlamaHost.
//
// Android/iOS keep the existing Pigeon MethodChannel host; Windows and Linux
// use the in-process FFI host over the plugin engine library.
library;

import 'dart:io' show Platform;

import 'llama_host.dart';
import 'llama_host_ffi.dart';
import 'llama_host_pigeon.dart';

LlamaHost createLlamaHost(LlamaHostEvents events) {
  if (Platform.isWindows || Platform.isLinux) return LlamaHostFfi(events);
  return LlamaHostPigeon();
}

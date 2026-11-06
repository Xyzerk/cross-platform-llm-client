// End-to-end test of the Windows cluster master (Phase 5 of
// docs/windows-port-plan.md): a real privatelm_rpc_worker.exe on this PC,
// a cluster plan handed to the plugin DLL, and a load that makes the master
// connect to the worker over llama.cpp's RPC protocol.
//
// The model is a metadata-only GGUF stub: it carries an architecture and a
// block count, which is all the native planner reads, then fails to load (as
// it must). The interesting part is the handshake before that failure: the
// worker logs the master's address. That needs no real model, but does need a
// built app (`flutter build windows`), so the test skips on machines that
// never built one.
@TestOn('windows')
library;

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:path/path.dart' as p;
import 'package:privatelm/services/cluster_windows_backend.dart';

/// The worker is resolved like WindowsClusterBackend does, so a debug or
/// release build both work.
String? _workerExe() {
  final override = Platform.environment['PRIVATELM_TEST_WORKER'];
  if (override != null && override.isNotEmpty) {
    return File(override).existsSync() ? override : null;
  }
  for (final config in ['Debug', 'Profile', 'Release']) {
    final candidate =
        File('build/windows/x64/runner/$config/privatelm_rpc_worker.exe');
    if (candidate.existsSync()) return candidate.absolute.path;
  }
  return null;
}

String? _dll() {
  final override = Platform.environment['PRIVATELM_TEST_DLL'];
  if (override != null && override.isNotEmpty) {
    return File(override).existsSync() ? override : null;
  }
  for (final config in ['Debug', 'Profile', 'Release']) {
    final candidate =
        File('build/windows/x64/runner/$config/llama_flutter_android.dll');
    if (candidate.existsSync()) return candidate.absolute.path;
  }
  return null;
}

void main() {
  final exe = _workerExe();
  final dll = _dll();
  if (exe == null || dll == null) {
    test('Windows master (build the Windows app to run this)', () {},
        skip: 'privatelm_rpc_worker.exe or llama_flutter_android.dll is not '
            'built');
    return;
  }

  const port = 50180;

  test('plans a load onto a real worker and connects over RPC', () async {
    final backend = WindowsClusterBackend(workerExe: exe, dllPath: dll);
    final dir = await Directory.systemTemp.createTemp('plm_master_');
    // A status file of its own, so this test never races the worker test (or a
    // worker the developer is running) over the shared app status file.
    final statusFile = File(p.join(dir.path, 'worker.json'));
    final stub = File(p.join(dir.path, 'stub.gguf'));
    await stub.writeAsBytes(_stubGguf(blockCount: 4));

    // Started with pipes (not detached) so the worker's own log proves the
    // master connected. WindowsClusterBackend only needs the status file.
    final worker = await Process.start(exe, [
      '--host', '0.0.0.0',
      '--port', '$port',
      '--threads', '2',
      '--cache-dir', p.join(dir.path, 'cache'),
      '--status-file', statusFile.path,
      '--id', 'test-worker',
      '--model', 'test-worker',
    ]);
    final log = StringBuffer();
    final stderrDone = worker.stderr
        .transform(utf8.decoder)
        .listen(log.write)
        .asFuture<void>();
    final stdoutDone = worker.stdout
        .transform(utf8.decoder)
        .listen(log.write)
        .asFuture<void>();

    try {
      await _waitForStatus(statusFile);

      const local =
          ClusterWorker(name: 'local', host: '127.0.0.1', port: port);
      await backend.setCluster([local], weights: [1], localWeight: 0);

      // The stub cannot load, but the planner runs first: it registers the
      // worker and connects, which is the part Phase 5 has to get right.
      final lib = ffi.DynamicLibrary.open(dll);
      expect(_load(lib, stub.path), isNot(0),
          reason: 'a metadata-only GGUF must not load');

      final connected = await _waitFor(
          () => log.toString().contains('RPC client connected: 127.0.0.1'));
      expect(connected, isTrue,
          reason: 'the worker never saw the master connect over RPC.\n'
              'Worker log:\n$log');
    } finally {
      await backend.clear();
      worker.kill();
      await worker.exitCode.timeout(const Duration(seconds: 5),
          onTimeout: () => -1);
      await stderrDone.catchError((_) {});
      await stdoutDone.catchError((_) {});
      await dir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// Calls `plm_load_model` directly: the test does not need the whole host
/// isolate machinery to prove the master path works.
int _load(ffi.DynamicLibrary lib, String path) {
  final load = lib.lookupFunction<_LoadModelNative, _LoadModelDart>(
      'plm_load_model');
  final unload =
      lib.lookupFunction<ffi.Void Function(), void Function()>('plm_unload');
  final model = path.toNativeUtf8();
  final noMmproj = ffi.Pointer<Utf8>.fromAddress(0);
  final noProgress = ffi.Pointer<
          ffi.NativeFunction<
              ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Double)>>.fromAddress(0);
  final noUser = ffi.Pointer<ffi.Void>.fromAddress(0);
  try {
    return load(model, 2, 512, 0, noMmproj, noProgress, noUser);
  } finally {
    calloc.free(model);
    unload();
  }
}

Future<void> _waitForStatus(File file) async {
  // Starting a worker benchmarks memory bandwidth first, which can take a few
  // seconds when the rest of the test suite is loading the machine.
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  var last = 'the status file was never written';
  while (DateTime.now().isBefore(deadline)) {
    try {
      last = file.readAsStringSync();
      final json = jsonDecode(last) as Map<String, dynamic>;
      if (json['state'] == 'running') return;
      if (json['state'] == 'error') {
        throw StateError('the worker failed to start: ${json['error']}');
      }
    } on StateError {
      rethrow;
    } catch (_) {
      // Half-written, or briefly locked while the worker replaces it.
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw StateError('the worker never reported "running" (last: $last)');
}

Future<bool> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return condition();
}

/// A GGUF with the two keys `plm::readBlockCount` needs and no tensors, so
/// `gguf_init_from_file` succeeds and model loading fails right after the
/// cluster planner has connected to the workers.
List<int> _stubGguf({int blockCount = 4}) {
  final out = BytesBuilder();
  void u32(int value) {
    final data = ByteData(4)..setUint32(0, value, Endian.little);
    out.add(data.buffer.asUint8List());
  }

  void u64(int value) {
    final data = ByteData(8)..setUint64(0, value, Endian.little);
    out.add(data.buffer.asUint8List());
  }

  void str(String value) {
    final bytes = utf8.encode(value);
    u64(bytes.length);
    out.add(bytes);
  }

  out.add(ascii.encode('GGUF'));
  u32(3); // GGUF version
  u64(0); // tensors
  u64(2); // metadata entries
  str('general.architecture');
  u32(8); // GGUF_TYPE_STRING
  str('llama');
  str('llama.block_count');
  u32(4); // GGUF_TYPE_UINT32
  u32(blockCount);
  return out.toBytes();
}

typedef _LoadModelNative = ffi.Int Function(
    ffi.Pointer<Utf8>,
    ffi.Int,
    ffi.Int,
    ffi.Int,
    ffi.Pointer<Utf8>,
    ffi.Pointer<
        ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Double)>>,
    ffi.Pointer<ffi.Void>);
typedef _LoadModelDart = int Function(
    ffi.Pointer<Utf8>,
    int,
    int,
    int,
    ffi.Pointer<Utf8>,
    ffi.Pointer<
        ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Double)>>,
    ffi.Pointer<ffi.Void>);

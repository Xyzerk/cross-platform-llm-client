// Linux-only smoke test for the worker's parent watchdog: when the app that
// started privatelm_rpc_worker disappears, the worker must exit instead of
// keeping port 50052 bound for the next launch.
//
// Like desktop_worker_test.dart this needs a built worker, so it skips on a
// machine that has never run `flutter build linux`.
@TestOn('linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String? _workerExe() {
  final override = Platform.environment['PRIVATELM_TEST_WORKER'];
  if (override != null && override.isNotEmpty) {
    return File(override).existsSync() ? override : null;
  }
  for (final mode in ['debug', 'profile', 'release']) {
    final candidate =
        File('build/linux/x64/$mode/bundle/lib/privatelm_rpc_worker');
    if (candidate.existsSync()) return candidate.absolute.path;
  }
  return null;
}

String? _stateOf(File status) {
  try {
    final json = jsonDecode(status.readAsStringSync());
    return json is Map<String, dynamic> ? json['state'] as String? : null;
  } catch (_) {
    // The worker writes through a temp file and rename, so a failure here is
    // a real parse problem; treat it as "not ready yet" while starting.
    return null;
  }
}

Future<void> _awaitState(File status, String expected) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    if (_stateOf(status) == expected) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail('worker never reported "$expected" (last: ${_stateOf(status)})');
}

void main() {
  final exe = _workerExe();
  if (exe == null) {
    test('Linux worker watchdog (build the Linux app to run this)', () {},
        skip: 'privatelm_rpc_worker has not been built');
    return;
  }

  test('the worker exits when the app that started it disappears', () async {
    final dir = await Directory.systemTemp.createTemp('plm_worker_watchdog');
    final status = File('${dir.path}/status.json');
    // A stand-in for the Flutter app: the worker only knows its pid.
    final parent = await Process.start('sleep', ['60']);
    final worker = await Process.start(exe, [
      '--host',
      '127.0.0.1',
      '--port',
      '50173',
      '--threads',
      '1',
      '--cache-dir',
      dir.path,
      '--status-file',
      status.path,
      '--id',
      'watchdog-test',
      '--model',
      'test',
      '--parent-pid',
      '${parent.pid}',
    ]);
    // The worker is chatty while starting; drain so it can never block on a
    // full pipe.
    unawaited(worker.stdout.drain<void>());
    unawaited(worker.stderr.drain<void>());

    try {
      // "running" is written after the watchdog is armed.
      await _awaitState(status, 'running');

      parent.kill(ProcessSignal.sigkill);
      await parent.exitCode;

      final code = await worker.exitCode.timeout(const Duration(seconds: 20));
      expect(code, 0, reason: 'the watchdog should call _exit(0)');
    } finally {
      worker.kill(ProcessSignal.sigkill);
      parent.kill(ProcessSignal.sigkill);
      await dir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}

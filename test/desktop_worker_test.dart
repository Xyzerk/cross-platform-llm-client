// End-to-end test of the desktop cluster worker (Windows and Linux): starts
// the real privatelm_rpc_worker, checks the status file it publishes, and
// stops it again.
//
// It needs a built worker (`flutter build windows` / `flutter build linux`),
// so it skips on machines that have never built the app. Everything else in
// test/ runs without one.
@TestOn('windows || linux')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/services/cluster_desktop_backend.dart';

/// Resolved like DesktopClusterBackend does, so a debug or release build both
/// work.
String? _workerExe() {
  final override = Platform.environment['PRIVATELM_TEST_WORKER'];
  if (override != null && override.isNotEmpty) {
    return File(override).existsSync() ? override : null;
  }
  if (Platform.isWindows) {
    for (final config in ['Debug', 'Profile', 'Release']) {
      final candidate =
          File('build/windows/x64/runner/$config/privatelm_rpc_worker.exe');
      if (candidate.existsSync()) return candidate.absolute.path;
    }
    return null;
  }
  for (final mode in ['debug', 'profile', 'release']) {
    final candidate =
        File('build/linux/x64/$mode/bundle/lib/privatelm_rpc_worker');
    if (candidate.existsSync()) return candidate.absolute.path;
  }
  return null;
}

void main() {
  final exe = _workerExe();
  if (exe == null) {
    test('Desktop worker (build the desktop app to run this)', () {},
        skip: 'privatelm_rpc_worker has not been built');
    return;
  }
  // The backend normally finds the exe next to the app; the test runner has no
  // bundled copy, so it passes the built one in.
  test('starts, publishes its status, and stops', () async {
    final backend = DesktopClusterBackend(workerExe: exe);
    await backend.startWorker(port: 50170);

    final status = await backend.workerStatus();
    expect(status.running, isTrue);
    expect(status.ramMb, greaterThan(0));
    expect(status.bandwidth, greaterThan(0));
    expect(status.id, isNotNull);
    expect(await backend.probe('127.0.0.1:50170'), isTrue);

    await backend.stopWorker();
    expect((await backend.workerStatus()).state, 'stopped');
    expect(await backend.probe('127.0.0.1:50170'), isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a port already in use is reported, not swallowed', () async {
    final blocker = await ServerSocket.bind(InternetAddress.anyIPv4, 50171);
    final backend = DesktopClusterBackend(workerExe: exe);
    try {
      await expectLater(
        backend.startWorker(port: 50171),
        throwsA(predicate((e) => '$e'.contains('50171'))),
      );
      final status = await backend.workerStatus();
      expect(status.state, 'error');
      expect(status.error, contains('50171'));
    } finally {
      await backend.stopWorker();
      await blocker.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}

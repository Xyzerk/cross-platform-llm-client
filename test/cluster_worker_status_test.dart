// The desktop worker advertises itself through a JSON status file (see
// src/rpc_worker/status_writer_posix.cpp and status_writer_win.cpp). The app
// reads it with ClusterWorkerStatus.fromMap, the same factory the Android/iOS
// platform channel uses, so a shape change on either side is caught here.

import 'package:flutter_test/flutter_test.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

void main() {
  test('a running POSIX worker maps every field', () {
    final status = ClusterWorkerStatus.fromMap(const {
      'state': 'running',
      'ramMb': 15987,
      'bandwidth': 23.5,
      'heldMb': 4096,
      'throttled': false,
      'batteryUnrestricted': true,
      'pid': 4242,
      'id': 'worker-1',
      'peer': '192.168.1.5:51000',
    });

    expect(status.running, isTrue);
    expect(status.state, 'running');
    expect(status.ramMb, 15987);
    expect(status.bandwidth, 23.5);
    expect(status.heldMb, 4096);
    expect(status.id, 'worker-1');
    expect(status.peer, '192.168.1.5:51000');
    expect(status.error, isNull);
    expect(status.batteryUnrestricted, isTrue);
    expect(status.throttled, isFalse);
  });

  test('a reported error becomes the state unless the worker runs', () {
    final starting = ClusterWorkerStatus.fromMap(const {
      'state': 'starting',
      'error': 'Address already in use',
    });
    expect(starting.state, 'error');
    expect(starting.error, 'Address already in use');

    final running = ClusterWorkerStatus.fromMap(const {
      'state': 'running',
      'error': 'transient log line',
    });
    expect(running.running, isTrue);
    expect(running.error, 'transient log line');
  });

  test('missing and empty fields fall back to idle defaults', () {
    final status = ClusterWorkerStatus.fromMap(const {
      'state': 'starting',
      'error': '',
      'peer': '',
      'id': '',
    });

    expect(status.state, 'starting');
    expect(status.error, isNull);
    expect(status.peer, isNull);
    expect(status.id, isNull);
    expect(status.heldMb, 0);
    expect(status.ramMb, 0);
    expect(status.bandwidth, 0);
    expect(status.throttled, isFalse);
    expect(status.batteryUnrestricted, isTrue);

    final stopped = ClusterWorkerStatus.fromMap(const {});
    expect(stopped.state, 'stopped');
    expect(stopped.running, isFalse);
  });

  test('numeric fields accept ints and doubles', () {
    final status = ClusterWorkerStatus.fromMap(const {
      'state': 'running',
      'heldMb': 1,
      'ramMb': 2048,
      'bandwidth': 8,
    });

    expect(status.heldMb, 1);
    expect(status.ramMb, 2048);
    expect(status.bandwidth, 8.0);
  });
}

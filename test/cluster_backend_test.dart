// Windows-only: ClusterService.isSupported is false on the CI host (Linux), so
// these role/load-planning paths can only be exercised on a Windows machine.
@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:privatelm/core/constants.dart';
import 'package:privatelm/services/cluster_backend.dart';
import 'package:privatelm/services/cluster_service.dart';
import 'package:privatelm/services/hive_service.dart';

/// Records what ClusterService asks the platform layer to do.
class _FakeBackend implements ClusterBackend {
  final started = <String>[];
  final stopped = <String>[];
  int clearCalls = 0;
  int? localFreeRam;
  double speed = 10;
  List<ClusterWorker>? clusterWorkers;
  List<double>? clusterWeights;
  double? clusterLocalWeight;

  ClusterWorkerStatus status =
      const ClusterWorkerStatus(state: 'stopped', batteryUnrestricted: true);

  @override
  Future<void> startWorker({
    int port = ClusterBackend.defaultPort,
    int? threads,
    String? advertiseIp,
  }) async {
    started.add('$port');
    status = const ClusterWorkerStatus(
        state: 'running', ramMb: 4096, bandwidth: 12);
  }

  @override
  Future<void> stopWorker() async {
    stopped.add('stop');
    status = const ClusterWorkerStatus(state: 'stopped');
  }

  @override
  Future<ClusterWorkerStatus> workerStatus() async => status;

  @override
  Future<void> setKeepScreenOn(bool on) async {}

  @override
  Future<void> requestBatteryUnrestricted() async {}

  @override
  Future<bool?> firewallReady() async => true;

  @override
  Future<void> allowFirewall() async {}

  @override
  Future<int> localFreeRamMb() async => localFreeRam ?? 0;

  @override
  Future<double> benchmark() async => speed;

  @override
  Future<List<({String name, double mb})>> lastLoadBuffers() async => const [];

  @override
  Future<List<ClusterWorker>> discover({
    Duration timeout = const Duration(seconds: 4),
  }) async =>
      const [];

  @override
  Future<bool> probe(String endpoint) async => true;

  @override
  Future<void> setCluster(
    List<ClusterWorker> workers, {
    List<double>? weights,
    double localWeight = 1.0,
  }) async {
    clusterWorkers = workers;
    clusterWeights = weights;
    clusterLocalWeight = localWeight;
  }

  @override
  Future<void> clear() async {
    clearCalls++;
    clusterWorkers = null;
  }
}

void main() {
  late Directory dir;
  late HiveService hive;
  late _FakeBackend backend;
  late ClusterService service;

  ClusterWorker worker({int ramMb = 4096, double bandwidth = 12}) =>
      ClusterWorker(
        name: 'Worker',
        host: '192.168.1.20',
        port: ClusterBackend.defaultPort,
        ramMb: ramMb,
        bandwidth: bandwidth,
      );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cluster_backend_test');
    Hive.init(dir.path);
    hive = await HiveService().init();
    Get.put(hive);

    backend = _FakeBackend();
    ClusterBackend.overrideForTesting = backend;
    service = ClusterService();
  });

  tearDown(() async {
    service.onClose();
    ClusterBackend.overrideForTesting = null;
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
    Get.reset();
  });

  test('instance returns the test override', () {
    expect(ClusterBackend.instance, same(backend));
  });

  test('switching to master persists cluster mode', () async {
    await service.setRole(ClusterRole.master);

    expect(service.role, ClusterRole.master);
    expect(hive.getSetting<bool>(AppConstants.keyClusterEnabled), isTrue);
    expect(backend.started, isEmpty);
  });

  test('switching to worker starts the platform worker', () async {
    await service.setRole(ClusterRole.worker);

    expect(service.role, ClusterRole.worker);
    expect(backend.started, hasLength(1));
    expect(service.worker.value.running, isTrue);
    expect(hive.getSetting<bool>(AppConstants.keyClusterEnabled), isFalse);
  });

  test('applyForNextLoad clears the cluster when disabled', () async {
    expect(await service.applyForNextLoad(r'C:\models\model.gguf'), 0);
    expect(backend.clearCalls, 1);
  });

  test('applyForNextLoad fills the fastest worker first', () async {
    service.enabled.value = true;
    service.workers.add(worker());
    final model = File('${dir.path}${Platform.pathSeparator}model.gguf');
    await model.writeAsBytes(List.filled(1024 * 1024, 0));

    final used = await service.applyForNextLoad(model.path);

    expect(used, 1);
    expect(backend.clusterWorkers, hasLength(1));
    expect(backend.clusterWeights!.single, closeTo(1.1, 0.1));
    expect(backend.clusterLocalWeight, 0);
  });

  test('applyForNextLoad refuses a model that does not fit', () async {
    service.enabled.value = true;
    service.workers.add(worker(ramMb: 0));
    final model = File('${dir.path}${Platform.pathSeparator}big.gguf');
    await model.writeAsBytes(List.filled(200 * 1024, 0));

    await expectLater(
      service.applyForNextLoad(model.path),
      throwsA(isA<Exception>()),
    );
  });
}
